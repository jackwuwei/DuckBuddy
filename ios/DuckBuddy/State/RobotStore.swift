import Foundation

/// 已添加过的机器人（`robots.json`）。按 SoC 序列号派生的首名识别，蓝牙标识只作缓存；
/// **不保存设置码**（只在 Keychain）。
struct KnownRobot: Codable, Identifiable, Equatable {
    /// 首名 `duck-xxxx`，改名不变。
    var id: String
    var displayName: String
    var lastIPv4: String?
    var lastVolts: Double?
    var peripheralID: UUID?
    var lastUsed: Date
    /// 官方配色（`colourwayKey`），用户在状态页选；空则为默认 Cream。
    var colourway: String?
}

@MainActor
final class RobotStore {
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("robots.json")
    }()

    func load() -> [KnownRobot] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([KnownRobot].self, from: data) else { return [] }
        return list.sorted { $0.lastUsed > $1.lastUsed }
    }

    func save(_ robots: [KnownRobot]) {
        if let data = try? JSONEncoder().encode(robots) { try? data.write(to: url, options: .atomic) }
    }
}
