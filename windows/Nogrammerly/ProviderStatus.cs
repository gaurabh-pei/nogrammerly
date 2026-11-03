namespace Nogrammerly;

/// <summary>Phi Silica availability, decoupled from the Windows App SDK so the wording is testable anywhere.</summary>
internal enum PhiState { Ready, NeedsDownload, DisabledByUser, Unsupported, NeedsInstall }

/// <summary>
/// The tray's UI-independent wording: the status line for the selected provider and the privacy
/// claim the app may make. Status text never contains the configured URL or any typed text.
/// </summary>
internal static class ProviderStatus
{
    public static string Name(AiProvider provider) => provider switch
    {
        AiProvider.PhiSilica => "Phi Silica",
        AiProvider.LmStudio => "LM Studio",
        _ => "Rules only",
    };

    /// <summary>One menu line: the selected provider plus its current problem, if any.</summary>
    public static string StatusText(AiProvider provider, PhiState phi, string? lmError) => provider switch
    {
        AiProvider.PhiSilica => phi switch
        {
            PhiState.Ready => "On-device AI is on",
            PhiState.NeedsDownload => "Set up on-device AI…",
            PhiState.DisabledByUser => "On-device AI is turned off in Windows Settings",
            PhiState.NeedsInstall => "Install with Install.cmd for on-device AI",
            _ => "On-device AI needs a Copilot+ PC",
        },
        AiProvider.LmStudio => lmError is { Length: > 0 } e ? "LM Studio: " + char.ToUpperInvariant(e[0]) + e[1..] : "LM Studio selected, no errors reported yet",
        _ => "Rules only: no AI provider is used",
    };

    /// <summary>The Phi download offer appears only while Phi Silica is the selected provider.</summary>
    public static bool ShowPhiSetup(AiProvider provider, PhiState phi) => provider == AiProvider.PhiSilica && phi == PhiState.NeedsDownload;

    /// <summary>What the app may claim about where text goes. Only local providers may say it stays on the PC.</summary>
    public static string PrivacyCopy(AiProvider provider) => provider switch
    {
        AiProvider.LmStudio => "With LM Studio, the text being checked or rewritten is sent over your network to the "
            + "address you configured — over plain HTTP that is unencrypted on your LAN (use HTTPS if your server "
            + "supports it). That model runs on a separate machine, not on this PC, and nothing is sent until LM Studio is selected.",
        _ => "Nothing you type leaves this PC.",
    };
}
