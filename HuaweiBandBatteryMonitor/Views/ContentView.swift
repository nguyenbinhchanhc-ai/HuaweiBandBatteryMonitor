import SwiftUI

struct ContentView: View {
    @ObservedObject var store: BatteryStore
    @ObservedObject var bleManager: BLEBatteryManager

    var body: some View {
        TabView {
            DashboardView(store: store, bleManager: bleManager)
                .tabItem {
                    Label("Tổng quan", systemImage: "battery.100.bolt")
                }

            AnalyticsView(store: store)
                .tabItem {
                    Label("Biểu đồ", systemImage: "chart.xyaxis.line")
                }

            DeviceSettingsView(store: store, bleManager: bleManager)
                .tabItem {
                    Label("Thiết bị", systemImage: "antenna.radiowaves.left.and.right")
                }
        }
    }
}
