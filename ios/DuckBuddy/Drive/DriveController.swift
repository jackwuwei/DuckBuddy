import AVFoundation
import Foundation
import Observation
import SwiftUI

/// 驾驶页逻辑（与设计稿 PortraitDrive / Main 的交互一一对应）：模式、摇杆发送、动作前置条件、
/// 启动键（短按启动 / 出发 / 停止，长按 1.5 s 回初始姿态）、电源键（长按 2 s 休息、4 s 关机）。
@MainActor
@Observable
final class DriveController {
    enum Mode: CaseIterable { case walk, head }

    var mode: Mode = .walk
    var left = CGPoint.zero
    var right = CGPoint.zero
    var camOn = true
    var tray = false
    /// 竖屏：动作列可以收起，让出画面。
    var actionsOpen = true
    /// 用户手动切换过的画面铺满 / 完整显示（键：是否竖屏）；没切换过按窗口和画面比例决定。
    var videoFill: [Bool: Bool] = [:]
    var rolling = false
    var quackDown = false
    var wheeeDown = false
    var startHeld = 0.0
    var powerHeld = 0.0
    var toast: (text: String, warn: Bool)?
    var output: DriveOutput?

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var rollTask: Task<Void, Never>?
    @ObservationIgnored private var gamesTask: Task<Void, Never>?
    /// 推摇杆接管自由活动时只关一次（等机器人确认关掉之前不重复发）。
    @ObservationIgnored private var takingOver = false
    /// 上一个情绪动作预计播完的时刻：机器人播放中会丢掉新的请求，这里先提示。
    @ObservationIgnored private var emotingUntil = Date.distantPast
    @ObservationIgnored private var wasIdle = true
    /// 上一拍是否发了非零速度（core 用它做站立 / 行走阈值的迟滞）。
    @ObservationIgnored private var wasMoving = false

    init(model: AppModel) { self.model = model }

    private var session: RobotSession { model.session }
    var power: Power { session.power }
    /// 不在站立（锁住的坐姿或未回零位）：技能、移动都要先站起。
    var seated: Bool { session.down }
    var off: Bool { session.power == .off }

    // MARK: 状态标签

    var stateLabel: (String, Color) {
        if let g = playing { return (L("game_\(GameStyle.key(g))On"), Palette.orange) }
        if off { return (L("relaxed"), Color.white.opacity(0.5)) }
        if seated { return (L("seated"), Palette.purple) }
        if power == .stiff { return (L("standing"), Palette.purple) }
        let moving = (output?.calls.contains { if case .robotMove(let x, let y, let w) = $0 { return x != 0 || y != 0 || w != 0 }; return false }) ?? false
        return (moving ? L("walking") : L("readyState"), Palette.cyan)
    }

    // MARK: 摇杆 → teleop（20 ms 一次，松手立即归零）

    func startLoop() {
        #if DEBUG
        debugStick()
        #endif
        gamesTask?.cancel()
        gamesTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.session.refreshGames()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.pump()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    #if DEBUG
    /// 调试：`-stick walk|head|look|height:<lx>,<ly>,<rx>,<ry>:<秒>` 启动后按住摇杆一段时间再松手。
    /// `-tray` 启动后打开情绪托盘（截图用）。`-capture photo|record:<秒>` 启动后拍照 / 录像。
    /// 模拟器里没有手指，用它走真实的摇杆 → teleop 路径（mapSticks → 20 ms 泵 → session.call → 视频通道）。
    private func debugStick() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-tray") { tray = true }
        // `-capture photo` / `-capture record:<秒>`：等出帧后拍一张 / 录一段，走真实的存相册路径。
        if let i = args.firstIndex(of: "-capture"), i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                for _ in 0..<200 where self?.session.media.videoLive == false { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if parts.first == "photo" { self.takePhoto(); return }
                self.toggleRecord()
                try? await Task.sleep(for: .seconds(parts.count > 1 ? Double(parts[1]) ?? 5 : 5))
                self.stopRecording()
            }
        }
        guard let i = args.firstIndex(of: "-stick"), i + 1 < args.count else { return }
        let parts = args[i + 1].split(separator: ":")
        guard parts.count == 3, let secs = Double(parts[2]) else { return }
        let v = parts[1].split(separator: ",").compactMap { Double($0) }
        guard v.count == 4 else { return }
        mode = ["walk": .walk, "head": .head][String(parts[0])] ?? .walk
        if mode == .walk { session.power = .walking }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))   // 等视频通道连上
            self?.left = CGPoint(x: v[0], y: v[1]); self?.right = CGPoint(x: v[2], y: v[3])
            try? await Task.sleep(for: .seconds(secs))
            self?.left = .zero; self?.right = .zero
        }
    }
    #endif

    func stopLoop() {
        gamesTask?.cancel()
        loop?.cancel()
        if session.power == .walking { Task { await session.intent(.robotMove(vx: 0, vy: 0, vyaw: 0)) } }
    }

    private func pump() {
        let m: StickMode = switch mode {
        case .walk: .walk
        case .head: .head
        }
        let out = mapSticks(mode: m, left: Stick(x: left.x, y: left.y), right: Stick(x: right.x, y: right.y), roller: session.isRoller, wasMoving: wasMoving)
        output = out
        wasMoving = out.moving
        let idle = left == .zero && right == .zero
        if !idle { takeOverFromAutonomous() }
        if idle && wasIdle { return } // 松手后只发一次零
        wasIdle = idle
        guard !off else { return }
        for call in out.calls {
            if case .robotMove = call, session.power != .walking || seated { continue }
            Task { _ = try? await session.call(call) }
        }
    }

    /// 自由活动（autod）只给实体手柄让路，不认 App 的摇杆：两边的指令会互相覆盖。
    /// 所以一推摇杆就关掉自由活动，由用户接管。追激光和踢球不用关：机器人自己让推动的摇杆优先。
    private func takeOverFromAutonomous() {
        guard session.games.autonomous, !takingOver else { return }
        takingOver = true
        say(L("autonomousTakeover"))
        Task {
            if let reason = await session.setGame(.autonomous, on: false) { say(reason, warn: true) }
            takingOver = false
        }
    }

    /// 读数：未启动时为 0（设计稿行为）。
    var readout: (String, String, String, String) {
        let parts = { (s: String) -> (String, String) in
            let p = s.split(separator: " ", maxSplits: 1).map(String.init)
            return (p.first ?? s, p.count > 1 ? p[1] : "")
        }
        guard let out = output else { return ("0.00", "m/s", "0.00", "rad/s") }
        switch mode {
        case .walk:
            let a = parts(out.readoutPrimary), b = parts(out.readoutSecondary)
            return (off ? "0.00" : a.0, "m/s", off ? "0.00" : b.0.replacingOccurrences(of: "-", with: ""), "rad/s")
        case .head:
            return (off ? "0°" : out.readoutPrimary, L("uTurn"), off ? "0°" : out.readoutSecondary, L("uNod"))
        }
    }

    var reticle: CGPoint {
        guard let out = output, !off else { return .zero }
        return CGPoint(x: out.reticleX, y: out.reticleY)
    }

    // MARK: 提示

    func say(_ text: String, warn: Bool = false) {
        toast = (text, warn)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: 动作

    struct Action: Identifiable {
        let id: String
        let name: String
        let icon: Icon
        var on = false
        var sound = false
        let down: () -> Void
        var up: () -> Void = {}
    }

    private func needOn(_ f: @escaping () -> Void) -> () -> Void {
        { [weak self] in
            guard let self else { return }
            if self.off { return self.say(L("needStart"), warn: true) }
            f()
        }
    }

    /// 技能：坐着时提示先站起、未出发时提示先启动（D-6）。
    func skill(_ name: String, label: String) {
        tray = false
        if seated { return say(L("needStand"), warn: true) }
        if off { return say(L("needStart"), warn: true) }
        say(label)
        Task {
            if let reason = await session.intent(.robotDo(skill: name)) { say(reason, warn: true) }
        }
    }

    private func sound(_ q: Quack, hold: Bool? = nil) {
        Task { await session.intent(.robotSound(quack: q, hold: hold)) }
    }

    var actions: [Action] {
        let all: [String: Action] = [
            "sit": Action(id: "sit", name: seated ? L("stand") : L("sit"), icon: seated ? .stand : .sit, down: needOn { [weak self] in
                // 站起：锁住的坐姿发 sit_toggle，未回零位发 init；坐下：sit_toggle。
                guard let self, let call = self.session.postureCall(sit: !self.seated) else { return }
                Task {
                    if let r = await self.session.intent(call) { self.say(r, warn: true) }
                    else { self.session.applied(call) }
                }
            }),
            "pick": Action(id: "pick", name: L("pickUp"), icon: .pick, down: { [weak self] in self?.skill("ground_pick", label: L("pickUp")) }),
            "kickL": Action(id: "kickL", name: L("kickL"), icon: .kickL, down: { [weak self] in self?.skill("kick_left", label: L("kickL")) }),
            "kickR": Action(id: "kickR", name: L("kickR"), icon: .kickR, down: { [weak self] in self?.skill("kick_right", label: L("kickR")) }),
            "roll": Action(id: "roll", name: L("roulade"), icon: .roulade, on: rolling, down: { [weak self] in
                guard let self else { return }
                if self.seated || self.power != .walking { return self.skill("roulade", label: L("roulade")) }
                self.rolling = true
                self.say(L("rouladeT"))
                // 按住连续翻：技能 chain，按住期间持续请求。
                self.rollTask = Task { [weak self] in
                    while !Task.isCancelled, self?.rolling == true {
                        await self?.session.intent(.robotDo(skill: "roulade"))
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                }
            }, up: { [weak self] in self?.rolling = false; self?.rollTask?.cancel() }),
            "center": Action(id: "center", name: L("center"), icon: .center, down: needOn { [weak self] in
                self?.say(L("centered"))
                Task { _ = try? await self?.session.call(.robotHead(neckPitch: 0, headPitch: 0, headYaw: 0, headRoll: 0)) }
            }),
            "quack": Action(id: "quack", name: L("quack"), icon: .quack, on: quackDown, sound: true, down: { [weak self] in
                self?.quackDown = true; self?.say(L("quackT")); self?.sound(.greet)
            }, up: { [weak self] in self?.quackDown = false }),
            "wheee": Action(id: "wheee", name: L("wheee"), icon: .wheee, on: wheeeDown, sound: true, down: { [weak self] in
                self?.wheeeDown = true; self?.say(L("wheeeT")); self?.sound(.wheee, hold: true)
            }, up: { [weak self] in self?.wheeeDown = false; self?.sound(.wheee, hold: false) }),
            "emo": Action(id: "emo", name: L("emotion"), icon: .emotion, on: tray, down: { [weak self] in self?.tray.toggle() }),
            "more": Action(id: "more", name: L("more"), icon: .more, on: tray, sound: true, down: { [weak self] in self?.tray.toggle() }),
        ]
        let set: [String] = switch mode {
        case .walk: session.isRoller ? ["pick", "kickL", "kickR", "roll", "more"] : ["sit", "pick", "kickL", "kickR", "roll", "more"]
        case .head: ["center", "quack", "wheee", "emo"]
        }
        return set.compactMap { all[$0] }
    }

    func dimmed(_ a: Action) -> Bool {
        (off && !a.sound) || (seated && a.id != "sit" && !a.sound)
    }

    struct Emotion: Identifiable {
        let id: String
        let name: String
        let icon: Icon
        let color: Color
        var on = false
        let go: () -> Void
    }

    /// 托盘里的全部按钮：行走模式下先是三个玩法开关（开着的高亮），再是叫声和情绪。
    var trayItems: [Emotion] {
        gameTiles.map { g in
            Emotion(id: "game-" + g.id, name: g.name, icon: g.icon, color: Palette.orange, on: g.on) { [weak self] in self?.toggleGame(g.game) }
        } + emotions
    }

    var emotions: [Emotion] {
        var list: [Emotion] = []
        if mode == .walk {
            list.append(Emotion(id: "quack", name: L("quack"), icon: .quack, color: Palette.text) { [weak self] in
                self?.tray = false; self?.say(L("quackT")); self?.sound(.greet)
            })
        }
        let shipped = session.emotions
        list += shipped.map { e in
            Emotion(id: e.name, name: EmotionStyle.label(e.name), icon: EmotionStyle.icon(e.name), color: EmotionStyle.color(e.name)) { [weak self] in
                self?.emote(e)
            }
        }
        // API 49 之前的机器人没有自带情绪：点头 / 摇头用 robot.head 轨迹，兴奋用 wheee。
        if shipped.isEmpty { list += [
            Emotion(id: "yes", name: L("yes"), icon: .check, color: Palette.cyan) { [weak self] in self?.gesture(nod: true) },
            Emotion(id: "no", name: L("no"), icon: .x, color: Palette.pink) { [weak self] in self?.gesture(nod: false) },
            Emotion(id: "excited", name: L("excited"), icon: .excited, color: Palette.orange) { [weak self] in
                guard let self else { return }
                self.tray = false
                if self.off { return self.say(L("needStart"), warn: true) }
                self.say(L("excited")); self.sound(.wheee, hold: true)
                Task { try? await Task.sleep(for: .seconds(1.5)); self.sound(.wheee, hold: false) }
            },
        ] }
        list += [
            Emotion(id: "custom", name: L("custom"), icon: .plus, color: Palette.purple) { [weak self] in
                guard let self else { return }
                self.tray = false
                let x = self.session.bindings.first { $0.button == "x" }?.skill ?? ""
                if x.isEmpty { self.say(L("assign"), warn: true) } else { self.skill(x, label: isShippedEmotion(name: x) ? EmotionStyle.label(x) : x) }
            },
        ]
        return list
    }

    // MARK: 玩法（追激光、踢球、自由活动）

    struct GameTile: Identifiable {
        let game: Game
        let name: String
        let icon: Icon
        let on: Bool
        var id: String { GameStyle.key(game) }
    }

    /// 正在玩的玩法（机器人报告的），没有为 nil。
    var playing: Game? { session.availableGames.first { gameIsOn(games: session.games, game: $0) } }

    /// 托盘第一行的玩法开关，只在行走模式下出现。
    var gameTiles: [GameTile] {
        guard mode == .walk, !session.isRoller else { return [] }
        return session.availableGames.map {
            GameTile(game: $0, name: L("game_\(GameStyle.key($0))"), icon: GameStyle.icon($0), on: gameIsOn(games: session.games, game: $0))
        }
    }

    /// 开 / 关一个玩法。激光和踢球要先启动、站着（它们靠行走策略走路）；自由活动由鸭子自己启动。
    func toggleGame(_ game: Game) {
        let on = !gameIsOn(games: session.games, game: game)
        let name = L("game_\(GameStyle.key(game))")
        if on, game != .autonomous {
            if off { return say(L("needStart"), warn: true) }
            if seated { return say(L("needStand"), warn: true) }
        }
        tray = false
        say(on ? (game == .autonomous ? L("autonomousStarted") : L("gameStarted", name)) : L("gameStopped", name))
        Task {
            if let reason = await session.setGame(game, on: on) { say(reason, warn: true) }
            else if on, game != .autonomous { try? await Task.sleep(for: .seconds(2.5)); say(L("game_\(GameStyle.key(game))Hint")) }
        }
    }

    /// 机器人自带的情绪：`robot.do <名字>`，和技能同样要求站着、已启动；一次只播一个。
    private func emote(_ e: EmotionInfo) {
        tray = false
        if seated { return say(L("needStand"), warn: true) }
        if off { return say(L("needStart"), warn: true) }
        if Date() < emotingUntil { return say(L("emoBusy"), warn: true) }
        let label = EmotionStyle.label(e.name)
        say(e.sits ? "\(label) · \(L("emoSits"))" : label)
        emotingUntil = Date() + e.seconds
        Task {
            if let reason = await session.intent(.robotDo(skill: e.name)) {
                emotingUntil = .distantPast
                say(reason, warn: true)
            }
        }
    }

    /// 点头 / 摇头：robot.head 预设轨迹（点头 = 俯仰 ±15° 两次，摇头 = 转向 ±25° 两次）。
    private func gesture(nod: Bool) {
        tray = false
        if seated { return say(L("needStand"), warn: true) }
        if off { return say(L("needStart"), warn: true) }
        say(nod ? L("yes") : L("no"))
        Task {
            let a = (nod ? 15.0 : 25.0) * .pi / 180
            for v in [a, -a, a, -a, 0] {
                let c: DuckCall = nod ? .robotHead(neckPitch: 0, headPitch: v, headYaw: 0, headRoll: 0)
                                      : .robotHead(neckPitch: 0, headPitch: 0, headYaw: v, headRoll: 0)
                for _ in 0..<6 { _ = try? await session.call(c); try? await Task.sleep(for: .milliseconds(50)) }
            }
        }
    }

    // MARK: 启动键 / 电源键

    var startIcon: Icon { off ? .bolt : power == .stiff ? .play : .pause }
    var startText: String { off ? L("start") : power == .stiff ? L("go") : L("stop") }

    func startReleased(_ held: Double) {
        Task {
            if held >= 1.5 {
                // init 只把鸭子送到座位、策略不驱动：保持"关"，下一次 Start 才发 enable 起身。
                if let r = await session.intent(.robotInit) { return say(r, warn: true) }
                session.applied(.robotInit)
                return say(L("home"))
            }
            switch session.power {
            case .off:
                if let r = await session.intent(.robotEnable(on: true)) { return say(r, warn: true) }
                session.applied(.robotEnable(on: true))
            case .stiff:
                session.power = .walking
            case .walking:
                await session.intent(.robotStop)
                session.power = .stiff
            }
        }
    }

    func powerReleased(_ held: Double) {
        if held >= 4 {
            say(L("poweringOff"), warn: true)
            Task {
                if let r = await session.intent(.robotShutdown) { return say(r, warn: true) }
                session.applied(.robotShutdown)
                await leaveAfterPowerOff()
            }
        } else if held >= 2 {
            say(L("resting"), warn: true)
            Task { await session.intent(.robotRest); session.applied(.robotRest) }
        } else {
            say(L("holdRest"))
        }
    }

    /// 关机被接受后：留在驾驶页看它坐下，等机器人断电、蓝牙断开（最多 20 s，演示 3 s），
    /// 再断开会话回到机器人列表，免得停在一个连不上的控制页里静默重连。
    private func leaveAfterPowerOff() async {
        let limit: Duration = session.isDemo ? .seconds(3) : .seconds(20)
        let start = ContinuousClock.now
        while session.linkState == .ready, ContinuousClock.now - start < limit {
            try? await Task.sleep(for: .milliseconds(250))
        }
        session.disconnect()
        model.path.removeAll()
        model.say(L("poweredOff"))
    }

    func toggleCam() {
        if camOn { stopRecording() }
        camOn.toggle()
        session.media.setVideo(camOn)
        say(camOn ? L("camOnT") : L("camOffT"))
    }

    // MARK: 拍照 / 录像

    /// 正在录像时的开始时刻（画面角标显示时长）。
    var recordingSince: Date?
    var recording: Bool { recordingSince != nil }
    @ObservationIgnored private var saving = false

    func takePhoto() {
        let capture = session.media.capture
        Task {
            do {
                let jpeg = try await capture.photo()
                try await PhotoLibrary.save(photo: jpeg)
                say(L("photoSaved"))
            } catch {
                say(Self.message(error), warn: true)
            }
        }
    }

    func toggleRecord() {
        if recording { stopRecording(); return }
        guard camOn, !saving else { return }
        guard session.media.videoLive else { return say(L("noFrame"), warn: true) }
        let capture = session.media.capture
        recordingSince = Date()
        Task {
            var mic = AVAudioApplication.shared.recordPermission == .granted
            if AVAudioApplication.shared.recordPermission == .undetermined { mic = await AVAudioApplication.requestRecordPermission() }
            guard recording else { return }
            do {
                try capture.startRecording(withMic: mic)
                if !mic { say(L("recNoMic"), warn: true) }
            } catch {
                recordingSince = nil
                say(L("recFailed"), warn: true)
            }
        }
    }

    /// 停止录像并存进相册（离开驾驶页、关画面、退到后台时也会调用）。
    func stopRecording() {
        guard recording else { return }
        recordingSince = nil
        saving = true
        let capture = session.media.capture
        Task {
            defer { saving = false }
            guard let url = await capture.stopRecording() else { return say(L("recFailed"), warn: true) }
            do {
                try await PhotoLibrary.save(video: url)
                say(L("videoSaved"))
            } catch {
                try? FileManager.default.removeItem(at: url)
                say(Self.message(error), warn: true)
            }
        }
    }

    private static func message(_ error: Error) -> String {
        switch error {
        case VideoCapture.Failure.noFrame: L("noFrame")
        case PhotoLibrary.Failure.denied: L("saveDenied")
        default: L("saveFailed")
        }
    }
}
