# DuckBuddy 技术方案

| 项目 | 内容 |
| --- | --- |
| 版本 | v0.2（改为 Kotlin / Swift 原生开发） |
| 日期 | 2026-11-13 |
| 对应需求 | [PRD](prd.md) |
| 原型 | [DuckBuddy 设计画布](https://claude.ai/artifact/1kW1trcfvcvhkW1cqkQFGn) |

本文以 Pollen 官方 `pollen-robotics/microduck` 仓库的设计为准。凡是官方已有的接口，直接写方法名；官方没有、由本方案提出的部分，明确标注 **【本方案提出】**，需要与官方确认或在机器人端补充。

## 1. 总体架构

```
┌──────────── Android App（Kotlin） ────────────┐  ┌──────────── iOS App（Swift） ─────────────┐
│ Jetpack Compose 界面                           │  │ SwiftUI 界面                               │
│ BLE：android.bluetooth（GATT 读写/通知）        │  │ BLE：CoreBluetooth                         │
│ 视频+数据通道：libwebrtc（Android SDK）         │  │ 视频+数据通道：libwebrtc（iOS framework）   │
│ 3D：OpenGL ES 3.0   麦克风：AudioRecord        │  │ 3D：Metal          麦克风：AVAudioEngine    │
│ 安全存储：Android Keystore                     │  │ 安全存储：Keychain                         │
└──────────────────────┬────────────────────────┘  └──────────────────────┬────────────────────┘
                       └──────────── 共享协议核心 duck-core ────────────────┘
                         Rust 库，经 UniFFI 生成 Kotlin / Swift 绑定：
                         duck-ipc-proto 消息类型、duck-ble 分帧与广播解析、
                         Noise 握手、会话状态机、站姿/运动学、manifest 兼容判定、
                         豆包实时语音客户端（WebSocket → 火山引擎）
                │ BLE（btd，Noise 加密会话）           │ Wi-Fi 局域网 WebRTC（duck-gateway）
                ▼                                     ▼
      configd / robotd / updaterd               mediad：视频轨 + teleop / control 数据通道
```

- **开发语言**：Android 用 Kotlin，iOS 用 Swift，界面、蓝牙收发、WebRTC、摄像头、麦克风、渲染、存储都用各平台原生 API 实现，不使用 WebView 或跨平台 UI 框架。
- **协议只写一份**：官方 App 的原则是"协议放在 Rust 里"——直接依赖 `duck-ipc-proto`（消息类型）和 `duck-ble`（分帧、GATT UUID、广播解析），协议一改 App 就编译失败（`mobile-app.md` §3）。原生 App 保留这一点：把这两个 crate 和会话逻辑封装成 `duck-core`，用 [UniFFI](https://mozilla.github.io/uniffi-rs/) 生成 Kotlin / Swift 绑定，以 `.aar` 和 `.xcframework` 形式引入。`duck-core` 不碰任何系统 API，只做纯逻辑：
  - 平台层把蓝牙收到的字节交给核心，核心返回要写出的帧（UniFFI 回调接口 `BleTransport`）；
  - WebRTC 数据通道上的 JSON-RPC 请求也由核心生成、回复由核心解析；Kotlin / Swift 代码里不出现方法名字符串（`mobile-app.md` §3.1）。
- **两条通道，不是二选一**（`mobile-app.md` §1.2、§4）：
  - **蓝牙**：常驻通道。配对、认证、设置、动作、策略、网络都走它。没有网络时也能用，所以能修好"连不上网"的问题。
  - **WebRTC（Wi-Fi）**：**摄像头视频只走 WebRTC**，与连续控制（`robot.move`）、状态流（`robot.subscribe`）共用同一条认证过的 PeerConnection。地址由蓝牙上的 `net.status` 提供。两端都用 Google libwebrtc 原生库（Android 使用 `org.webrtc` SDK，iOS 使用 `WebRTC.xcframework`），版本两端保持一致。
- **版本下限**：握手时拒绝 `API_VERSION` < 31（机器人 0.14）的机器人，提示用 `duckctl update apply` 升级（`mobile-app.md` §6）。
- **系统版本**：Android 8.0（API 26）起，iOS 16 起。

> **备选方案（不推荐）**：不引入 Rust，在 Kotlin 和 Swift 中各自实现协议。代价是同一套协议、Noise 握手和会话状态机要写两遍，协议变更时没有编译期报错，只能靠两端共用的测试向量（golden 文件）发现不一致。

## 2. 工程结构

```
app/
  docs/                    本文档与 PRD
  core/                    duck-core（Rust）：协议、会话、站姿、运动学、manifest 判定、豆包语音客户端与工具执行
    uniffi/                绑定定义；构建脚本输出 duck-core.aar 与 DuckCore.xcframework
  shared/
    fonts/                 Anton、DM Sans、Noto Sans SC（随 App 打包）
    models/                duck-web-mouth-v2.bin（3D 模型，二进制）
    i18n/strings.yaml      唯一文案源，脚本生成 Android strings.xml 与 iOS String Catalog
    tokens.yaml            设计 Token，脚本生成 Compose 与 SwiftUI 常量
  android/                 Gradle 工程，Kotlin + Jetpack Compose
    app/src/main/kotlin/
      design/              色板、字体、选中态、主按钮、标题栏组件
      screens/             Connect, Setup, Drive, Policy, Status, Network, Gamepad
      drive/               摇杆、动作列、语音、视频框
      ble/                 BleTransport 实现（BluetoothLeScanner、BluetoothGatt）
      rtc/                 WebRTC 连接、视频渲染、数据通道
      viewer/              OpenGL ES 3.0 渲染器
      state/               ViewModel + StateFlow
  ios/                     Xcode 工程，Swift + SwiftUI
    DuckBuddy/
      Design/ Screens/ Drive/ BLE/ RTC/ Viewer/（Metal） State/（@Observable）
```

两端的页面、组件、文件划分一一对应，便于对照评审。共享逻辑一律放 `core/`，平台目录只放界面和系统 API 调用。

**设计系统**（对应原型）：

| Token | 值 |
| --- | --- |
| 背景 / 卡片 / 内嵌 | `#08080c` / `#101018` / `#1d1d29` |
| 主色 / 黄 / 粉 / 青 / 紫 | `#FF7A2F` / `#FFD23F` / `#FF2FA8` / `#2FF0E6` / `#9D87E8` |
| 字体 | 标题 Anton（中文回退 Noto Sans SC 900，打包真实粗体字重，禁止系统合成粗体）；正文 DM Sans + Noto Sans SC |
| 选中态 | 2pt `#FF7A2F` 描边 + 向右下偏移 4pt 的 `#FF7A2F` 实色块（无模糊） |
| 主按钮 | 橙底、`2px #08080c` 描边、`4px 4px 0 #FFD23F` 硬投影；不可用 `#1d1d29` |
| 卡片 | 直角，`1px rgba(255,255,255,.09)` 细边；圆形只用于图标按钮、摇杆、状态点 |

原型里的硬投影是 CSS `box-shadow`；原生端不用系统阴影（有模糊），统一用组件 `HardShadow`：在内容下方偏移 (4, 4) 画一个实色矩形（Compose 用 `Modifier.drawBehind`，SwiftUI 用 `.background(alignment:)` 叠加偏移矩形）。字体随 App 打包，不在运行时从网络加载。

## 3. 各功能的接口与实现

### 3.1 连接与添加新鸭子

| 步骤 | 实现 | 接口 |
| --- | --- | --- |
| 发现 | 平台层扫描 BLE 广播（Android `BluetoothLeScanner`，iOS `CBCentralManager.scanForPeripherals`），原始广播数据交给核心，由 `duck-ble::adv` 解析出名字（`duck-xxxx`）和 IPv4；**按 SoC 序列号识别机器人，地址只作缓存**，被别的板子复用的旧地址按名字拒绝；过滤不可连接的广播 | 广播 |
| 认出自己那只 | "嘎"按钮让机器人叫一声 | `robot.sound`（**官方待办：需在认证前可用**，`mobile-app.md` §7）；不可用时隐藏按钮 |
| 已联网判断 | 广播里带 IPv4 即视为已联网，跳过配网步骤 | 广播 |
| 认证 | 扫码（Android CameraX + ML Kit 条码识别，iOS VisionKit `DataScannerViewController`）或粘贴 `md1:<名字>:<64 hex>`；校验名字与广播名一致；以设置码中的 32 字节密钥完成 Noise 握手后发 `hello`；PIN 模式机器人静默发送出厂 PIN `000000` | `hello`、`system.authenticate` |
| 系统配对 | Android 调 `BluetoothDevice.createBond()` 弹出系统配对框，监听 `ACTION_BOND_STATE_CHANGED`；iOS 在首次读写加密特征时由系统弹出；取消后回到验证表单 | 系统 API |
| 配网 | `net.scan` 列网络，`net.connect` 发送 SSID 与密码（加密会话内）；成功后 `net.status` 取 IP | `net.scan`、`net.connect`、`net.status` |
| 起名 | 改显示名，ID 不变 | `system.setName` |

**设置码存储**：只存系统安全存储（iOS Keychain / Android Keystore），不写入 `robots.json`。官方 MVP 目前只在内存中，本方案要求持久化到安全存储 **【本方案提出】**。

**会话层**（官方 App 的核心）：

- 蓝牙断开后静默重连、重新认证、重新订阅；每个页面都能容忍链路中途断开再恢复。
- 认证会话 60 秒无请求会过期；前台每 20 秒发一个只读请求续期（官方 `authenticated-app-mvp.md`）。
- 未完成的握手 15 秒超时。

### 3.2 驾驶

**通道**

- 打开驾驶页：蓝牙 `net.status` 取 IP → 经 `duck-gateway` 建立认证过的 WebRTC 连接（视频轨 + `teleop` 不可靠通道 + `control` 可靠通道）。信令（offer / answer）经认证隧道交换，由核心生成和校验；平台层只负责 `PeerConnection` 本身。
- 连续意图（`robot.move`、`robot.head`）以 JSON-RPC 通知发到 `teleop` 通道，50 Hz 以内，后写覆盖先写；离散请求发到 `control` 通道。
- 后台、断网、页面离开：立即关闭 WebRTC（Android 监听 `ProcessLifecycleOwner` 的 `ON_STOP`，iOS 监听 `scenePhase == .background`），机器人"死人开关"在约 0.6 s 内把速度归零（官方实测 0.614 s / 0.918 s）。

**摇杆映射**（坐标统一为弧度、躯干坐标系、右手系）：

| 模式 | 左摇杆 | 右摇杆 | 发送 |
| --- | --- | --- | --- |
| 行走 | `vx = -y·0.3`、`vy = -x·0.3` m/s | `vyaw = -x·1.5` rad/s | `robot.move` |
| 头部 | 转头 ±60°、点头 ±30° | 歪头 | `robot.head` |
| 边走边看 | `vx`、`vyaw` | 头部朝向 | `robot.move` + `robot.head` |
| 高度 | 高度、侧倾 | 头部朝向 | 机身姿态接口 **【需与官方确认】** |

死区 0.08；松手立即回零。轮子模式下摇杆限幅使用官方 `[pad_roller]` 预设（前进/刹车不对称、无平移）。

**动作与按钮**

| 界面操作 | 接口 |
| --- | --- |
| 启动（未上力矩） | `robot.enable {on:true}`：Limp → Homing（2 s 斜坡）→ Ready → 策略驱动 |
| 出发 / 停止 | 启用 / 停用策略驱动；停止时保持姿态 |
| 长按启动 1.5 s 回初始姿态 | `robot.init` |
| 坐下 / 站起 | `robot.do sit_toggle` |
| 捡起、左踢、右踢、翻滚、情绪类 | `robot.do <技能名>`；翻滚按住时连续触发（技能 `chain`） |
| 嘎嘎 / 欢呼 | `robot.sound` |
| 电源长按 2 s 休息 / 4 s 关机 | 休息、关机接口 **【需与官方确认】**（`robot.relax` 官方不在蓝牙上开放） |

按钮前置条件（未启动、坐着）在 App 端判断给出提示，最终以机器人回复为准；机器人拒绝时显示其返回原因。

**摄像头视频（9:16）**

- 视频来自 `mediad`，**只经 WebRTC 视频轨传输**（不另开 HTTP / RTSP 流），官方实测为 1280×720。渲染：Android `SurfaceViewRenderer`（硬件解码，`EglBase` 共享上下文），iOS `RTCMTLVideoView`。
- 界面按 9:16 竖幅显示：若摄像头为竖装，按原样显示；若为横装，在 `mediad` 端旋转，或在 App 端居中裁切（Android `ScalingType.SCALE_ASPECT_FILL`，iOS `videoContentMode = .scaleAspectFill`）**【需确认摄像头安装方向】**。
- 弱网：依赖 WebRTC 自带的拥塞控制自动降码率；界面角标显示 `getStats()` 的帧率与往返时延，断流超过 2 s 显示"视频中断"，控制不受影响。
- **关闭视频**：只把视频收发器方向设为不活动（Android `RtpTransceiver.setDirection(INACTIVE)`，iOS `RTCRtpTransceiver.setDirection(.inactive)`）并重新协商，保留 `teleop` / `control` 数据通道，控制不受影响；再次打开时重新协商。若机器人端支持暂停编码，同时通知 `mediad` 停止编码以省电 **【本方案提出】**。
- 准星位置由当前头部朝向（`robot.subscribe` 的关节角）计算。

### 3.3 语音控制 【本方案提出】

官方没有语音接口。本方案用**手机麦克风**采集，接入豆包「实时语音大模型 3.0（全双工版）」理解语音，模型通过**工具调用（Function Call）**下达动作，App 把工具调用翻译成鸭子已有的接口；鸭子用 `robot.sound` 的叫声配合动作，**手机扬声器播放豆包的简短语音，只报执行状态和结果**。接入方式参照 `~/workspace/stopwatch-doubao`（M5Stack 手表上的同一模型接入，已真机跑通），下文"手表项目"即指它。

**整体链路**

```
手机麦克风 ──16 kHz PCM，32 ms 一包──▶ 豆包实时语音（WebSocket）
     ▲                                   │ 实时转写 → 界面
     │ 按住 / 上划 / 松手                 │ 工具调用 duck_*（参数为 JSON）
     │                                   ▼
  界面手势 ◀──────── duck-core 语音模块：攒住工具调用，松手到"发送"才执行
                                         │
                       蓝牙：robot.do / robot.sound / robot.head
                       WebRTC teleop：robot.move（限时、限速）
                                         │ 执行结果回传模型 → 一句短语音
                                         ▼
                                  手机扬声器播报
```

**代码位置**：WebSocket 客户端、事件解析、工具定义与执行、叫声选择、播报截断都放在 `duck-core`（Rust，`tokio-tungstenite`），两端共用；平台层只负责采集麦克风、播放核心交来的 PCM、显示核心推上来的状态。

#### 3.3.1 连接与会话

| 项 | 取值（与手表项目一致） |
| --- | --- |
| 地址 | `wss://openspeech.bytedance.com/api/v3/duplex/realtime/dialogue` |
| 鉴权头 | 新版控制台 `X-Api-Key`；旧版 `X-Api-App-Id` + `X-Api-Access-Key` + `X-Api-Resource-Id: volc.speech.dialog` + `X-Api-App-Key` + `X-Api-Request-Id` |
| 模型 | `session.model = "1.2.6.1"`（手表项目所用版本，上线前按火山引擎控制台核对） |
| 上行 | `pcm`，16 kHz 单声道 s16le；每 32 ms（512 采样）一包 `input_audio_buffer.append`，base64；**严格按实时节奏发**，不攒包 |
| 下行语音 | `pcm_s16le`，24 kHz 单声道（约 48 KB/s，手机带宽足够；手表项目为省 ESP32 带宽才用 `ogg_opus`，手机上用 PCM 省掉解码） |
| 协议 | 全部为 JSON 文本帧，每条带 `type` 和自增 `event_id` |

**会话生命周期**：

- 进入驾驶页、已设置密钥且已同意语音时**预连接**并发 `session.create`（手表实测冷连接约 0.5 s、预连接 0.6 s 建好）；离开驾驶页、App 进后台或闲置 60 s 关闭（`session.close`）。
- 按下麦克风时若会话还没建好，先把采集到的 PCM 缓存在内存，`session.created` 到达后按顺序补发，开头几个字不丢。
- 一次会话可包含多次按住；每次按住是一"轮"，由核心记录轮次号。
- 连接断开：本轮视为取消，下次按住时重连；不自动重试多次。

**`session.create` 内容**：

```json
{
  "type": "session.create",
  "session": {
    "id": "<随机>", "model": "1.2.6.1",
    "instructions": "<见下>",
    "audio": {
      "input":  { "format": { "type": "pcm", "rate": 16000 } },
      "output": { "format": { "type": "pcm_s16le", "rate": 24000 }, "voice": "zh_female_vv_jupiter_bigtts" }
    },
    "tools": [ /* 3.3.3 的 duck_* 工具 */ ]
  },
  "extension": { "dialog": { "extra": { "strict_audit": false, "enable_music": false } } }
}
```

不开联网搜索、唱歌、退出意图识别；不带跨会话记忆。

**提示词要点**（`instructions`）：

- 你是小鸭子机器人"<鸭子显示名>"的遥控助手，用动作和叫声让鸭子回应用户；**每次回应都必须调用工具**，不调工具等于没回应。
- **说话只报状态和结果，每句不超过 15 个字**，不寒暄、不解释、不反问：调用工具前最多说一句开始语（"好，往前走"）；拿到工具结果后说一句结果（"走完了""坐不下，已经坐着了"）。
- 工具返回失败时照原因简短说出，不要自己编结果。
- 用户要你做动作时调用对应工具；能连着做就按顺序调用多个工具。
- 只是聊天、夸你、打招呼时，调用 `duck_quack`，按心情选叫声。
- 听不清、意思不明白时调用 `duck_quack(tag="inquire")`，不要猜着动。
- 移动的时长换算成秒，"一步"约 1 秒，不超过 5 秒；没说时长按 2 秒。
- 当前状态（每轮开始前由 App 用 `conversation.item.create` 以系统消息更新）：是否已启动、站 / 坐 / 躺、双腿 / 轮子、视频通道是否连上、可用技能列表。

#### 3.3.2 一轮的流程与"按住说话"

全双工模型自己判断用户何时说完（服务端 VAD），可能在用户还按着时就开始回应。所以**模型的工具调用先攒住，松手到"发送"才执行**：

| 时机 | 核心的处理 |
| --- | --- |
| 按下 | 新轮次；开始上行 PCM；界面进入"正在听" |
| `conversation.item.input_audio_transcription.delta` | 拼接后推给界面实时显示（手表项目发现 delta 会重发修正过的片段：显示策略以 `completed` 整体替换为准，delta 只作临时显示，**需真机看重复程度**） |
| `…transcription.completed` | 用 `transcript`（无则 `text`）替换显示文字 |
| `response.function_call_arguments.done` | 把 `items[]`（`name`、`call_id`、`arguments`）放进本轮待执行队列，**不执行** |
| `response.output_text.delta / done` | 攒文字，按播放进度作为字幕显示（手表项目的 `pace_caption` 做法：已播秒数 × 语速） |
| `response.output_audio.started / delta` | 松手前到达的：缓存在内存，不播放；松手后到达的：直接送入播放队列 |
| `response.output_audio.done` | 标记本句结束，播完后回到空闲 |
| 松手在"发送" | 停止上行；发 `input_audio_buffer.commit` 强制判停；播放已缓存的开始语；等本轮 `response.done`（最多 4 s），按顺序执行队列里的工具调用 |
| 松手在"取消"或原地 | 停止上行；丢弃已缓存和之后到达的语音、文字、工具调用；仍把每个调用回传为"用户取消了，没有执行"，让模型上下文和实际一致 |
| 执行完 | 每个调用用 `conversation.item.create`（`role: tool`、`call_id`、`content: [{type: input_text, text: 结果}]`）回传结果，**再发一次 `input_audio_buffer.commit`**，让模型据结果说一句结果语（手表项目：只回传不 commit，模型不会开口）。一串动作全部执行完后统一回传、只 commit 一次，只播一句总结果 |
| 本轮无工具调用 | 视为没听懂：鸭子叫 `inquire`；模型若已说了话就播它，否则播内置提示音"没听清，再说一次"（本地录好的音频，不走豆包） |

手表项目踩过的坑，这里直接沿用结论：

- **不发 `response.cancel`**：实测取消后服务端识别只有 started 没有 completed，会话卡死。取消一律在 App 端丢弃。
- 工具回传只是放进上下文，模型不会自动开口；要它说结果必须补发 `input_audio_buffer.commit`。
- `response.output_audio.delta` 占下行流量的绝大部分且体积大：只看消息头尾判断类型后，直接定位 `"delta":"` 原地 base64 解码，不做完整 JSON 解析。
- 服务端发语音远快于实时：收到就入队，播放按实时进度消费；字幕跟播放进度走，不跟收包走。
- `response.done` 却没有任何输出时，不要卡在"鸭子在想"：4 s 超时后按没听懂处理。

**麦克风采集**：

- Android：`AudioRecord`，`MediaRecorder.AudioSource.VOICE_RECOGNITION`，16 kHz 单声道 16 bit，512 采样一读。
- iOS：`AVAudioSession` 设为 `.record`（模式 `.measurement`），`AVAudioEngine` 输入节点装 tap，用 `AVAudioConverter` 转成 16 kHz 单声道 Int16，凑满 512 采样发一包。
- 播报和采集不同时进行：按下麦克风时先停掉播报再开始采集，所以不需要回声消除；鸭子的叫声会被录进去，但只在按住期间采集，影响有限。
- 音量条用每包的 RMS 计算，平台层直接算，不经过核心。

**语音播放（播报）**：

- Android：`AudioTrack`（`USAGE_ASSISTANT`、`CONTENT_TYPE_SPEECH`，24 kHz 单声道 16 bit，流模式）；请求短时音频焦点 `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK`，播完释放。
- iOS：`AVAudioSession` 类别 `.playAndRecord`、选项 `.defaultToSpeaker` + `.duckOthers`（同一会话兼顾采集，免得每次按住切换类别产生停顿）；`AVAudioPlayerNode` 按块 `scheduleBuffer`。
- 走扬声器，跟随媒体音量；接了耳机就走耳机。
- **截断**：单句播放超过 4 s，核心在最后 200 ms 做淡出并丢弃该句剩余音频（提示词已要求短句，这是兜底）。
- **打断**：再次按住麦克风、按任意动作键或摇杆时立即停止播放、清空队列，并丢弃该句之后到达的语音；不发 `response.cancel`。
- 设置里关闭"语音播报"或手机静音时：语音照收照丢，只显示字幕。

#### 3.3.3 工具定义

工具描述用中文，参数尽量少且为枚举（手表项目经验：参数拆得太细时模型容易不调工具、直接口头说"好了"）。

| 工具 | 参数 | 执行 | 默认叫声 |
| --- | --- | --- | --- |
| `duck_move` | `direction`：forward / backward / left / right / turn_left / turn_right；`seconds`：0.5–5 | 经 WebRTC `teleop` 以 20 Hz 发 `robot.move`：前后 0.15 m/s、平移 0.1 m/s、转向 0.75 rad/s（摇杆上限的一半），到时发零速 | chirp |
| `duck_stop` | 无 | 立即零速，停用驱动；同时取消队列里剩下的调用 | chirp |
| `duck_posture` | `action`：sit / stand | 按当前站姿决定是否发 `robot.do sit_toggle`；已经是目标姿态就只叫不动 | 站 greet、坐 coo |
| `duck_head` | `action`：nod / shake / look_left / look_right / look_up / look_down / center | `robot.head` 按预设轨迹发 1–1.5 s 后回正（点头 = 俯仰 ±15° 两次，摇头 = 转向 ±25° 两次） | 点头 chirp、摇头 inquire |
| `duck_skill` | `name`：枚举，取自 `robot.skills` 的技能名与 `built_in`（每次建会话时填入） | `robot.do <name>`；翻滚等可连续技能只触发一次 | 翻滚类 wheee，其余 chirp |
| `duck_quack` | `tag`：chirp / greet / inquire / coo / wheee / alarm / peck；`times`：1–3 | `robot.sound {tag}`，多次之间间隔 0.4 s；wheee 用 `hold: true` 持续 1.5 s 后 `hold: false` | — |

动作类工具都带可选参数 `sound`（同上 7 种），模型想配别的叫声时可以指定；没指定用上表默认。叫声与动作**同时**发出（叫声走 `robot.sound`，与动作互不阻塞）。叫声名与官方 `SoundTag` 一一对应（`duck-ipc-proto`，v10 起），每台鸭子的嗓音由其 SoC 序列号决定。

**执行前检查**（不满足时不执行，改为叫 `alarm`，回传原因给模型）：

| 情况 | 依据 | 回传 |
| --- | --- | --- |
| 未启动（无力矩） | 会话状态 | "鸭子还没启动" |
| 坐着时要求移动 / 踢 | 站姿 | "鸭子坐着，先站起来" |
| 躺倒 | 站姿 | "鸭子摔倒了" |
| 移动但 WebRTC 未连上 | 会话状态 | "没连上 Wi-Fi，只能原地动作" |
| 加载策略、切换模式、配网期间 | 全局操作锁 | "鸭子正在忙" |
| 技能名不在 `robot.skills` 里 | 技能列表 | "鸭子不会这个" |
| 机器人拒绝 | 接口返回的原因 | 原因原文 |

**安全**：

- 语音触发的移动有硬上限（5 s、半速），由核心强制，不信任模型给的参数。
- 移动期间用户按任意动作键、摇杆或说"停"，立即零速并清空队列。
- 移动依赖 `teleop` 持续发送；App 进后台、WebRTC 断开时机器人的"死人开关"照常生效（约 0.6 s 归零）。

#### 3.3.4 密钥与隐私

- **密钥由用户在设置页自己填写**（PRD 5.9），App 不内置、不经任何中转服务，手机直连豆包。没有密钥时语音模块不启动：不预连接、麦克风键为锁定态。
- **两种凭证**，与手表项目 `doubao_ws.cpp` 相同：
  - API Key：握手头 `X-Api-Key`；
  - App ID + Access Token：握手头 `X-Api-App-Id`、`X-Api-Access-Key`，另加固定的 `X-Api-Resource-Id: volc.speech.dialog`、`X-Api-App-Key` 和每次新生成的 `X-Api-Request-Id`（UUID）。
- **存储**：
  - iOS：Keychain，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，不进 iCloud 钥匙串、不随备份迁移。
  - Android：Android Keystore 生成的 AES-GCM 密钥加密后存 DataStore；该文件在 `dataExtractionRules` / `fullBackupContent` 中排除，不进云备份和设备迁移。
  - 读取只发生在建立 WebSocket 时，由平台层取出传给 `duck-core`，核心不落盘；日志、崩溃报告、截图字幕中一律不出现密钥。
  - 界面只回显末 4 位。
- **测试并保存**：用待保存的凭证建一次 WebSocket 并发 `session.create`，收到 `session.created` 即成功、随即 `session.close`；超时 10 s。失败分类：握手 HTTP 401 / 403 → 密钥不对；服务端 `error` 事件里提示未开通 / 无权限 → 账号未开通；DNS / TLS / 超时 → 网络问题。成功才写入安全存储。
- **运行中失效**：握手被拒或会话中收到鉴权类 `error`，本轮按取消处理，把密钥状态标为不可用（不删除），提示去设置页更换。
- 只在按住期间上传音频；App 不保存录音，日志不记录转写原文以外的音频信息。
- 首次使用单独征得同意（PRD V-9）；删除密钥即关闭语音，不再预连接。
- 手机无网络时语音不可用，其他控制照常（蓝牙不依赖网络）。

### 3.4 状态页

**数据来源**

| 显示 | 来源 |
| --- | --- |
| 关节实测角 / 指令角 | `robot.subscribe` 流中的 `joints` / `targets`（`JOINT_NAMES` 顺序），服务端降采样到 10 Hz |
| 躯干姿态 | 同一帧的 IMU 四元数（标量在前） |
| 电池 | `battery.volts` / `battery.percent`（机器人端已按 6.6–8.2 V 换算好，App 不自行换算） |
| 舵机最高温度、主控温度 | `robot.health` |
| 站姿 | `duck-core` 直接复用官方 `posture.rs` 计算（见下） |

**关节顺序与 ID**（官方 `JOINT_NAMES` / `JOINT_IDS`）：

| 索引 | 0–4 | 5–9 | 10–14 |
| --- | --- | --- | --- |
| 关节 | 左髋转向、左髋侧摆、左髋前后、左膝、左踝 | 颈部俯仰、头部俯仰、头部转向、头部侧摆、嘴 | 右髋转向、右髋侧摆、右髋前后、右膝、右踝 |
| ID | 20–24 | 30–34 | 10–14 |

**站姿判定**（`duck-core` 引用 `robotd/src/posture.rs` 同一份代码，不移植）：

1. 由关节角经运动学模型算出双脚位置，按 IMU 姿态转到世界坐标，得到躯干离脚的高度，除以模型站立高度得到比例。
2. 倾斜角 = 躯干向上方向与世界向上方向的夹角。
3. 倾斜 > 45° → 躺倒；否则比例 < 0.5 → 坐着，> 0.8 → 站立，之间 → 不确定。

为避免与机器人端判定不一致，建议机器人在 `robot.state` 中直接下发站姿结果 **【本方案提出】**；在此之前由 `duck-core` 计算。

**偏差条**：偏差 = 实测 − 指令，满刻度 ±5°；<1° 灰、1–3° 黄、>3° 粉。单位可切换 ° / rad，与 `robotctl monitor` 一致。

**3D 渲染**

- 以本仓库 `tools/xl330-calibration/duck-view.js`（WebGL2）为参考实现，按平台重写：
  - **共享部分（`duck-core`）**：解析模型 `shared/models/duck-web-mouth-v2.bin`（保留官方 MJCF 运动学树和原始三角面，约 6.3 MB）；由关节角和躯干姿态四元数算出每个部件的世界变换矩阵。站姿判定用的也是这套运动学，两处结果一致。
  - **平台部分**：只负责把网格和变换矩阵画出来。Android 用 OpenGL ES 3.0（`GLSurfaceView`，`RENDERMODE_WHEN_DIRTY`），iOS 用 Metal（`MTKView`，`isPaused = true` + 按需 `draw()`）；着色器从 duck-view 的 GLSL 移植，iOS 改写为 Metal Shading Language。
- 相对 duck-view 的新增：
  - 躯干姿态：根节点乘以 IMU 四元数，躺倒、后仰才能正确显示；
  - 深色主题网格颜色；
  - 视窗缩放：`WINDOW_METRES = 0.29`、`LOOK_AT_Z = 0.135`，让模型尽量占满渲染区域。
- 模型随 App 打包，后台线程加载，加载中显示占位文字。
- 每收到一帧状态，把关节角和四元数交给核心算变换，再标记重绘；限 30 fps，空闲时不重绘。
- 原型中为绕开素材库限制把模型转为 base64 文本加载；正式 App 直接读二进制，不需要这一步。

**重启舵机**：`robot.rebootMotors`（官方已在蓝牙开放，用于恢复过载锁定的舵机）。

### 3.5 网络（设置页的"网络"标签）

| 操作 | 接口 |
| --- | --- |
| 当前网络、IP、信号 | `net.status` |
| 重新连接 | 对当前 SSID 再次 `net.connect`（使用已保存的配置，不需要密码）**【需确认 `net.connect` 是否支持无密码重连已保存网络】** |
| 扫描 | `net.scan` |
| 换网络 | `net.connect {ssid, password}` |
| 忘记网络 | `net.forget`（P2） |

全部走蓝牙。换网络期间 WebRTC 会断开，会话层在 `net.status` 返回新 IP 后自动重建视频；控制保持在蓝牙上可用。

### 3.6 策略页

**数据**

| 显示 / 操作 | 接口 |
| --- | --- |
| 槽位、当前策略、来源、版本、技能列表（含内置） | `robot.policies`、`robot.skills`（`built_in` 单独返回 `ground_pick`、`sit_toggle`） |
| 加载 / 恢复官方 / 关闭槽位 | `robot.loadPolicy {slot, path}`；恢复官方 = 不带路径；关闭 = `"none"`（行走槽不可关闭） |
| 双腿 / 轮子 | `robot.setMode`（`policy.mode = walk | roller`） |
| 检查更新 | `policy.check`（只报告，不安装） |
| 搜索 | `policy.search`（返回描述与预览视频路径） |
| 下载 | `policy.fetch`；社区策略在 `allow_community = false` 时返回 `PERMISSION_DENIED` |
| 添加技能 / 停用 / 移除 | `robot.setSkill`（写配置并重载）；停用内置技能 = `"none"` |
| 允许社区下载开关 | `[policy] allow_community` **【需确认手机端写入接口】** |

**各模式的官方默认**（`robotd-params` `resolved_with`）：

| 槽位 | 双腿 | 轮子 |
| --- | --- | --- |
| walk | `velstand.onnx` | `roller.onnx` |
| stand | 不加载（velstand 零速时自站） | 不加载（轮子无站立网络） |
| sitstand | `alpha_sitstand.onnx` | `alpha_sitstand.onnx` |
| ground_pick | `alpha_ground_pick.onnx` | `roller_crouch.onnx` |

**关键规则（界面必须体现）**

1. **槽位配置两种模式共用**（`[policy] walk` 只有一个键）。轮子模式下若 walk 被覆盖为双腿步态，界面告警并提供恢复官方。
2. **只有换掉正在驱动的网络才回初始姿态**，其他槽位原地换上；界面的进度步骤和说明文字由此决定。
3. **请求本来就成立时不做事**（如对未覆盖的槽位恢复官方），主按钮显示"正在运行"并置灰；唯一例外是开机加载失败的槽位，恢复官方必须能发出以清掉配置。
4. **加载失败保留原控制器**并返回原因；界面展示原因，不改变"正在运行"。
5. **开机时社区 / 本地覆盖加载失败**：机器人退回官方并报告 degraded，配置不自动清除；App 从 `robot.health` 读到后在对应槽位显示"!"。
6. **兼容性在下载前判定**（判定逻辑在 `duck-core`）：读 manifest 的 `obs_len`（须为 61）、`action_len`（14）、`model_api`、`robot.model`；字段缺失不算不兼容。`command.encoding` 为 `phase` 或 `posture_flag` 的不能作为技能。
7. 版本显示：官方用套件版本；社区有 `v*` 标签用标签，否则短 SHA + 日期；本地显示"无版本号"。

**进度展示**：App 按"是否需要下载 / 是否换驱动网络"生成步骤（下载 → 校验 → 回到初始姿态 → 换上），以 `robot.loadPolicy` 的接受应答和后续状态变化推进。

### 3.7 手柄按键

| 操作 | 接口 |
| --- | --- |
| 读取绑定 | `pad.bindings` |
| 修改 | `pad.bind {button, skill}`，机器人用现有技能名列表校验，拒绝时返回可用列表 |
| 恢复默认 | 官方有 `robotctl pad reset`，对应的 RPC 名称 **【需确认】** |

可绑定键只有 A、B、X、Y、LB、RB；官方默认 A 坐下、B 捡起，其余为空。原型中 Y / LB / RB 的预设（兴奋、点头、摇头）仅为演示，实现以官方默认为准。轮子模式下 A、X 由机器人端屏蔽（`ROLLER_UNBOUND`）。

## 4. 状态管理

- **单一会话对象**（`duck-core`）：连接状态、认证状态、当前机器人、链路类型、重连与续期计时；通过 UniFFI 回调把状态变化推给平台层。
- **平台状态层**：Android 用 `ViewModel` + `StateFlow`（协程收集核心回调），iOS 用 `@Observable` 模型 + Swift Concurrency（`AsyncStream` 包装核心回调）。界面只读这一层。
- **机器人状态**：`robot.subscribe` 流按页面需要降采样（驾驶 10 Hz 读数、状态页 10 Hz、3D 30 fps 插值）；降采样在核心完成，减少跨语言调用次数。
- **策略缓存**：`robot.policies` 结果缓存，加载 / 恢复 / 模式切换后重新拉取。
- **语言**：全局一个设置，默认中文，所有页面读取同一值（原型中每个画板各自设置，是画布工具的限制）。
- **操作锁**：加载策略、切换模式、配网期间设置全局 busy，相关控件置灰。
- **权限**：
  - Android：`BLUETOOTH_SCAN`（`neverForLocation`）、`BLUETOOTH_CONNECT`、`RECORD_AUDIO`、`CAMERA`（扫码）、`INTERNET`；Android 11 及以下另需定位权限扫描蓝牙。
  - iOS：`NSBluetoothAlwaysUsageDescription`、`NSLocalNetworkUsageDescription`、`NSMicrophoneUsageDescription`、`NSCameraUsageDescription`。
  - 都在首次用到时再申请，不在启动时一次全要。

## 5. 安全

| 风险 | 措施 |
| --- | --- |
| Wi-Fi 密码泄露 | 只在 Noise 加密会话内发送 `net.connect`（官方实测抓包无明文） |
| 未认证访问视频 / 控制 | 每条局域网隧道独立与 `duck-gateway` 认证；蓝牙断开不得回退到旧的明文信令（官方已修复的降级问题，需回归测试） |
| 设置码泄露 | 只存系统安全存储；不进日志、不进崩溃报告 |
| 社区策略 | 默认禁止下载；运行安全由机器人端沙箱保证（关节限位、摔倒放松、死人开关、61 维输入校验） |
| 语音隐私 | 只在按住期间上传到火山引擎；首次单独同意；不保存录音 |
| 豆包密钥 | 用户自填；只存系统安全存储、排除备份；不进日志；只用于直连豆包（3.3.4） |
| 语音误动作 | 移动限时限速由核心强制；工具调用松手到"发送"才执行；执行前按站姿和状态检查 |
| 播报过长 / 吵人 | 提示词限 15 字；单句 4 s 截断；任何操作立即停播 |
| 误操作 | 关机、休息、回位均为长按；按钮前置条件提示 |

## 6. 测试

| 类别 | 内容 |
| --- | --- |
| 核心单元（Rust `cargo test`） | 协议编解码、站姿判定（用官方 `DEFAULT_POSITION` / `REST_POSITION` 样本）、运动学变换、manifest 兼容判定；语音：用录制的豆包事件流回放，验证工具调用的攒住 / 发送 / 取消、执行前检查、移动限时限速 |
| 平台单元 | Android JUnit、iOS XCTest：摇杆映射与死区、偏差着色阈值、语音上划区域判定；两端共用同一份测试用例表 |
| 界面 | Compose UI Test / XCUITest；截图对比（Paparazzi / swift-snapshot-testing）检查两端与原型一致 |
| 会话 | 核心的 `BleTransport` 是接口，测试中换成模拟实现，覆盖断链、挂起、重连、重新认证、重新订阅（官方用蓝牙模拟器测试同类场景，发现过 3 个缺陷） |
| 端到端（真机） | 添加流程（含取消配对、错误设置码）、配网与换网、后台停止、断网停止、视频开关不影响控制、策略加载失败保留原策略、轮子模式共享覆盖告警 |
| 平台 | Android 与 iPhone 各测一遍，Android 覆盖 API 26 / 31 / 最新三档；iPhone 首次局域网连接需处理"本地网络"权限弹窗后的重试 |
| 语音（真机） | 首批指令各说 10 遍（安静 / 有背景声）：执行正确率、松手到动作的延迟；取消后确认鸭子无任何动作、叫声和播报；播报时长中位数与 4 s 截断；按住时立即停播；断网时麦克风置灰 |
| 豆包密钥 | 无密钥时麦克风锁定且不联网；两种凭证各测正确 / 错误 / 断网三种结果；吊销后语音中提示失效；卸载重装和设备迁移后密钥不保留；日志中搜不到密钥 |
| WebRTC | 视频首帧时间、弱网降码率、视频关闭后数据通道仍可控制、前后台切换后正确关闭 |
| 回归 | 蓝牙断开后视频仍走认证网关，不降级 |

## 7. 里程碑

| 阶段 | 内容 |
| --- | --- |
| M0 | `duck-core` 与 UniFFI 绑定、两端工程骨架、Token / 文案生成脚本、CI 同时出 Android 与 iOS 包 |
| M1 | 设计系统组件、连接、添加新鸭子、会话层 |
| M2 | 驾驶（视频、摇杆、动作、启动/电源、视频开关） |
| M3 | 状态页（3D、站姿、舵机位置）、设置页的网络标签 |
| M4 | 策略页、手柄按键 |
| M5 | 设置页（密钥、语言）、语音控制（豆包接入、工具与叫声、播报）、双平台测试、可用性测试 |

## 8. 待与官方确认

1. 高度 / 侧倾模式使用的机身姿态接口名称。
2. 休息、关机在蓝牙上的接口（`robot.relax` 官方明确不开放）。
3. 认证前可用的 identify（让机器人叫一声）。
4. `allow_community` 的手机端写入方式。
5. `net.connect` 是否支持无密码重连已保存网络。
6. 摄像头安装方向，以及是否提供竖幅（9:16）输出。
7. `robot.state` 是否直接下发站姿结果。

**与火山引擎确认**：

1. 3.0 全双工版当前的 `model` 版本号。
2. 未开通、欠费、限流时 `error` 事件的具体错误码，用于设置页和语音中的提示分类。
