# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

DuckBuddy is the phone app for Pollen Robotics' **Microduck**, a 15-servo bipedal duck, built natively for iOS (SwiftUI) and Android (Jetpack Compose) on a shared Rust core. Bundle ID / package: `robot.duckbuddy.microduck`. Docs and UI text are Chinese-first, with English mirrors (`README.en.md`). Requirements and design live in `docs/prd.md` and `docs/technical-design.md` (Chinese).

## Commands

`cargo` is in `~/.cargo/bin`. Android builds use Android Studio's bundled JDK.

```bash
cd core && cargo test                       # 49 core tests; single test: cargo test secure_mode
core/scripts/build-ios.sh                   # → ios/DuckCore/ (xcframework + Swift bindings)
core/scripts/build-android.sh               # → android/app/src/main/{jniLibs,java/uniffi}
python3 shared/gen.py                       # after editing shared/icons.json
cd ios && xcodebuild -project DuckBuddy.xcodeproj -target DuckBuddy -sdk iphonesimulator -arch arm64 CODE_SIGNING_ALLOWED=NO build
cd android && JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew :app:assembleDebug
ios/scripts/screenshots.sh <dir> [pages]       # demo-mode screenshots, iPad simulator emulating other windows
android/scripts/screenshots.sh <dir> [pages]   # needs a running emulator (e.g. a Pixel Fold AVD)
android/scripts/package.sh <dir> [ver] [build]  # release APK, signed with the local debug key
ios/scripts/package.sh <dir> [ver] [build]      # unsigned ipa (no certificate needed)
```

- Run the binding scripts on a fresh clone and after any change to `core/`. The generated Swift and Kotlin bindings and the native libraries are git-ignored; never edit them by hand.
- The icon code that `shared/gen.py` generates *is* committed; CI fails if it is stale.
- GitHub Actions (`.github/workflows/ci.yml`) runs on every push to `main` and on pull requests: `cargo test --locked`, the stale-icon check, an Android debug build and an iOS simulator build. Nothing is signed.
- Two remotes: `origin` is the private Gitea (`192.168.50.48:3000`), `github` is the public open-source mirror. `AGENTS.md` is a symlink to this file.
- `android/local.properties` (`sdk.dir=…`) is local and ignored.
- Gitea Actions (`.gitea/workflows/package.yml`) runs both package scripts on a self-hosted macOS runner (label `macos`, host mode) on `v*` tags or manual dispatch, uploads the files as run artifacts, and publishes them to the generic package `duckbuddy/<version>` when the `PKG_TOKEN` secret is set.
- **Demo mode** runs every screen without a robot:
  - iOS: launch arg `-demo`, plus `-route drive|status|policy|gamepad|settings|setup`, `-simulateWindow WxH`, `-started`, `-colourway cream|graphite|lavender|sky`.
  - Android: `adb shell am start -n robot.duckbuddy.microduck/.MainActivity --ez demo true`, plus `--es route <page>`, `--es window WxH`, `--ez en true`, `--es colourway <name>`.
  - Real video in demo mode (simulators have no Bluetooth): iOS `-webrtc <robot ip>`, Android `--es webrtc <robot ip>`. Video and sticks then go to the real robot's `mediad`; everything else stays demo data. `-stick walk|head:<lx>,<ly>,<rx>,<ry>:<seconds>` (Android `--es stick …`) holds a stick after launch, because a simulator has no fingers. `-tray` (Android `--ez tray true`) opens the emotion tray for screenshots. `-capture photo|record:<seconds>` (Android `--es capture …`) takes a photo or records a clip once video is live. On the Android emulator, `adb shell input swipe` drives the real sticks.

## Architecture

### `core/`: the only place the protocol lives (Rust, UniFFI)
- Depends on the official crates `duck-ipc-proto`, `duck-ble`, `duck-auth` and `kinematics` from `pollen-robotics/microduck`, via git `main`. Upstream protocol changes are meant to break this build.
- Platform code never contains RPC method names. It builds typed `DuckCall` values (`calls.rs`, mapped to `proto::Call`) and decodes replies with the `decode_*` functions in `results.rs`.
- `link.rs` / `DuckLink` is a pure BLE session state machine. The platform passes notification bytes to `receive()` and writes out the chunks it returns. It has two modes:
  - Secure: Noise `NNpsk0` from an `md1:<name>:<64 hex>` setup code, then encrypted `data` envelopes.
  - PIN: `hello` then `system.authenticate`, silently with the saved PIN or the factory `000000`. If refused, `PinRequired` parks the link in `AwaitingPin` until the platform calls `submit_pin`. Labelled robots default to the last 6 digits of the label serial; btd allows 3 tries per session. Setup asks for the PIN only then, and for a setup code only when `hello` gets no reply; otherwise it skips the Verify step.
  - Robots below API 31 are refused.
- `RpcCodec` produces the same JSON-RPC lines for the WebRTC data channel. Continuous intents (`robot.move`, `robot.head`) are notifications, meant for `teleop`. Robot 0.17.8 only creates `control`, so the apps fall back to it.
- `signalling.rs`: the `mediad` WebRTC signalling (gst `webrtcsink` protocol on `ws://<ip>:8443`, LAN, no auth) as a pure state machine. It follows the robot's own `mediad/webclient/index.html`: the robot offers and the app answers, ICE trickles both ways, and the robot creates the `control` data channel. It also handles `media.video` (camera mount rotation, 90° on the bench robot).
- `state.rs`: posture classification, with the same thresholds as robotd's `posture.rs`.
- `drive.rs`: stick mapping, deadzone, and the roller preset.
- `viewer.rs`: loads `shared/models/duck-web-mouth-v2.bin` (DHD2 format) and computes per-part matrices (forward kinematics plus trunk attitude) and the orthographic camera. Platforms only draw.
  - Each part's 4th colour byte is its official material role (mapped from the mesh names in pollen-robotics.com/microduck's `microduck.glb`). `part_colours(Colourway)` gives the colours for the four official colourways (Cream, Graphite, Lavender, Sky), from the site's three.js table converted to sRGB. The battery (`np_f970`) is the site's mesh. The user picks the colourway on the Status page, and it is saved per robot in `KnownRobot.colourway`.
- `emotion.rs`: the robot's own emotion animations (13 since API 49, unchanged in 0.23.0), played with `robot.do <name>`. The robot lists them only in the `robot.subscribe` reply, which BLE can't reach, so the list lives here. The Drive emotion tray and the Gamepad page use it; robots below API 49 keep the old head-gesture fallback.
- `games.rs`: the three play modes — laser chase, autonomous soccer, free play (`robot.laserTrack` / `robot.soccer` / `robot.autonomous`) — and `robot.mode` decoding. One at a time, the way NFC mode tags switch them. `prefers_media` sends them over `control` when the video link is open (any `mediad`); BLE routes them only from 0.23.0 (API 67). `autod` (free play) yields only to `padd`, so pushing an app stick switches free play off (`takeOverFromAutonomous`). The Drive tray shows them first; in wide windows the tray is a grid beside the video so it never covers it.
- `voice.rs`: the Doubao realtime-voice turn logic. It holds tool calls until the user releases on "Send", discards everything on cancel, runs pre-checks, and caps voice moves at 5 s and half speed. It handles JSON frames only; the WebSocket, mic and speaker are platform code.
- `manifest.rs`: checks a policy manifest before download (obs length 61, action length 14, robot model, skill encoding). A missing field is not an incompatibility; only a stated mismatch is.
- `fan.rs`: fan status, which is **not** an official protocol. It comes from `duck-fanstat`, our own read-only service in `robot/fanstat/` (install script plus a systemd unit), at `http://<ip>:8096/fan` with schema `duckbuddy.fan/v1`. On a duck without the service the request fails, and the apps show no fan.
- `DuckLink` uses `shutdown()` rather than `close()`, because `close` clashes with Kotlin's `AutoCloseable`.

### `shared/`: a single source for both apps
- `i18n/strings.json` holds all UI text (`zh` / `en`) and is loaded at runtime on both platforms.
- `icons.json` holds the design canvas's SVG paths; `gen.py` generates `ios/.../Design/Icons.generated.swift` and `android/.../design/Icons.kt` from it.
- `fonts/`, `images/` and `models/` are referenced in place by both projects (Xcode file references; Gradle `assets.srcDirs` plus a font copy task), not duplicated.

### `ios/` and `android/`: platform layers mirror each other file by file
| Piece | iOS | Android |
| --- | --- | --- |
| BLE | `BleCentral` (CoreBluetooth) | `BleCentral` (explicit `createBond()` before protected reads; GATT-triggered bonding timed out on some phones) |
| Session | `RobotSession`: silent reconnect, 20 s lease renewal, request/reply matching by id, global `busy` lock | same |
| Video / teleop | `MediaLink`: `WebRTCMediaLink` (libwebrtc via SPM `stasel/WebRTC`, `RTCMTLVideoView`) opens on the robot's Wi-Fi IP once BLE is ready; it subscribes `robot.state` over `control` and restarts the session when decoded frames stall. `DemoMediaLink` streams fake state | same (`io.github.webrtc-sdk:android`, `SurfaceViewRenderer`; cleartext `ws://` allowed in the manifest) |
| Demo backend | `DemoRobot` answers in official reply shapes, decoded by the same core | same |
| Secure storage | Keychain `ThisDeviceOnly` | Keystore AES-GCM in `secure.xml`, excluded from backup and transfer |
| 3D | Metal (`DuckViewer`) | GLES 3.0 (`DuckGLView`), same shader math |

- The iOS project uses Xcode folder-synchronized groups, so new files under `ios/DuckBuddy/` are picked up without editing the pbxproj.
- iOS state is `@Observable` with `@MainActor`.
- Android state is Compose `mutableStateOf` in `AppModel` (a ViewModel). Navigation is a route stack in `AppModel.path`.
- Photos and recording (platform code, not core): `VideoCapture` on each platform taps the same frames as the video view, with the camera mount rotation applied. A photo is a JPEG of the next frame; a recording is an MP4 with H.264 video and AAC audio. `mediad` sends no audio, so the AAC track is the phone mic, filled with silence whenever the mic gives nothing (no permission, held by the voice key, no input device). iOS uses AVAssetWriter, with rotation in the track matrix; Android uses MediaCodec and MediaMuxer, drawing frames upright through EGL. Files go to the photo library (iOS add-only access; Android MediaStore `Pictures|Movies/DuckBuddy`, with `WRITE_EXTERNAL_STORAGE` only on API ≤ 28). Recording stops and saves when you leave Drive, turn the camera off, or go to the background.

### Adaptive layout (same rules on both platforms)
- `LayoutClass` is based only on window size:
  - PhonePortrait: width < 600
  - PhoneLandscape: height < 500
  - Dual: aspect < 1.3
  - Expanded: anything else
- Phone layouts place elements at the design canvas coordinates (390×844 portrait, 844×390 landscape), scaled. The Drive screen does this explicitly.
- Wide layouts use `TwoPane`. On the Drive screen the sticks hug the outer edges, and the mic and Start keys sit either side of the centre line.
- Android reads the fold from WindowManager `FoldingFeature` (`LocalHinge`):
  - Any vertical fold switches to Dual, with panes split at the fold. A fold lying flat is not reported as "separating", but the crease is still there.
  - Tabletop posture keeps the video above the fold.
- iOS has no hinge API, so the iPhone Duo is handled by window size.
- Folding, rotation and split view must never interrupt the session; keep state in the models, not in views.

### Design fidelity
The UI implements the DuckBuddy design canvas (not public). Colours, sizes, the Anton/DM Sans type, hard shadows and the selection style come from it; see `Palette` / `Typo` in each `Theme` file. Anton titles render CJK runs in the heaviest system weight, matching the canvas's `Noto Sans SC 900` fallback (`Title(...)`). After UI changes, compare screenshots from the scripts against the canvas.

## Robot facts learned on hardware (0.17.8, API 44)
- BLE (`btd`) refuses `robot.move`, `robot.head`, `robot.stop`, `robot.mode` and `robot.subscribe`. The sticks need WebRTC, and `robot.stop` goes over `control` when it is open.
- Standing up: when the policy is not driving, `robot.enable on` homes the robot and rises it. `sit_toggle` is refused until the policy drives. `robot.init` only reaches the seat. The rules are in core `posture_call`.
- `btd` serves one BLE central at a time. While one is connected it advertises the same payload as a non-connectable broadcast; core parses it as `Advertisement.busy`, and the apps report "connected to another device" instead of "not nearby". `mediad` accepts several WebRTC peers.
- `PoliciesResult.enabled` is the `[policy] enabled` config flag, not the motor state.
- `mediad` can be disabled per robot by a drop-in. Its video pipeline sometimes freezes until `mediad` restarts; the apps can only detect this and reconnect.
- Doubao realtime: transcription deltas are snapshots, not increments. The server needs uplink audio to finish a turn, so the apps send silence after Send. Tool results use `items:[{type:message, role:tool}]`. Cancelling closes the session, because the input buffer can't be cleared.

## Not implemented yet
- A `teleop` (unreliable) channel: robot 0.17.8 doesn't create one.
- Secure (Noise setup-code) mode: robot 0.17.8's `btd` doesn't support it.
- Open questions with Pollen (technical design §8): the body height/lean API, writing `allow_community` from the phone, and identify-before-auth.
