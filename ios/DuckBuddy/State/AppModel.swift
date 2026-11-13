import Foundation
import Observation
import SwiftUI

enum Route: Hashable {
    case setup, drive, status, policy, gamepad, settings
}

/// 豆包密钥（只存 Keychain，界面只回显末 4 位）。
struct DoubaoKey: Codable, Equatable {
    enum Method: String, Codable { case apiKey, appToken }
    var method: Method
    var key: String
    var appID: String?

    var credential: DoubaoCredential {
        method == .apiKey ? .apiKey(key: key) : .appToken(appId: appID ?? "", accessToken: key)
    }

    var masked: String { "••••••" + String(key.suffix(4)) }
}

/// App 全局状态。界面只读这一层；跨折叠 / 展开、分屏改变尺寸时保持不变，所以 iPhone Duo 开合不打断驾驶。
@MainActor
@Observable
final class AppModel {
    var path: [Route] = []
    var robots: [KnownRobot]
    var selectedID: String?
    var toast: (text: String, warn: Bool)?
    var lang: Lang {
        didSet {
            L10n.shared.lang = lang
            UserDefaults.standard.set(lang.rawValue, forKey: "lang")
        }
    }

    // 语音设置
    var doubaoKey: DoubaoKey?
    var doubaoInvalid = false
    var speakReplies: Bool { didSet { UserDefaults.standard.set(speakReplies, forKey: "speakReplies") } }
    var voiceConsent: Bool { didSet { UserDefaults.standard.set(voiceConsent, forKey: "voiceConsent") } }
    var allowCommunity = false

    let session: RobotSession
    @ObservationIgnored private let store = RobotStore()
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(demo: Bool) {
        let saved = UserDefaults.standard.string(forKey: "lang").flatMap(Lang.init(rawValue:))
        lang = saved ?? .zh
        L10n.shared.lang = saved ?? .zh
        speakReplies = UserDefaults.standard.object(forKey: "speakReplies") as? Bool ?? true
        voiceConsent = UserDefaults.standard.bool(forKey: "voiceConsent")
        session = RobotSession(demo: demo)
        robots = demo
            ? [KnownRobot(id: "duck-1a2b", displayName: "duck-1a2b", lastIPv4: "192.168.1.42", lastVolts: 7.9, lastUsed: Date()),
               KnownRobot(id: "duck-7c90", displayName: "duck-7c90", lastIPv4: nil, lastVolts: 7.4, lastUsed: Date(timeIntervalSinceNow: -60))]
            : RobotStore().load()
        selectedID = robots.first?.id
        if let json = SecureStore.get(SecureStore.doubaoKey), let data = json.data(using: .utf8) {
            doubaoKey = try? JSONDecoder().decode(DoubaoKey.self, from: data)
        }
    }

    func say(_ text: String, warn: Bool = false) {
        withAnimation(.easeOut(duration: 0.15)) { toast = (text, warn) }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation { self?.toast = nil }
        }
    }

    func remember(_ robot: KnownRobot) {
        robots.removeAll { $0.id == robot.id }
        robots.insert(robot, at: 0)
        if !session.isDemo { store.save(robots) }
    }

    func touch(_ id: String) {
        guard let i = robots.firstIndex(where: { $0.id == id }) else { return }
        robots[i].lastUsed = Date()
        if let v = session.health?.batteryVolts { robots[i].lastVolts = v }
        if let ip = session.net?.ip4 { robots[i].lastIPv4 = ip }
        robots.sort { $0.lastUsed > $1.lastUsed }
        if !session.isDemo { store.save(robots) }
    }

    func saveDoubaoKey(_ key: DoubaoKey?) {
        doubaoKey = key
        doubaoInvalid = false
        if let key, let data = try? JSONEncoder().encode(key), let s = String(data: data, encoding: .utf8) {
            SecureStore.set(s, for: SecureStore.doubaoKey)
        } else {
            SecureStore.remove(SecureStore.doubaoKey)
        }
    }

    func setupCode(for id: String) -> SetupCode? {
        SecureStore.get(SecureStore.setupCodeKey(id)).flatMap { try? parseSetupCode(text: $0) }
    }

    /// 连接选中的机器人并进入驾驶页。
    func connectSelected() async {
        guard let id = selectedID else { return }
        do {
            try await session.connect(robotID: id, credential: setupCode(for: id))
            touch(id)
            path = [.drive]
        } catch {
            say(error.localizedDescription, warn: true)
        }
    }
}
