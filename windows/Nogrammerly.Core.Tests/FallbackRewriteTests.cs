using Nogrammerly.Core;
using Xunit;

public class FallbackRewriteTests
{
    [Theory]
    [InlineData("I think we should go. I think so.", WritingTone.Confident, "We should go. So.")]
    [InlineData("Maybe I think it works.", WritingTone.Confident, "Maybe it works.")]
    [InlineData("Just adjust the very first one.", WritingTone.Concise, "Adjust the first one.")]
    [InlineData("We adjust it.", WritingTone.Concise, "We adjust it.")]
    public void DroppedWordsLeaveWholeWordsAndCapitals(string text, WritingTone tone, string expected) =>
        Assert.Equal(expected, WritingEngine.Rewrite(text, tone));
}
