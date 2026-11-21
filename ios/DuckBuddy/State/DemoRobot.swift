import Foundation

/// 演示鸭子：按官方回复的形状应答（JSON 与 `duck-ipc-proto` 结构一致，经同一套 duck-core 解码），
/// 用于没有硬件时在模拟器里走完全部页面，也用于界面截图对照设计稿。
/// 启动参数 `-demo` 开启。
@MainActor
final class DemoRobot {
    private var mode = "walk"
    private var sitting = false
    /// 与真机一致：休息后没回零位（趴着但不是 sit_toggle 锁住的坐姿），站起要 init。
    private var homed = true
    private var enabled = false
    private var laser = false, soccer = false, autonomous = false
    private var name = "duck-1a2b"
    private var head: [Double] = [0, 0, 0, 0]
    private var move: [Double] = [0, 0, 0]
    private var t = 0.0
    private var bindings: [String: String] = ["a": "sit_toggle", "b": "ground_pick", "x": "", "y": "", "lb": "", "rb": ""]
    private var disabledSkills: Set<String> = []

    /// 官方 HOME / REST 姿态（duck-control model.rs，与设计稿状态页同一组数）。
    static let home: [Double] = [0, -0.0873, -0.4579, -0.0049, 0.453, 0.3491, 0.3491, 0, 0, 0, 0, 0.0873, 0.4579, 0.0049, -0.453]
    static let rest: [Double] = [0.3129, 0.405, -0.2338, 1.5493, 0.5522, 0.9572, 1.4787, -0.0129, -0.0522, -0.0121, 0.0353, -0.566, 0.2853, -1.4696, -0.4096]

    var nearby: [NearbyRobot] {
        [
            NearbyRobot(advert: Advertisement(name: "duck-1a2b", ipv4: "192.168.1.42", hasAddressField: true, isExtended: true, busy: false),
                        rssi: -52, peripheral: nil, lastSeen: Date()),
            NearbyRobot(advert: Advertisement(name: "duck-7c90", ipv4: nil, hasAddressField: true, isExtended: true, busy: false),
                        rssi: -74, peripheral: nil, lastSeen: Date()),
            NearbyRobot(advert: Advertisement(name: "duck-e41f", ipv4: nil, hasAddressField: true, isExtended: true, busy: false),
                        rssi: -88, peripheral: nil, lastSeen: Date()),
        ]
    }

    func name(for id: String) -> String { id == "duck-1a2b" ? name : id }

    func apply(_ call: DuckCall) {
        switch call {
        case .robotMove(let vx, let vy, let vyaw): move = [vx, vy, vyaw]
        case .robotHead(let np, let hp, let hy, let hr): head = [np, hp, hy, hr]
        default: break
        }
    }

    func tick(session: RobotSession) -> DuckState {
        t += 0.1
        let base = sitting || !homed ? Self.rest : Self.home
        var targets = base
        targets[6] += head[1]; targets[7] += head[2]; targets[8] += head[3]
        let joints = targets.enumerated().map { i, v in
            v + ((i == 3 ? 2.2 : 0) + sin(t * 0.9 + Double(i) * 1.7) * 0.35) * .pi / 180
        }
        let pitch = -(sitting || !homed ? 9.0 : 3.0) * .pi / 180
        let quat = [cos(pitch / 2), 0, sin(pitch / 2), 0]
        return DuckState(t: t, joints: joints, targets: targets, quat: quat, policy: enabled ? "walk" : "held",
                         fallen: false, limp: !enabled, pickedUp: false, head: head, applied: move,
                         posture: classifyPosture(joints: joints, quat: quat))
    }

    func answer(_ call: DuckCall, session: RobotSession) async throws -> String {
        try await Task.sleep(for: .milliseconds(120))
        let ok = #"{"accepted":true}"#
        switch call {
        case .systemInfo:
            return #"{"name":"\#(name)","serial":"1a2b3c4d","uptime_seconds":5321}"#
        case .systemSetName(let n):
            name = n
            return #"{"name":"\#(n)"}"#
        case .robotHealth:
            return #"{"healthy":true,"battery":{"volts":7.9,"percent":81},"motors":{"hottest":"left_knee","max_c":41.5,"mean_c":36.2},"cpu_temp_c":52.0,"bus":{"consecutive_errors":0,"startup_failures":0}}"#
        case .netStatus:
            return #"{"state":"connected","ssid":"Home Wi-Fi","signal":72,"ip4":"192.168.1.42","ip6":null,"mac":null,"iface":"wlan0"}"#
        case .netScan:
            try await Task.sleep(for: .milliseconds(600))
            return #"{"networks":[{"ssid":"Home Wi-Fi","signal":72,"security":"wpa_psk","saved":true},{"ssid":"Home Wi-Fi 5G","signal":64,"security":"wpa_psk","saved":false},{"ssid":"Phone hotspot","signal":45,"security":"wpa_psk","saved":false},{"ssid":"Neighbour","signal":20,"security":"wpa_psk","saved":false}]}"#
        case .netConnect:
            try await Task.sleep(for: .milliseconds(1500))
            return #"{"state":"connected","ssid":"Home Wi-Fi","signal":72,"ip4":"192.168.1.42","ip6":null,"mac":null,"iface":"wlan0"}"#
        case .robotPolicies:
            let roller = mode == "roller"
            return """
            {"mode":"\(mode)","enabled":true,"homed":\(homed),"sitting":\(sitting),"skills":["kick_left","kick_right","roulade"],"slots":[
            {"slot":"walk","path":"/usr/share/microduck/policies/\(roller ? "roller" : "velstand").onnx","origin":"official","overridden":false,"error":null},
            {"slot":"stand","path":null,"origin":null,"overridden":false,"error":null},
            {"slot":"sitstand","path":"/usr/share/microduck/policies/alpha_sitstand.onnx","origin":"official","overridden":false,"error":null},
            {"slot":"ground_pick","path":"/usr/share/microduck/policies/\(roller ? "roller_crouch" : "alpha_ground_pick").onnx","origin":"official","overridden":false,"error":null}]}
            """
        case .robotSkills:
            let skill = { (n: String, d: Double, chain: Bool) in
                #"{"name":"\#(n)","path":\#(self.disabledSkills.contains(n) ? "\"none\"" : "null"),"duration":\#(d),"chain":\#(chain)}"#
            }
            return #"{"skills":[\#(skill("kick_left", 1.6, false)),\#(skill("kick_right", 1.6, false)),\#(skill("roulade", 2.4, true))],"built_in":["ground_pick","sit_toggle"]}"#
        case .robotDisableSkill(let n):
            disabledSkills.insert(n); return ok
        case .robotAddSkill(let n, _, _):
            disabledSkills.remove(n); return ok
        case .padBindings:
            let rows = ["a", "b", "x", "y", "lb", "rb"].map { #"{"button":"\#($0)","skill":"\#(bindings[$0] ?? "")","overridden":false}"# }
            return #"{"bindings":[\#(rows.joined(separator: ","))]}"#
        case .padBind(let button, let target):
            switch target {
            case .skill(let n): bindings[button] = n
            case .off: bindings[button] = ""
            case .default: bindings[button] = ["a": "sit_toggle", "b": "ground_pick"][button] ?? ""
            }
            return ok
        case .robotSetMode(let m):
            try await Task.sleep(for: .milliseconds(900))
            mode = m == .roller ? "roller" : "walk"
            return ok
        case .robotEnable(let on):
            // 与真机一致：策略接管后自己回零位、从座位起身。
            enabled = on
            if on { homed = true; sitting = false }
            return ok
        case .robotDo(let skill):
            if !enabled { return #"{"accepted":false,"reason":"press Start first"}"# }
            if skill == "sit_toggle" { if sitting { sitting = false; homed = true } else if homed { sitting = true } }
            if skill == "devastated" { sitting = true }
            return ok
        case .robotLaserTrack(let a):
            laser = a; if a { soccer = false }; return ok
        case .robotSoccer(let a, _):
            soccer = a; if a { laser = false }; return ok
        case .robotAutonomous(let a):
            autonomous = a; return ok
        case .robotMode:
            return #"{"mode":"\#(mode)"\#(soccer ? #","soccer":{"active":true,"autonomous":true}"# : "")\#(laser ? #","laser":true"# : "")\#(autonomous ? #","autonomous":true"# : "")}"#
        case .robotRest, .robotShutdown:
            enabled = false; sitting = false; homed = false; return ok
        case .robotInit:
            enabled = false; sitting = true; homed = true; return ok
        case .robotLoadPolicy:
            try await Task.sleep(for: .milliseconds(1200))
            return ok
        case .policyCheck:
            return "[]"
        case .policySearch:
            try await Task.sleep(for: .milliseconds(500))
            return #"{"models":[{"id":"pollen-robotics/microduck-bouncy-walk","origin":"official","likes":12,"downloads":340,"description":"A bouncier walk"},{"id":"someone/flamingo-cycle","origin":"community","likes":3,"downloads":41,"description":"Stands on one foot, switching sides"},{"id":"someone/bow","origin":"community","likes":5,"downloads":20,"description":"Bows from a two-foot stand and comes back up, 4 s"}]}"#
        case .policyFetch(let repo, _):
            try await Task.sleep(for: .milliseconds(900))
            let leaf = repo.split(separator: "/").last.map(String.init) ?? repo
            return #"{"path":"/var/lib/microduck/policies/\#(leaf).onnx","repo":"\#(repo)","revision":"main","commit":null,"file":"policy.onnx","origin":"community","name":"\#(leaf)","description":null,"kind":null,"duration_s":4.0,"action_scale":null,"unwind_s":null,"idle":null,"encoding":null,"chain":false,"schema_version":1}"#
        default:
            return ok
        }
    }
}
