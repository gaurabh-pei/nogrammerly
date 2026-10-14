# Nogrammerly for Windows (beta)

The same free, on-device writing assistant as the Mac app, for Windows 10 and 11. It underlines spelling, grammar, clarity and style issues in almost any app, and you can right-click an underline to fix it. Nothing you type leaves your PC.

## Install

1. Download the zip for your PC from the [latest release](https://github.com/gaurabh-pei/nogrammerly/releases):
   - **Nogrammerly-Windows-x64.zip** for most PCs (Intel or AMD).
   - **Nogrammerly-Windows-arm64.zip** for Arm PCs, such as Snapdragon Copilot+ PCs.

   Not sure which you have? Open **Settings › System › About** and look at **System type**.
2. Right-click the zip, choose **Extract All…**, then open the extracted folder.
3. Double-click **Install.cmd**. If Windows shows "Windows protected your PC", click **More info › Run anyway**. The app isn't code-signed yet.

The installer:
- installs Nogrammerly for your account only, in `%LOCALAPPDATA%\Programs\Nogrammerly`, so it doesn't need admin rights;
- adds it to Start;
- starts it whenever you sign in.

Look for the ✦ icon near the clock. If you don't see it, it may be hidden under **^**.

## On-device AI (Copilot+ PCs)

On a Copilot+ PC, Nogrammerly can use **Phi Silica**, the language model built into Windows that runs on the PC's NPU. This is the Windows counterpart of Apple Intelligence on the Mac. It adds grammar, clarity and tone checks, and AI rewrites in four tones.

Windows only lets installed packages use Phi Silica. To install Nogrammerly as a package without a paid code-signing certificate, the installer needs **Developer Mode**:

1. Open **Settings › System › For developers** and turn on **Developer Mode**.
2. Run **Install.cmd** again.
3. Click the ✦ icon, choose **Set up on-device AI…**, and confirm. Windows may need to download the model through Windows Update first.

The ✦ menu shows whether the AI is on. Without Developer Mode, or on a PC that isn't a Copilot+ PC, Nogrammerly still works. It uses the Windows spell checker and its built-in style rules.

## How to use it

- Type in almost any app. Issues are underlined in four colours:
  - red for correctness
  - blue for clarity
  - purple for delivery
  - orange for style
- **Right-click an underline** to:
  - **Replace** the text, which you can undo with Ctrl+Z;
  - **Copy suggestion**;
  - **Rewrite sentence**;
  - **Ignore** the issue;
  - **Add to dictionary**.
- **Click the round button** in the corner of the text box to:
  - see every suggestion;
  - rewrite your selection;
  - rewrite the whole text.
- **Click the ✦ icon** to:
  - pause Nogrammerly;
  - check whether the AI is on;
  - quit.

Password fields are never read. Fixes are only typed while the app you're writing in is in front, and line breaks are typed as Shift+Enter, so a rewrite can't send a chat message early.

## Troubleshooting

- **No underlines in one app.** Some apps, notably some Electron apps, don't tell Windows where their text is on screen. The round button and the ✦ menu still list and apply every suggestion.
- **"Install with Install.cmd for on-device AI" in the ✦ menu.** Turn on Developer Mode, then run **Install.cmd** again.
- **"On-device AI needs a Copilot+ PC".** This PC has no supported NPU. The spelling and style checks still work.

## Uninstall

Double-click **Uninstall.cmd** in the extracted folder. Or run `Install.ps1 -Uninstall` from `%LOCALAPPDATA%\Programs\Nogrammerly`.

## Build from source

You need the .NET 10 SDK on Windows.

```powershell
cd windows
dotnet test --project Nogrammerly.Core.Tests
dotnet test --project Nogrammerly.Tests
dotnet publish Nogrammerly -c Release -r win-x64 -o out
```

| Folder | What's in it |
|---|---|
| `Nogrammerly.Core` | The writing engine shared with the Mac app's logic: style rules, sentence splitting and parsing the AI's replies. Cross-platform. |
| `Nogrammerly` | The Windows app: UI Automation to read and edit text in other apps, the Windows Spell Checking API, Phi Silica through the Windows App SDK, and the overlay windows. |
| `Nogrammerly/Package` | The package manifest and the installer scripts. |

CI ([`.github/workflows/windows.yml`](../.github/workflows/windows.yml)) builds both architectures. It runs the tests on Windows, including one that edits a real Notepad window. It also attaches the zips to tagged releases.
