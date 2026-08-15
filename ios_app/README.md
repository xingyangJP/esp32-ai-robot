# RobotBrain — native iOS app (Concept B)

Talk to the Freenove ESP32 car **from your iPhone**: type or **speak** a goal, watch
the live camera under a **frosted-glass (Liquid Glass) HUD**, and the app runs the
OpenAI vision→action loop and drives the car — **no Mac at runtime**.
**Bilingual (日本語 / English).** (You still need a Mac + Xcode **once** to build & install it.)

## ⚠️ Honest status
- These are **hand-written Swift source files, NOT compiled or tested** (this can't be
  done outside Xcode). Expect to open them in Xcode, fix a few small issues, and iterate.
  The logic mirrors the **already-verified** Python host-brain and firmware protocol.
- **Motion** still needs the car's batteries. Keep **Dry-run ON** until then (plans +
  speaks, never sends motor commands).

## Build & run (on a Mac)
The project is **ready to open** — Info.plist keys, en/ja localizations, and the app icon are already wired
(via `project.yml` → `RobotBrain.xcodeproj`). It's **verified to build on Xcode 26 / iOS 26 SDK** and runs on
the iOS 26 simulator (Japanese UI + glass HUD confirmed).

1. `open ios_app/RobotBrain.xcodeproj` (if you edit `project.yml`, run `xcodegen generate` to rebuild it).
2. Select the **RobotBrain** target → **Signing & Capabilities** → your personal Apple ID team (free).
3. Put your **iPhone on the same Wi-Fi** as the car, pick it as the run destination, press **Run**.
   Tap **Allow** on the local-network prompt; tap the mic button to grant microphone/speech when you first use voice.
4. In the app: set **Car IP** (the car's current DHCP IP — check its serial boot log or your router) and paste
   your **OpenAI API key**. Keep **Dry-run ON** until the batteries are in.

The in-app Settings → Language picker (Auto / English / 日本語) switches UI, AI replies, and voice live.

## Notes
- **Car IP is DHCP** and can change. If it stops connecting, re-check the car's IP (serial boot log or your router) and update it in Settings.
- **API key is stored in `UserDefaults`** on the phone (not encrypted). Personal use only; don't share the build. (Move to Keychain if you want it hardened.)
- The camera uses the car's TCP `:7000` stream (4-byte length + JPEG) directly — no Mac proxy.
- **Glass look**: panels use `.ultraThinMaterial`. On iOS 26 you can swap those for `.glassEffect()` for the true system Liquid Glass material.

## Files
- `RobotBrainApp.swift` — app entry.
- `ContentView.swift` — glass UI over the live camera (status, report, goal, mic, STOP, settings); bilingual via `LocalizedStringKey` + `.environment(\.locale)`.
- `RobotController.swift` — control loop (safety > pulse-drive; heartbeat), language resolution, state.
- `CarLink.swift` — TCP `:4000` commands + `:7000` JPEG stream (Network.framework).
- `Brain.swift` — OpenAI vision call → structured Intent (replies in the chosen language).
- `Speech.swift` — speech-to-text (goals) + text-to-speech (robot voice), locale-aware.
- `Dispatcher.swift` — semantic action → exact `CMD_` strings (clamps + dead-zone).
- `Assets.xcassets/AppIcon` — the app icon (1024²).
- `en.lproj/`, `ja.lproj/` — `Localizable.strings` (English / Japanese).
