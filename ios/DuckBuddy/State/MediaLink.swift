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
    /// 关闭视频：只把视频收发器设为 inactive，数据通道保留（D-7）。
    func setVideo(_ on: Bool)
    func close()
    func videoView() -> AnyView
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
    private var watchdog: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var lastDecoded: Int = -1
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
        lastProgress = Date()
    }

    private func teardownPeer() {
        track?.remove(renderer)
        track = nil
        control?.delegate = nil
        teleop?.delegate = nil
        control = nil
        teleop = nil
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
                let decoded: Int = await withCheckedContinuation { c in
                    pc.statistics { report in
                        let n = report.statistics.values.first { $0.type == "inbound-rtp" && ($0.values["kind"] as? String) == "video" }
                        c.resume(returning: (n?.values["framesDecoded"] as? NSNumber)?.intValue ?? 0)
                    }
                }
                self.check(decoded: decoded)
            }
        }
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
                if let info = videoInfoNotification(method: method, paramsJson: params) { video.rotate = info.rotate }
            case .reply(let id, let json) where id == mediaVideoId:
                if let info = decodeVideoInfo(json: json) { video.rotate = info.rotate }
            default: break
            }
        }
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

    func setVideo(_ on: Bool) { track?.isEnabled = on }

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
        track = t
        t.add(renderer)
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
