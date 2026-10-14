using Nogrammerly.Core;
using Xunit;

public class ProofreadingTests
{
    [Fact]
    public void ParsesIssuesAndLocatesThem()
    {
        const string paragraph = "Me and him recieve alot of mail.";
        const string reply = """
            Here you go:
            [{"original": "recieve", "replacement": "receive", "kind": "correctness", "explanation": "Spelling"},
             {"original": "alot", "replacement": "a lot", "kind": "Correctness", "explanation": "Two words"}]
            """;
        var issues = Proofreading.ParseIssues(reply, paragraph);
        Assert.Equal([new TextSpan(11, 7), new TextSpan(19, 4)], issues.Select(i => i.Span));
        Assert.Equal("a lot", issues[1].Replacement);
    }

    [Fact]
    public void DropsUnchangedMissingAndMalformedIssues()
    {
        const string reply = """[{"original": "fine", "replacement": "fine"}, {"original": "absent", "replacement": "x"}, 42, {"replacement": "y"}]""";
        Assert.Empty(Proofreading.ParseIssues(reply, "This is fine."));
        Assert.Empty(Proofreading.ParseIssues("not json [", "This is fine."));
    }

    [Fact]
    public void RepeatedOriginalsGetDistinctSpans()
    {
        const string reply = """[{"original": "teh", "replacement": "the"}, {"original": "teh", "replacement": "the"}]""";
        Assert.Equal([new TextSpan(0, 3), new TextSpan(8, 3)], Proofreading.ParseIssues(reply, "teh cat teh dog").Select(i => i.Span));
    }

    [Fact]
    public void ParagraphsSkipBlankLines() =>
        Assert.Equal([new TextSpan(0, 2), new TextSpan(6, 3)], Proofreading.Paragraphs("Hi\r\n\r\nYou\n  \n").Select(p => p.Span));

    [Theory]
    [InlineData("\"Hello there.\"", "Hello there.")]
    [InlineData("```\nHello there.\n```", "Hello there.")]
    [InlineData("   ", null)]
    public void CleansRewrites(string reply, string? expected) => Assert.Equal(expected, Proofreading.CleanRewrite(reply));
}
