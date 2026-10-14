# Contributing

Thanks for helping make Nogrammerly better! Issues and pull requests are welcome.

## Getting started

```bash
./script/create_signing_identity.sh   # once: keeps the Accessibility permission across rebuilds
./script/build_and_run.sh             # build and launch dist/Nogrammerly.app
swift test                            # run the tests
```

You only need the Xcode Command Line Tools; full Xcode isn't required. AI features need macOS 26+ with Apple Intelligence turned on.

## Good first contributions

- **App compatibility.** Try Nogrammerly in an app you use and report (or fix) cases where underlines are misplaced or replacements fail. Please include the app name and version.
- **Style rules.** Add phrase rules to `styleRules` in `Sources/Nogrammerly/WritingEngine.swift`, with a test in `Tests/NogrammerlyTests`.
- **Localization.** The rule-based checks are English-only today.

## Guidelines

- Keep everything on-device. Pull requests that send user text over the network won't be accepted.
- Never read secure (password) fields.
- Match the surrounding code style, keep changes focused, and add a test where it makes sense.
- Testing tip: run `.build/debug/Nogrammerly` from a terminal that has Accessibility access. It inherits that permission, so you don't need to re-grant it after each build.
