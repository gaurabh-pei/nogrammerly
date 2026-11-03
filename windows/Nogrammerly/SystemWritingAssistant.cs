using Nogrammerly.Core;

#if WINDOWS
using System.Collections.Concurrent;
using System.Drawing;
using System.Globalization;
using FlaUI.UIA3;
#endif

namespace Nogrammerly;

#if WINDOWS
/// <summary>An issue drawn on screen: one rectangle per line it covers, in physical screen pixels.</summary>
internal sealed record Mark(WritingSuggestion Suggestion, Rectangle[] Rects);

/// <summary>What the UI shows for the focused field. Immutable, so it can cross from the worker thread to the UI thread.</summary>
internal sealed record FieldState(IReadOnlyList<WritingSuggestion> Suggestions, IReadOnlyList<Mark> Marks, Rectangle? Frame, bool HasSelection)
{
    public static readonly FieldState None = new([], [], null, false);
    public bool IsActive => Frame is not null;
}

/// <summary>
/// Grammarly-style assistance in other apps. A worker thread watches the focused control through UI Automation,
/// checks its text, and publishes a <see cref="FieldState"/> that the UI thread draws as underlines.
/// UI Automation calls are cross-process and can block, so they never run on the UI thread.
/// </summary>
internal sealed class SystemWritingAssistant : IDisposable
{
    private const int PollMilliseconds = 450;
    private const int MaxMarks = 60;

    private readonly BlockingCollection<Action> work = new();
    private readonly Thread worker;
    private readonly SynchronizationContext ui;
    private readonly SpellChecker spellChecker = new(CultureInfo.CurrentUICulture.Name);
    private readonly HashSet<string> ignored = [];
    private readonly int ownProcessId = Environment.ProcessId;
    private readonly LmStudioWriter lmStudio;
    private volatile bool running = true;

    // Worker-thread state.
    private UIA3Automation? automation;
    private TextField? field;
    private string text = "";
    private IReadOnlyList<WritingSuggestion> suggestions = [];
    private CancellationTokenSource? proofread;
    private CancellationTokenSource? rewrite;
    private AppSettings settings = AppSettings.Default;
    private long generation;   // bumped on every settings update; invalidates in-flight AI work
    private int fieldSerial;   // bumped whenever the watched field changes, even for identical text

    /// <summary>Raised on the UI thread whenever the focused field's state changes.</summary>
    public event Action<FieldState>? StateChanged;
    /// <summary>Raised on the UI thread with a message for the user.</summary>
    public event Action<string>? Notice;

    public SystemWritingAssistant(AppSettings settings, LmStudioWriter lmStudio)
    {
        this.settings = settings;
        this.lmStudio = lmStudio;
        ui = SynchronizationContext.Current ?? throw new InvalidOperationException("Create on the UI thread.");
        // UI Automation clients should run on an MTA thread of their own.
        worker = new Thread(Run) { IsBackground = true, Name = "UI Automation" };
        worker.SetApartmentState(ApartmentState.MTA);
        worker.Start();
    }

    public bool IsRunning => running;

    public void SetRunning(bool value)
    {
        running = value;
        if (!value) work.Add(Reset);
    }

    /// <summary>
    /// Applies a new provider selection on the worker queue: cancels in-flight AI work, bumps the
    /// generation so stale results are discarded, and forces a fresh analysis of the current field.
    /// </summary>
    public void UpdateSettings(AppSettings settings) => work.Add(() =>
    {
        this.settings = settings;
        generation++;
        proofread?.Cancel();
        rewrite?.Cancel();
        text = ""; // the next poll re-analyses the field the user is in, with the new provider
    });

    // Commands from the UI. Each re-checks that the suggestion is still live, so a stale menu can't act on old text.

    public void Apply(WritingSuggestion suggestion) => work.Add(() =>
    {
        if (Live(suggestion) is { Replacement: { } replacement } live) ReplaceText(live.Span, live.Original, replacement);
    });

    public void Ignore(WritingSuggestion suggestion) => work.Add(() =>
    {
        ignored.Add(suggestion.IgnoreKey);
        Publish(suggestions.Where(s => s.IgnoreKey != suggestion.IgnoreKey).ToList());
    });

    public void Learn(WritingSuggestion suggestion) => work.Add(() =>
    {
        spellChecker.Learn(suggestion.Original);
        Publish(suggestions.Where(s => !(s.IsSpelling && s.Original == suggestion.Original)).ToList());
    });

    public void RewriteSentence(WritingSuggestion suggestion, WritingTone tone) => work.Add(() =>
    {
        if (Live(suggestion) is { } live) Rewrite(WritingEngine.SentenceSpan(live.Span, text), tone);
    });

    public void RewriteSelection(WritingTone tone) => work.Add(() =>
    {
        if (field?.Selection() is { Length: > 0 } selection && selection.End <= text.Length) Rewrite(selection, tone);
    });

    public void RewriteAll(WritingTone tone) => work.Add(() => Rewrite(new TextSpan(0, text.Length), tone));

    // Worker thread.

    private void Run()
    {
        automation = new UIA3Automation();
        while (!work.IsCompleted)
        {
            if (work.TryTake(out var action, PollMilliseconds))
            {
                Safely(action);
                continue;
            }
            if (running) Safely(Poll);
        }
        automation.Dispose();
    }

    private void Safely(Action action)
    {
        try { action(); }
        catch (Exception) { Reset(); } // A control that disappears mid-call; the next poll starts afresh.
    }

    private void Poll()
    {
        // While one of our own menus is open, keep the state for the field the user was in.
        if (NativeMethods.ForegroundProcessId() == ownProcessId) return;
        var focused = TextField.From(automation!.FocusedElement());
        var value = focused?.ReadText();
        if (focused is null || string.IsNullOrEmpty(value) || value.Length > WritingEngine.MaxLength) { Reset(); return; }

        if (field is null || !field.IsSameElement(focused) || value != text)
        {
            field = focused;
            text = value;
            fieldSerial++; // pending work for the previous field is stale even if the text is identical
            suggestions = WritingEngine.Analyze(value, spellChecker.Check).Suggestions.Where(s => !ignored.Contains(s.IgnoreKey)).ToList();
            ScheduleProofread(value);
        }
        Publish(suggestions);
    }

    /// <summary>Debounced AI pass through the explicitly selected provider; merges its findings behind the instant spelling and style results.</summary>
    private void ScheduleProofread(string value)
    {
        proofread?.Cancel();
        proofread?.Dispose(); // the previous pass is already cancelled; release its handle
        if (settings.Provider == AiProvider.RulesOnly) return; // no AI call at all
        if (settings.Provider == AiProvider.PhiSilica && !AIWriter.IsReady) return;
        var cancellation = proofread = new CancellationTokenSource();
        var selected = settings;
        var ticket = new WorkTicket(generation, fieldSerial, value);
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(900, cancellation.Token);
                var found = await ProviderRouting.ProofreadAsync(selected, value, lmStudio, AIWriter.ProofreadAsync, cancellation.Token);
                if (cancellation.IsCancellationRequested || found.Count == 0) return;
                work.Add(() =>
                {
                    if (!ticket.Current(generation, fieldSerial, text)) return;
                    suggestions = WritingEngine.Merge(suggestions, found.Where(s => !ignored.Contains(s.IgnoreKey)));
                    Publish(suggestions);
                });
            }
            catch (Exception) { } // cancelled or provider failed: the deterministic rules already on screen stand
        }, cancellation.Token);
    }

    private void Publish(IReadOnlyList<WritingSuggestion> current)
    {
        suggestions = current;
        if (field is null) { Post(FieldState.None); return; }
        var frame = field.Frame();
        var marks = new List<Mark>();
        if (frame is { } visible && field.HasLayout)
        {
            var clip = Rectangle.Inflate(visible, 2, 2);
            foreach (var suggestion in current.Take(MaxMarks))
            {
                // Lines scrolled out of view, or reported outside the control, are not drawn over other windows.
                var rects = field.Bounds(suggestion.Span).Where(r => r is { Width: > 0, Height: > 0 and < 120 } && clip.Contains(r)).ToArray();
                if (rects.Length > 0) marks.Add(new Mark(suggestion, rects));
            }
        }
        Post(new FieldState(current, marks, frame, field.HasSelectedText()));
    }

    private void Reset()
    {
        proofread?.Cancel();
        rewrite?.Cancel();
        if (field is null && suggestions.Count == 0) return;
        field = null; text = ""; suggestions = [];
        fieldSerial++; // pending work for the field we just dropped must not come back
        Post(FieldState.None);
    }

    private WritingSuggestion? Live(WritingSuggestion suggestion) => suggestions.FirstOrDefault(s => s.Id == suggestion.Id);

    private void Rewrite(TextSpan span, WritingTone tone)
    {
        if (field is null || span.Length == 0 || span.End > text.Length) return;
        var original = text.Substring(span.Start, span.Length);
        var cancellation = rewrite = new CancellationTokenSource();
        var selected = settings;
        var ticket = new WorkTicket(generation, fieldSerial, text);
        Say(selected.Provider == AiProvider.PhiSilica && !AIWriter.IsReady || selected.Provider == AiProvider.RulesOnly
            ? "Rewriting with built-in rules (the selected AI is not available)…" : "Rewriting…");
        _ = Task.Run(async () =>
        {
            try
            {
                var rewritten = await ProviderRouting.RewriteAsync(selected, original, tone, lmStudio, AIWriter.RewriteAsync, cancellation.Token);
                work.Add(() =>
                {
                    // A settings change, pause or field switch since the request started discards it.
                    if (!ticket.Current(generation, fieldSerial, text)) return;
                    ReplaceText(span, original, rewritten);
                });
            }
            catch (Exception) { } // cancelled or failed: nothing is replaced, no unobserved exception
        }, cancellation.Token);
    }

    /// <summary>Replaces <paramref name="span"/> only if it still contains <paramref name="expected"/>, so a stale suggestion can never overwrite newer typing.</summary>
    private void ReplaceText(TextSpan span, string expected, string replacement)
    {
        if (field is null) return;
        // Give the app a moment to take focus back from our menu.
        Thread.Sleep(80);
        var current = field.ReadText();
        if (current is null || span.End > current.Length || current.Substring(span.Start, span.Length) != expected)
        {
            Say("The text changed, so that suggestion was skipped.");
            return;
        }
        if (!field.Replace(span, replacement, current))
            Say("This app didn't let Nogrammerly edit its text. Use Copy suggestion instead.");
        text = ""; // Force a fresh check on the next poll.
    }

    private void Post(FieldState state) => ui.Post(_ => StateChanged?.Invoke(state), null);
    private void Say(string message) => ui.Post(_ => Notice?.Invoke(message), null);

    public void Dispose()
    {
        proofread?.Cancel();
        rewrite?.Cancel();
        work.CompleteAdding();
        worker.Join(TimeSpan.FromSeconds(2));
        proofread?.Dispose();
        rewrite?.Dispose();
    }
}
#endif

// Narrow test seam (kept outside #if WINDOWS so routing and staleness rules are testable off Windows):
// pure provider dispatch and the staleness gate the worker checks before publishing or replacing.

/// <summary>Snapshot of the work a pending AI call belongs to; a result may only land on a still-current field.</summary>
internal readonly record struct WorkTicket(long Generation, int FieldSerial, string Text)
{
    public bool Current(long generation, int fieldSerial, string text)
        => Generation == generation && FieldSerial == fieldSerial && Text == text;
}

internal static class ProviderRouting
{
    /// <summary>Runs the selected provider only. A failure yields no findings — never another AI.</summary>
    public static async Task<IReadOnlyList<WritingSuggestion>> ProofreadAsync(
        AppSettings settings, string text, LmStudioWriter lmStudio,
        Func<string, CancellationToken, Task<IReadOnlyList<WritingSuggestion>>> phi,
        CancellationToken token)
    {
        try
        {
            return settings.Provider switch
            {
                AiProvider.PhiSilica => await phi(text, token),
                AiProvider.LmStudio => await lmStudio.ProofreadAsync(text, settings, token),
                _ => [], // RulesOnly: no AI call at all
            };
        }
        catch (Exception) { return []; } // cancellation or provider failure: deterministic rules already on screen stand
    }

    /// <summary>Rewrites with the selected provider only; on failure or RulesOnly falls back to the deterministic rules rewrite.</summary>
    public static async Task<string> RewriteAsync(
        AppSettings settings, string text, WritingTone tone, LmStudioWriter lmStudio,
        Func<string, WritingTone, Task<string?>> phi,
        CancellationToken token)
    {
        string? rewritten = null;
        try
        {
            rewritten = settings.Provider switch
            {
                AiProvider.PhiSilica => await phi(text, tone),
                AiProvider.LmStudio => await lmStudio.RewriteAsync(text, tone, settings, token),
                _ => null, // RulesOnly: no AI call at all
            };
        }
        catch (Exception) { }
        return rewritten ?? WritingEngine.Rewrite(text, tone);
    }
}
