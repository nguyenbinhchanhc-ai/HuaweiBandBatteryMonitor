import SwiftUI

struct DeviceSettingsView: View {
    @ObservedObject var store: BatteryStore
    @ObservedObject var bleManager: BLEBatteryManager

    @State private var showingResetConfirm = false
    @State private var exportedFileURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("Thiết bị BLE (Battery Service 0x180F)") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bleManager.connectedDeviceName ?? "Chưa chọn thiết bị")
                                .font(.headline)
                            Text(bleManager.connectionState.label)
                                .font(.caption)
                                .foregroundStyle(bleManager.connectionState == .connected ? .green : .secondary)
                        }
                        Spacer()
                        Button("Quét lại") {
                            bleManager.startScanning()
                        }
                        .buttonStyle(.bordered)
                    }

                    ForEach(bleManager.discoveredDevices) { device in
                        Button {
                            bleManager.selectDevice(uuid: device.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                        .foregroundStyle(.primary)
                                    Text(device.isSystemConnected ? "Đang kết nối sẵn với iOS" : "RSSI: \(device.rssi) dBm")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if bleManager.connectedDeviceUUID == device.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }

                Section("Thông báo nhắc sạc & Pin yếu") {
                    Stepper("Nhắc rút sạc khi đạt: \(store.chargeAlertTarget)%", value: $store.chargeAlertTarget, in: 70...100, step: 5)
                    Stepper("Cảnh báo pin yếu dưới: \(store.lowBatteryAlertThreshold)%", value: $store.lowBatteryAlertThreshold, in: 5...35, step: 5)
                    Button("Cấp quyền Thông báo") {
                        NotificationManager.shared.requestAuthorization()
                    }
                }

                Section("Dữ liệu & Sao lưu") {
                    if let url = exportedFileURL {
                        ShareLink(item: url) {
                            Label("Chia sẻ file BandPulse_History.csv", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button {
                            prepareCSVExport()
                        } label: {
                            Label("Xuất lịch sử pin ra CSV", systemImage: "doc.text")
                        }
                    }

                    Button(role: .destructive) {
                        showingResetConfirm = true
                    } label: {
                        Label("Xóa toàn bộ lịch sử pin", systemImage: "trash")
                    }
                }

                Section("Mẹo chạy nền khi cài bằng SideStore") {
                    Text("• Giữ app ở chế độ chạy nền (không vuốt tắt app khỏi trình đa nhiệm) để CoreBluetooth State Restoration tự ghi nhận khi pin thay đổi.\n• Làm mới app định kỳ 7 ngày trong SideStore (qua StosVPN) để duy trì chứng chỉ Apple ID miễn phí.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Thiết bị & Cài đặt")
            .confirmationDialog(
                "Xóa toàn bộ mẫu và lịch sử sạc/xả?",
                isPresented: $showingResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Xóa tất cả", role: .destructive) {
                    store.clearHistory()
                }
                Button("Hủy", role: .cancel) {}
            }
        }
    }

    private func prepareCSVExport() {
        let csv = store.exportCSV()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BandPulse_History.csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        exportedFileURL = url
    }
}
