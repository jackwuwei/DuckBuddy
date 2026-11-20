import CoreBluetooth
import Foundation

/// 附近的一只鸭子（扫描结果）。
struct NearbyRobot: Identifiable, Equatable {
    var id: String { advert.name }
    var advert: Advertisement
    var rssi: Int
    var peripheral: CBPeripheral?
    var lastSeen: Date

    /// 0–4 格信号。
    var bars: Int {
        switch rssi {
        case (-60)...: 4
        case (-70)...: 3
        case (-80)...: 2
        case (-90)...: 1
        default: 0
        }
    }
}

/// CoreBluetooth 平台层：扫描、连接、读一次 RPC 特征（触发系统配对）、订阅、按顺序写。
/// 不解析任何协议字节——全部交给 `DuckLink`（duck-core）。
@MainActor
final class BleCentral: NSObject {
    enum LinkError: Error { case poweredOff, unauthorized, notFound, pairingCancelled, disconnected }

    private(set) var nearby: [String: NearbyRobot] = [:]
    /// 最近一次看到忙碌广播（被别的设备连着）的时间，按鸭子名。
    private(set) var busySeen: [String: Date] = [:]
    var onNearbyChange: (() -> Void)?
    var onPoweredOn: (() -> Void)?
    /// 链路就绪（已配对、已订阅），参数为 ATT MTU。
    var onReady: ((UInt16) -> Void)?
    var onData: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rpc: CBCharacteristic?
    private var awaitingVersionRead = false
    private var writeQueue: [Data] = []
    private var writing = false

    private let serviceUUID = CBUUID(string: serviceUuid())
    private let rpcUUID = CBUUID(string: rpcCharacteristicUuid())

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isPoweredOn: Bool { central.state == .poweredOn }
    var authorization: CBManagerAuthorization { CBManager.authorization }

    func startScan() {
        guard central.state == .poweredOn else { return }
        // 不按服务过滤：官方经验是扫描不过滤、由客户端自己甄别（mobile-app.md §2）；
        // 广播是否属于鸭子由 duck-core 的 parseAdvertisement 判定。
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() { central.stopScan() }

    /// 剔除 6 秒内没再出现的。
    func pruneNearby() {
        let cutoff = Date().addingTimeInterval(-6)
        let before = nearby.count
        nearby = nearby.filter { $0.value.lastSeen > cutoff }
        busySeen = busySeen.filter { $0.value > cutoff }
        if nearby.count != before { onNearbyChange?() }
    }

    /// 鸭子此刻被另一台设备连着：最近看到它的忙碌广播，且比可连接广播更新。
    func isBusy(_ name: String) -> Bool {
        guard let busy = busySeen[name], busy.timeIntervalSinceNow > -6 else { return false }
        guard let free = nearby[name] else { return true }
        return busy > free.lastSeen
    }

    func peripheral(id: UUID) -> CBPeripheral? {
        central.retrievePeripherals(withIdentifiers: [id]).first
    }

    func connect(_ p: CBPeripheral) {
        disconnect()
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    func disconnect() {
        if let p = peripheral {
            if let rpc, p.state == .connected { p.setNotifyValue(false, for: rpc) }
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        rpc = nil
        writeQueue.removeAll()
        writing = false
    }

    /// 按顺序写出一批分块（带响应写，保证顺序与不丢包）。
    func write(_ chunks: [Data]) {
        writeQueue.append(contentsOf: chunks)
        pump()
    }

    private func pump() {
        guard !writing, let p = peripheral, let rpc, !writeQueue.isEmpty else { return }
        writing = true
        p.writeValue(writeQueue.removeFirst(), for: rpc, type: .withResponse)
    }
}

extension BleCentral: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state == .poweredOn { onPoweredOn?() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
            let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
            var manufacturer: [UInt16: Data] = [:]
            if let raw = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, raw.count >= 2 {
                let company = UInt16(raw[raw.startIndex]) | UInt16(raw[raw.startIndex + 1]) << 8
                manufacturer[company] = raw.dropFirst(2)
            }
            let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
            guard let ad = parseAdvertisement(name: name, serviceUuids: uuids, manufacturerData: manufacturer,
                                              connectable: connectable) else { return }
            if ad.busy { busySeen[ad.name] = Date(); return }
            // 扩展广播双胞胎优先（authenticated-app-mvp.md：板子的控制器只接受扩展广播上的连接）。
            if let existing = nearby[ad.name], existing.advert.isExtended, !ad.isExtended,
               existing.lastSeen.timeIntervalSinceNow > -3 {
                return
            }
            nearby[ad.name] = NearbyRobot(advert: ad, rssi: RSSI.intValue, peripheral: peripheral, lastSeen: Date())
            onNearbyChange?()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { peripheral.discoverServices([serviceUUID]) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { onDisconnect?(error ?? LinkError.disconnected) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == self.peripheral else { return }
            rpc = nil
            writeQueue.removeAll()
            writing = false
            onDisconnect?(error)
        }
    }
}

extension BleCentral: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let svc = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
                onDisconnect?(LinkError.notFound); return
            }
            peripheral.discoverCharacteristics([rpcUUID], for: svc)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard let c = service.characteristics?.first(where: { $0.uuid == rpcUUID }) else {
                onDisconnect?(LinkError.notFound); return
            }
            rpc = c
            // 先读一次：需要加密链路，系统会在这里弹出配对框；读到的是机器人的 API 版本（gatt.rs）。
            awaitingVersionRead = true
            peripheral.readValue(for: c)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if awaitingVersionRead {
                awaitingVersionRead = false
                if let error {
                    // 用户取消了配对框或配对失败：回到验证表单（authenticated-app-mvp.md）。
                    onDisconnect?(CBATTError(_nsError: error as NSError).code == .insufficientAuthentication
                        ? LinkError.pairingCancelled : error)
                    return
                }
                peripheral.setNotifyValue(true, for: characteristic)
                return
            }
            if let data = characteristic.value, error == nil { onData?(data) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, characteristic.isNotifying else {
                onDisconnect?(error ?? LinkError.disconnected); return
            }
            let mtu = UInt16(peripheral.maximumWriteValueLength(for: .withoutResponse) + 3)
            onReady?(mtu)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            writing = false
            if error != nil { writeQueue.removeAll(); return }
            pump()
        }
    }
}
