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

/// CoreBluetooth central manager dedicated to reading standard Battery Service (0x180F / 0x2A19)
/// from Huawei Band 11 alongside the official Huawei Health connection.
final class BLEBatteryManager: NSObject, ObservableObject {
    static let batteryServiceUUID = CBUUID(string: "180F")
    static let batteryLevelCharacteristicUUID = CBUUID(string: "2A19")
    static let heartRateServiceUUID = CBUUID(string: "180D")
    private static let restoreIdentifier = "com.bandpulse.battery.central"

    @Published private(set) var connectionState: BLEConnectionState = .idle
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var connectedDeviceUUID: UUID?
    @Published private(set) var lastBatteryLevel: Int?
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var supportsNotify: Bool = false
    @Published private(set) var discoveredDevices: [DiscoveredBLEDevice] = []
    @Published private(set) var statusMessage: String = "Đang tìm Huawei Band 11..."

    var onBatteryReading: ((Int, SampleSource, String?) -> Void)?
    var onConnectionChanged: ((String?, Bool) -> Void)?

    private var centralManager: CBCentralManager!
    private var activePeripheral: CBPeripheral?
    private var batteryCharacteristic: CBCharacteristic?
    private var pollTimer: Timer?
    private var pendingReadContinuation: CheckedContinuation<Int?, Never>?

    override init() {
        super.init()
        self.centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
        self.connectedDeviceName = UserDefaults.standard.string(forKey: AppConstants.selectedDeviceNameKey)
        if let rawUUID = UserDefaults.standard.string(forKey: AppConstants.selectedDeviceUUIDKey) {
            self.connectedDeviceUUID = UUID(uuidString: rawUUID)
        }
    }

    /// Attempts to attach to an already-connected Huawei Band 11 (or saved UUID) without dropping Huawei Health.
    func connectToSavedOrSystemBand() {
        guard centralManager.state == .poweredOn else {
            updateStateForCentral(centralManager.state)
            return
        }

        // 1. Check already-connected peripherals exposing 0x180F (or 0x180D as secondary hint).
        let systemConnected = centralManager.retrieveConnectedPeripherals(withServices: [
            Self.batteryServiceUUID,
            Self.heartRateServiceUUID
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

        // Prefer Huawei Band if multiple 0x180F peripherals are connected.
        if let huawei = systemConnected.first(where: { ($0.name ?? "").localizedCaseInsensitiveContains("huawei") || ($0.name ?? "").localizedCaseInsensitiveContains("band") }) {
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
        statusMessage = "Đang quét thiết bị BLE..."

        let systemConnected = centralManager.retrieveConnectedPeripherals(withServices: [
            Self.batteryServiceUUID,
            Self.heartRateServiceUUID
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
        } else {
            connectToSavedOrSystemBand()
        }
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

    // MARK: - Private Connection Lifecycle

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
            statusMessage = "Đang đọc Battery Service (0x180F)..."
            peripheral.discoverServices([Self.batteryServiceUUID])
        } else {
            connectionState = .connecting
            statusMessage = "Đang kết nối tới \(resolvedName)..."
            centralManager.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
            ])
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
        pollTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            guard let self,
                  let peripheral = self.activePeripheral,
                  peripheral.state == .connected,
                  let char = self.batteryCharacteristic else { return }
            peripheral.readValue(for: char)
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
        statusMessage = "Đã kết nối \(name). Đang đọc pin..."
        onConnectionChanged?(name, true)
        peripheral.discoverServices([Self.batteryServiceUUID])
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
        statusMessage = "Mất kết nối BLE. Đang chờ Band 11 kết nối lại..."
        onConnectionChanged?(connectedDeviceName, false)

        // Ask CoreBluetooth to auto-reconnect when the band comes back in range.
        central.connect(peripheral, options: nil)
    }
}

// MARK: - CBPeripheralDelegate

extension BLEBatteryManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            statusMessage = "Không tìm thấy Battery Service (0x180F)."
            return
        }
        guard let batteryService = services.first(where: { $0.uuid == Self.batteryServiceUUID }) else {
            statusMessage = "Thiết bị này không mở dịch vụ pin 0x180F."
            return
        }
        peripheral.discoverCharacteristics([Self.batteryLevelCharacteristicUUID], for: batteryService)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }
        guard let levelChar = characteristics.first(where: { $0.uuid == Self.batteryLevelCharacteristicUUID }) else {
            statusMessage = "Không tìm thấy characteristic 0x2A19."
            return
        }

        batteryCharacteristic = levelChar
        supportsNotify = levelChar.properties.contains(.notify)

        if supportsNotify {
            peripheral.setNotifyValue(true, for: levelChar)
        }
        if levelChar.properties.contains(.read) {
            peripheral.readValue(for: levelChar)
        }
        startPollingTimer()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil,
              characteristic.uuid == Self.batteryLevelCharacteristicUUID,
              let data = characteristic.value,
              let firstByte = data.first else {
            return
        }

        let level = min(100, max(0, Int(firstByte)))
        let source: SampleSource = characteristic.isNotifying ? .bleNotify : .bleRead
        let name = peripheral.name ?? connectedDeviceName

        lastBatteryLevel = level
        lastUpdatedAt = Date()
        connectionState = .connected
        statusMessage = "Đã đồng bộ \(level)% qua \(source.label)"

        if let pending = pendingReadContinuation {
            pendingReadContinuation = nil
            pending.resume(returning: level)
        }

        onBatteryReading?(level, source, name)
    }
}
