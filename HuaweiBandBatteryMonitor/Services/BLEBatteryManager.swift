import CoreBluetooth
import Foundation

/// Connection state exposed to the SwiftUI interface.
enum BLEConnectionState: Equatable {
    case idle
    case bluetoothOff
    case unauthorized
    case scanning
    case connecting
    case connected
    case disconnected

    var label: String {
        switch self {
        case .idle: return "Đang khởi tạo"
        case .bluetoothOff: return "Bluetooth đang tắt"
        case .unauthorized: return "Chưa cấp quyền Bluetooth"
        case .scanning: return "Đang tìm thiết bị..."
        case .connecting: return "Đang kết nối..."
        case .connected: return "Đã kết nối BLE"
        case .disconnected: return "Chưa kết nối"
        }
    }
}

/// Discovered BLE device metadata shown in the scanner list.
struct DiscoveredBLEDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let isSystemConnected: Bool
}

/// CoreBluetooth central manager that discovers all readable GATT services on Huawei Band 11,
/// subscribes to Battery Service (0x180F / 0x2A19) + Heart Rate (0x180D / 0x2A37),
/// and uses adaptive polling + State Restoration for maximum iOS background continuity.
final class BLEBatteryManager: NSObject, ObservableObject {
    static let batteryServiceUUID = CBUUID(string: "180F")
    static let batteryLevelUUID = CBUUID(string: "2A19")
    static let batteryPowerStateUUID = CBUUID(string: "2A1A")
    static let batteryLevelStateUUID = CBUUID(string: "2A1B")

    static let heartRateServiceUUID = CBUUID(string: "180D")
    static let heartRateMeasurementUUID = CBUUID(string: "2A37")
    static let deviceInfoServiceUUID = CBUUID(string: "180A")

    private static let restoreIdentifier = "com.bandpulse.battery.central"

    @Published private(set) var connectionState: BLEConnectionState = .idle
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var connectedDeviceUUID: UUID?
    @Published private(set) var lastBatteryLevel: Int?
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var liveHeartRateBPM: Int?
    @Published private(set) var currentRSSI: Int?
    @Published private(set) var supportsNotify: Bool = false
    @Published private(set) var firmwareChargingFlag: Bool?
    @Published private(set) var deviceInfoFields: [String: String] = [:]
    @Published private(set) var gattServices: [GATTServiceSnapshot] = []
    @Published private(set) var protocolLogs: [BLEPacketLogEntry] = []
    @Published private(set) var discoveredDevices: [DiscoveredBLEDevice] = []
    @Published private(set) var statusMessage: String = "Đang tìm Huawei Band 11..."
    @Published var enableHeartRateStream: Bool {
        didSet {
            UserDefaults.standard.set(enableHeartRateStream, forKey: AppConstants.readHeartRateKey)
            applyHeartRateSubscription()
        }
    }

    var onBatteryReading: ((Int, SampleSource, String?) -> Void)?
    var onConnectionChanged: ((String?, Bool) -> Void)?

    private var centralManager: CBCentralManager!
    private var activePeripheral: CBPeripheral?
    private var batteryCharacteristic: CBCharacteristic?
    private var heartRateCharacteristic: CBCharacteristic?
    private var characteristicIndex: [String: CBCharacteristic] = [:]
    private var pollTimer: Timer?
    private var activePollInterval: TimeInterval = 30
    private var pendingReadContinuation: CheckedContinuation<Int?, Never>?

    override init() {
        if UserDefaults.standard.object(forKey: AppConstants.readHeartRateKey) == nil {
            self.enableHeartRateStream = true
        } else {
            self.enableHeartRateStream = UserDefaults.standard.bool(forKey: AppConstants.readHeartRateKey)
        }
        super.init()
        self.centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )
        self.connectedDeviceName = UserDefaults.standard.string(forKey: AppConstants.selectedDeviceNameKey)
        if let rawUUID = UserDefaults.standard.string(forKey: AppConstants.selectedDeviceUUIDKey) {
            self.connectedDeviceUUID = UUID(uuidString: rawUUID)
        }
    }

    /// Dynamically speeds up BLE polling during charging (12s) vs discharging (30s).
    func updateAdaptivePolling(isCharging: Bool) {
        let desired: TimeInterval = isCharging ? 12 : 30
        guard abs(desired - activePollInterval) > 0.1 || pollTimer == nil else { return }
        activePollInterval = desired
        if connectionState == .connected {
            startPollingTimer()
        }
    }

    /// Attaches to an already-connected Huawei Band 11 (or saved UUID) without dropping Huawei Health.
    func connectToSavedOrSystemBand() {
        guard centralManager.state == .poweredOn else {
            updateStateForCentral(centralManager.state)
            return
        }

        let systemConnected = centralManager.retrieveConnectedPeripherals(withServices: [
            Self.batteryServiceUUID,
            Self.heartRateServiceUUID,
            CBUUID(string: "3802"),
            CBUUID(string: "FE86")
        ])

        refreshDiscoveredList(withSystemPeripherals: systemConnected)

        if let savedUUID = connectedDeviceUUID {
            if let match = systemConnected.first(where: { $0.identifier == savedUUID }) {
                connect(to: match)
                return
            }
            let known = centralManager.retrievePeripherals(withIdentifiers: [savedUUID])
            if let match = known.first {
                connect(to: match)
                return
            }
        }

        if let huawei = systemConnected.first(where: {
            let name = $0.name ?? ""
            return name.localizedCaseInsensitiveContains("huawei") || name.localizedCaseInsensitiveContains("band")
        }) {
            connect(to: huawei)
            return
        }

        if let first = systemConnected.first {
            connect(to: first)
            return
        }

        startScanning()
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            updateStateForCentral(centralManager.state)
            return
        }
        connectionState = .scanning
        statusMessage = "Đang quét toàn bộ thiết bị BLE..."

        let systemConnected = centralManager.retrieveConnectedPeripherals(withServices: [
            Self.batteryServiceUUID,
            Self.heartRateServiceUUID,
            CBUUID(string: "3802"),
            CBUUID(string: "FE86")
        ])
        refreshDiscoveredList(withSystemPeripherals: systemConnected)

        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.centralManager.isScanning else { return }
            self.centralManager.stopScan()
            if self.connectionState == .scanning {
                self.connectionState = .disconnected
                self.statusMessage = self.discoveredDevices.isEmpty
                    ? "Không thấy Band 11. Hãy đảm bảo vòng đang bật Bluetooth và gần iPhone."
                    : "Chọn thiết bị từ danh sách để kết nối."
            }
        }
    }

    func selectDevice(uuid: UUID) {
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        if let peripheral = peripherals.first {
            connect(to: peripheral)
            return
        }
        let systemConnected = centralManager.retrieveConnectedPeripherals(withServices: [
            Self.batteryServiceUUID,
            Self.heartRateServiceUUID
        ])
        if let peripheral = systemConnected.first(where: { $0.identifier == uuid }) {
            connect(to: peripheral)
        }
    }

    func refreshBatteryNow() {
        if let peripheral = activePeripheral,
           peripheral.state == .connected,
           let char = batteryCharacteristic {
            peripheral.readValue(for: char)
            peripheral.readRSSI()
        } else {
            connectToSavedOrSystemBand()
        }
    }

    /// Allows the user to manually read any readable characteristic from the GATT Inspector.
    func readCharacteristic(id: String) {
        guard let peripheral = activePeripheral,
              peripheral.state == .connected,
              let char = characteristicIndex[id],
              char.properties.contains(.read) else { return }
        peripheral.readValue(for: char)
    }

    /// Allows the user to toggle passive Notify observation on any notifiable characteristic in GATT Inspector.
    func toggleNotify(forCharacteristicID id: String) {
        guard let peripheral = activePeripheral,
              peripheral.state == .connected,
              let char = characteristicIndex[id],
              char.properties.contains(.notify) || char.properties.contains(.indicate) else { return }
        peripheral.setNotifyValue(!char.isNotifying, for: char)
    }

    /// Subscribes passively to all notifiable characteristics (including 0xFE02, 0xFE06, 0x4A02)
    /// without writing any command bytes, keeping Huawei Health undisturbed.
    func subscribeAllNotifiableCharacteristics() {
        guard let peripheral = activePeripheral,
              peripheral.state == .connected else { return }
        for char in characteristicIndex.values {
            if (char.properties.contains(.notify) || char.properties.contains(.indicate)) && !char.isNotifying {
                peripheral.setNotifyValue(true, for: char)
            }
        }
    }

    /// Sends a user-initiated probe payload to a writable characteristic and logs the TX packet.
    func writeCharacteristic(id: String, data: Data) {
        guard let peripheral = activePeripheral,
              peripheral.state == .connected,
              let char = characteristicIndex[id] else { return }

        let writeType: CBCharacteristicWriteType
        if char.properties.contains(.writeWithoutResponse) {
            writeType = .withoutResponse
        } else if char.properties.contains(.write) {
            writeType = .withResponse
        } else {
            return
        }

        appendPacketLog(direction: .tx, characteristicUUID: char.uuid, data: data)
        peripheral.writeValue(data, for: char, type: writeType)
    }

    func clearProtocolLogs() {
        protocolLogs.removeAll()
    }

    func exportProtocolLogsText() -> String {
        let formatter = ISO8601DateFormatter()
        return protocolLogs.map { entry in
            "[\(formatter.string(from: entry.timestamp))] \(entry.direction.rawValue) \(entry.characteristicUUID) | \(entry.decodedSummary) | HEX: \(entry.rawHex)"
        }.joined(separator: "\n")
    }

    /// Async helper used by BGAppRefreshTask to perform a single BLE battery poll.
    @MainActor
    func performBackgroundPoll() async -> Int? {
        guard centralManager.state == .poweredOn else { return nil }
        if let peripheral = activePeripheral,
           peripheral.state == .connected,
           let char = batteryCharacteristic {
            return await withCheckedContinuation { continuation in
                self.pendingReadContinuation = continuation
                peripheral.readValue(for: char)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    if let pending = self?.pendingReadContinuation {
                        self?.pendingReadContinuation = nil
                        pending.resume(returning: nil)
                    }
                }
            }
        }
        connectToSavedOrSystemBand()
        return nil
    }

    // MARK: - Private Connection & GATT Discovery

    private func connect(to peripheral: CBPeripheral) {
        centralManager.stopScan()
        activePeripheral = peripheral
        peripheral.delegate = self

        let resolvedName = peripheral.name ?? connectedDeviceName ?? "HUAWEI Band 11"
        connectedDeviceName = resolvedName
        connectedDeviceUUID = peripheral.identifier
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: AppConstants.selectedDeviceUUIDKey)
        UserDefaults.standard.set(resolvedName, forKey: AppConstants.selectedDeviceNameKey)

        if peripheral.state == .connected {
            connectionState = .connected
            statusMessage = "Đang khám phá toàn bộ dịch vụ GATT..."
            peripheral.discoverServices(nil)
            peripheral.readRSSI()
        } else {
            connectionState = .connecting
            statusMessage = "Đang kết nối tới \(resolvedName)..."
            centralManager.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                CBConnectPeripheralOptionNotifyOnNotificationKey: true
            ])
        }
    }

    private func applyHeartRateSubscription() {
        guard let peripheral = activePeripheral,
              peripheral.state == .connected,
              let hrChar = heartRateCharacteristic,
              hrChar.properties.contains(.notify) else { return }
        peripheral.setNotifyValue(enableHeartRateStream, for: hrChar)
        if !enableHeartRateStream {
            liveHeartRateBPM = nil
        }
    }

    private func refreshDiscoveredList(withSystemPeripherals peripherals: [CBPeripheral]) {
        for peripheral in peripherals {
            let item = DiscoveredBLEDevice(
                id: peripheral.identifier,
                name: peripheral.name ?? "Thiết bị BLE đã kết nối",
                rssi: 0,
                isSystemConnected: true
            )
            if let idx = discoveredDevices.firstIndex(where: { $0.id == item.id }) {
                discoveredDevices[idx] = item
            } else {
                discoveredDevices.insert(item, at: 0)
            }
        }
    }

    private func startPollingTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: activePollInterval, repeats: true) { [weak self] _ in
            guard let self,
                  let peripheral = self.activePeripheral,
                  peripheral.state == .connected else { return }
            if let char = self.batteryCharacteristic {
                peripheral.readValue(for: char)
            }
            peripheral.readRSSI()
        }
    }

    private func updateStateForCentral(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            connectToSavedOrSystemBand()
        case .poweredOff:
            connectionState = .bluetoothOff
            statusMessage = "Hãy bật Bluetooth trên iPhone."
            onConnectionChanged?(connectedDeviceName, false)
        case .unauthorized:
            connectionState = .unauthorized
            statusMessage = "Hãy cấp quyền Bluetooth cho BandPulse trong Cài đặt iPhone."
            onConnectionChanged?(connectedDeviceName, false)
        default:
            connectionState = .idle
        }
    }

    private func rebuildGATTSnapshot(for peripheral: CBPeripheral) {
        let services = peripheral.services ?? []
        var built: [GATTServiceSnapshot] = []
        characteristicIndex.removeAll()

        for service in services {
            let serviceUUID = service.uuid.uuidString
            let chars = (service.characteristics ?? []).map { char -> GATTCharacteristicSnapshot in
                let charID = "\(serviceUUID)/\(char.uuid.uuidString)"
                characteristicIndex[charID] = char
                let existing = gattServices
                    .flatMap(\.characteristics)
                    .first(where: { $0.id == charID })

                let hex = char.value.map { Self.formatHex($0) } ?? (existing?.hexValue ?? "--")
                let decoded = char.value.map { Self.decodeCharacteristicValue(uuid: char.uuid, data: $0) }
                    ?? (existing?.decodedSummary ?? "Chưa đọc")

                return GATTCharacteristicSnapshot(
                    id: charID,
                    uuid: char.uuid.uuidString,
                    name: Self.friendlyName(for: char.uuid),
                    propertiesDescription: Self.describeProperties(char.properties),
                    hexValue: hex,
                    decodedSummary: decoded,
                    isNotifying: char.isNotifying,
                    canRead: char.properties.contains(.read),
                    canNotify: char.properties.contains(.notify) || char.properties.contains(.indicate),
                    canWrite: char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse),
                    updatedAt: char.value != nil ? Date() : existing?.updatedAt
                )
            }
            built.append(
                GATTServiceSnapshot(
                    id: serviceUUID,
                    uuid: serviceUUID,
                    title: Self.friendlyServiceTitle(for: service.uuid),
                    characteristics: chars
                )
            )
        }
        gattServices = built
    }

    private func appendPacketLog(direction: PacketDirection, characteristicUUID: CBUUID, data: Data) {
        let parsed = HuaweiProtocolDecoder.parseFrame(data)
        let summary = parsed?.summary ?? Self.decodeCharacteristicValue(uuid: characteristicUUID, data: data)
        let entry = BLEPacketLogEntry(
            timestamp: Date(),
            direction: direction,
            characteristicUUID: characteristicUUID.uuidString,
            rawHex: Self.formatHex(data),
            decodedSummary: summary,
            parsedFrame: parsed
        )
        protocolLogs.insert(entry, at: 0)
        if protocolLogs.count > 200 {
            protocolLogs.removeLast(protocolLogs.count - 200)
        }
    }

    // MARK: - GATT Formatting & Decoding Helpers

    private static func formatHex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func describeProperties(_ props: CBCharacteristicProperties) -> String {
        var list: [String] = []
        if props.contains(.read) { list.append("Read") }
        if props.contains(.notify) { list.append("Notify") }
        if props.contains(.indicate) { list.append("Indicate") }
        if props.contains(.write) { list.append("Write") }
        if props.contains(.writeWithoutResponse) { list.append("WriteNoResp") }
        return list.isEmpty ? "None" : list.joined(separator: ", ")
    }

    private static func friendlyServiceTitle(for uuid: CBUUID) -> String {
        switch uuid.uuidString.uppercased() {
        case "180F": return "Battery Service (0x180F)"
        case "180D": return "Heart Rate (0x180D)"
        case "180A": return "Device Information (0x180A)"
        case "FE86": return "Huawei Wear Protocol (0xFE86)"
        case "3802": return "Huawei Accessory Service (0x3802)"
        default: return "Service \(uuid.uuidString)"
        }
    }

    private static func friendlyName(for uuid: CBUUID) -> String {
        switch uuid.uuidString.uppercased() {
        case "2A19": return "Battery Level (0x2A19)"
        case "2A1A": return "Battery Power State (0x2A1A)"
        case "2A1B": return "Battery Level State (0x2A1B)"
        case "2A37": return "Heart Rate Measurement (0x2A37)"
        case "2A38": return "Body Sensor Location (0x2A38)"
        case "2A24": return "Model Number (0x2A24)"
        case "2A25": return "Serial Number (0x2A25)"
        case "2A26": return "Firmware Revision (0x2A26)"
        case "2A27": return "Hardware Revision (0x2A27)"
        case "2A29": return "Manufacturer Name (0x2A29)"
        default: return uuid.uuidString
        }
    }

    private static func decodeCharacteristicValue(uuid: CBUUID, data: Data) -> String {
        switch uuid.uuidString.uppercased() {
        case "2A19":
            guard let pct = data.first else { return "--" }
            return "\(pct)%"
        case "2A37":
            guard let bpm = parseHeartRateBPM(from: data) else { return "--" }
            return "\(bpm) BPM"
        case "2A24", "2A25", "2A26", "2A27", "2A28", "2A29":
            return String(data: data, encoding: .utf8) ?? formatHex(data)
        default:
            if data.count == 1, let val = data.first {
                return "uint8: \(val)"
            }
            if let ascii = String(data: data, encoding: .utf8),
               ascii.allSatisfy({ $0.isASCII && !$0.isNewline }) {
                return ascii
            }
            return formatHex(data)
        }
    }

    private static func parseHeartRateBPM(from data: Data) -> Int? {
        guard data.count >= 2 else { return nil }
        let flags = data[data.startIndex]
        let is16Bit = (flags & 0x01) != 0
        if is16Bit, data.count >= 3 {
            let low = UInt16(data[data.startIndex + 1])
            let high = UInt16(data[data.startIndex + 2]) << 8
            return Int(low | high)
        }
        return Int(data[data.startIndex + 1])
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEBatteryManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateStateForCentral(central.state)
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            activePeripheral = restored
            restored.delegate = self
            connectedDeviceUUID = restored.identifier
            if let name = restored.name {
                connectedDeviceName = name
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        guard let name = advName, !name.isEmpty else { return }

        let item = DiscoveredBLEDevice(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            isSystemConnected: false
        )
        if let idx = discoveredDevices.firstIndex(where: { $0.id == item.id }) {
            discoveredDevices[idx] = item
        } else {
            discoveredDevices.append(item)
        }

        if connectedDeviceUUID == peripheral.identifier ||
            (connectedDeviceUUID == nil && name.localizedCaseInsensitiveContains("huawei band")) {
            connect(to: peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = .connected
        let name = peripheral.name ?? connectedDeviceName ?? "HUAWEI Band 11"
        connectedDeviceName = name
        statusMessage = "Đã kết nối \(name). Đang khám phá dịch vụ BLE..."
        onConnectionChanged?(name, true)
        peripheral.discoverServices(nil)
        peripheral.readRSSI()
        startPollingTimer()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = .disconnected
        statusMessage = "Kết nối thất bại: \(error?.localizedDescription ?? "Không rõ nguyên nhân")"
        onConnectionChanged?(connectedDeviceName, false)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionState = .disconnected
        pollTimer?.invalidate()
        batteryCharacteristic = nil
        heartRateCharacteristic = nil
        liveHeartRateBPM = nil
        currentRSSI = nil
        statusMessage = "Mất kết nối BLE. Đang tự chờ Band 11 nối lại..."
        onConnectionChanged?(connectedDeviceName, false)

        central.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ])
    }
}

// MARK: - CBPeripheralDelegate

extension BLEBatteryManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil {
            currentRSSI = RSSI.intValue
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            statusMessage = "Không thể đọc danh sách dịch vụ BLE."
            return
        }
        rebuildGATTSnapshot(for: peripheral)
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }
        rebuildGATTSnapshot(for: peripheral)

        for char in characteristics {
            switch char.uuid {
            case Self.batteryLevelUUID:
                batteryCharacteristic = char
                supportsNotify = char.properties.contains(.notify)
                if supportsNotify {
                    peripheral.setNotifyValue(true, for: char)
                }
                if char.properties.contains(.read) {
                    peripheral.readValue(for: char)
                }

            case Self.batteryPowerStateUUID, Self.batteryLevelStateUUID:
                if char.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: char)
                }
                if char.properties.contains(.read) {
                    peripheral.readValue(for: char)
                }

            case Self.heartRateMeasurementUUID:
                heartRateCharacteristic = char
                if enableHeartRateStream && char.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: char)
                }

            default:
                // Read standard Device Info (0x180A) and Body Sensor Location passively without touching proprietary write channels.
                if service.uuid == Self.deviceInfoServiceUUID || char.uuid == CBUUID(string: "2A38") {
                    if char.properties.contains(.read) {
                        peripheral.readValue(for: char)
                    }
                }
            }
        }
        startPollingTimer()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        appendPacketLog(direction: .rx, characteristicUUID: characteristic.uuid, data: data)
        rebuildGATTSnapshot(for: peripheral)

        switch characteristic.uuid {
        case Self.batteryLevelUUID:
            guard let firstByte = data.first else { return }
            let level = min(100, max(0, Int(firstByte)))
            let source: SampleSource = characteristic.isNotifying ? .bleNotify : .bleRead
            let name = peripheral.name ?? connectedDeviceName

            lastBatteryLevel = level
            lastUpdatedAt = Date()
            connectionState = .connected
            statusMessage = "Realtime \(level)% • \(source.label)"

            if let pending = pendingReadContinuation {
                pendingReadContinuation = nil
                pending.resume(returning: level)
            }

            onBatteryReading?(level, source, name)

        case Self.batteryPowerStateUUID, Self.batteryLevelStateUUID:
            // Standard BLE Battery Power State (bits 4..5 == 3 means charging).
            if let byte = data.first {
                let chargingBits = (byte >> 4) & 0x03
                if chargingBits == 3 {
                    firmwareChargingFlag = true
                } else if chargingBits == 2 {
                    firmwareChargingFlag = false
                }
            }

        case Self.heartRateMeasurementUUID:
            liveHeartRateBPM = Self.parseHeartRateBPM(from: data)

        default:
            if characteristic.service?.uuid == Self.deviceInfoServiceUUID,
               let text = String(data: data, encoding: .utf8),
               !text.isEmpty {
                deviceInfoFields[Self.friendlyName(for: characteristic.uuid)] = text
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        rebuildGATTSnapshot(for: peripheral)
    }
}
