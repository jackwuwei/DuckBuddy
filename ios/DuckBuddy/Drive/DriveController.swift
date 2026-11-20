import Foundation
import Observation
import SwiftUI

/// 驾驶页逻辑（与设计稿 PortraitDrive / Main 的交互一一对应）：模式、摇杆发送、动作前置条件、
/// 启动键（短按启动 / 出发 / 停止，长按 1.5 s 回初始姿态）、电源键（长按 2 s 休息、4 s 关机）。
@MainActor
@Observable
final class DriveController {
    enum Mode: CaseIterable { case walk, head, look, height }

    var mode: Mode = .walk
    var left = CGPoint.zero
    var right = CGPoint.zero
    var camOn = true
    var tray = false
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
    /// 模拟器里没有手指，用它走真实的摇杆 → teleop 路径（mapSticks → 20 ms 泵 → session.call → 视频通道）。
    private func debugStick() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-stick"), i + 1 < args.count else { return }
        let parts = args[i + 1].split(separator: ":")
        guard parts.count == 3, let secs = Double(parts[2]) else { return }
        let v = parts[1].split(separator: ",").compactMap { Double($0) }
        guard v.count == 4 else { return }
        mode = ["walk": .walk, "head": .head, "look": .look, "height": .height][String(parts[0])] ?? .walk
        if mode == .walk || mode == .look { session.power = .walking }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))   // 等视频通道连上
            self?.left = CGPoint(x: v[0], y: v[1]); self?.right = CGPoint(x: v[2], y: v[3])
            try? await Task.sleep(for: .seconds(secs))
            self?.left = .zero; self?.right = .zero
        }
    }
    #endif

    func stopLoop() {
        loop?.cancel()
        if session.power == .walking { Task { await session.intent(.robotMove(vx: 0, vy: 0, vyaw: 0)) } }
    }

    private func pump() {
        let m: StickMode = switch mode {
        case .walk: .walk
        case .head: .head
        case .look: .walkLook
        case .height: .height
        }
        let out = mapSticks(mode: m, left: Stick(x: left.x, y: left.y), right: Stick(x: right.x, y: right.y), roller: session.isRoller, wasMoving: wasMoving)
        output = out
        wasMoving = out.moving
        let idle = left == .zero && right == .zero
        if idle && wasIdle { return } // 松手后只发一次零
        wasIdle = idle
        guard !off else { return }
        for call in out.calls {
            if case .robotMove = call, session.power != .walking || seated { continue }
            Task { _ = try? await session.call(call) }
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
        case .walk, .look:
            let a = parts(out.readoutPrimary), b = parts(out.readoutSecondary)
            if mode == .look { return (a.0, "m/s", off ? "0°" : b.0, L("uTurn")) }
            return (off ? "0.00" : a.0, "m/s", off ? "0.00" : b.0.replacingOccurrences(of: "-", with: ""), "rad/s")
        case .head:
            return (off ? "0°" : out.readoutPrimary, L("uTurn"), off ? "0°" : out.readoutSecondary, L("uNod"))
        case .height:
            return (off ? "0%" : out.readoutPrimary, L("uHeight"), off ? "0°" : out.readoutSecondary, L("uLean"))
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
            "level": Action(id: "level", name: L("level"), icon: .reset, down: needOn { [weak self] in self?.say(L("leveled")) }),
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
        case .look: ["sit", "center", "quack", "emo"]
        case .height: ["level", "sit", "quack", "wheee"]
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
        let go: () -> Void
    }

    var emotions: [Emotion] {
        var list: [Emotion] = []
        if mode == .walk {
            list.append(Emotion(id: "quack", name: L("quack"), icon: .quack, color: Palette.text) { [weak self] in
                self?.tray = false; self?.say(L("quackT")); self?.sound(.greet)
            })
        }
        list += [
            Emotion(id: "yes", name: L("yes"), icon: .check, color: Palette.cyan) { [weak self] in self?.gesture(nod: true) },
            Emotion(id: "no", name: L("no"), icon: .x, color: Palette.pink) { [weak self] in self?.gesture(nod: false) },
            Emotion(id: "excited", name: L("excited"), icon: .excited, color: Palette.orange) { [weak self] in
                guard let self else { return }
                self.tray = false
                if self.off { return self.say(L("needStart"), warn: true) }
                self.say(L("excited")); self.sound(.wheee, hold: true)
                Task { try? await Task.sleep(for: .seconds(1.5)); self.sound(.wheee, hold: false) }
            },
            Emotion(id: "custom", name: L("custom"), icon: .plus, color: Palette.purple) { [weak self] in
                guard let self else { return }
                self.tray = false
                let x = self.session.bindings.first { $0.button == "x" }?.skill ?? ""
                if x.isEmpty { self.say(L("assign"), warn: true) } else { self.skill(x, label: x) }
            },
        ]
        return list
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
            Task { await session.intent(.robotShutdown); session.applied(.robotShutdown) }
        } else if held >= 2 {
            say(L("resting"), warn: true)
            Task { await session.intent(.robotRest); session.applied(.robotRest) }
        } else {
            say(L("holdRest"))
        }
    }

    func toggleCam() {
        camOn.toggle()
        session.media.setVideo(camOn)
        say(camOn ? L("camOnT") : L("camOffT"))
    }
}
