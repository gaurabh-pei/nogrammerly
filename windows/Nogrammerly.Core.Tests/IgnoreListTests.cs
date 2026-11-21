using Nogrammerly.Core;
using Xunit;

public class IgnoreListTests
{
    [Fact]
    public void IsSavedAndKeyedOnTheChangeNotTheTitle()
    {
        var path = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName(), "ignored.json");
        try
        {
            // The on-device model words its titles differently on each run.
            new IgnoreList(path).Add(new WritingSuggestion(SuggestionKind.Correctness, "Subject-verb agreement", "", "They is", "They are", new TextSpan(0, 7)));
            var again = new WritingSuggestion(SuggestionKind.Clarity, "Verb should be plural", "", "they is", "They are", new TextSpan(40, 7));
            Assert.True(new IgnoreList(path).Contains(again));
            Assert.False(new IgnoreList(path).Contains(again with { Replacement = "They were" }));
        }
        finally { Directory.Delete(Path.GetDirectoryName(path)!, true); }
    }
}
