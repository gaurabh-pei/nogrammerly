using Microsoft.Windows.AI;
using Microsoft.Windows.AI.Text;
using Nogrammerly.Core;

namespace Nogrammerly;

/// <summary>
/// Grammar, clarity and tone checks and rewrites using Windows' on-device language model (Phi Silica),
/// which runs on the NPU of Copilot+ PCs. Text never leaves the PC. Every entry point degrades to
/// "no result" when the model is unavailable.
/// </summary>
internal static class AIWriter
{
    public enum Availability { Ready, NeedsDownload, DisabledByUser, Unsupported, NeedsInstall }

    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static readonly Dictionary<string, IReadOnlyList<WritingSuggestion>> ParagraphCache = [];
    private static LanguageModel? model;

    /// <summary>
    /// The Windows AI APIs only work for apps with package identity, which Install.ps1 provides;
    /// a copy run straight from the folder gets <see cref="Availability.NeedsInstall"/>.
    /// </summary>
    public static Availability Check()
    {
        try
        {
            return LanguageModel.GetReadyState() switch
            {
                AIFeatureReadyState.Ready => Availability.Ready,
                AIFeatureReadyState.NotReady => Availability.NeedsDownload,
                AIFeatureReadyState.DisabledByUser => Availability.DisabledByUser,
                _ => Availability.Unsupported,
            };
        }
        catch (Exception)
        {
            return Availability.NeedsInstall;
        }
    }

    public static bool IsReady => Check() == Availability.Ready;

    /// <summary>Asks Windows to install the model. Call only after the user agrees: it can be a large download.</summary>
    public static async Task<bool> DownloadAsync()
    {
        try { return (await LanguageModel.EnsureReadyAsync()).Status == AIFeatureReadyResultState.Success; }
        catch (Exception) { return false; }
    }

    /// <summary>Proofreads paragraph by paragraph; unchanged paragraphs come from cache, so typing only re-checks the edited one.</summary>
    public static async Task<IReadOnlyList<WritingSuggestion>> ProofreadAsync(string text, CancellationToken token)
    {
        if (!IsReady) return [];
        var found = new List<WritingSuggestion>();
        foreach (var (paragraph, span) in Proofreading.Paragraphs(text))
        {
            if (token.IsCancellationRequested) return [];
            IReadOnlyList<WritingSuggestion>? local;
            lock (ParagraphCache) ParagraphCache.TryGetValue(paragraph, out local);
            if (local is null)
            {
                var reply = await GenerateAsync(Proofreading.ProofreadPrompt(paragraph));
                if (token.IsCancellationRequested) return [];
                local = reply is null ? [] : Proofreading.ParseIssues(reply, paragraph);
                lock (ParagraphCache)
                {
                    if (ParagraphCache.Count > 500) ParagraphCache.Clear();
                    ParagraphCache[paragraph] = local;
                }
            }
            found.AddRange(local.Select(s => s with { Span = new TextSpan(s.Span.Start + span.Start, s.Span.Length) }));
        }
        return found;
    }

    public static async Task<string?> RewriteAsync(string text, WritingTone tone) =>
        IsReady ? Proofreading.CleanRewrite(await GenerateAsync(Proofreading.RewritePrompt(text, tone))) : null;

    /// <summary>Loads the model ahead of the first check, so the first underline does not wait for it.</summary>
    public static Task PrewarmAsync() => IsReady ? GenerateAsync("Reply with OK.") : Task.CompletedTask;

    private static async Task<string?> GenerateAsync(string prompt)
    {
        await Gate.WaitAsync();
        try
        {
            model ??= await LanguageModel.CreateAsync();
            var result = await model.GenerateResponseAsync(prompt);
            return string.IsNullOrWhiteSpace(result.Text) ? null : result.Text;
        }
        catch (Exception)
        {
            return null;
        }
        finally
        {
            Gate.Release();
        }
    }
}
