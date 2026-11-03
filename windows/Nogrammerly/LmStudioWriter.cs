using System.Text;
using System.Text.Json;
using Nogrammerly.Core;

namespace Nogrammerly;

/// <summary>
/// Talks to the user's LAN LM Studio through its OpenAI-compatible HTTP API. The client is owned
/// here with redirects disabled, so edited text can never be transmitted to a host the user did
/// not configure. Failures never throw onto the worker: they yield "no result" plus a concise
/// <see cref="LastError"/> category that never contains submitted text or the URL.
/// </summary>
internal sealed class LmStudioWriter : IDisposable
{
    private const int MaxBodyBytes = 256 * 1024;

    // Bounded strict schema mirroring Proofreading.ParseStructuredIssues' limits.
    private const string IssuesFormat = """
        {"type":"json_schema","json_schema":{"name":"issues","strict":true,"schema":{"type":"object",
        "properties":{"issues":{"type":"array","maxItems":30,"items":{"type":"object","properties":{
        "original":{"type":"string","maxLength":500},"replacement":{"type":"string","maxLength":500},
        "kind":{"type":"string","enum":["correctness","clarity","delivery","style"]},
        "explanation":{"type":"string","maxLength":500}},
        "required":["original","replacement","kind","explanation"],"additionalProperties":false}}},
        "required":["issues"],"additionalProperties":false}}}
        """;

    private readonly HttpClient http;
    private readonly TimeSpan timeout;

    public string? LastError { get; private set; }

    /// <param name="timeout">Request budget; production uses 15 s, tests pass a short one.</param>
    public LmStudioWriter(TimeSpan? timeout = null)
    {
        this.timeout = timeout ?? TimeSpan.FromSeconds(15);
        http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = this.timeout };
    }

    public void Dispose() => http.Dispose();

    public async Task<IReadOnlyList<WritingSuggestion>> ProofreadAsync(string text, AppSettings settings, CancellationToken token)
    {
        if (!settings.TryValidate(out _)) { LastError = "invalid settings"; return []; }
        var found = new List<WritingSuggestion>();
        foreach (var (paragraph, span) in Proofreading.Paragraphs(text))
        {
            var body = $$"""{"model":{{JsonSerializer.Serialize(settings.ModelId)}},"messages":[{"role":"user","content":{{JsonSerializer.Serialize(Proofreading.ProofreadPrompt(paragraph))}}}],"response_format":{{IssuesFormat}}}""";
            var content = await PostForContentAsync(settings.BaseUrl, body, token);
            if (content is null) return [];
            // ponytail: cheap shape check only for an accurate LastError; ParseStructuredIssues still enforces every bound.
            if (!HasIssuesShape(content)) { LastError = "malformed reply"; return []; }
            foreach (var suggestion in Proofreading.ParseStructuredIssues(content, paragraph))
                found.Add(suggestion with { Span = new TextSpan(suggestion.Span.Start + span.Start, suggestion.Span.Length) });
        }
        LastError = null;
        return found;
    }

    public async Task<string?> RewriteAsync(string text, WritingTone tone, AppSettings settings, CancellationToken token)
    {
        if (!settings.TryValidate(out _)) { LastError = "invalid settings"; return null; }
        var body = $$"""{"model":{{JsonSerializer.Serialize(settings.ModelId)}},"messages":[{"role":"user","content":{{JsonSerializer.Serialize(Proofreading.RewritePrompt(text, tone))}}}]}""";
        var content = await PostForContentAsync(settings.BaseUrl, body, token);
        if (content is null) return null;
        var cleaned = Proofreading.CleanRewrite(content);
        if (cleaned is null) { LastError = "malformed reply"; return null; }
        LastError = null;
        return cleaned;
    }

    public async Task<IReadOnlyList<string>> ModelsAsync(AppSettings settings, CancellationToken token)
    {
        if (!settings.TryValidate(out _)) { LastError = "invalid settings"; return []; }
        using var cts = Link(token);
        try
        {
            using var response = await http.GetAsync(Endpoint(settings.BaseUrl, "/models"), HttpCompletionOption.ResponseHeadersRead, cts.Token);
            if (!response.IsSuccessStatusCode) { LastError = $"HTTP {(int)response.StatusCode}"; return []; }
            var body = await ReadBoundedAsync(response, cts.Token);
            if (body is null) return [];
            var ids = ReadModelIds(body);
            if (ids is null) { LastError = "malformed reply"; return []; }
            LastError = null;
            return ids;
        }
        catch (OperationCanceledException) { LastError = token.IsCancellationRequested ? "cancelled" : "timeout"; return []; }
        catch (Exception) { LastError = "connection failed"; return []; }
    }

    private static string Endpoint(string baseUrl, string path) => baseUrl.TrimEnd('/') + path;

    private CancellationTokenSource Link(CancellationToken token)
    {
        var cts = CancellationTokenSource.CreateLinkedTokenSource(token);
        cts.CancelAfter(timeout);
        return cts;
    }

    private async Task<string?> PostForContentAsync(string baseUrl, string jsonBody, CancellationToken token)
    {
        using var cts = Link(token);
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint(baseUrl, "/chat/completions"));
            request.Content = new StringContent(jsonBody, Encoding.UTF8, "application/json");
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            if (!response.IsSuccessStatusCode) { LastError = $"HTTP {(int)response.StatusCode}"; return null; }
            var body = await ReadBoundedAsync(response, cts.Token);
            if (body is null) return null;
            var content = ChatContent(body);
            if (content is null) LastError = "malformed reply";
            return content;
        }
        catch (OperationCanceledException) { LastError = token.IsCancellationRequested ? "cancelled" : "timeout"; return null; }
        catch (Exception) { LastError = "connection failed"; return null; }
    }

    /// <summary>Reads the body with the 256 KiB cap enforced while streaming, never after an unbounded read.</summary>
    private async Task<string?> ReadBoundedAsync(HttpResponseMessage response, CancellationToken token)
    {
        using var stream = await response.Content.ReadAsStreamAsync(token);
        using var buffer = new MemoryStream();
        var chunk = new byte[8192];
        while (await stream.ReadAsync(chunk, token) is var read && read > 0)
        {
            if (buffer.Length + read > MaxBodyBytes) { LastError = "response too large"; return null; }
            buffer.Write(chunk, 0, read);
        }
        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    /// <summary>Extracts choices[0].message.content; a missing or non-text content is malformed.</summary>
    private string? ChatContent(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("choices", out var choices) || choices.ValueKind != JsonValueKind.Array
                || choices.EnumerateArray().FirstOrDefault() is not { ValueKind: JsonValueKind.Object } first
                || !first.TryGetProperty("message", out var message) || message.ValueKind != JsonValueKind.Object
                || !message.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.String)
                return null;
            return content.GetString();
        }
        catch (JsonException) { return null; }
    }

    private static bool HasIssuesShape(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.ValueKind == JsonValueKind.Object
                && doc.RootElement.TryGetProperty("issues", out var issues) && issues.ValueKind == JsonValueKind.Array;
        }
        catch (JsonException) { return false; }
    }

    private static IReadOnlyList<string>? ReadModelIds(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Object
                || !doc.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array)
                return null;
            var ids = new List<string>();
            foreach (var model in data.EnumerateArray())
            {
                if (model.ValueKind != JsonValueKind.Object
                    || !model.TryGetProperty("id", out var id) || id.ValueKind != JsonValueKind.String)
                    return null;
                ids.Add(id.GetString()!);
            }
            return ids;
        }
        catch (JsonException) { return null; }
    }
}
