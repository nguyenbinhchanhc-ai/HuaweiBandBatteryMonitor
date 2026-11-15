import SwiftUI

struct DeviceSettingsView: View {
    @ObservedObject var store: BatteryStore
    @ObservedObject var bleManager: BLEBatteryManager

    @State private var showingResetConfirm = false
    @State private var exportedFileURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("Thiết bị BLE (0x180F + Toàn bộ GATT)") {
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

                    Toggle("Đọc nhịp tim realtime (0x180D)", isOn: $bleManager.enableHeartRateStream)

                    NavigationLink {
                        GATTInspectorView(bleManager: bleManager)
                    } label: {
                        HStack {
                            Label("GATT Live Inspector", systemImage: "waveform.and.magnifyingglass")
                            Spacer()
                            Text("\(bleManager.gattServices.count) dịch vụ")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !bleManager.deviceInfoFields.isEmpty {
                    Section("Thông tin phần cứng (0x180A)") {
                        ForEach(bleManager.deviceInfoFields.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            HStack {
                                Text(key)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(value)
                                    .font(.subheadline.monospaced())
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

                Section {
                    Picker("Mốc dự phòng ban đầu", selection: $store.usageProfile) {
                        ForEach(UsageProfile.allCases) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                } header: {
                    Text("Tham chiếu khởi tạo")
                } footer: {
                    Text("Chỉ dùng trong thời gian ngắn khi mới cài app chưa đo được biến thiên 1% qua BLE. Ngay khi có từ 2 mốc pin khác nhau, app tính hoàn toàn bằng dữ liệu thực tế.")
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

                Section("Giới hạn phần cứng & Bảo toàn kết nối") {
                    Text("• Chip nguồn Huawei Band 11 không phát trực tiếp cảm biến mA/mV/nhiệt độ pin qua BLE; ứng dụng tính dòng sạc/xả quy đổi chính xác từ tốc độ biến thiên % thực tế trên cell 300 mAh.\n• Kênh đọc thụ động trên 0x180F & 0x180D hoạt động song song với Huawei Health và không ghi lệnh lên kênh độc quyền 0xFE86 để tránh mất kết nối đồng bộ.\n• Làm mới SideStore định kỳ 7 ngày qua StosVPN và không vuốt tắt app để CoreBluetooth chạy nền liên tục.")
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

/// Live GATT explorer showing every service, characteristic, decoded value, and raw hex payload exposed on iOS.
struct GATTInspectorView: View {
    @ObservedObject var bleManager: BLEBatteryManager

    var body: some View {
        List {
            if bleManager.gattServices.isEmpty {
                ContentUnavailableView(
                    "Chưa có dịch vụ GATT",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("Hãy kết nối Band 11 để khám phá toàn bộ các dịch vụ BLE mà iOS cho phép đọc.")
                )
            } else {
                ForEach(bleManager.gattServices) { service in
                    Section(service.title) {
                        ForEach(service.characteristics) { char in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(char.name)
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text(char.propertiesDescription)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Text("Giá trị: \(char.decodedSummary)")
                                    .font(.caption)
                                    .foregroundStyle(.cyan)
                                Text("Hex: \(char.hexValue)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 10) {
                                    if char.canRead {
                                        Button("Read") {
                                            bleManager.readCharacteristic(id: char.id)
                                        }
                                        .font(.caption.bold())
                                        .buttonStyle(.bordered)
                                    }
                                    if char.canNotify {
                                        Button(char.isNotifying ? "Tắt Notify" : "Bật Notify") {
                                            bleManager.toggleNotify(forCharacteristicID: char.id)
                                        }
                                        .font(.caption.bold())
                                        .buttonStyle(.borderedProminent)
                                        .tint(char.isNotifying ? .green : .blue)
                                    }
                                }
                                .padding(.top, 2)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .navigationTitle("GATT Live Inspector")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Làm mới") {
                    bleManager.refreshBatteryNow()
                }
            }
        }
    }
}
