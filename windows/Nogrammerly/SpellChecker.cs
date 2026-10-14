using System.Runtime.InteropServices;
using Nogrammerly.Core;

namespace Nogrammerly;

/// <summary>
/// The Windows Spell Checking API (spellcheck.h), the same checker Windows uses in its own text boxes.
/// Words added here go into the user's Windows dictionary, shared with other apps.
/// </summary>
internal sealed class SpellChecker
{
    private readonly ISpellChecker? checker;
    private readonly Lock gate = new();

    public SpellChecker(string language)
    {
        try
        {
            var factory = (ISpellCheckerFactory)new SpellCheckerFactoryClass();
            var tag = factory.IsSupported(language) != 0 ? language : "en-US";
            if (factory.IsSupported(tag) != 0) checker = factory.CreateSpellChecker(tag);
        }
        catch (COMException) { checker = null; }
    }

    public bool IsAvailable => checker is not null;

    public IEnumerable<WritingSuggestion> Check(string text)
    {
        if (checker is null) return [];
        var suggestions = new List<WritingSuggestion>();
        lock (gate)
        {
            var errors = checker.Check(text);
            while (errors.Next(out var error) == 0 && error is not null)
            {
                var span = new TextSpan((int)error.StartIndex, (int)error.Length);
                if (span.End > text.Length) continue;
                var word = text.Substring(span.Start, span.Length);
                string? replacement = error.CorrectiveAction switch
                {
                    CorrectiveAction.Replace => error.Replacement,
                    CorrectiveAction.Delete => "",
                    CorrectiveAction.GetSuggestions => FirstSuggestion(word),
                    _ => null,
                };
                var explanation = error.CorrectiveAction == CorrectiveAction.Delete
                    ? $"“{word}” is repeated."
                    : replacement is null ? $"“{word}” may be misspelled." : $"“{word}” may be misspelled. Did you mean “{replacement}”?";
                suggestions.Add(new WritingSuggestion(SuggestionKind.Correctness, error.CorrectiveAction == CorrectiveAction.Delete ? "Repeated word" : "Spelling",
                    explanation, word, replacement, span, IsSpelling: error.CorrectiveAction != CorrectiveAction.Delete));
            }
        }
        return suggestions;
    }

    public void Learn(string word)
    {
        if (checker is null) return;
        lock (gate) checker.Add(word);
    }

    private string? FirstSuggestion(string word)
    {
        var list = checker!.Suggest(word);
        var buffer = new string[1];
        return list.Next(1, buffer, out var fetched) == 0 && fetched == 1 ? buffer[0] : null;
    }

    // COM declarations. Methods must stay in vtable order; only the leading ones we call are declared.

    [ComImport, Guid("7AB36653-1796-484B-BDFA-E74F1DB7C1DC")]
    private class SpellCheckerFactoryClass;

    [ComImport, Guid("8E018A9D-2415-4677-BF08-794EA61F94BB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISpellCheckerFactory
    {
        IEnumString SupportedLanguages { get; }
        int IsSupported([MarshalAs(UnmanagedType.LPWStr)] string languageTag);
        ISpellChecker CreateSpellChecker([MarshalAs(UnmanagedType.LPWStr)] string languageTag);
    }

    [ComImport, Guid("B6FD0B71-E2BC-4653-8D05-F197E412770B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISpellChecker
    {
        string LanguageTag { [return: MarshalAs(UnmanagedType.LPWStr)] get; }
        IEnumSpellingError Check([MarshalAs(UnmanagedType.LPWStr)] string text);
        IEnumString Suggest([MarshalAs(UnmanagedType.LPWStr)] string word);
        void Add([MarshalAs(UnmanagedType.LPWStr)] string word);
    }

    [ComImport, Guid("803E3BD4-2828-4410-8290-418D1D73C762"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IEnumSpellingError
    {
        [PreserveSig] int Next(out ISpellingError? value);
    }

    [ComImport, Guid("B7C82D61-FBE8-4B47-9B27-6C0D2E0DE0A3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISpellingError
    {
        uint StartIndex { get; }
        uint Length { get; }
        CorrectiveAction CorrectiveAction { get; }
        string Replacement { [return: MarshalAs(UnmanagedType.LPWStr)] get; }
    }

    [ComImport, Guid("00000101-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IEnumString
    {
        [PreserveSig] int Next(int count, [Out, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr, SizeParamIndex = 0)] string[] values, out int fetched);
    }

    private enum CorrectiveAction { None = 0, GetSuggestions = 1, Replace = 2, Delete = 3 }
}
