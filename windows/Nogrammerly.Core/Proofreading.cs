using System.Text.Json;
using System.Text.RegularExpressions;

namespace Nogrammerly.Core;

/// <summary>
/// Prompts for the on-device model and parsing of its replies. Kept here, away from the Windows AI APIs,
/// so the parsing can be tested on any machine.
/// </summary>
public static class Proofreading
{
    /// <summary>Paragraphs longer than this are skipped; the on-device context window is small.</summary>
    public const int MaxParagraphLength = 2_500;

    public static string ProofreadPrompt(string paragraph) => $$"""
        You are a meticulous proofreader. Report every grammar, spelling, punctuation, word-choice, clarity and tone problem in the text below.
        Reply with only a JSON array, no other words. Each item is an object:
        {"original": "...", "replacement": "...", "kind": "correctness|clarity|delivery|style", "explanation": "..."}
        "original" must be copied verbatim from the text and be as short as possible (a few words).
        Use kind "correctness" for grammar, spelling and punctuation; "clarity" for wordy or confusing phrasing;
        "delivery" for tone that is too harsh, hesitant or informal; "style" for weak or repetitive word choice.
        "replacement" must be what a fluent native speaker would naturally write (for example "he and I", not "I and he").
        "explanation" says why it should change, in under 10 words.
        Never report text that is already correct. Reply [] if there are no problems.

        Text:
        {{paragraph}}
        """;

    public static string RewritePrompt(string text, WritingTone tone) => $"""
        Rewrite the text below so it reads {tone.Instruction()}. Fix any grammar, spelling and punctuation mistakes.
        Keep the original meaning, language, names, numbers, links and line breaks.
        Reply with only the rewritten text: no preamble, no quotes, no explanation.

        Text:
        {text}
        """;

    /// <summary>Non-empty paragraphs (split on line breaks) that are short enough to send to the model.</summary>
    public static IEnumerable<(string Text, TextSpan Span)> Paragraphs(string text)
    {
        foreach (Match match in Regex.Matches(text, @"[^\r\n]+"))
        {
            if (match.Length <= MaxParagraphLength && match.Value.Any(char.IsLetter))
                yield return (match.Value, new TextSpan(match.Index, match.Length));
        }
    }

    /// <summary>
    /// Turns the model's JSON reply into suggestions positioned within <paramref name="paragraph"/>.
    /// Anything malformed, unlocatable or unchanged is dropped rather than guessed at.
    /// </summary>
    public static IReadOnlyList<WritingSuggestion> ParseIssues(string reply, string paragraph)
    {
        var start = reply.IndexOf('[');
        var end = reply.LastIndexOf(']');
        if (start < 0 || end <= start) return [];
        JsonElement root;
        try { root = JsonDocument.Parse(reply[start..(end + 1)]).RootElement; }
        catch (JsonException) { return []; }

        var claimed = new List<TextSpan>();
        var suggestions = new List<WritingSuggestion>();
        foreach (var issue in root.EnumerateArray())
        {
            if (issue.ValueKind != JsonValueKind.Object) continue;
            var original = Read(issue, "original");
            var replacement = Read(issue, "replacement");
            if (string.IsNullOrWhiteSpace(original) || replacement is null || original == replacement) continue;
            TextSpan? span = WritingEngine.WordSpans(original, paragraph).Cast<TextSpan?>().FirstOrDefault(c => !claimed.Any(k => k.Overlaps(c!.Value)))
                ?? ExactSpan(original, paragraph, claimed);
            if (span is not { } found) continue;
            claimed.Add(found);
            var kind = Enum.TryParse<SuggestionKind>(Read(issue, "kind"), ignoreCase: true, out var parsed) ? parsed : SuggestionKind.Correctness;
            var explanation = Read(issue, "explanation") is { Length: > 0 } text ? text : "Suggested improvement.";
            suggestions.Add(new WritingSuggestion(kind, explanation, $"Replace “{original}” with “{replacement}”.",
                paragraph.Substring(found.Start, found.Length), replacement, found));
        }
        return suggestions;
    }

    private static string? Read(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static TextSpan? ExactSpan(string original, string text, List<TextSpan> claimed)
    {
        var index = text.IndexOf(original, StringComparison.Ordinal);
        if (index < 0) return null;
        var span = new TextSpan(index, original.Length);
        return claimed.Any(k => k.Overlaps(span)) ? null : span;
    }

    /// <summary>Strips wrapping quotes or code fences a small model sometimes adds around a rewrite.</summary>
    public static string? CleanRewrite(string? reply)
    {
        var text = reply?.Trim();
        if (string.IsNullOrEmpty(text)) return null;
        if (text.StartsWith("```"))
            text = Regex.Replace(text, @"^```[^\n]*\n?|\n?```$", "").Trim();
        if (text.Length > 1 && text[0] == '"' && text[^1] == '"') text = text[1..^1].Trim();
        return text.Length == 0 ? null : text;
    }
}
