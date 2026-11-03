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

public class AppSettingsTests
{
    private static string TempPath() => Path.Combine(Path.GetTempPath(), $"nogrammerly-settings-{Guid.NewGuid():N}.json");

    [Fact]
    public void DefaultIsPhiSilicaLocalhostWithNoModel()
    {
        Assert.Equal(AiProvider.PhiSilica, AppSettings.Default.Provider);
        Assert.Equal("http://127.0.0.1:1234/v1", AppSettings.Default.BaseUrl);
        Assert.Equal("", AppSettings.Default.ModelId);
        Assert.True(AppSettings.Default.TryValidate(out _));
    }

    [Theory]
    [InlineData("http://192.168.1.20:1234/v1")]
    [InlineData("https://lm.lan.example:1234/v1")]
    public void LanHttpAndHttpsUrlsAreValid(string url) =>
        Assert.True(new AppSettings(AiProvider.LmStudio, url, "qwen3").TryValidate(out _));

    [Theory]
    [InlineData("http://user:pass@host/v1")] // embedded credentials
    [InlineData("http://host/v1?key=1")] // query string
    [InlineData("http://host/v1#frag")] // fragment
    [InlineData("ftp://host/v1")] // non-HTTP scheme
    [InlineData("http://host/v2")] // wrong base path
    [InlineData("http://host/v1/models")] // path below /v1
    [InlineData("http://host")] // no path
    [InlineData("not a url")]
    public void MalformedOrUnsafeUrlsAreRejected(string url) =>
        Assert.False(new AppSettings(AiProvider.LmStudio, url, "qwen3").TryValidate(out _));

    [Fact]
    public void LmStudioRequiresModelButOtherProvidersDoNot()
    {
        Assert.False(new AppSettings(AiProvider.LmStudio, "http://127.0.0.1:1234/v1", "").TryValidate(out var error));
        Assert.False(string.IsNullOrWhiteSpace(error));
        Assert.True(new AppSettings(AiProvider.PhiSilica, "http://127.0.0.1:1234/v1", "").TryValidate(out _));
        Assert.True(new AppSettings(AiProvider.RulesOnly, "http://127.0.0.1:1234/v1", "").TryValidate(out _));
    }

    [Fact]
    public void ValidSettingsSurviveSaveLoadWhileServerIsOffline()
    {
        var path = TempPath();
        try
        {
            var settings = new AppSettings(AiProvider.LmStudio, "http://192.168.1.20:1234/v1", "qwen3");
            settings.Save(path);
            var loaded = AppSettings.Load(path, out var error);
            Assert.Null(error);
            Assert.Equal(settings, loaded);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void MissingFileLoadsDefaultsWithoutError()
    {
        var loaded = AppSettings.Load(TempPath(), out var error);
        Assert.Null(error);
        Assert.Equal(AppSettings.Default, loaded);
    }

    [Fact]
    public void MalformedJsonFallsBackToDefaultsWithNotice()
    {
        var path = TempPath();
        try
        {
            File.WriteAllText(path, "{ this is not json");
            var loaded = AppSettings.Load(path, out var error);
            Assert.Equal(AppSettings.Default, loaded);
            Assert.False(string.IsNullOrWhiteSpace(error));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void InvalidStoredSettingsCannotEnableLmStudio()
    {
        var path = TempPath();
        try
        {
            File.WriteAllText(path, """{"provider":"LmStudio","baseUrl":"http://192.168.1.20:1234/v1","modelId":""}""");
            var loaded = AppSettings.Load(path, out var error);
            Assert.NotEqual(AiProvider.LmStudio, loaded.Provider);
            Assert.False(string.IsNullOrWhiteSpace(error));
        }
        finally { File.Delete(path); }
    }
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
