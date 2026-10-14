using System.Text.RegularExpressions;

namespace Nogrammerly.Core;

/// <summary>
/// Fast, synchronous checks: local style rules plus a spelling pass supplied by the platform
/// (the Windows spell checker in the app, nothing in tests). Deeper grammar, clarity and tone checks
/// come asynchronously from the on-device model.
/// </summary>
public static class WritingEngine
{
    /// <summary>Fields longer than this are skipped to keep system-wide polling cheap.</summary>
    public const int MaxLength = 20_000;

    private static readonly (string Phrase, string? Replacement, string Title, SuggestionKind Kind)[] StyleRules =
    [
        ("utilize", "use", "Prefer simpler wording", SuggestionKind.Clarity),
        ("utilise", "use", "Prefer simpler wording", SuggestionKind.Clarity),
        ("in order to", "to", "Make this more concise", SuggestionKind.Clarity),
        ("due to the fact that", "because", "Make this more concise", SuggestionKind.Clarity),
        ("at this point in time", "now", "Make this more concise", SuggestionKind.Clarity),
        ("in the event that", "if", "Make this more concise", SuggestionKind.Clarity),
        ("very", null, "Consider a more precise word", SuggestionKind.Style),
        ("really", null, "Consider a more precise word", SuggestionKind.Style),
        ("just", null, "This may weaken your message", SuggestionKind.Delivery),
        ("I think", null, "Sound more confident", SuggestionKind.Delivery),
        ("sorry to bother you", null, "This may undercut your request", SuggestionKind.Delivery),
    ];

    public static WritingAnalysis Analyze(string text, Func<string, IEnumerable<WritingSuggestion>>? spelling = null)
    {
        var suggestions = new List<WritingSuggestion>();
        foreach (var rule in StyleRules)
        {
            foreach (var span in WordSpans(rule.Phrase, text))
            {
                var original = text.Substring(span.Start, span.Length);
                var replacement = rule.Replacement is null ? null : MatchCase(original, rule.Replacement);
                suggestions.Add(new WritingSuggestion(rule.Kind, rule.Title,
                    replacement is null ? $"“{original}” can make the sentence less direct." : $"Replace “{original}” with “{replacement}”.",
                    original, replacement, span));
            }
        }
        foreach (Match match in Regex.Matches(text, " {2,}"))
        {
            suggestions.Add(new WritingSuggestion(SuggestionKind.Correctness, "Extra space", "Use one space between words.", match.Value, " ", new TextSpan(match.Index, match.Length)));
        }
        foreach (var span in SentenceSpans(text))
        {
            var count = CountWords(text.Substring(span.Start, span.Length));
            if (count > 28)
            {
                suggestions.Add(new WritingSuggestion(SuggestionKind.Clarity, "Long sentence", $"This sentence has {count} words. Consider splitting it.", text.Substring(span.Start, span.Length), null, span));
            }
        }
        foreach (Match match in Regex.Matches(text, "!{2,}"))
        {
            suggestions.Add(new WritingSuggestion(SuggestionKind.Delivery, "Repeated exclamation marks", "One exclamation mark is enough, if any.", match.Value, "!", new TextSpan(match.Index, match.Length)));
        }
        // Specific phrase rules win over the dictionary where they overlap (e.g. "utilize" → "use", not "utilise").
        var merged = Merge(suggestions, spelling?.Invoke(text) ?? []);
        return new WritingAnalysis(merged, CountWords(text));
    }

    /// <summary>Combines suggestion lists, dropping any whose span overlaps one already kept (earlier lists win).</summary>
    public static IReadOnlyList<WritingSuggestion> Merge(IEnumerable<WritingSuggestion> primary, IEnumerable<WritingSuggestion> secondary)
    {
        var kept = new List<WritingSuggestion>();
        foreach (var suggestion in primary.Concat(secondary))
        {
            if (!kept.Any(k => k.Span.Overlaps(suggestion.Span) || k.Span == suggestion.Span)) kept.Add(suggestion);
        }
        return kept.OrderBy(s => s.Span.Start).ToList();
    }

    /// <summary>Rule-based rewrite used when the on-device model is unavailable.</summary>
    public static string Rewrite(string text, WritingTone tone)
    {
        var result = text;
        foreach (var suggestion in Analyze(text).Suggestions.Reverse())
        {
            if (suggestion.Replacement is { } replacement)
                result = result.Remove(suggestion.Span.Start, suggestion.Span.Length).Insert(suggestion.Span.Start, replacement);
        }
        return tone switch
        {
            WritingTone.Professional => result.Replace("!", "."),
            WritingTone.Confident => Regex.Replace(result, "I think ", "", RegexOptions.IgnoreCase),
            WritingTone.Concise => Regex.Replace(result, "(just|very|really) ", "", RegexOptions.IgnoreCase),
            _ => result,
        };
    }

    /// <summary>Span of the sentence containing <paramref name="span"/>, without surrounding whitespace.</summary>
    public static TextSpan SentenceSpan(TextSpan span, string text)
    {
        foreach (var sentence in SentenceSpans(text))
        {
            if (sentence.Contains(span.Start))
            {
                var start = Math.Min(sentence.Start, span.Start);
                return new TextSpan(start, Math.Max(sentence.End, span.End) - start);
            }
        }
        return span;
    }

    /// <summary>
    /// Sentences end after a run of . ! or ? followed by whitespace, or at a line break.
    /// Each span excludes leading and trailing whitespace.
    /// </summary>
    public static IEnumerable<TextSpan> SentenceSpans(string text)
    {
        var start = 0;
        for (var i = 0; i <= text.Length; i++)
        {
            var atEnd = i == text.Length;
            var boundary = atEnd || text[i] == '\n' || text[i] == '\r'
                || (".!?".Contains(text[i]) && (i + 1 == text.Length || char.IsWhiteSpace(text[i + 1])));
            if (!boundary) continue;
            var end = atEnd || char.IsWhiteSpace(text[i]) ? i : i + 1;
            var s = start;
            while (s < end && char.IsWhiteSpace(text[s])) s++;
            var e = end;
            while (e > s && char.IsWhiteSpace(text[e - 1])) e--;
            if (e > s) yield return new TextSpan(s, e - s);
            start = end;
        }
    }

    /// <summary>Case-insensitive whole-word occurrences of <paramref name="phrase"/>.</summary>
    public static IEnumerable<TextSpan> WordSpans(string phrase, string text) =>
        Regex.Matches(text, $@"(?<![\p{{L}}\p{{N}}']){Regex.Escape(phrase)}(?![\p{{L}}\p{{N}}])", RegexOptions.IgnoreCase)
            .Select(m => new TextSpan(m.Index, m.Length));

    private static int CountWords(string text) => text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;

    private static string MatchCase(string original, string replacement) =>
        original.Length > 0 && char.IsUpper(original[0]) ? char.ToUpperInvariant(replacement[0]) + replacement[1..] : replacement;
}
