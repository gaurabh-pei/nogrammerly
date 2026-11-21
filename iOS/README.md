# Nogrammerly for iPhone and iPad

An editor app plus the **Nogrammerly keyboard**, which checks your writing in any app.
It shares the writing engine (`NogrammerlyCore` in the root Swift package) with the Mac app.

- Requires iOS 26. AI grammar, tone and rewrites need Apple Intelligence; spelling and style checks work without it.
- The keyboard does not request Full Access, so iOS keeps it off the network.
- A keyboard only sees the text before the cursor, so fixes apply to what you have just typed.

## Build

```sh
brew install xcodegen      # once
cd iOS && xcodegen          # regenerates Nogrammerly.xcodeproj from project.yml
open Nogrammerly.xcodeproj  # scheme: NogrammerlyiOS
```

To run on an iPhone, choose your team under Signing & Capabilities for both the
NogrammerlyiOS and NogrammerlyKeyboard targets. Then turn the keyboard on in
Settings → Apps → Nogrammerly → Keyboards.

## Test

The UI test types a typo with the Nogrammerly keys and taps the fix. Enable the keyboard on the simulator first:

```sh
xcrun simctl spawn booted defaults write .GlobalPreferences AppleKeyboards -array \
  com.nogrammerly.ios.keyboard "en_US@sw=QWERTY;hw=Automatic"
# then restart the simulator
xcodebuild -project Nogrammerly.xcodeproj -scheme NogrammerlyiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
