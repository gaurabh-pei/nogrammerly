using System.Text.Json;

namespace Nogrammerly.Core;

/// <summary>
/// Issues the user chose to ignore. Saved to a file when given a path, so they stay ignored after a restart.
/// Safe to use from several threads: the system-wide checker and the add-in bridge share one list.
/// </summary>
public sealed class IgnoreList
{
    private readonly HashSet<string> keys = [];
    private readonly Lock gate = new();
    private readonly string? path;

    public IgnoreList(string? path = null)
    {
        this.path = path;
        if (path is null || !File.Exists(path)) return;
        try { keys.UnionWith(JsonSerializer.Deserialize<string[]>(File.ReadAllText(path)) ?? []); }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException) { } // Start empty rather than fail.
    }

    public bool Contains(WritingSuggestion suggestion) => Contains(suggestion.IgnoreKey);

    public bool Contains(string key)
    {
        lock (gate) return keys.Contains(key);
    }

    public void Add(WritingSuggestion suggestion) => Add(suggestion.IgnoreKey);

    public void Add(string key)
    {
        lock (gate)
        {
            if (!keys.Add(key) || path is null) return;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(path, JsonSerializer.Serialize(keys));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { } // Still ignored until the app quits.
        }
    }
}
