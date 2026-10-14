using System.Diagnostics;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;
using Nogrammerly;
using Nogrammerly.Core;
using Xunit;

public class SpellCheckerTests
{
    [Fact]
    public void FindsAndCorrectsMisspelling()
    {
        var checker = new SpellChecker("en-US");
        Assert.True(checker.IsAvailable);
        var issue = Assert.Single(checker.Check("We recieve mail."));
        Assert.Equal(new TextSpan(3, 7), issue.Span);
        Assert.Equal("receive", issue.Replacement);
        Assert.True(issue.IsSpelling);
    }

    [Fact]
    public void CleanTextHasNoIssues() => Assert.Empty(new SpellChecker("en-US").Check("The report is ready."));
}

/// <summary>Reads and positions text in a real Notepad window through UI Automation.</summary>
public class TextFieldTests : IDisposable
{
    private readonly UIA3Automation automation = new();
    private readonly HashSet<int> existing = Process.GetProcessesByName("notepad").Select(p => p.Id).ToHashSet();

    [Fact]
    public void ReadsLocatesAndReplacesTextInNotepad()
    {
        Process.Start(new ProcessStartInfo("notepad.exe") { UseShellExecute = true });
        var editor = FindEditor();
        editor.Focus();
        editor.Patterns.Value.Pattern.SetValue("We recieve mail.");

        var field = TextField.From(editor);
        Assert.NotNull(field);
        Assert.Equal("We recieve mail.", field.ReadText()?.TrimEnd('\r', '\n'));
        Assert.True(field.HasLayout);

        var word = Assert.Single(field.Bounds(new TextSpan(3, 7)));
        var frame = field.Frame();
        Assert.NotNull(frame);
        Assert.True(frame.Value.Contains(word), $"{word} should be inside {frame}");

        Assert.True(field.Replace(new TextSpan(3, 7), "receive", field.ReadText()!));
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (field.ReadText()?.TrimEnd('\r', '\n') != "We receive mail." && DateTime.UtcNow < deadline) Thread.Sleep(100);
        Assert.Equal("We receive mail.", field.ReadText()?.TrimEnd('\r', '\n'));
    }

    private AutomationElement FindEditor()
    {
        var deadline = DateTime.UtcNow.AddSeconds(20);
        while (DateTime.UtcNow < deadline)
        {
            var window = automation.GetDesktop().FindAllChildren().FirstOrDefault(w => w.Properties.ProcessId.ValueOrDefault is var pid && IsNewNotepad(pid));
            var editor = window?.FindFirstDescendant(cf => cf.ByControlType(ControlType.Document).Or(cf.ByControlType(ControlType.Edit)));
            if (editor?.Patterns.Value.IsSupported == true) return editor;
            Thread.Sleep(250);
        }
        throw new TimeoutException("Notepad's editor didn't appear.");
    }

    private bool IsNewNotepad(int pid) =>
        !existing.Contains(pid) && Process.GetProcessesByName("notepad").Any(p => p.Id == pid);

    public void Dispose()
    {
        foreach (var process in Process.GetProcessesByName("notepad").Where(p => !existing.Contains(p.Id))) process.Kill();
        automation.Dispose();
    }
}
