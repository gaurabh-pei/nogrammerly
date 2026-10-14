namespace Nogrammerly.Core;

public enum WritingTone { Professional, Friendly, Confident, Concise }

public enum SuggestionKind { Correctness, Clarity, Delivery, Style }

public static class WritingToneExtensions
{
    public static string Instruction(this WritingTone tone) => tone switch
    {
        WritingTone.Professional => "polished, courteous and professional",
        WritingTone.Friendly => "warm, friendly and approachable",
        WritingTone.Confident => "confident and direct, without hedging words like \"I think\" or \"just\"",
        _ => "as concise as possible, removing filler while keeping every key point",
    };
}

/// <summary>A span of UTF-16 code units, the same unit Windows UI Automation counts characters in.</summary>
public readonly record struct TextSpan(int Start, int Length)
{
    public int End => Start + Length;
    public bool Overlaps(TextSpan other) => Start < other.End && other.Start < End;
    public bool Contains(int index) => index >= Start && index < End;
}

public sealed record WritingSuggestion(
    SuggestionKind Kind,
    string Title,
    string Explanation,
    // The exact text at Span when the suggestion was made; replacements are refused if the field no longer matches.
    string Original,
    string? Replacement,
    TextSpan Span,
    bool IsSpelling = false)
{
    public Guid Id { get; } = Guid.NewGuid();
    public string IgnoreKey => $"{Title}|{Original.ToLowerInvariant()}";
}

public sealed record WritingAnalysis(IReadOnlyList<WritingSuggestion> Suggestions, int Words);
