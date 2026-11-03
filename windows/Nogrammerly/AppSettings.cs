using System.Text.Json;
using System.Text.Json.Serialization;

namespace Nogrammerly;

internal enum AiProvider { PhiSilica, LmStudio, RulesOnly }

/// <summary>
/// The user's explicit AI choice, persisted per-user as JSON. An invalid or
/// unreadable file never enables LM Studio: it falls back to defaults with a
/// notice the tray UI can surface.
/// </summary>
internal sealed record AppSettings(AiProvider Provider, string BaseUrl, string ModelId)
{
    public static AppSettings Default { get; } = new(AiProvider.PhiSilica, "http://127.0.0.1:1234/v1", "");

    public static string ProductionPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Nogrammerly", "settings.json");

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter((JsonNamingPolicy?)null, allowIntegerValues: false) },
        WriteIndented = true,
    };

    public bool TryValidate(out string error)
    {
        if (!Uri.TryCreate(BaseUrl, UriKind.Absolute, out var url)
            || (url.Scheme != Uri.UriSchemeHttp && url.Scheme != Uri.UriSchemeHttps)
            || url.Host.Length == 0 || url.UserInfo.Length > 0
            || url.Query.Length > 0 || url.Fragment.Length > 0
            || url.AbsolutePath != "/v1")
        {
            error = "Enter an absolute http(s) URL with a host and a /v1 path, with no credentials, query, or fragment.";
            return false;
        }
        if (Provider == AiProvider.LmStudio && string.IsNullOrWhiteSpace(ModelId))
        {
            error = "LM Studio needs a model ID before it can be enabled.";
            return false;
        }
        error = "";
        return true;
    }

    public void Save(string path)
    {
        if (!TryValidate(out var error)) throw new InvalidOperationException(error); // never persist invalid settings
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        File.WriteAllText(path, JsonSerializer.Serialize(this, Json));
    }

    public static AppSettings Load(string path, out string? error)
    {
        error = null;
        if (!File.Exists(path)) return Default;
        try
        {
            var loaded = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path), Json) ?? Default;
            if (loaded.TryValidate(out var problem)) return loaded;
            error = "Saved settings are invalid, so the default provider is used: " + problem;
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
        {
            error = "Saved settings could not be read, so the default provider is used: " + e.Message;
        }
        return Default;
    }
}
