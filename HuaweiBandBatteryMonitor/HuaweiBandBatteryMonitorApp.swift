import SwiftUI

@main
struct HuaweiBandBatteryMonitorApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: BatteryStore
    @StateObject private var bleManager: BLEBatteryManager

    init() {
        let batteryStore = BatteryStore()
        let ble = BLEBatteryManager()

        ble.onBatteryReading = { level, source, name in
            Task { @MainActor in
                batteryStore.recordReading(
                    level: level,
                    source: source,
                    deviceName: name,
                    isConnected: true
                )
            }
        }

        ble.onConnectionChanged = { name, connected in
            Task { @MainActor in
                batteryStore.updateDeviceMetadata(name: name, isConnected: connected)
            }
        }

        BackgroundRefreshManager.register(bleManager: ble, store: batteryStore)

        _store = StateObject(wrappedValue: batteryStore)
        _bleManager = StateObject(wrappedValue: ble)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, bleManager: bleManager)
                .onAppear {
                    NotificationManager.shared.requestAuthorization()
                    bleManager.connectToSavedOrSystemBand()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                bleManager.refreshBatteryNow()
            case .background:
                BackgroundRefreshManager.scheduleNextRefresh()
            default:
                break
            }
        }
    }
}
