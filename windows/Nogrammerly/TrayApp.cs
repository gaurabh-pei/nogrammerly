using System.Drawing;
using System.Runtime.InteropServices;
using Nogrammerly.Core;
using static Nogrammerly.NativeMethods;

namespace Nogrammerly;

/// <summary>
/// The app's UI: a notification-area icon with the field's suggestions, underlines over the field,
/// a round button in the field's corner, and a menu when the user right-clicks an underline.
/// </summary>
internal sealed class TrayApp : ApplicationContext
{
    private readonly SynchronizationContext ui = SynchronizationContext.Current!;
    private AppSettings settings;
    private readonly LmStudioWriter lmStudio = new();
    private readonly SystemWritingAssistant assistant;
    private readonly NotifyIcon tray = new();
    private readonly UnderlineOverlay overlay = new();
    private readonly FieldButton fieldButton;
    private readonly MenuHost menuHost = new();
    private readonly LowLevelMouseProc hookProc;
    private readonly IntPtr hook;
    private FieldState state = FieldState.None;
    private bool swallowRightButtonUp;

    public TrayApp(bool firstRun)
    {
        settings = AppSettings.Load(AppSettings.ProductionPath, out var settingsError);
        assistant = new SystemWritingAssistant(settings, lmStudio);
        fieldButton = new FieldButton(() => ShowMenu(BuildFieldMenu()));
        tray.Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? SystemIcons.Application;
        tray.Text = "Nogrammerly";
        tray.Visible = true;
        tray.ContextMenuStrip = new ContextMenuStrip();
        tray.ContextMenuStrip.Opening += (_, e) => { RebuildTrayMenu(tray.ContextMenuStrip); e.Cancel = false; };
        tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ShowMenu(BuildFieldMenu()); };

        assistant.StateChanged += Render;
        assistant.Notice += message => tray.ShowBalloonTip(4000, "Nogrammerly", message, ToolTipIcon.None);

        // Kept in a field: the hook must not be garbage collected while Windows still calls it.
        hookProc = MouseHook;
        hook = SetWindowsHookEx(WH_MOUSE_LL, hookProc, GetModuleHandle(null), 0);

        _ = AIWriter.PrewarmAsync();
        if (settingsError is not null) tray.ShowBalloonTip(6000, "Nogrammerly", settingsError, ToolTipIcon.None);
        if (firstRun) Welcome();
    }

    private void Render(FieldState newState)
    {
        state = newState;
        overlay.ShowMarks(state.Marks);
        if (state.Frame is { } frame) fieldButton.ShowFor(frame, state.Suggestions.Count); else fieldButton.Hide();
        var count = state.Suggestions.Count;
        tray.Text = !assistant.IsRunning ? "Nogrammerly (paused)" : count == 0 ? "Nogrammerly" : $"Nogrammerly: {count} suggestion{(count == 1 ? "" : "s")}";
    }

    // Right-click on an underline. Runs on the UI thread for every mouse event system-wide, so it must stay quick.

    private IntPtr MouseHook(int code, IntPtr message, IntPtr data)
    {
        if (code >= 0 && assistant.IsRunning)
        {
            if (message == WM_RBUTTONDOWN)
            {
                var info = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(data);
                var point = new Point(info.pt.X, info.pt.Y);
                var hit = state.Marks.FirstOrDefault(m => m.Rects.Any(r => Rectangle.Inflate(r, 2, 4).Contains(point)));
                if (hit is not null)
                {
                    swallowRightButtonUp = true;
                    ui.Post(_ => ShowMenu(BuildSuggestionMenu(hit.Suggestion)), null);
                    return 1;
                }
            }
            else if (message == WM_RBUTTONUP && swallowRightButtonUp)
            {
                swallowRightButtonUp = false;
                return 1;
            }
        }
        return CallNextHookEx(hook, code, message, data);
    }

    // Menus.

    private void ShowMenu(ContextMenuStrip menu) => menuHost.Pop(menu, Cursor.Position);

    private ContextMenuStrip BuildSuggestionMenu(WritingSuggestion suggestion)
    {
        var menu = new ContextMenuStrip();
        AddSuggestionItems(menu.Items, suggestion);
        return menu;
    }

    private ContextMenuStrip BuildFieldMenu()
    {
        var menu = new ContextMenuStrip();
        var count = state.Suggestions.Count;
        Header(menu.Items, !state.IsActive ? "Click into a text field to check it" : count == 0 ? "No issues found" : $"{count} suggestion{(count == 1 ? "" : "s")}");
        if (state.IsActive)
        {
            menu.Items.Add(new ToolStripSeparator());
            AddFieldItems(menu.Items);
        }
        return menu;
    }

    private void RebuildTrayMenu(ContextMenuStrip menu)
    {
        menu.Items.Clear();
        var count = state.Suggestions.Count;
        Header(menu.Items, !assistant.IsRunning ? "Paused" : !state.IsActive ? "Watching for a text field…" : $"{count} suggestion{(count == 1 ? "" : "s")} in this field");
        AddAIStatus(menu.Items);
        if (assistant.IsRunning && state.IsActive)
        {
            menu.Items.Add(new ToolStripSeparator());
            AddFieldItems(menu.Items);
        }
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(assistant.IsRunning ? "Pause" : "Resume", null, (_, _) => { assistant.SetRunning(!assistant.IsRunning); Render(FieldState.None); });
        menu.Items.Add("How to use…", null, (_, _) => Welcome());
        menu.Items.Add("Quit Nogrammerly", null, (_, _) => ExitThread());
    }

    private void AddAIStatus(ToolStripItemCollection items)
    {
        var phi = (PhiState)AIWriter.Check();
        Header(items, ProviderStatus.StatusText(settings.Provider, phi, lmStudio.LastError));
        var pick = new ToolStripMenuItem($"AI provider: {ProviderStatus.Name(settings.Provider)}");
        foreach (var provider in Enum.GetValues<AiProvider>())
            pick.DropDownItems.Add(new ToolStripMenuItem(ProviderStatus.Name(provider), null, (_, _) => SelectProvider(provider)) { Checked = provider == settings.Provider });
        pick.DropDownItems.Add(new ToolStripSeparator());
        pick.DropDownItems.Add("LM Studio settings…", null, (_, _) => EditLmStudioSettings());
        items.Add(pick);
        if (ProviderStatus.ShowPhiSetup(settings.Provider, phi))
            items.Add("Set up on-device AI…", null, async (_, _) => await OfferDownload());
    }

    /// <summary>Sticky provider choice: persisted, then handed to the worker, which cancels stale AI work.</summary>
    private void SelectProvider(AiProvider provider)
    {
        var next = settings with { Provider = provider };
        if (!next.TryValidate(out var error))
        {
            Warn($"LM Studio needs a URL and a model ID before it can be selected.\n\n{error}\n\nUse “LM Studio settings…” to configure them.");
            return;
        }
        SaveSettings(next);
    }

    private bool SaveSettings(AppSettings next)
    {
        try { next.Save(AppSettings.ProductionPath); }
        catch (Exception e) { Warn($"Nogrammerly couldn't save its settings: {e.Message}"); return false; }
        settings = next;
        assistant.UpdateSettings(next);
        return true;
    }

    private void EditLmStudioSettings()
    {
        using var dialog = new LmStudioSettingsDialog(settings, lmStudio, SaveSettings);
        dialog.ShowDialog();
    }

    private void Warn(string message) => MessageBox.Show(message, "Nogrammerly", MessageBoxButtons.OK, MessageBoxIcon.Warning);

    private async Task OfferDownload()
    {
        var answer = MessageBox.Show(
            "Nogrammerly can use the language model built into Windows for AI grammar checks and rewrites. " +
            "It runs entirely on this PC.\n\nWindows may need to download it first (it can be several GB, through Windows Update). " +
            "You can remove it later in Settings › System › AI Components.\n\nSet it up now?",
            "Nogrammerly", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
        if (answer != DialogResult.Yes) return;
        tray.ShowBalloonTip(4000, "Nogrammerly", "Setting up on-device AI. Progress is shown in Settings › Windows Update.", ToolTipIcon.None);
        var ready = await AIWriter.DownloadAsync();
        tray.ShowBalloonTip(4000, "Nogrammerly", ready ? "On-device AI is ready." : "On-device AI couldn't be set up on this PC.", ToolTipIcon.None);
    }

    /// <summary>Suggestions for the focused field plus rewrite actions; shared by the field button and the tray icon.</summary>
    private void AddFieldItems(ToolStripItemCollection items)
    {
        foreach (var suggestion in state.Suggestions.Take(15))
        {
            var original = suggestion.Original.Length > 40 ? suggestion.Original[..40] + "…" : suggestion.Original;
            var item = new ToolStripMenuItem($"{original} — {suggestion.Title}");
            AddSuggestionItems(item.DropDownItems, suggestion);
            items.Add(item);
        }
        if (state.Suggestions.Count > 0) items.Add(new ToolStripSeparator());
        if (state.HasSelection) items.Add(ToneMenu("Rewrite selection", assistant.RewriteSelection));
        items.Add(ToneMenu("Rewrite entire text", assistant.RewriteAll));
    }

    private void AddSuggestionItems(ToolStripItemCollection items, WritingSuggestion suggestion)
    {
        Header(items, $"{suggestion.Kind} · {suggestion.Title}");
        Header(items, suggestion.Explanation);
        items.Add(new ToolStripSeparator());
        if (suggestion.Replacement is { } replacement)
        {
            var bold = items.Add($"Replace with “{(replacement.Length == 0 ? "(remove)" : replacement)}”", null, (_, _) => assistant.Apply(suggestion));
            bold.Font = new Font(bold.Font, FontStyle.Bold);
            items.Add("Copy suggestion", null, (_, _) => { if (replacement.Length > 0) Clipboard.SetText(replacement); });
        }
        items.Add(ToneMenu("Rewrite sentence", tone => assistant.RewriteSentence(suggestion, tone)));
        items.Add(new ToolStripSeparator());
        items.Add("Ignore", null, (_, _) => assistant.Ignore(suggestion));
        if (suggestion.IsSpelling) items.Add($"Add “{suggestion.Original}” to dictionary", null, (_, _) => assistant.Learn(suggestion));
    }

    private static ToolStripMenuItem ToneMenu(string title, Action<WritingTone> action)
    {
        var item = new ToolStripMenuItem(title);
        foreach (var tone in Enum.GetValues<WritingTone>()) item.DropDownItems.Add(tone.ToString(), null, (_, _) => action(tone));
        return item;
    }

    private static void Header(ToolStripItemCollection items, string text) => items.Add(new ToolStripMenuItem(text) { Enabled = false });

    private void Welcome()
    {
        var ai = settings.Provider switch
        {
            AiProvider.LmStudio => $"AI provider: LM Studio ({settings.BaseUrl}, model {settings.ModelId}).",
            AiProvider.RulesOnly => "AI provider: rules only — spelling and built-in style rules, no language model.",
            _ => AIWriter.Check() switch
            {
                AIWriter.Availability.Ready => "AI provider: Phi Silica, the language model built into Windows.",
                AIWriter.Availability.NeedsDownload => "Phi Silica is available on this PC. Choose “Set up on-device AI” from the tray icon menu to turn it on.",
                AIWriter.Availability.NeedsInstall => "To use Phi Silica on a Copilot+ PC, install Nogrammerly with Install.cmd.",
                _ => "Phi Silica isn't available on this PC, so Nogrammerly uses the Windows spell checker and its built-in style rules.",
            },
        };
        MessageBox.Show(
            "Nogrammerly is running in the notification area (bottom-right, near the clock; look under ^ if you don't see ✦).\n\n" +
            "• Type in almost any app. Issues are underlined: red = correctness, blue = clarity, purple = delivery, orange = style.\n" +
            "• Right-click an underline to replace it, copy the suggestion, rewrite the sentence, or ignore it.\n" +
            "• Click the round button in the corner of the text box to see every suggestion, or rewrite your selection or the whole text.\n\n" +
            ai + "\n\n" + ProviderStatus.PrivacyCopy(settings.Provider),
            "Welcome to Nogrammerly", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    protected override void ExitThreadCore()
    {
        if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
        tray.Visible = false;
        tray.Dispose();
        assistant.Dispose();
        lmStudio.Dispose();
        base.ExitThreadCore();
    }
}
