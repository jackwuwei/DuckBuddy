import CoreBluetooth
import Foundation
import Observation

enum LinkState: Equatable {
    case idle, connecting, pairing, authenticating, ready, reconnecting
    case failed(String)
}

/// 机器人在 App 里的"电源"状态：放松（无力矩）/ 站着（有力矩、未驱动）/ 行走中（策略驱动）。
enum Power { case off, stiff, walking }

struct RobotError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 一只机器人的会话层（技术方案 §3.1 会话层）：
/// - 蓝牙断开后静默重连、重新认证、重新拉取状态；
/// - 认证会话 60 s 无请求会过期，前台每 20 s 发一个只读请求续期；
/// - 所有请求由 duck-core 生成，回复按 JSON-RPC id 匹配。
@MainActor
@Observable
final class RobotSession {
    // 连接
    private(set) var linkState: LinkState = .idle
    private(set) var nearby: [NearbyRobot] = []
    private(set) var robotID: String?
    var robotName: String = ""
    private(set) var apiVersion: UInt32?

    // 机器人状态
    var health: Health?
    var net: NetStatus?
    var policies: Policies?
    var skills: [SkillInfo] = []
    var bindings: [PadBinding] = []
    var state: DuckState?
    var power: Power = .off
    var seated = false
    /// 全局操作锁：加载策略、切换模式、配网期间。
    var busy = false

    let isDemo: Bool
    @ObservationIgnored let media: MediaLink
    @ObservationIgnored private let ble: BleCentral?
    @ObservationIgnored private var link: DuckLink?
    @ObservationIgnored private var credential: SetupCode?
    @ObservationIgnored private var pending: [UInt64: CheckedContinuation<String, Error>] = [:]
    @ObservationIgnored private var connectWaiter: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var leaseTask: Task<Void, Never>?
    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    @ObservationIgnored private var wantConnected = false
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private let demo: DemoRobot?

    init(demo: Bool) {
        isDemo = demo
        if demo {
            let d = DemoRobot()
            self.demo = d
            ble = nil
            media = DemoMediaLink(robot: d)
            nearby = d.nearby
        } else {
            self.demo = nil
            ble = BleCentral()
            media = WebRTCMediaLink()
        }
        media.onState = { [weak self] s in self?.state = s }
        ble?.onNearbyChange = { [weak self] in self?.refreshNearby() }
        ble?.onPoweredOn = { [weak self] in self?.startScan() }
        ble?.onReady = { [weak self] mtu in self?.linkReady(mtu: mtu) }
        ble?.onData = { [weak self] data in self?.receive(data) }
        ble?.onDisconnect = { [weak self] error in self?.linkDropped(error) }
    }

    var bluetoothUsable: Bool { isDemo || (ble?.isPoweredOn ?? false) }

    // MARK: 扫描

    func startScan() {
        guard let ble else { return }
        ble.startScan()
        pruneTask?.cancel()
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.ble?.pruneNearby()
            }
        }
    }

    func stopScan() {
        ble?.stopScan()
        pruneTask?.cancel()
    }

    private func refreshNearby() {
        nearby = (ble?.nearby.values.map { $0 } ?? []).sorted { $0.rssi > $1.rssi }
    }

    // MARK: 连接

    /// 连接并认证。`credential` 为空时走 PIN 模式（出厂 PIN 静默发送）。
    func connect(robotID: String, credential: SetupCode?) async throws {
        self.robotID = robotID
        self.credential = credential
        wantConnected = true
        if let demo {
            linkState = .connecting
            try await Task.sleep(for: .milliseconds(500))
            robotName = demo.name(for: robotID)
            linkState = .ready
            await afterReady()
            return
        }
        guard let ble else { return }
        guard ble.isPoweredOn else { throw RobotError(message: L("bleOff")) }
        guard let p = ble.nearby[robotID]?.peripheral else { throw RobotError(message: L("notNearby")) }
        peripheral = p
        link = DuckLink(credential: credential)
        linkState = .connecting
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connectWaiter = c
            ble.connect(p)
        }
    }

    func disconnect() {
        wantConnected = false
        leaseTask?.cancel()
        media.close()
        link?.close()
        ble?.disconnect()
        failPending(RobotError(message: L("linkLost")))
        linkState = .idle
        power = .off
        state = nil
    }

    private func linkReady(mtu: UInt16) {
        guard let link else { return }
        link.setMtu(mtu: mtu)
        linkState = credential == nil ? .authenticating : .pairing
        do { ble?.write(try link.open()) } catch { finishConnect(error) }
    }

    private func receive(_ data: Data) {
        guard let link else { return }
        for event in link.receive(chunk: data) { handle(event) }
    }

    private func handle(_ event: LinkEvent) {
        switch event {
        case .write(let chunks):
            ble?.write(chunks)
        case .authenticated(let api, _):
            apiVersion = api
            linkState = .ready
            finishConnect(nil)
            Task { await afterReady() }
        case .reply(let id, let json):
            pending.removeValue(forKey: id)?.resume(returning: json)
        case .refused(let id, _, let message):
            pending.removeValue(forKey: id)?.resume(throwing: RobotError(message: message))
        case .state(let s):
            state = s
        case .notification:
            break
        case .failed(let failure):
            let message: String
            switch failure {
            case .robotTooOld(let api, let min): message = L("robotTooOld", api, min)
            case .wrongKey: message = L("wrongKey")
            case .pinRejected: message = L("pinRejected")
            case .framing, .protocol: message = L("linkLost")
            }
            wantConnected = false
            ble?.disconnect()
            linkState = .failed(message)
            finishConnect(RobotError(message: message))
        }
    }

    private func finishConnect(_ error: Error?) {
        guard let c = connectWaiter else { return }
        connectWaiter = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    private func linkDropped(_ error: Error?) {
        link?.close()
        failPending(RobotError(message: L("linkLost")))
        leaseTask?.cancel()
        if connectWaiter != nil {
            // 握手阶段断开：安全模式下多半是设置码不对（机器人直接断开），或用户取消了系统配对框。
            let message: String
            if case BleCentral.LinkError.pairingCancelled? = error as? BleCentral.LinkError { message = L("pairCancelled") }
            else if link?.phase() == .handshaking { message = L("wrongKey") }
            else { message = L("linkLost") }
            linkState = .failed(message)
            finishConnect(RobotError(message: message))
            return
        }
        guard wantConnected, let p = peripheral else { linkState = .idle; return }
        // 静默重连：不弹窗，状态栏显示"重连中"，成功后重新认证并重新拉取。
        linkState = .reconnecting
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.wantConnected else { return }
            self.link = DuckLink(credential: self.credential)
            self.ble?.connect(p)
        }
    }

    private func failPending(_ error: Error) {
        let all = pending
        pending.removeAll()
        all.values.forEach { $0.resume(throwing: error) }
    }

    /// 认证后：拉取状态、开启续期、尝试打开视频通道。
    private func afterReady() async {
        await refreshAll()
        leaseTask?.cancel()
        leaseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                await self?.refreshHealth()
            }
        }
        if let ip = net?.ip4 { media.open(ip: ip, session: self) }
    }

    // MARK: 请求

    /// 发一个请求并等待回复 JSON。超时 10 s。
    func call(_ call: DuckCall, timeout: Duration = .seconds(10)) async throws -> String {
        if let demo { return try await demo.answer(call, session: self) }
        if call.isContinuous {
            media.send(call)
            return "null"
        }
        guard let link, linkState == .ready else { throw RobotError(message: L("linkLost")) }
        let out = try link.request(call: call)
        ble?.write(out.chunks)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { c in self.pending[out.id] = c }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RobotError(message: L("linkLost"))
            }
            defer {
                group.cancelAll()
                self.pending.removeValue(forKey: out.id)?.resume(throwing: CancellationError())
            }
            return try await group.next()!
        }
    }

    /// 动作类请求：被拒绝时返回原因，成功返回 nil。
    @discardableResult
    func intent(_ c: DuckCall) async -> String? {
        do {
            let json = try await call(c)
            if let i = try? decodeIntent(json: json), !i.accepted { return i.reason ?? "refused" }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshAll() async {
        await refreshHealth()
        if let json = try? await call(.netStatus) { net = try? decodeNetStatus(json: json) }
        await refreshPolicies()
        if let json = try? await call(.padBindings) { bindings = (try? decodePadBindings(json: json)) ?? bindings }
        if let json = try? await call(.systemInfo), let info = try? decodeSystemInfo(json: json) { robotName = info.name }
    }

    func refreshHealth() async {
        if let json = try? await call(.robotHealth) { health = try? decodeHealth(json: json) }
    }

    func refreshPolicies() async {
        if let json = try? await call(.robotPolicies), let p = try? decodePolicies(json: json) {
            policies = p
            if let s = p.sitting { seated = s }
        }
        if let json = try? await call(.robotSkills) { skills = (try? decodeSkills(json: json)) ?? skills }
    }

    var batteryFraction: Double {
        if let pct = health?.batteryPercent { return pct / 100 }
        if let v = health?.batteryVolts { return DuckBuddy.batteryFraction(volts: v) }
        return 0
    }

    var isRoller: Bool { policies?.mode == "roller" }
}

extension DuckCall {
    var isContinuous: Bool {
        switch self {
        case .robotMove, .robotHead: true
        default: false
        }
    }
}
