# DuckBuddy App

[简体中文](README.md) | **English**

The phone app for Microduck, built natively for iOS and Android: add a robot, drive it, run moves, swap policies, check its status and change its network. The screens follow the [design canvas](https://claude.ai/artifact/1kW1trcfvcvhkW1cqkQFGn) and adapt to phones in portrait and landscape, iPad and Android tablets, iPhone Duo and Android foldables.

- Package / bundle ID: `robot.duckbuddy.microduck`
- Requirements: [docs/prd.md](docs/prd.md)　Technical design: [docs/technical-design.md](docs/technical-design.md) (both in Chinese)

## Contents

- [Features](#features)
- [Project layout](#layout)
- [Requirements](#requirements)
- [Build and run](#build)
- [Demo mode](#demo)
- [Adaptive layout](#adaptive)
- [Security and privacy](#security)
- [Tests and design checks](#testing)
- [Not done yet](#todo)

<a id="features"></a>

## Features

| Screen | What it does |
| --- | --- |
| Connect | Robots you've added (link type, voltage); select one and connect; rescan |
| Set up a duck | Find the duck → verify by scanning the QR code or pasting the `md1:` setup code → join Wi-Fi (skipped if the robot is already online) → name it |
| Drive | 9:16 video, four stick modes (walk / head / look / height), an action column that changes with the mode, an emotion tray, the Start key (hold 1.5 s to return home), the power key (hold 2 s to rest, 4 s to power off), a camera toggle and hold-to-talk |
| Status | Live 3D pose, posture, battery / hottest servo / controller temperature, measured angle and deviation bar for all 15 servos, reboot servos |
| Policy | Legs / wheels, slots and skills, load / reset to official / turn a slot off, check for updates, search and download from Hugging Face |
| Gamepad | Bind skills to A B X Y LB RB, reset to defaults |
| Settings | Network (current network, reconnect, switch), Voice (test and save a Doubao key, spoken replies), Language (中文 / English) |

Voice control: hold the mic and talk. It only runs if you slide up to **Send** before letting go; sliding to **Cancel** or releasing in place discards it. Doubao's realtime voice model works out what you meant, the robot answers with moves and quacks, and the phone says one short line about the result.

<a id="layout"></a>

## Project layout

```
app/
  core/          Shared Rust core (UniFFI generates the Swift / Kotlin bindings)
    src/           link: BLE session and Noise auth · calls: typed calls · results: reply decoding · state: posture
                   drive: stick mapping · viewer: 3D model and kinematics · voice: voice turns · manifest: compatibility
    scripts/       build-ios.sh · build-android.sh
  shared/        Resources used by both apps
    i18n/strings.json   The only source of UI text (Chinese / English)
    icons.json          Icons from the design (gen.py generates code for both apps)
    fonts/ images/      Anton and DM Sans (OFL), duck images, demo video
    models/             3D model duck-web-mouth-v2.bin (official MJCF meshes; upstream CC BY-SA-NC model license)
  ios/           SwiftUI project (Metal 3D, CoreBluetooth, VisionKit QR scanning)
  android/       Jetpack Compose project (OpenGL ES 3D, WindowManager for foldables, CameraX + ML Kit QR scanning)
  docs/          PRD and technical design
```

The protocol is not rewritten in the app. The core depends directly on `duck-ipc-proto`, `duck-ble`, `duck-auth` and `kinematics` from the official `pollen-robotics/microduck` repository, tracking `main`, so a change to the official protocol breaks the core's build. No RPC method names appear in the Swift or Kotlin code.

<a id="requirements"></a>

## Requirements

| For | Version |
| --- | --- |
| Rust | 1.89+, with targets `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android` (the build scripts run `rustup target add` for you) |
| iOS | Xcode 26, iOS 17+ |
| Android | Android SDK 36, an NDK (the newest installed one is used), JDK 17+ (Android Studio's bundled JBR works), minSdk 26 |

<a id="build"></a>

## Build and run

Generate the core bindings for both apps first (again whenever the core changes):

```bash
app/core/scripts/build-ios.sh        # → app/ios/DuckCore/ (xcframework + Swift bindings)
app/core/scripts/build-android.sh    # → app/android/app/src/main/{jniLibs,java/uniffi}
```

After editing `shared/icons.json`, regenerate the icon code:

```bash
python3 app/shared/gen.py
```

**iOS**: open `app/ios/DuckBuddy.xcodeproj` in Xcode and run, or from the command line:

```bash
cd app/ios
xcodebuild -project DuckBuddy.xcodeproj -target DuckBuddy -sdk iphonesimulator build
```

**Android**:

```bash
cd app/android
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Core unit tests:

```bash
cd app/core && cargo test
```

Generated files (`DuckCore/`, `jniLibs/`, `java/uniffi/`, `target/` and the Gradle build folders) are in `.gitignore` and aren't committed.

<a id="demo"></a>

## Demo mode

Every screen works without a robot. The demo duck answers in the same format as the official protocol, decoded by the same core.

| Platform | How to start |
| --- | --- |
| iOS | Launch argument `-demo`; optionally `-route drive\|status\|policy\|gamepad\|settings\|setup`, `-simulateWindow 820x904`, `-started` |
| Android | `adb shell am start -n robot.duckbuddy.microduck/.MainActivity --ez demo true`; optionally `--es route drive`, `--es window 390x844`, `--ez en true` |

`-simulateWindow` / `window` confines the UI to a window of the given size, for checking layouts that have no matching simulator (such as the iPhone Duo's inner and outer screens).

<a id="adaptive"></a>

## Adaptive layout

Both apps use the same rules, based on **the window's actual size** rather than the device model:

| Class | Condition | Typical devices |
| --- | --- | --- |
| Narrow portrait | width < 600 | Phone in portrait, foldable cover screen, iPhone Duo outer screen, narrow tablet split view |
| Short landscape | height < 500 | Phone in landscape |
| Near-square | width ≥ 600 and aspect ratio < 1.3 | Unfolded foldable, unfolded iPhone Duo, tablet in portrait |
| Wide | anything else | Tablet in landscape, wide windows |

- On phones, elements are placed at the design's coordinates, scaled (390×844 portrait, 844×390 landscape).
- Wide windows use two panes. On the Drive screen the video sits on top, the sticks hug the outer edges, and the voice and Start keys sit either side of the centre line, never on the crease.
- **Android foldables**: Jetpack WindowManager reports where the fold is. With a vertical fold, the two panes split exactly at it. Android doesn't report a fold lying flat as separating, but the crease is still there, so the app splits there too. In tabletop posture (horizontal fold, half open) the video stays in the top half and every control goes in the bottom half.
- **iPhone Duo**: iOS has no public hinge API, so it's handled by window size. Unfolded, the window is near-square and gets two equal panes that meet at the crease.
- Folding, unfolding, rotating and split view only change the layout. Connection and driving state live in the model, so nothing is interrupted.

<a id="security"></a>

## Security and privacy

- In secure mode, Bluetooth uses the official Noise handshake (`Noise_NNpsk0_25519_ChaChaPoly_SHA256`) and every request after it is encrypted. Older robots use the factory PIN, which the app sends silently.
- Setup codes and the Doubao key are kept only in the system's secure storage (iOS Keychain, `ThisDeviceOnly`; Android Keystore AES-GCM, excluded from cloud backup and device transfer), never in the robot list file.
- Users enter their own Doubao key; the app ships with none and only ever shows its last 4 characters.
- Sound is uploaded only while the mic is held, voice needs separate consent on first use, and no recordings are kept.
- When the app goes to the background, it closes the video and control channels at once, and the robot's dead-man switch stops it within about 0.6 s.

<a id="testing"></a>

## Tests and design checks

- Core: `cargo test` (21 tests), covering the Noise handshake against the official `duck-auth` robot side, wrong keys, PIN mode, refusing robots that are too old, posture classification (on samples from the official `posture.rs`), holding / cancelling voice commands and their time and speed caps, and loading the repository's 3D model.
- Design checks: each app has a screenshot script that captures every page in several window sizes, for comparison against the design canvas:

```bash
app/ios/scripts/screenshots.sh <output dir> [pages...]       # on an iPad simulator, emulating phone portrait / landscape and the Duo's outer / inner screens
app/android/scripts/screenshots.sh <output dir> [pages...]   # needs a running emulator (e.g. Pixel Fold)
```

<a id="todo"></a>

## Not done yet

- **WebRTC video and the teleop data channel**: the `MediaLink` connection point is in place in both apps, waiting for libwebrtc and `duck-gateway` authentication. Until then the sticks only move the demo robot; Bluetooth controls (actions, Start, power) work.
- **Testing on real hardware**: Bluetooth pairing, the Doubao key and QR scanning have only been checked in demo mode and in simulators.
- **Waiting on Pollen** (technical design §8): the body height / lean API (height mode only moves the head for now), writing "allow community downloads" from the phone (currently app-side only), and making a robot quack before authentication (currently shown in demo mode only).
