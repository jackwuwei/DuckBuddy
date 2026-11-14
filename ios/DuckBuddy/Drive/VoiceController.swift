import AVFoundation
import Foundation
import Network
import Observation
import SwiftUI

/// 语音控制（PRD 5.4，技术方案 3.3）。手势：按住说话 → 上划到"发送"松开才执行；上划到"取消"或原地松开不执行。
/// 豆包事件的攒住 / 放行 / 规划由 duck-core 的 `VoiceTurn` 负责，这里只做 WebSocket、麦克风、扬声器和执行。
@MainActor
@Observable
final class VoiceController {
    enum Phase { case idle, listening, thinking }
    enum Zone { case cancel, send }

    var phase = Phase.idle
    var zone: Zone?
    var heard = ""
    var caption = ""
    var level: Float = 0
    var showConsent = false

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let say: (String, Bool) -> Void
    @ObservationIgnored private var pressedAt = Date()
    @ObservationIgnored private let engine = DoubaoEngine()
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private var demoIndex = 0
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private(set) var online = true

    init(model: AppModel, say: @escaping (String, Bool) -> Void) {
        self.model = model
        self.say = say
        pathMonitor.pathUpdateHandler = { [weak self] p in
            Task { @MainActor in self?.online = p.status == .satisfied }
        }
        pathMonitor.start(queue: .main)
        engine.onEvent = { [weak self] e in self?.handle(e) }
    }

    var hasKey: Bool { model.doubaoKey != nil && !model.doubaoInvalid }
    var locked: Bool { !hasKey || !online }

    // MARK: 手势

    func press() {
        guard phase == .idle else { return }
        engine.stopPlayback() // 按住时立即停播
        if !hasKey { return say(L("needKey"), true) }
        if !online { return say(L("needNet"), true) }
        if !model.voiceConsent { showConsent = true; return }
        pressedAt = Date()
        heard = ""; caption = ""; zone = nil
        phase = .listening
        if model.session.isDemo { startDemo(); return }
        guard let key = model.doubaoKey else { return }
        engine.begin(credential: key.credential, duckName: model.session.robotName,
                     skills: model.session.skills.filter { !$0.disabled }.map(\.name), context: context)
    }

    /// 相对按下点的位移（pt）。上划超过 50 才进入目标区。
    func move(dx: CGFloat, dy: CGFloat) {
        guard phase == .listening else { return }
        let z: Zone? = dy < -50 ? (dx < 0 ? .cancel : .send) : nil
        if z != zone { zone = z }
    }

    func release(interrupted: Bool = false) {
        guard phase == .listening else { return }
        let z = interrupted ? Zone.cancel : zone
        if z != .cancel && Date().timeIntervalSince(pressedAt) < 0.35 {
            reset(); engine.cancelTurn(); demoTask?.cancel()
            return say(L("holdTalk"), false)
        }
        guard z == .send else {
            reset(); engine.cancelTurn(); demoTask?.cancel()
            return say(z == .cancel ? L("cancelled") : L("notSent"), z != .cancel)
        }
        phase = .thinking
        if model.session.isDemo { finishDemo(); return }
        engine.send(speak: model.speakReplies)
    }

    private func reset() { phase = .idle; zone = nil; heard = ""; level = 0 }

    private var context: RobotContext {
        let s = model.session
        let posture = s.state?.posture?.posture
        return RobotContext(enabled: s.power != .off, sitting: s.seated, homed: s.homed, lying: posture == .lying, roller: s.isRoller,
                            teleopReady: s.media.isOpen, busy: s.busy,
                            skills: s.skills.filter { !$0.disabled }.map(\.name))
    }

    // MARK: 引擎事件

    private func handle(_ e: DoubaoEngine.Event) {
        switch e {
        case .level(let l): level = l
        case .transcript(let t): heard = t
        case .caption(let c): caption += c
        case .plan:
            guard let steps = engine.plan(context) else { return }
            Task { await execute(steps) }
        case .nothing:
            reset()
            Task { await model.session.intent(.robotSound(quack: .inquire, hold: nil)) }
            say(L("notGot"), true)
        case .authFailed:
            model.doubaoInvalid = true
            reset()
            say(L("keyInvalid"), true)
        case .failed(let m):
            reset()
            say(m, true)
        }
    }

    /// 按顺序执行规划好的步骤；移动以 20 Hz 发 robot.move，到时发零速（限时限速已由核心强制）。
    private func execute(_ steps: [VoiceStep]) async {
        let session = model.session
        var results: [(String, String)] = []
        let summary = "“\(heard)” → "
        reset()
        for step in steps {
            switch step {
            case .refuse(let id, let reason):
                await session.intent(.robotSound(quack: .alarm, hold: nil))
                say(summary + reason, true)
                results.append((id, reason))
            case .stop(let id):
                _ = try? await session.call(.robotMove(vx: 0, vy: 0, vyaw: 0))
                await session.intent(.robotStop)
                results.append((id, "已停下"))
            case .act(let id, let call, let seconds, let quack, let times, let note):
                if let quack {
                    Task {
                        for i in 0..<Int(max(1, times)) {
                            if i > 0 { try? await Task.sleep(for: .milliseconds(400)) }
                            await session.intent(.robotSound(quack: quack, hold: quack == .wheee ? true : nil))
                        }
                        if quack == .wheee { try? await Task.sleep(for: .seconds(1.5)); await session.intent(.robotSound(quack: .wheee, hold: false)) }
                    }
                }
                var outcome = "完成"
                if let call, let seconds {
                    if session.power == .stiff { session.power = .walking }
                    let end = Date().addingTimeInterval(seconds)
                    while Date() < end { _ = try? await session.call(call); try? await Task.sleep(for: .milliseconds(50)) }
                    _ = try? await session.call(.robotMove(vx: 0, vy: 0, vyaw: 0))
                } else if let call {
                    if let r = await session.intent(call) { outcome = r }
                    else { session.applied(call) }
                }
                say(summary + note, false)
                results.append((id, outcome))
            }
        }
        engine.report(results)
    }

    // MARK: 演示

    private let demoPhrases: [(String, String)] = [("站起来", "stand"), ("往前走", "walk"), ("嘎嘎叫", "quack"), ("点个头", "yes"), ("停下", "stop"), ("今天吃什么", "?"), ("坐下", "sit")]

    private func startDemo() {
        let phrase = demoPhrases[demoIndex % demoPhrases.count].0
        let t0 = Date()
        demoTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase == .listening else { return }
                let k = min(1, max(0, (Date().timeIntervalSince(t0) - 0.3) / 1.4))
                self.heard = String(phrase.prefix(Int(ceil(Double(phrase.count) * k))))
                self.level = Float.random(in: 0.2...1)
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func finishDemo() {
        demoTask?.cancel()
        let (phrase, id) = demoPhrases[demoIndex % demoPhrases.count]
        demoIndex += 1
        heard = phrase
        Task {
            try? await Task.sleep(for: .milliseconds(550))
            let q = "“\(phrase)” → "
            let s = model.session
            reset()
            switch id {
            case "stand", "sit", "walk", "yes":
                if s.power == .off { return say(q + L("needStart"), true) }
                if id == "walk" && s.down { return say(q + L("needStand"), true) }
                if id == "stand" || id == "sit", let c = s.postureCall(sit: id == "sit") { s.applied(c) }
                if id == "walk" { s.power = .walking }
                say(q + L(["stand": "stand", "sit": "sit", "walk": "sMove", "yes": "yes"][id]!), false)
            case "stop": if s.power == .walking { s.power = .stiff }; say(q + L("stop"), false)
            case "quack": say(q + L("quackT"), false)
            default: say(q + L("notGot"), true)
            }
        }
    }
}

/// 豆包实时语音（全双工）WebSocket 客户端 + 麦克风采集 + 扬声器播放。
@MainActor
final class DoubaoEngine {
    enum Event { case level(Float), transcript(String), caption(String), plan, nothing, authFailed, failed(String) }
    var onEvent: ((Event) -> Void)?

    private var socket: URLSessionWebSocketTask?
    private var turn = VoiceTurn()
    private var ready = false
    private var buffered: [String] = []
    private let audio = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var pcm = Data()
    private var speak = true
    private var waitTask: Task<Void, Never>?
    /// 松手后的静音上行（见 `keepAlive`）。
    private var silenceTask: Task<Void, Never>?
    private var gotDone = false
    private var playedSeconds = 0.0

    private let inFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    /// 建立会话（若尚未建立）并开始一轮。会话建好前采集到的音频先缓存，`session.created` 后按序补发。
    func begin(credential: DoubaoCredential, duckName: String, skills: [String], context: RobotContext) {
        turn.begin()
        gotDone = false
        stopKeepAlive()
        if socket == nil { connect(credential: credential, duckName: duckName, skills: skills) }
        sendText(turn.contextUpdate(ctx: context))
        startMic()
    }

    private func connect(credential: DoubaoCredential, duckName: String, skills: [String]) {
        var req = URLRequest(url: URL(string: doubaoUrl())!)
        for h in doubaoHeaders(credential: credential, requestId: UUID().uuidString) { req.setValue(h.value, forHTTPHeaderField: h.name) }
        let task = URLSession.shared.webSocketTask(with: req)
        socket = task
        ready = false
        task.resume()
        task.send(.string(turn.sessionCreate(sessionId: UUID().uuidString, duckName: duckName, skills: skills))) { _ in }
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                // 取消后会重连：旧连接迟到的回调不能动新连接。
                guard let self, task === self.socket else { return }
                switch result {
                case .success(.string(let text)):
                    if text.contains("\"session.created\"") {
                        self.ready = true
                        self.buffered.forEach { self.socket?.send(.string($0)) { _ in } }
                        self.buffered.removeAll()
                    }
                    self.onServer(text)
                    self.receive(task)
                case .success:
                    self.receive(task)
                case .failure(let e):
                    let ns = e as NSError
                    // 先读握手状态码，再丢掉连接（之前顺序反了，密钥错误永远报成网络错误）。
                    let http = (task.response as? HTTPURLResponse)?.statusCode
                    self.socket = nil
                    self.ready = false
                    self.stopKeepAlive()
                    if let http, http == 401 || http == 403 {
                        self.onEvent?(.authFailed)
                    } else if ns.code != NSURLErrorCancelled {
                        self.onEvent?(.failed(L("errNet")))
                    }
                }
            }
        }
    }

    private func onServer(_ text: String) {
        for e in turn.onServerEvent(text: text) {
            switch e {
            case .transcript(let t, _): onEvent?(.transcript(t))
            case .speech(let pcm): if speak { play(pcm) }
            case .caption(let c): onEvent?(.caption(c))
            case .responseDone: gotDone = true
            case .authFailed: onEvent?(.authFailed)
            case .error(let m): onEvent?(.failed(m))
            }
        }
    }

    private func sendText(_ s: String) {
        if ready { socket?.send(.string(s)) { _ in } } else { buffered.append(s) }
    }

    /// 松手在"发送"：关麦、强制判停、放出缓存的开始语，等到工具调用或 response.done（最多 4 s）后规划执行。
    /// 带工具调用的回复要等结果回传后才有 response.done，所以收到调用就规划，不干等 4 s。
    func send(speak: Bool) {
        self.speak = speak
        stopMic()
        sendText(turn.commit())
        keepAlive()
        for e in turn.release(send: true) { if case .speech(let pcm) = e, speak { play(pcm) } }
        waitTask?.cancel()
        waitTask = Task { [weak self] in
            let t0 = Date()
            while let self, !self.gotDone, !self.turn.hasCalls(), Date().timeIntervalSince(t0) < 4 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self else { return }
            self.onEvent?(self.turn.hasCalls() ? .plan : .nothing)
        }
    }

    func plan(_ ctx: RobotContext) -> [VoiceStep]? { turn.plan(ctx: ctx) }

    /// 执行结果统一回传后只 commit 一次，模型据此说一句结果语。
    func report(_ results: [(String, String)]) {
        for (id, text) in results { sendText(turn.toolResult(callId: id, text: text)) }
        if !results.isEmpty { sendText(turn.commit()); keepAlive() }
    }

    /// 取消：丢弃这一轮并关掉会话，下次按住时重连（约 0.2 s）。
    /// 豆包没有清空输入缓冲的事件（`input_audio_buffer.clear` 会报错并断开），`response.cancel` 又会卡死会话；
    /// 不关会话的话，取消掉的那句话会和下一句拼在一起被执行（实测"停下" + 下一句）。
    func cancelTurn() {
        stopMic()
        stopKeepAlive()
        _ = turn.release(send: false)
        if ready { socket?.send(.string(turn.sessionClose())) { _ in } }
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        ready = false
        buffered.removeAll()
    }

    /// 关麦后用静音维持上行 `seconds` 秒：服务端只有继续收到音频才会结束识别、说出结果语（实测）。
    private func keepAlive(_ seconds: Double = 10) {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            let end = Date().addingTimeInterval(seconds)
            while !Task.isCancelled, Date() < end, let self {
                self.sendText(self.turn.silence())
                try? await Task.sleep(for: .milliseconds(32))
            }
        }
    }

    private func stopKeepAlive() {
        silenceTask?.cancel()
        silenceTask = nil
    }

    // MARK: 麦克风：16 kHz 单声道 s16le，512 采样（32 ms）一包

    private func startMic() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers, .allowBluetoothA2DP])
        try? s.setActive(true)
        let input = audio.inputNode
        let hw = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: hw, to: inFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: hw) { [weak self] buffer, _ in
            Task { @MainActor in self?.convert(buffer) }
        }
        if !audio.attachedNodes.contains(player) {
            audio.attach(player)
            audio.connect(player, to: audio.mainMixerNode, format: outFormat)
        }
        try? audio.start()
    }

    private func stopMic() {
        audio.inputNode.removeTap(onBus: 0)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = inFormat.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard let ch = out.int16ChannelData else { return }
        let n = Int(out.frameLength)
        var sum: Float = 0
        for i in 0..<n { let v = Float(ch[0][i]) / 32768; sum += v * v }
        onEvent?(.level(min(1, sqrt(sum / Float(max(1, n))) * 6)))
        pcm.append(Data(bytes: ch[0], count: n * 2))
        while pcm.count >= 1024 {
            sendText(turn.audioAppend(pcm: pcm.prefix(1024)))
            pcm.removeFirst(1024)
        }
    }

    // MARK: 播报：24 kHz s16le；单句超过 4 s 截断

    private func play(_ data: Data) {
        guard playedSeconds < 4 else { return }
        let n = data.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<n { buf.floatChannelData![0][i] = Float(src[i]) / 32768 }
        }
        playedSeconds += Double(n) / 24000
        player.scheduleBuffer(buf, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    func stopPlayback() {
        player.stop()
        playedSeconds = 0
    }

    func close() {
        stopKeepAlive()
        if ready { socket?.send(.string(turn.sessionClose())) { _ in } }
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        ready = false
        audio.stop()
    }
}
