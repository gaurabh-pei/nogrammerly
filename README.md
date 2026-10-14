<p align="center"><img src="Assets/Nogrammerly-logo.png" width="520" alt="Nogrammerly"></p>

<p align="center"><b>The free, open-source, 100% on-device Grammarly alternative for Mac and Windows.</b><br>
Spelling, grammar, clarity and tone checks plus one-click rewrites, in Slack, Teams, Outlook, Mail, Zoom, Notepad and almost every other app.<br>
Powered by the AI built into your computer: Apple Intelligence on Mac, Phi Silica on Windows Copilot+ PCs. Your writing never leaves your device.</p>

<p align="center">
  <a href="https://github.com/gaurabh-pei/nogrammerly/releases/latest"><img src="https://img.shields.io/github/v/release/gaurabh-pei/nogrammerly?label=download&color=4f46e5" alt="Download"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011%20(beta)-0078D4?logo=windows" alt="Windows 10 and 11 (beta)">
  <a href="https://github.com/gaurabh-pei/nogrammerly/actions/workflows/swift.yml"><img src="https://github.com/gaurabh-pei/nogrammerly/actions/workflows/swift.yml/badge.svg" alt="Mac build"></a>
  <a href="https://github.com/gaurabh-pei/nogrammerly/actions/workflows/windows.yml"><img src="https://github.com/gaurabh-pei/nogrammerly/actions/workflows/windows.yml/badge.svg" alt="Windows build"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT license"></a>
</p>

<p align="center"><a href="https://github.com/gaurabh-pei/nogrammerly/releases/latest"><b>⬇ Download for Mac</b></a> · <a href="https://github.com/gaurabh-pei/nogrammerly/releases/tag/v1.2.0-beta.1"><b>⬇ Download for Windows (beta)</b></a> · <a href="#how-it-works">How it works</a> · <a href="CONTRIBUTING.md">Contribute</a></p>

<p align="center"><img src="Assets/demo.gif" width="820" alt="Nogrammerly fixing spelling and wordiness with a right-click, then rewriting the message in a professional tone"></p>

---

## Why Nogrammerly?

Cloud writing assistants read everything you type, including private Slack DMs, work email and medical notes, and send it to their servers. Nogrammerly does the same job **entirely on your computer**, using the language model built into it: Apple Intelligence on a Mac, Phi Silica on a Windows Copilot+ PC.

| | Nogrammerly | Cloud writing assistants |
|---|---|---|
| Where your text goes | **Stays on your device** | Sent to their servers |
| Price | **Free** | Free tier, then a subscription |
| Account needed | **No** | Yes |
| Works offline | **Yes** | No |
| Source code | **Open (MIT)** | Closed |
| Platforms | **Mac and Windows** | Varies |

## Features

- **Works everywhere.** It underlines problems in the text field you're typing in, in almost any app.
  - 🔴 correctness · 🔵 clarity · 🟣 delivery · 🟠 style
- **Right-click an underline** to see the suggestion and choose **Replace**, **Copy suggestion**, **Rewrite sentence**, **Ignore** or **Add to dictionary**.
- **A floating field button** sits in the bottom-right corner of the active field: a green ✦ when there are no issues, red with a count when there are. Click it to see all the suggestions, or to **rewrite the selection** or **the whole text**. Rewrites come in four tones: Professional, Friendly, Confident and Concise.
- **A ✦ icon** in the Mac menu bar or the Windows notification area shows the issue count for the current field, with the same actions.
- **A built-in editor** (Mac) with a writing score, a tone picker and a ✦ Rewrite button.
- **Private by design.** Checks use the system spell checker, built-in style rules and the on-device language model: Apple Intelligence on Mac, Phi Silica on Windows. Nothing is sent over the network.
- **No AI hardware? Still useful.** Without an on-device model you still get spelling, grammar and style checks.

## Install

### Mac

1. Download **Nogrammerly-Installer.dmg** from the [latest release](https://github.com/gaurabh-pei/nogrammerly/releases/latest).
2. Open it and drag **Nogrammerly** into **Applications**.
3. Open Nogrammerly from Applications. The app isn't notarized by Apple yet, so the first time, macOS will block it. Go to **System Settings › Privacy & Security**, scroll down and click **Open Anyway**. You only need to do this once.
4. Follow the **Setup** window. It walks you through allowing Accessibility access and shows a live status for each step.

| Requirement | |
|---|---|
| macOS | 14 Sonoma or later, on Apple silicon |
| AI checks & rewrites | macOS 26+ with Apple Intelligence turned on. Without it you still get spelling, grammar and style checks. |
| Permission | Accessibility (System Settings › Privacy & Security › Accessibility) |

### Windows (beta)

1. Download the zip for your PC from the [Windows beta release](https://github.com/gaurabh-pei/nogrammerly/releases/tag/v1.2.0-beta.1):
   - **Nogrammerly-Windows-x64.zip** for most Intel and AMD PCs.
   - **Nogrammerly-Windows-arm64.zip** for Arm PCs, such as Snapdragon Copilot+ PCs.
2. Extract it and double-click **Install.cmd**. If Windows says "Windows protected your PC", click **More info › Run anyway**. The app isn't code-signed yet.
3. Look for the ✦ icon near the clock.

| Requirement | |
|---|---|
| Windows | Windows 10 (version 2004) or Windows 11, on x64 or Arm |
| AI checks & rewrites | A Copilot+ PC, with **Developer Mode** turned on before you run Install.cmd. Without it you still get spelling and style checks. |
| Permission | None. It installs for your account only, without admin rights. |

The [Windows guide](windows/README.md) covers setting up the AI, troubleshooting and building from source.

## Build

### Mac

You need the Xcode Command Line Tools (Swift 5.10+). Full Xcode isn't required.

```bash
# One-time: create a self-signed code-signing identity in your login keychain.
# Without it, builds are signed ad hoc and macOS forgets the Accessibility
# permission after every rebuild.
./script/create_signing_identity.sh

./script/build_and_run.sh            # build dist/Nogrammerly.app and launch it
./script/build_and_run.sh --bundle   # build only
./script/build_and_run.sh --logs     # launch and stream logs
./script/create_dmg.sh               # build dist/Nogrammerly-Installer.dmg
swift test                           # run the WritingEngine tests (also run by GitHub Actions)
```

The icon is generated from `Assets/Nogrammerly-icon.png` (a 1024×1024 image with square edges that fills the whole canvas). `script/create_icon.sh` masks it to the macOS rounded-square shape and builds the `.icns`.

### Windows

The Windows app is C# on .NET 10, in [`windows/`](windows/README.md#build-from-source). You need Windows to build it. GitHub Actions builds and tests it on every push.

## How it works

Nogrammerly works the way system-wide checkers like Grammarly Desktop do. Here is the Mac version; the Windows version follows the same steps with Windows APIs (see the table below).

1. **Read.** It uses the macOS Accessibility API to find the focused text element and read its value and selection. For Electron apps such as Slack, it sets `AXManualAccessibility` so their text fields become readable. Password fields are always skipped.
2. **Analyse.** `NSSpellChecker` handles spelling and grammar, phrase rules catch wordiness and hedging, and Apple's on-device language model does contextual proofreading. AI results are cached per paragraph and debounced while you type.
3. **Draw.** It asks the app where each issue is on screen (`AXBoundsForRange`) and draws underlines in a transparent overlay panel that lets clicks pass through.
4. **Interact.** A session event tap picks up right-clicks that land on an underline, and only those; every other click passes through to the app.
5. **Replace.** It selects the issue's range and writes the replacement text through the Accessibility API, so undo (⌘Z) works. If an app ignores that, it falls back to pasting and then restores your clipboard.

| File | Responsibility |
|---|---|
| `Sources/Nogrammerly/SystemWritingAssistant.swift` | Cross-app monitoring, overlay underlines, right-click menu, field button, text replacement |
| `Sources/Nogrammerly/WritingEngine.swift` | Spelling, grammar and style rules; merging suggestions |
| `Sources/Nogrammerly/AIWriter.swift` | On-device Foundation Models proofreading and rewrites |
| `Sources/Nogrammerly/SetupWindowController.swift` | First-run setup guide with live status |
| `Sources/Nogrammerly/AppDelegate.swift` | App lifecycle, menus, built-in editor window |
| `script/` | Build, signing, icon, and DMG scripts |
| `windows/` | The Windows app ([details](windows/README.md#build-from-source)) |

| Step | Mac | Windows |
|---|---|---|
| Read the text you're typing | Accessibility API | UI Automation |
| Spelling | `NSSpellChecker` | Windows Spell Checking API |
| AI proofreading & rewrites | Apple Foundation Models | Phi Silica (Windows App SDK) |
| Catch right-clicks on underlines | Event tap | Low-level mouse hook |
| Replace text (undo works) | Accessibility API, then paste | Select with UI Automation, then type |

## Troubleshooting

These are for the Mac. For Windows, see the [Windows guide](windows/README.md#troubleshooting).

- **Accessibility is switched on but Setup still shows it amber.** macOS ties the approval to the exact signed build. Click **Reset & Ask Again** in the Setup window and switch Nogrammerly on again. With the stable signing identity this is only needed once.
- **No underlines in one app.** Some apps don't report where their text is on screen. The field button and the ✦ menu-bar icon still list and apply every suggestion.
- **Grammarly or another checker is installed.** Their underlines may overlap with Nogrammerly's. Turn one of them off.
- **AI suggestions are missing.** Make sure Apple Intelligence is turned on and has finished downloading.

## Uninstall

**Mac:** quit Nogrammerly from the ✦ menu. Drag it from Applications to the Bin, then remove it from System Settings › Privacy & Security › Accessibility.

**Windows:** double-click **Uninstall.cmd** in the folder you extracted.

---

<p align="center">Nogrammerly is an independent open-source project. It is not affiliated with, endorsed by or connected to Grammarly, Inc.<br>
If it saves you a subscription, please ⭐ <b>star the repo</b>. It helps other people find it.</p>
