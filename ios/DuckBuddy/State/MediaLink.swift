import SwiftUI
import ImageIO
import WebRTC

/// WebRTC 通道（技术方案 §3.2）：视频轨 + `teleop`（不可靠）+ `control`（可靠）数据通道，
/// 经 `duck-gateway` 认证。连续意图（`robot.move` / `robot.head`）由 duck-core 的 `RpcCodec` 编码后发到 `teleop`。
@MainActor
protocol MediaLink: AnyObject {
    var onState: ((DuckState) -> Void)? { get set }
    /// 数据通道已打开（可以发摇杆）。
    var isOpen: Bool { get }
    func open(ip: String, session: RobotSession)
    func send(_ call: DuckCall)
    /// 经 `control` 发一个请求并等回复 JSON；没打开或机器人拒绝时抛 `RobotError`。（调试 `-webrtc` 模式下替代蓝牙。）
    func request(_ call: DuckCall, timeout: Duration) async throws -> String
    /// 关闭视频：只把视频收发器设为 inactive，数据通道保留（D-7）。
    func setVideo(_ on: Bool)
    func close()
    func videoView() -> AnyView
    /// 正在出帧（驾驶页据此保持亮屏）。
    var videoLive: Bool { get }
    /// 视频接收码率（kbit/s），还没有统计时为 nil。
    var videoKbps: Int? { get }
    /// 拍照和录像从这里取帧。
    var capture: VideoCapture { get }
}

extension MediaLink {
    func request(_ call: DuckCall, timeout: Duration) async throws -> String { throw RobotError(message: L("linkLost")) }
}

/// 真机 WebRTC 通道：局域网直连机器人的 `mediad`（`ws://<ip>:8443`，webrtcsink 信令，无认证）。
///
/// 流程与机器人自带网页客户端一致，协议在 duck-core 的 `Signalling` 里：机器人出 offer、App 答；
/// 机器人创建 `control` 数据通道（可靠，JSON-RPC 一行一条），0.17.8 还没有 `teleop`，连续意图也走 `control`。
/// 视频是机器人硬件编码的 H.264，按 `media.video` 的安装角度旋转显示。
///
/// 机器人端的视频管线偶尔会停在上一帧（实测，重启 mediad 才恢复）：这里每 2 s 看一次解码帧数，
/// 停住就重开会话；连续几次重开都没有画面，就提示需要在机器人上重启 mediad。
@MainActor
final class WebRTCMediaLink: NSObject, MediaLink {
    var onState: ((DuckState) -> Void)?
    private(set) var isOpen = false
    private let codec = RpcCodec()
    private let video = VideoModel()
    private let renderer = RTCMTLVideoView(frame: .zero)
    let capture = VideoCapture()

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private var ip: String?
    private var socket: URLSessionWebSocketTask?
    private var sig = Signalling()
    private var pc: RTCPeerConnection?
    private var control: RTCDataChannel?
    private var teleop: RTCDataChannel?
    private var track: RTCVideoTrack?
    private var mediaVideoId: UInt64?
    private var pending: [UInt64: CheckedContinuation<String, Error>] = [:]
    private var watchdog: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var lastDecoded: Int = -1
    private var lastBytes: Int = -1
    private var lastBytesAt = Date()
    private var lastProgress = Date()
    private var sessionStarted = Date()
    private var restarts = 0

    override init() {
        super.init()
        renderer.videoContentMode = .scaleAspectFill
        renderer.clipsToBounds = true
    }

    func open(ip: String, session: RobotSession) {
        if self.ip == ip, socket != nil { return }
        close()
        self.ip = ip
        restarts = 0
        connect()
    }

    private func connect() {
        guard let ip else { return }
        sig = Signalling()
        video.status = L("videoConnecting")
        let task = URLSession.shared.webSocketTask(with: URL(string: sig.url(ip: ip))!)
        socket = task
        task.resume()
        receive(task)
        startWatchdog()
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, task === self.socket else { return }
                switch result {
                case .success(.string(let text)):
                    for action in self.sig.onMessage(text: text) { self.handle(action) }
                    self.receive(task)
                case .success:
                    self.receive(task)
                case .failure:
                    // 信令断了（机器人重启、离开局域网）：拆掉会话，过一会儿重连。
                    self.teardownPeer()
                    self.socket = nil
                    self.video.status = L("videoNeedsWifi")
                    self.scheduleReconnect(after: 5)
                }
            }
        }
    }

    private func sendSignal(_ text: String?) {
        guard let text else { return }
        socket?.send(.string(text)) { _ in }
    }

    private func handle(_ action: SignalAction) {
        switch action {
        case .send(let text):
            sendSignal(text)
        case .createPeer:
            makePeer()
        case .remoteOffer(let sdp):
            guard let pc else { return }
            pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] error in
                guard error == nil else { return }
                pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, _ in
                    guard let answer else { return }
                    pc.setLocalDescription(answer) { _ in
                        Task { @MainActor in self?.sendSignal(self?.sig.answer(sdp: answer.sdp)) }
                    }
                }
            }
        case .remoteIce(let candidate, let index):
            pc?.add(RTCIceCandidate(sdp: candidate, sdpMLineIndex: Int32(index), sdpMid: nil)) { _ in }
        case .noProducer:
            video.status = L("videoNoProducer")
            scheduleRestart(after: 5)
        case .ended:
            teardownPeer()
            scheduleRestart(after: 2)
        }
    }

    private func makePeer() {
        teardownPeer()
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = []   // 局域网：只用 host 候选
        pc = Self.factory.peerConnection(with: config,
                                         constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
                                         delegate: self)
        sessionStarted = Date()
        lastDecoded = -1
        lastBytes = -1
        video.kbps = nil
        lastProgress = Date()
    }

    private func teardownPeer() {
        track?.remove(renderer)
        track?.remove(capture)
        track = nil
        control?.delegate = nil
        teleop?.delegate = nil
        control = nil
        teleop = nil
        pending.values.forEach { $0.resume(throwing: RobotError(message: L("linkLost"))) }
        pending.removeAll()
        pc?.close()
        pc = nil
        isOpen = false
        video.live = false
    }

    /// 同一条信令连接上重开会话（视频卡住、机器人结束会话）。
    private func scheduleRestart(after seconds: Double) {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.socket != nil else { return }
            self.teardownPeer()
            for frame in self.sig.restart() { self.sendSignal(frame) }
        }
    }

    private func scheduleReconnect(after seconds: Double) {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.ip != nil, self.socket == nil else { return }
            self.connect()
        }
    }

    /// 每 2 s 读一次接收统计：解码帧数不再增长就算卡住。
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, let pc = self.pc else { continue }
                let (decoded, bytes): (Int, Int) = await withCheckedContinuation { c in
                    pc.statistics { report in
                        let n = report.statistics.values.first { $0.type == "inbound-rtp" && ($0.values["kind"] as? String) == "video" }
                        c.resume(returning: ((n?.values["framesDecoded"] as? NSNumber)?.intValue ?? 0,
                                             (n?.values["bytesReceived"] as? NSNumber)?.intValue ?? 0))
                    }
                }
                self.measure(bytes: bytes)
                self.check(decoded: decoded)
            }
        }
    }

    /// 两次统计之间收到的字节数换算成码率。
    private func measure(bytes: Int) {
        let now = Date()
        if lastBytes >= 0, bytes >= lastBytes, now.timeIntervalSince(lastBytesAt) > 0.5 {
            video.kbps = Int(Double(bytes - lastBytes) * 8 / now.timeIntervalSince(lastBytesAt) / 1000)
        }
        lastBytes = bytes
        lastBytesAt = now
    }

    private func check(decoded: Int) {
        let now = Date()
        if decoded > lastDecoded {
            lastDecoded = decoded
            lastProgress = now
            if decoded > 0 {
                video.live = true
                video.status = nil
                restarts = 0
            }
            return
        }
        // 刚开会话给 8 s 出第一帧；之后 5 s 没有新帧算卡住。
        let grace: TimeInterval = decoded == 0 ? 8 : 5
        guard now.timeIntervalSince(lastProgress) > grace, now.timeIntervalSince(sessionStarted) > grace else { return }
        video.live = false
        restarts += 1
        if restarts > 3 {
            video.status = L("videoStuck")
            lastProgress = now
            scheduleRestart(after: 30)
        } else {
            video.status = L("videoStalled")
            lastProgress = now
            scheduleRestart(after: 0.2)
        }
    }

    // MARK: 数据通道

    private func didOpen(_ channel: RTCDataChannel) {
        channel.delegate = self
        if channel.label == "teleop" { teleop = channel } else { control = channel }
        if channel.readyState == .open { channelOpened(channel) }
    }

    private func channelOpened(_ channel: RTCDataChannel) {
        guard channel === control else { return }
        isOpen = true
        // 状态流（10 Hz）和画面角度都走 control。
        write(codec.encode(call: .robotSubscribe(hz: 10)).line, on: channel)
        let mv = codec.encodeMediaVideo()
        mediaVideoId = mv.id
        write(mv.line, on: channel)
    }

    private func onControl(_ text: String) {
        for line in text.split(separator: "\n") {
            switch codec.decode(line: String(line)) {
            case .state(let s): onState?(s)
            case .notification(let method, let params):
                if let info = videoInfoNotification(method: method, paramsJson: params) { setRotate(info.rotate) }
            case .reply(let id, let json) where id == mediaVideoId:
                if let info = decodeVideoInfo(json: json) { setRotate(info.rotate) }
            case .reply(let id, let json):
                pending.removeValue(forKey: id)?.resume(returning: json)
            case .refused(let id, _, let message):
                pending.removeValue(forKey: id)?.resume(throwing: RobotError(message: message))
            default: break
            }
        }
    }

    private func setRotate(_ degrees: UInt32) {
        video.rotate = degrees
        capture.mountRotation = Int(degrees)
    }

    private func write(_ line: String, on channel: RTCDataChannel) {
        channel.sendData(RTCDataBuffer(data: Data(line.utf8), isBinary: false))
    }

    func send(_ call: DuckCall) {
        guard isOpen, let control else { return }
        let out = codec.encode(call: call)
        // 0.17.8 的 mediad 只建 control；有 teleop（不可靠通道）时连续意图走它。
        let channel = out.teleop ? (teleop?.readyState == .open ? teleop! : control) : control
        write(out.line, on: channel)
    }

    func request(_ call: DuckCall, timeout: Duration) async throws -> String {
        guard isOpen, let control else { throw RobotError(message: L("linkLost")) }
        let out = codec.encode(call: call)
        guard let id = out.id else { write(out.line, on: control); return "null" }
        write(out.line, on: control)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { c in self.pending[id] = c }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RobotError(message: L("linkLost"))
            }
            defer {
                group.cancelAll()
                self.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
            return try await group.next()!
        }
    }

    func setVideo(_ on: Bool) { track?.isEnabled = on }
    var videoLive: Bool { video.live }
    var videoKbps: Int? { video.live ? video.kbps : nil }

    func close() {
        retry?.cancel()
        watchdog?.cancel()
        sendSignal(sig.end())
        teardownPeer()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        ip = nil
        video.status = nil
    }

    func videoView() -> AnyView { AnyView(VideoSurface(renderer: renderer, model: video)) }

    fileprivate func attach(_ receiver: RTCRtpReceiver) {
        guard let t = receiver.track as? RTCVideoTrack, t !== track else { return }
        track?.remove(renderer)
        track?.remove(capture)
        track = t
        t.add(renderer)
        t.add(capture)
    }
}

extension WebRTCMediaLink: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let sdp = candidate.sdp, index = UInt32(max(0, candidate.sdpMLineIndex))
        Task { @MainActor in
            guard peerConnection === self.pc else { return }
            self.sendSignal(self.sig.ice(candidate: sdp, sdpMlineIndex: index))
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor in
            guard peerConnection === self.pc else { return }
            self.didOpen(dataChannel)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        Task { @MainActor in
            guard peerConnection === self.pc else { return }
            self.attach(rtpReceiver)
        }
    }
}

extension WebRTCMediaLink: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let state = dataChannel.readyState
        Task { @MainActor in
            if state == .open { self.channelOpened(dataChannel) }
            else if state == .closed, dataChannel === self.control { self.isOpen = false }
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, let text = String(data: buffer.data, encoding: .utf8) else { return }
        Task { @MainActor in self.onControl(text) }
    }
}

/// 视频画面的显示状态（与连接逻辑分开，供 SwiftUI 观察）。
@Observable
@MainActor
final class VideoModel {
    /// 正在出帧。
    var live = false
    /// 接收码率（kbit/s）。
    var kbps: Int?
    /// 相机安装角度（顺时针，度）。
    var rotate: UInt32 = 0
    /// 没有画面时显示的说明。
    var status: String?
}

/// libwebrtc 的 Metal 视频视图，按相机安装角度旋转；没出帧时盖一层说明。
struct VideoSurface: View {
    let renderer: RTCMTLVideoView
    let model: VideoModel

    var body: some View {
        ZStack {
            RendererView(renderer: renderer, rotate: model.rotate)
            if !model.live { VideoPlaceholder(text: model.status ?? L("videoConnecting")) }
        }
    }
}

private struct RendererView: UIViewRepresentable {
    let renderer: RTCMTLVideoView
    let rotate: UInt32

    func makeUIView(context: Context) -> RTCMTLVideoView { renderer }
    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        let r: RTCVideoRotation = switch rotate {
        case 90: ._90
        case 180: ._180
        case 270: ._270
        default: ._0
        }
        view.rotationOverride = NSNumber(value: r.rawValue)
    }
}

/// 演示通道：10 Hz 状态流 + 动图画面，让所有页面在模拟器里可看可点。
@MainActor
final class DemoMediaLink: MediaLink {
    var onState: ((DuckState) -> Void)?
    private(set) var isOpen = false
    private let robot: DemoRobot
    private var task: Task<Void, Never>?
    private var frames: Task<Void, Never>?
    let capture = VideoCapture()

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
        // 演示画面也能拍照录像：按 GIF 自己的节奏把帧喂给 capture。
        frames?.cancel()
        frames = Task.detached(priority: .utility) { [capture] in
            let gif = GifFrames.load("demo_camera")
            guard !gif.isEmpty else { return }
            var i = 0
            while !Task.isCancelled {
                if let pb = gif[i].pixelBuffer() { capture.push(pb) }
                try? await Task.sleep(for: .seconds(gif[i].delay))
                i = (i + 1) % gif.count
            }
        }
    }

    func send(_ call: DuckCall) { robot.apply(call) }
    func setVideo(_ on: Bool) {}
    func close() { isOpen = false; task?.cancel(); frames?.cancel() }
    var videoLive: Bool { true }
    var videoKbps: Int? { nil }

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
        let frames = GifFrames.load(name)
        if !frames.isEmpty {
            v.image = UIImage.animatedImage(with: frames.map { UIImage(cgImage: $0.image) }, duration: frames.reduce(0) { $0 + $1.delay })
        }
        return v
    }
    func updateUIView(_ uiView: UIImageView, context: Context) {}
}

/// 打包 GIF 的帧和每帧时长。
struct GifFrames: @unchecked Sendable {
    let image: CGImage
    let delay: Double

    static func load(_ name: String) -> [GifFrames] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "gif"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return (0..<CGImageSourceGetCount(src)).compactMap { i in
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { return nil }
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return GifFrames(image: cg, delay: max((gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1, 0.02))
        }
    }

    /// 转成 BGRA 的 CVPixelBuffer（H.264 编码器和 Core Image 都收）。
    func pixelBuffer() -> CVPixelBuffer? {
        let w = image.width & ~1, h = image.height & ~1
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &out) == kCVReturnSuccess, let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pb
    }
}
