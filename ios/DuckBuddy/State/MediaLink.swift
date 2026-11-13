import SwiftUI
import ImageIO

/// WebRTC 通道（技术方案 §3.2）：视频轨 + `teleop`（不可靠）+ `control`（可靠）数据通道，
/// 经 `duck-gateway` 认证。连续意图（`robot.move` / `robot.head`）由 duck-core 的 `RpcCodec` 编码后发到 `teleop`。
@MainActor
protocol MediaLink: AnyObject {
    var onState: ((DuckState) -> Void)? { get set }
    /// 数据通道已打开（可以发摇杆）。
    var isOpen: Bool { get }
    func open(ip: String, session: RobotSession)
    func send(_ call: DuckCall)
    /// 关闭视频：只把视频收发器设为 inactive，数据通道保留（D-7）。
    func setVideo(_ on: Bool)
    func close()
    func videoView() -> AnyView
}

/// 真机 WebRTC 通道。
///
/// 依赖 Google libwebrtc（`WebRTC.xcframework`）与 `duck-gateway` 的认证隧道。接入点已固定：
/// `open` 建立 PeerConnection、`send` 走 teleop 通道、`setVideo` 改收发器方向、`close` 在后台立即关闭。
/// 在接入 libwebrtc 之前它保持未打开状态：驾驶页显示"视频需要机器人联网"，蓝牙控制（动作、启动、电源）照常可用。
@MainActor
final class WebRTCMediaLink: MediaLink {
    var onState: ((DuckState) -> Void)?
    private(set) var isOpen = false
    private let codec = RpcCodec()

    func open(ip: String, session: RobotSession) {
        // TODO(M2): RTCPeerConnectionFactory + 经认证隧道交换 offer/answer；`teleop` / `control` 两个数据通道。
        isOpen = false
    }

    func send(_ call: DuckCall) {
        guard isOpen else { return }
        _ = codec.encode(call: call) // 由 teleop 数据通道发送
    }

    func setVideo(_ on: Bool) {}
    func close() { isOpen = false }

    func videoView() -> AnyView {
        AnyView(VideoPlaceholder(text: L("videoNeedsWifi")))
    }
}

/// 演示通道：10 Hz 状态流 + 动图画面，让所有页面在模拟器里可看可点。
@MainActor
final class DemoMediaLink: MediaLink {
    var onState: ((DuckState) -> Void)?
    private(set) var isOpen = false
    private let robot: DemoRobot
    private var task: Task<Void, Never>?

    init(robot: DemoRobot) { self.robot = robot }

    func open(ip: String, session: RobotSession) {
        isOpen = true
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.onState?(self.robot.tick(session: session))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func send(_ call: DuckCall) { robot.apply(call) }
    func setVideo(_ on: Bool) {}
    func close() { isOpen = false; task?.cancel() }

    func videoView() -> AnyView { AnyView(AnimatedImage(name: "demo_camera")) }
}

struct VideoPlaceholder: View {
    let text: String
    var body: some View {
        ZStack {
            Palette.panel
            VStack(spacing: 8) {
                IconView(.wifi, size: 30, weight: 2)
                Text(text).font(Typo.body(12, weight: .bold)).multilineTextAlignment(.center)
            }
            .foregroundStyle(Palette.disabled)
            .padding(16)
        }
    }
}

/// 播放打包的 GIF（演示画面）。
struct AnimatedImage: UIViewRepresentable {
    let name: String
    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        if let url = Bundle.main.url(forResource: name, withExtension: "gif"),
           let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            var frames: [UIImage] = []
            var duration = 0.0
            for i in 0..<CGImageSourceGetCount(src) {
                guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
                frames.append(UIImage(cgImage: cg))
                let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
                let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                duration += (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            }
            v.image = UIImage.animatedImage(with: frames, duration: duration)
        }
        return v
    }
    func updateUIView(_ uiView: UIImageView, context: Context) {}
}
