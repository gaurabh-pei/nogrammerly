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

    [Fact]
    public void StructuredParsesValidObjectPayload()
    {
        const string paragraph = "Me and him recieve alot of mail.";
        const string json = """
            {"issues":[{"original":"recieve","replacement":"receive","kind":"correctness","explanation":"Spelling"},
                       {"original":"alot","replacement":"a lot","kind":"Style","explanation":"Two words"}]}
            """;
        var issues = Proofreading.ParseStructuredIssues(json, paragraph);
        Assert.Equal([new TextSpan(11, 7), new TextSpan(19, 4)], issues.Select(i => i.Span));
        Assert.Equal(SuggestionKind.Style, issues[1].Kind);
        Assert.Equal("a lot", issues[1].Replacement);
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("[]")]
    [InlineData("""{"issues": 3}""")]
    [InlineData("""{"issues":[{"original":"recieve","replacement":"x","kind":"grammar","explanation":"e"}]}""")]
    [InlineData("""{"issues":[{"original":"recieve","replacement":"x","kind":"99","explanation":"e"}]}""")]
    [InlineData("""{"issues":[42]}""")]
    [InlineData("""{"issues":[{"original":"recieve","replacement":"recieve","kind":"correctness","explanation":"e"}]}""")]
    [InlineData("""{"issues":[{"original":"absent","replacement":"x","kind":"clarity","explanation":"e"}]}""")]
    [InlineData("""{"issues":[{"original":"recieve","replacement":"x","kind":"clarity"}]}""")]
    [InlineData("""{"issues":[{"original":"recieve","replacement":"x","explanation":"e"}]}""")]
    [InlineData("""{"issues":[{"original":"recieve","replacement":"x","kind":"clarity","explanation":"e"},{"original":"recieve","replacement":"y","kind":"clarity","explanation":"e"}]}""")]
    public void StructuredRejectsInvalidPayloads(string json) =>
        Assert.Empty(Proofreading.ParseStructuredIssues(json, "Me and him recieve alot of mail."));

    [Fact]
    public void StructuredRejectsTooManyItemsAndOversizedStrings()
    {
        Assert.Empty(Proofreading.ParseStructuredIssues(StructuredWith(31), string.Join(" ", Enumerable.Repeat("a", 31))));
        Assert.Equal(30, Proofreading.ParseStructuredIssues(StructuredWith(30), string.Join(" ", Enumerable.Repeat("a", 30))).Count);
        Assert.Single(Proofreading.ParseStructuredIssues(StructuredWith(1, new string('x', 500)), new string('x', 500)));
        Assert.Empty(Proofreading.ParseStructuredIssues(StructuredWith(1, new string('x', 501)), new string('x', 501)));
    }

    private static string StructuredWith(int count, string original = "a") =>
        """{"issues":[""" + string.Join(",", Enumerable.Repeat(
            $$"""{"original":"{{original}}","replacement":"b","kind":"style","explanation":"e"}""", count)) + "]}";

    [Fact]
    public void NativeParserToleratesObjectShapedReplyWithoutThrowing() =>
        Assert.Empty(Proofreading.ParseIssues("""{"issues": [42, "x"]}""", "Me recieve."));

    [Theory]
    [InlineData("\"Hello there.\"", "Hello there.")]
    [InlineData("```\nHello there.\n```", "Hello there.")]
    [InlineData("   ", null)]
    public void CleansRewrites(string reply, string? expected) => Assert.Equal(expected, Proofreading.CleanRewrite(reply));
}
