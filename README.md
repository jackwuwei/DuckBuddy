# DuckBuddy App

**简体中文** | [English](README.en.md)

Microduck 的手机 App，iOS 和 Android 均为原生开发：添加机器人、驾驶、做动作、换策略、看状态、改网络。界面按[设计画布](https://claude.ai/artifact/1kW1trcfvcvhkW1cqkQFGn)实现，支持手机横竖屏、iPad / Android 平板、iPhone Duo 和 Android 折叠屏。

- 包名 / Bundle ID：`robot.duckbuddy.microduck`
- 需求：[docs/prd.md](docs/prd.md)　方案：[docs/technical-design.md](docs/technical-design.md)

## 目录

- [功能](#features)
- [工程结构](#layout)
- [环境要求](#requirements)
- [构建与运行](#build)
- [演示模式](#demo)
- [自适应布局](#adaptive)
- [安全与隐私](#security)
- [测试与设计对照](#testing)
- [尚未完成](#todo)

<a id="features"></a>

## 功能

| 页面 | 内容 |
| --- | --- |
| 连接 | 已添加的机器人（连接方式、电压），选中后连接；重新扫描 |
| 添加新鸭子 | 找鸭子 → 扫码或粘贴 `md1:` 设置码验证 → 连 Wi-Fi（已联网自动跳过）→ 起名字 |
| 驾驶 | 9:16 视频框、四种摇杆模式（行走 / 头部 / 边走边看 / 高度）、随模式变化的动作列、情绪托盘、启动键（长按 1.5 s 回初始姿态）、电源键（长按 2 s 休息、4 s 关机）、摄像头开关、按住说话 |
| 状态 | 实时 3D 姿态、站姿判定、电池 / 舵机最高温度 / 主控温度、15 个舵机的实测角度与偏差条、重启舵机 |
| 策略 | 双腿 / 轮子切换、槽位与技能、加载 / 恢复官方 / 关闭槽位、检查更新、在 Hugging Face 搜索与下载 |
| 手柄按键 | 为 A B X Y LB RB 绑定技能、恢复默认 |
| 设置 | 网络（当前网络、重连、换网）、语音（豆包密钥测试并保存、语音播报）、语言（中文 / English） |

语音控制：按住麦克风说话，上划到「发送」松开才执行，上划到「取消」或原地松开不执行。语音由豆包实时语音大模型理解，机器人用动作和叫声回应，手机只播报一句很短的执行结果。

<a id="layout"></a>

## 工程结构

```
app/
  core/          共享 Rust 核心（UniFFI 生成 Swift / Kotlin 绑定）
    src/           link 蓝牙会话与 Noise 认证 · calls 类型化调用 · results 回复解码 · state 站姿
                   drive 摇杆映射 · viewer 3D 模型与运动学 · voice 语音轮次 · manifest 兼容判定
    scripts/       build-ios.sh · build-android.sh
  shared/        两端共用资源
    i18n/strings.json   唯一文案源（中 / 英）
    icons.json          设计稿图标（gen.py 生成两端代码）
    fonts/ images/      Anton、DM Sans（OFL）、鸭子图片、演示画面
    models/             3D 模型 duck-web-mouth-v2.bin（官方 MJCF 网格，按上游 CC BY-SA-NC 模型许可）
  ios/           SwiftUI 工程（Metal 3D、CoreBluetooth、VisionKit 扫码）
  android/       Jetpack Compose 工程（OpenGL ES 3D、WindowManager 折叠屏、CameraX + ML Kit 扫码）
  docs/          PRD 与技术方案
```

协议不在 App 里重写：核心直接依赖官方 `pollen-robotics/microduck` 的 `duck-ipc-proto`、`duck-ble`、`duck-auth`、`kinematics`（跟随 `main`），官方协议一改，核心就编译失败。Swift / Kotlin 代码里不出现 RPC 方法名。

<a id="requirements"></a>

## 环境要求

| 用途 | 版本 |
| --- | --- |
| Rust | 1.89+，加上目标 `aarch64-apple-ios`、`aarch64-apple-ios-sim`、`aarch64-linux-android`、`armv7-linux-androideabi`、`x86_64-linux-android`（构建脚本会自动 `rustup target add`） |
| iOS | Xcode 26，iOS 17+ |
| Android | Android SDK 36、NDK（取最新已装版本）、JDK 17+（可用 Android Studio 自带 JBR），minSdk 26 |

<a id="build"></a>

## 构建与运行

先生成两端的核心绑定（核心代码改动后重新执行）：

```bash
app/core/scripts/build-ios.sh        # → app/ios/DuckCore/（xcframework + Swift 绑定）
app/core/scripts/build-android.sh    # → app/android/app/src/main/{jniLibs,java/uniffi}
```

改了 `shared/icons.json` 后重新生成两端图标代码：

```bash
python3 app/shared/gen.py
```

**iOS**：用 Xcode 打开 `app/ios/DuckBuddy.xcodeproj` 运行；或命令行：

```bash
cd app/ios
xcodebuild -project DuckBuddy.xcodeproj -target DuckBuddy -sdk iphonesimulator build
```

**Android**：

```bash
cd app/android
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

核心单元测试：

```bash
cd app/core && cargo test
```

生成物（`DuckCore/`、`jniLibs/`、`java/uniffi/`、`target/`、Gradle 构建目录）已在 `.gitignore` 中，不提交。

<a id="demo"></a>

## 演示模式

不连机器人也能走完全部页面。演示鸭子的回复格式与官方协议一致，并经过同一套核心解码。

| 平台 | 启动方式 |
| --- | --- |
| iOS | 启动参数 `-demo`；可加 `-route drive\|status\|policy\|gamepad\|settings\|setup`、`-simulateWindow 820x904`、`-started` |
| Android | `adb shell am start -n robot.duckbuddy.microduck/.MainActivity --ez demo true`；可加 `--es route drive`、`--es window 390x844`、`--ez en true` |

`-simulateWindow` / `window` 把界面限制在指定窗口尺寸里，用来在没有对应模拟器时检查布局（例如 iPhone Duo 内屏、外屏）。

<a id="adaptive"></a>

## 自适应布局

两端用同一套规则，只看**当前窗口的实际尺寸**，不看设备型号：

| 类别 | 条件 | 典型设备 |
| --- | --- | --- |
| 窄竖屏 | 宽 < 600 | 手机竖屏、折叠屏外屏、iPhone Duo 外屏、平板窄分屏 |
| 矮横屏 | 高 < 500 | 手机横屏 |
| 接近正方形 | 宽 ≥ 600 且宽高比 < 1.3 | 折叠屏展开、iPhone Duo 展开、平板竖屏 |
| 宽屏 | 其他 | 平板横屏、宽窗口 |

- 手机按设计稿坐标等比放置（竖屏 390×844、横屏 844×390）。
- 宽窗口为两栏；驾驶页视频在上，摇杆贴住左右外缘，语音键和启动键在中线两侧，不压在折痕上。
- **Android 折叠屏**：通过 Jetpack WindowManager 读取折痕位置。有竖直折痕时两栏以折痕为界（展平时系统不把折痕报告为分隔，但折痕仍在，同样处理）；桌面姿态（水平折痕半开）时视频只占上半屏，控件全部在下半屏。
- **iPhone Duo**：iOS 没有公开的铰链接口，按窗口尺寸处理；展开后接近正方形，两栏等分，正好落在折痕两侧。
- 折叠 / 展开、旋转、分屏只改变布局，连接和驾驶状态保留在模型里，不会中断。

<a id="security"></a>

## 安全与隐私

- 安全模式下蓝牙走官方 Noise 握手（`Noise_NNpsk0_25519_ChaChaPoly_SHA256`），之后全部请求加密；旧机器人走出厂 PIN，由 App 静默发送。
- 设置码和豆包密钥只存在系统安全存储（iOS Keychain `ThisDeviceOnly`；Android Keystore AES-GCM，并从云备份和设备迁移中排除），不写进机器人列表文件。
- 豆包密钥由用户自己填写，App 不内置任何密钥；界面只显示末 4 位。
- 只在按住麦克风期间上传声音，首次使用单独征得同意，不保存录音。
- App 进入后台立即关闭视频与控制通道，机器人的"死人开关"约 0.6 s 内停下。

<a id="testing"></a>

## 测试与设计对照

- 核心：`cargo test`（21 项），包括与官方 `duck-auth` 机器人端的 Noise 握手互通、错误密钥、PIN 模式、旧版本机器人拒绝、站姿判定（官方 `posture.rs` 样本）、语音的攒住 / 取消 / 限时限速、加载仓库里的 3D 模型。
- 设计对照：两端各有截图脚本，按页面 × 窗口批量截图，与设计画布逐页比较：

```bash
app/ios/scripts/screenshots.sh <输出目录> [页面...]       # iPad 模拟器上模拟手机竖 / 横屏、Duo 外屏 / 内屏
app/android/scripts/screenshots.sh <输出目录> [页面...]   # 需要已启动的模拟器（例如 Pixel Fold）
```

<a id="todo"></a>

## 尚未完成

- **WebRTC 视频与 teleop 数据通道**：两端的 `MediaLink` 接入点已固定，待接入 libwebrtc 和 `duck-gateway` 认证。在此之前摇杆只在演示模式生效；动作、启动、电源等蓝牙控制可用。
- **真机验证**：蓝牙配对、豆包密钥、扫码只在演示模式和模拟器中验证过。
- **待官方确认**（技术方案 §8）：机身高度 / 侧倾接口（高度模式目前只控制头部）、手机端写入"允许下载社区策略"（目前只在 App 内生效）、认证前让机器人叫一声（目前只在演示模式显示）。
