using Nogrammerly.Core;
using Xunit;

public class WritingEngineTests
{
    [Fact]
    public void SuggestsSimplerWordWithMatchingCase()
    {
        var suggestion = Assert.Single(WritingEngine.Analyze("Utilize it.").Suggestions);
        Assert.Equal("Use", suggestion.Replacement);
        Assert.Equal(new TextSpan(0, 7), suggestion.Span);
    }

    [Fact]
    public void CleanTextHasNoSuggestions() =>
        Assert.Empty(WritingEngine.Analyze("The report is ready for review.").Suggestions);

    [Fact]
    public void PhraseRulesWinOverOverlappingSpelling()
    {
        var spelling = (string text) => new[] { new WritingSuggestion(SuggestionKind.Correctness, "Spelling", "", "utilize", "utilise", new TextSpan(3, 7), IsSpelling: true) };
        var suggestion = Assert.Single(WritingEngine.Analyze("We utilize it.", spelling).Suggestions);
        Assert.Equal("use", suggestion.Replacement);
    }

    [Fact]
    public void WordSpansMatchWholeWordsOnly() =>
        Assert.Equal([new TextSpan(0, 4)], WritingEngine.WordSpans("just", "Just adjust justice."));

    [Fact]
    public void SentenceSpanFindsTheContainingSentence()
    {
        const string text = "First one. Second one here!  Third.";
        Assert.Equal("Second one here!", Slice(text, WritingEngine.SentenceSpan(new TextSpan(18, 3), text)));
    }

    [Fact]
    public void SentencesSplitOnLineBreaks() =>
        Assert.Equal(["Hi team", "Thanks."], WritingEngine.SentenceSpans("Hi team\r\nThanks.").Select(s => Slice("Hi team\r\nThanks.", s)));

    [Fact]
    public void FlagsExtraSpacesAndRepeatedExclamationMarks()
    {
        var kinds = WritingEngine.Analyze("Great  news!!").Suggestions.Select(s => s.Title);
        Assert.Equal(["Extra space", "Repeated exclamation marks"], kinds);
    }

    [Fact]
    public void FallbackRewriteAppliesFixesAndTone() =>
        Assert.Equal("I'll use it to help.", WritingEngine.Rewrite("I'll just utilize it in order to help.", WritingTone.Concise));

    private static string Slice(string text, TextSpan span) => text.Substring(span.Start, span.Length);
}
