#if WINDOWS
using System.Diagnostics;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;
#endif
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Nogrammerly;
using Nogrammerly.Core;
using Xunit;

#if WINDOWS
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
#endif

#if WINDOWS
public class LmStudioSettingsDialogTests
{
    [Fact]
    public void SavingConnectionDoesNotSelectProvider()
    {
        using var writer = new LmStudioWriter();
        var current = new AppSettings(AiProvider.PhiSilica, "http://127.0.0.1:1234/v1", "model-a");
        using var dialog = new LmStudioSettingsDialog(current, writer, _ => true);
        var draft = (AppSettings)typeof(LmStudioSettingsDialog)
            .GetProperty("Draft", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
            .GetValue(dialog)!;
        Assert.Equal(AiProvider.PhiSilica, draft.Provider);
    }
}
#endif

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

    [Theory]
    [InlineData("""{"provider":"LmStudio","baseUrl":"http://127.0.0.1:1234/v1"}""")] // modelId missing
    [InlineData("""{"provider":"LmStudio","baseUrl":"http://127.0.0.1:1234/v1","modelId":null}""")] // modelId null
    public void MissingOrNullModelIdFallsBackToDefaultsWithNotice(string json)
    {
        var path = TempPath();
        try
        {
            File.WriteAllText(path, json);
            var loaded = AppSettings.Load(path, out var error);
            Assert.Equal(AppSettings.Default, loaded);
            Assert.False(string.IsNullOrWhiteSpace(error));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void UnknownNumericProviderFallsBackToDefaultsWithNotice()
    {
        var path = TempPath();
        try
        {
            File.WriteAllText(path, """{"provider":99,"baseUrl":"http://127.0.0.1:1234/v1","modelId":"qwen3"}""");
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

/// <summary>
/// Loopback HTTP fake: records requests and replays a scripted response, or hands the raw
/// socket to the test for truncation/stall cases. Synthetic content only.
/// </summary>
internal sealed class FakeHttpServer : IDisposable
{
    internal record Request(string Method, string Path, string Body);

    private readonly TcpListener listener = new(IPAddress.Loopback, 0);

    public List<Request> Requests { get; } = [];
    public int Connections;
    public Func<Request, (int Status, string Body, string ContentType, string? Location)> Responder = _ => (200, "{}", "application/json", null);
    public Action<NetworkStream>? RawHandler;

    public string BaseUrl => $"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}/v1";

    public void Start()
    {
        listener.Start();
        _ = Task.Run(async () =>
        {
            while (listener.Server.IsBound)
            {
                TcpClient client;
                try { client = await listener.AcceptTcpClientAsync(); }
                catch (Exception) { return; }
                Interlocked.Increment(ref Connections);
                _ = Task.Run(() => { try { Serve(client); } catch (Exception) { } }); // client may hang up early (oversize/timeout tests)
            }
        });
    }

    private void Serve(TcpClient client)
    {
        using (client)
        using (var stream = client.GetStream())
        {
            if (RawHandler is not null) { RawHandler(stream); return; }
            var reader = new StreamReader(stream, Encoding.UTF8, leaveOpen: true);
            var parts = (reader.ReadLine() ?? "").Split(' ');
            var length = 0;
            while (reader.ReadLine() is { } header && header.Length > 0)
                if (header.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                    length = int.Parse(header[15..].Trim());
            // ponytail: JsonSerializer escapes request bodies to ASCII, so chars == bytes here.
            var chars = new char[length];
            var read = 0;
            while (read < length) { var n = reader.ReadBlock(chars, read, length - read); if (n == 0) break; read += n; }
            var request = new Request(parts.Length > 1 ? parts[0] : "", parts.Length > 1 ? parts[1] : "", new string(chars, 0, read));
            lock (Requests) Requests.Add(request);
            var (status, body, contentType, location) = Responder(request);
            var payload = Encoding.UTF8.GetBytes(body);
            var head = $"HTTP/1.1 {status} Fake\r\nContent-Type: {contentType}\r\n"
                + (location is null ? "" : $"Location: {location}\r\n")
                + $"Content-Length: {payload.Length}\r\nConnection: close\r\n\r\n";
            var headerBytes = Encoding.UTF8.GetBytes(head);
            stream.Write(headerBytes, 0, headerBytes.Length);
            stream.Write(payload, 0, payload.Length);
        }
    }

    public void Dispose() => listener.Stop();
}

public class LmStudioWriterTests
{
    // The writer's own timeout/cancellation semantics are under test, so these calls pass explicit tokens.
#pragma warning disable xUnit1051
    private static AppSettings Settings(FakeHttpServer server) => new(AiProvider.LmStudio, server.BaseUrl, "test-model");

    private static string Chat(string? content) =>
        JsonSerializer.Serialize(new { choices = new[] { new { message = new { content } } } });

    private const string OneIssue = """{"issues":[{"original":"recieve","replacement":"receive","kind":"correctness","explanation":"Misspelling."}]}""";
    [Fact]
    public async Task ProofreadPositionsSecondParagraphInDocument()
    {
        using var server = new FakeHttpServer();
        server.Responder = request => (200, Chat(request.Body.Contains("recieve") ? OneIssue : """{"issues":[]}"""), "application/json", null);
        server.Start();
        using var writer = new LmStudioWriter();

        var result = await writer.ProofreadAsync("First.\nWe recieve mail.", Settings(server), default);

        Assert.Equal(new TextSpan(10, 7), Assert.Single(result).Span);
        Assert.Equal(2, server.Requests.Count);
    }

    [Theory]
    [InlineData("""{"issues":[{"original":"absent","replacement":"present","kind":"correctness","explanation":"No match."}]}""")]
    [InlineData("""{"issues":[{"original":"recieve","replacement":"receive","kind":"99","explanation":"Bad kind."}]}""")]
    public async Task ProofreadReportsRejectedIssuesAsMalformed(string reply)
    {
        using var server = new FakeHttpServer();
        server.Responder = _ => (200, Chat(reply), "application/json", null);
        server.Start();
        using var writer = new LmStudioWriter();

        Assert.Empty(await writer.ProofreadAsync("We recieve mail.", Settings(server), default));
        Assert.Equal("malformed reply", writer.LastError);
    }

    [Fact]
    public async Task ProofreadPostsSelectedModelAndSchemaAndPositionsSuggestions()
    {
        using var server = new FakeHttpServer();
        server.Responder = _ => (200, Chat(OneIssue), "application/json", null);
        server.Start();
        using var writer = new LmStudioWriter();

        var result = await writer.ProofreadAsync("We recieve mail.", Settings(server), default);

        var suggestion = Assert.Single(result);
        Assert.Equal(new TextSpan(3, 7), suggestion.Span);
        Assert.Equal("receive", suggestion.Replacement);
        Assert.Null(writer.LastError);

        var request = Assert.Single(server.Requests);
        Assert.Equal("POST", request.Method);
        Assert.Equal("/v1/chat/completions", request.Path);
        using var doc = JsonDocument.Parse(request.Body);
        Assert.Equal("test-model", doc.RootElement.GetProperty("model").GetString());
        Assert.Contains("We recieve mail.", doc.RootElement.GetProperty("messages")[0].GetProperty("content").GetString());
        var format = doc.RootElement.GetProperty("response_format");
        Assert.Equal("json_schema", format.GetProperty("type").GetString());
        Assert.Equal("issues", format.GetProperty("json_schema").GetProperty("name").GetString());
        Assert.True(format.GetProperty("json_schema").GetProperty("strict").GetBoolean());
        var item = format.GetProperty("json_schema").GetProperty("schema")
            .GetProperty("properties").GetProperty("issues").GetProperty("items");
        var required = item.GetProperty("required").EnumerateArray().Select(e => e.GetString()).ToList();
        Assert.Equal(new[] { "original", "replacement", "kind", "explanation" }, required);
        Assert.False(item.GetProperty("additionalProperties").GetBoolean());
    }

    [Theory]
    [InlineData("not json at all")]
    [InlineData("[]")]
    [InlineData("""{"issues":"nope"}""")]
    public async Task ProofreadRejectsMalformedStructuredReplies(string reply)
    {
        using var server = new FakeHttpServer();
        server.Responder = _ => (200, Chat(reply), "application/json", null);
        server.Start();
        using var writer = new LmStudioWriter();

        Assert.Empty(await writer.ProofreadAsync("We recieve mail.", Settings(server), default));
        Assert.Equal("malformed reply", writer.LastError);
    }

    [Fact]
    public async Task ProofreadRejectsNullContent()
    {
        using var server = new FakeHttpServer();
        server.Responder = _ => (200, Chat(null), "application/json", null);
        server.Start();
        using var writer = new LmStudioWriter();

        Assert.Empty(await writer.ProofreadAsync("We recieve mail.", Settings(server), default));
        Assert.Equal("malformed reply", writer.LastError);
    }

    [Fact]
    public async Task ModelsListsIdsFromGetModels()
    {
        using var server = new FakeHttpServer();
        server.Responder = _ => (200, """{"data":[{"id":"alpha"},{"id":"beta"}]}""", "application/json", null);
        server.Start();
        using var writer = new LmStudioWriter();

        var ids = await writer.ModelsAsync(Settings(server), default);

        Assert.Equal(new[] { "alpha", "beta" }, ids);
        Assert.Null(writer.LastError);
        var request = Assert.Single(server.Requests);
        Assert.Equal("GET", request.Method);
        Assert.Equal("/v1/models", request.Path);
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("""{"data":"nope"}""")]
    [InlineData("""{"data":[{"nope":1}]}""")]
    public async Task ModelsRejectsMalformedPayloads(string body)
    {
        using var server = new FakeHttpServer();
        server.Responder = _ => (200, body, "application/json", null);
        server.Start();
        using var writer = new LmStudioWriter();

        Assert.Empty(await writer.ModelsAsync(Settings(server), default));
        Assert.Equal("malformed reply", writer.LastError);
    }

    [Fact]
    public async Task RewriteCleansFencedReply()
    {
        using var server = new FakeHttpServer();
        server.Responder = _ => (200, Chat("```\nRewritten sentence.\n```"), "application/json", null);
        server.Start();
        using var writer = new LmStudioWriter();

        var rewrite = await writer.RewriteAsync("Original sentence.", WritingTone.Friendly, Settings(server), default);

        Assert.Equal("Rewritten sentence.", rewrite);
        Assert.Null(writer.LastError);
        var request = Assert.Single(server.Requests);
        Assert.Equal("POST", request.Method);
        Assert.Equal("/v1/chat/completions", request.Path);
        using var doc = JsonDocument.Parse(request.Body);
        Assert.Equal("test-model", doc.RootElement.GetProperty("model").GetString());
        Assert.Contains("warm, friendly", doc.RootElement.GetProperty("messages")[0].GetProperty("content").GetString());
    }

    [Fact]
    public async Task RewriteRejectsBlankContent()
    {
        using var server = new FakeHttpServer();
        server.Responder = _ => (200, Chat("   "), "application/json", null);
        server.Start();
        using var writer = new LmStudioWriter();

        Assert.Null(await writer.RewriteAsync("Original sentence.", WritingTone.Professional, Settings(server), default));
        Assert.Equal("malformed reply", writer.LastError);
    }

    [Fact]
    public async Task HttpErrorYieldsNoResult()
    {
        using var server = new FakeHttpServer();
        server.Responder = _ => (500, "boom", "text/plain", null);
        server.Start();
        using var writer = new LmStudioWriter();

        Assert.Empty(await writer.ProofreadAsync("We recieve mail.", Settings(server), default));
        Assert.Equal("HTTP 500", writer.LastError);
        Assert.DoesNotContain("127.0.0.1", writer.LastError);
    }

    [Fact]
    public async Task OversizedResponseIsRejected()
    {
        using var server = new FakeHttpServer();
        server.Responder = _ => (200, new string('x', 300_000), "application/json", null);
        server.Start();
        using var writer = new LmStudioWriter();

        Assert.Empty(await writer.ProofreadAsync("We recieve mail.", Settings(server), default));
        Assert.Equal("response too large", writer.LastError);
    }

    [Fact]
    public async Task TruncatedResponseIsRejected()
    {
        using var server = new FakeHttpServer();
        server.RawHandler = stream =>
        {
            var head = Encoding.UTF8.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 5000\r\n\r\n");
            stream.Write(head, 0, head.Length);
            var partial = Encoding.UTF8.GetBytes("""{"choices":[{"message":{"content":"cut""");
            stream.Write(partial, 0, partial.Length);
            stream.Close();
        };
        server.Start();
        using var writer = new LmStudioWriter();

        Assert.Empty(await writer.ProofreadAsync("We recieve mail.", Settings(server), default));
        Assert.False(string.IsNullOrEmpty(writer.LastError));
        Assert.DoesNotContain("recieve", writer.LastError);
    }

    [Fact]
    public async Task RedirectIsNotFollowed()
    {
        using var target = new FakeHttpServer();
        target.Start();
        using var server = new FakeHttpServer();
        server.Responder = _ => (302, "", "text/plain", target.BaseUrl + "/chat/completions");
        server.Start();
        using var writer = new LmStudioWriter();

        Assert.Empty(await writer.ProofreadAsync("We recieve mail.", Settings(server), default));
        Assert.Equal("HTTP 302", writer.LastError);
        Assert.Single(server.Requests);
        Assert.Equal(0, Volatile.Read(ref target.Connections)); // text never reached the redirect destination
    }

    [Fact]
    public async Task TimeoutYieldsNoResult()
    {
        using var server = new FakeHttpServer();
        server.RawHandler = _ => Thread.Sleep(5000); // accept, never answer
        server.Start();
        using var writer = new LmStudioWriter(TimeSpan.FromMilliseconds(300));

        Assert.Empty(await writer.ProofreadAsync("We recieve mail.", Settings(server), default));
        Assert.Equal("timeout", writer.LastError);
    }

    [Fact]
    public async Task CancelledCallYieldsNoResult()
    {
        using var server = new FakeHttpServer();
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        server.RawHandler = stream =>
        {
            stream.ReadExactly(new byte[64]);
            started.SetResult();
            Thread.Sleep(5000);
        };
        server.Start();
        using var writer = new LmStudioWriter();
        using var cts = new CancellationTokenSource();

        var call = writer.ProofreadAsync("We recieve mail.", Settings(server), cts.Token);
        await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        cts.Cancel();

        Assert.Empty(await call);
        Assert.Equal("cancelled", writer.LastError);
    }

    [Fact]
    public async Task InvalidSettingsMakeNoRequest()
    {
        using var server = new FakeHttpServer();
        server.Start();
        using var writer = new LmStudioWriter();
        var broken = new AppSettings(AiProvider.LmStudio, server.BaseUrl, "");

        Assert.Empty(await writer.ProofreadAsync("We recieve mail.", broken, default));
        Assert.Equal("invalid settings", writer.LastError);
        Assert.Null(await writer.RewriteAsync("We recieve mail.", WritingTone.Friendly, broken, default));
        Assert.Equal("invalid settings", writer.LastError);
        Assert.Empty(await writer.ModelsAsync(broken, default));
        Assert.Equal(0, Volatile.Read(ref server.Connections));
    }
#pragma warning restore xUnit1051
}

/// <summary>
/// The tray's UI-independent status and privacy wording: which line the menu shows for the
/// selected provider, and what the app may claim about where text goes.
/// </summary>
public class ProviderStatusTests
{
    [Fact]
    public void EveryProviderHasADisplayName()
    {
        Assert.Equal("Phi Silica", ProviderStatus.Name(AiProvider.PhiSilica));
        Assert.Equal("LM Studio", ProviderStatus.Name(AiProvider.LmStudio));
        Assert.Equal("Rules only", ProviderStatus.Name(AiProvider.RulesOnly));
    }

    [Fact]
    public void PhiSilicaStatusReflectsAvailability()
    {
        Assert.Equal("On-device AI is on", ProviderStatus.StatusText(AiProvider.PhiSilica, PhiState.Ready, null));
        Assert.Equal("On-device AI needs a Copilot+ PC", ProviderStatus.StatusText(AiProvider.PhiSilica, PhiState.Unsupported, null));
        Assert.Equal("Set up on-device AI…", ProviderStatus.StatusText(AiProvider.PhiSilica, PhiState.NeedsDownload, null));
        Assert.True(ProviderStatus.ShowPhiSetup(AiProvider.PhiSilica, PhiState.NeedsDownload));
        Assert.False(ProviderStatus.ShowPhiSetup(AiProvider.LmStudio, PhiState.NeedsDownload)); // setup prompt only when Phi is selected
    }

    [Fact]
    public void LmStudioStatusShowsLastErrorAndNeverLeaksUrlOrText()
    {
        Assert.Equal("LM Studio: Connection failed", ProviderStatus.StatusText(AiProvider.LmStudio, PhiState.Ready, "connection failed"));
        Assert.Equal("LM Studio: HTTP 500", ProviderStatus.StatusText(AiProvider.LmStudio, PhiState.Ready, "HTTP 500"));
        Assert.Equal("LM Studio selected, no errors reported yet", ProviderStatus.StatusText(AiProvider.LmStudio, PhiState.Unsupported, null));
        var status = ProviderStatus.StatusText(AiProvider.LmStudio, PhiState.Ready, "connection failed");
        Assert.DoesNotContain("127.0.0.1", status);
        Assert.DoesNotContain("recieve", status);
    }

    [Fact]
    public void RulesOnlyNeverClaimsAI()
        => Assert.Equal("Rules only: no AI provider is used", ProviderStatus.StatusText(AiProvider.RulesOnly, PhiState.Ready, "connection failed"));

    [Fact]
    public void PrivacyCopyOnlyClaimsOnPcForLocalProviders()
    {
        Assert.Contains("leaves this PC", ProviderStatus.PrivacyCopy(AiProvider.PhiSilica));
        Assert.Contains("leaves this PC", ProviderStatus.PrivacyCopy(AiProvider.RulesOnly));
        var lan = ProviderStatus.PrivacyCopy(AiProvider.LmStudio);
        Assert.DoesNotContain("leaves this PC", lan);
        Assert.Contains("unencrypted", lan); // LAN HTTP warning is explicit
        Assert.DoesNotContain("inside this PC", lan); // never call LM Studio local
    }
}

/// <summary>
/// Provider dispatch and staleness gating, exercised through the narrow seam in
/// <see cref="SystemWritingAssistant"/>. Synthetic text only; the fake server records every connection.
/// </summary>
public class ProviderRoutingTests
{
    // These tests exercise explicit cancellation semantics (default and pre-cancelled tokens), not test-run cancellation.
#pragma warning disable xUnit1051
    private const string Text = "We recieve mail.";
    private static readonly WritingSuggestion PhiIssue = new(SuggestionKind.Correctness, "Spelling", "Misspelling.", "recieve", "receive", new TextSpan(3, 7));

    private static Task<IReadOnlyList<WritingSuggestion>> PhiMustNotBeCalled(string _, CancellationToken __)
        => throw new InvalidOperationException("Phi Silica must not run for another provider");

    private static Task<string?> PhiRewriteMustNotBeCalled(string _, WritingTone __)
        => throw new InvalidOperationException("Phi Silica must not run for another provider");

    [Fact]
    public async Task RulesOnlyProofreadMakesNoCallAnywhere()
    {
        using var server = new FakeHttpServer();
        server.Start();
        using var lm = new LmStudioWriter();

        var result = await ProviderRouting.ProofreadAsync(
            new AppSettings(AiProvider.RulesOnly, server.BaseUrl, ""), Text, lm, PhiMustNotBeCalled, default);

        Assert.Empty(result);
        Assert.Equal(0, Volatile.Read(ref server.Connections));
    }

    [Fact]
    public async Task RulesOnlyRewriteUsesDeterministicRules()
    {
        using var server = new FakeHttpServer();
        server.Start();
        using var lm = new LmStudioWriter();

        var result = await ProviderRouting.RewriteAsync(
            new AppSettings(AiProvider.RulesOnly, server.BaseUrl, ""), Text, WritingTone.Concise, lm, PhiRewriteMustNotBeCalled, default);

        Assert.Equal(WritingEngine.Rewrite(Text, WritingTone.Concise), result);
        Assert.Equal(0, Volatile.Read(ref server.Connections));
    }

    [Fact]
    public async Task LmProofreadFailureNeverFallsBackToPhi()
    {
        using var server = new FakeHttpServer();
        server.Responder = _ => (500, "nope", "text/plain", null);
        server.Start();
        using var lm = new LmStudioWriter();
        var phiCalled = false;

        var result = await ProviderRouting.ProofreadAsync(
            new AppSettings(AiProvider.LmStudio, server.BaseUrl, "test-model"), Text, lm,
            (_, _) => { phiCalled = true; return Task.FromResult<IReadOnlyList<WritingSuggestion>>([PhiIssue]); }, default);

        Assert.Empty(result); // deterministic rules already on screen survive; no other AI runs
        Assert.False(phiCalled);
        Assert.Equal(1, Volatile.Read(ref server.Connections));
    }

    [Fact]
    public async Task LmRewriteFailureFallsBackToRulesNotPhi()
    {
        using var server = new FakeHttpServer();
        server.Responder = _ => (500, "nope", "text/plain", null);
        server.Start();
        using var lm = new LmStudioWriter();
        var phiCalled = false;

        var result = await ProviderRouting.RewriteAsync(
            new AppSettings(AiProvider.LmStudio, server.BaseUrl, "test-model"), Text, WritingTone.Concise, lm,
            (_, _) => { phiCalled = true; return Task.FromResult<string?>("never"); }, default);

        Assert.Equal(WritingEngine.Rewrite(Text, WritingTone.Concise), result);
        Assert.False(phiCalled);
    }

    [Fact]
    public async Task PhiProofreadUsesPhiAndNotLm()
    {
        using var server = new FakeHttpServer();
        server.Start();
        using var lm = new LmStudioWriter();

        var result = await ProviderRouting.ProofreadAsync(
            new AppSettings(AiProvider.PhiSilica, server.BaseUrl, ""), Text, lm,
            (_, _) => Task.FromResult<IReadOnlyList<WritingSuggestion>>([PhiIssue]), default);

        Assert.Same(PhiIssue, Assert.Single(result));
        Assert.Equal(0, Volatile.Read(ref server.Connections));
    }

    [Fact]
    public async Task PhiRewriteWithoutResultFallsBackToRules()
    {
        using var lm = new LmStudioWriter();

        var result = await ProviderRouting.RewriteAsync(
            new AppSettings(AiProvider.PhiSilica, "http://127.0.0.1:1/v1", ""), Text, WritingTone.Concise, lm,
            (_, _) => Task.FromResult<string?>(null), default);

        Assert.Equal(WritingEngine.Rewrite(Text, WritingTone.Concise), result);
    }

    [Fact]
    public async Task CancelledProofreadYieldsNoResult()
    {
        using var server = new FakeHttpServer();
        server.Responder = _ => (200, "{}", "application/json", null);
        server.Start();
        using var lm = new LmStudioWriter();
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var result = await ProviderRouting.ProofreadAsync(
            new AppSettings(AiProvider.LmStudio, server.BaseUrl, "test-model"), Text, lm, PhiMustNotBeCalled, cancellation.Token);

        Assert.Empty(result);
    }

    [Fact]
    public void IdenticalTextInADifferentFieldIsStale()
    {
        var ticket = new WorkTicket(0, 1, Text);

        Assert.True(ticket.Current(0, 1, Text));
        Assert.False(ticket.Current(0, 2, Text)); // same text, new field: the old result must not publish
    }

    [Fact]
    public void SettingsChangeAndPauseInvalidatePendingWork()
    {
        var ticket = new WorkTicket(3, 5, "hello");

        Assert.False(ticket.Current(4, 5, "hello")); // settings update bumped the generation
        Assert.False(ticket.Current(3, 5, ""));      // pause/reset cleared the field text
    }
#pragma warning restore xUnit1051
}

#if WINDOWS
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
#endif
