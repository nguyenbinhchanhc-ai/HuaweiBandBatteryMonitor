import SwiftUI
import UIKit

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

                    NavigationLink {
                        ProtocolLabView(bleManager: bleManager)
                    } label: {
                        HStack {
                            Label("0xFE86 Sniffer & Frame Lab", systemImage: "terminal")
                            Spacer()
                            Text("\(bleManager.protocolLogs.count) gói")
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

/// Interactive sniffer & decoder for Huawei 0x5A Link Protocol frames (CRC16-CCITT + TLV)
/// plus user-initiated hex probe testing.
struct ProtocolLabView: View {
    @ObservedObject var bleManager: BLEBatteryManager

    @State private var selectedTargetID: String = ""
    @State private var serviceHex: String = "01"
    @State private var commandHex: String = "08"
    @State private var rawHexInput: String = ""
    @State private var useRawHexMode: Bool = false
    @State private var copiedFeedback: Bool = false

    private var writableCharacteristics: [GATTCharacteristicSnapshot] {
        bleManager.gattServices
            .flatMap(\.characteristics)
            .filter(\.canWrite)
    }

    var body: some View {
        List {
            Section {
                Button {
                    bleManager.subscribeAllNotifiableCharacteristics()
                } label: {
                    Label("Nghe thụ động toàn bộ kênh Notify (0xFE02, 0xFE06, 0x4A02...)", systemImage: "ear.badge.waveform")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)

                Text("Bật Notify thụ động hoàn toàn an toàn, không ghi lệnh nên giữ nguyên kết nối với Huawei Health. Sau khi bấm, hãy sang Huawei Health kéo đồng bộ rồi quay lại xem Log bên dưới.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("1. Nghe thụ động (An toàn 100%)")
            }

            Section {
                if writableCharacteristics.isEmpty {
                    Text("Chưa thấy đặc tính Write nào. Hãy kết nối Band 11 trước.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Kênh gửi (Write)", selection: $selectedTargetID) {
                        ForEach(writableCharacteristics) { char in
                            Text("\(char.name) (\(char.propertiesDescription))").tag(char.id)
                        }
                    }
                    .onAppear {
                        if selectedTargetID.isEmpty {
                            selectedTargetID = writableCharacteristics.first(where: { $0.uuid.uppercased() == "FE01" })?.id
                                ?? writableCharacteristics.first?.id
                                ?? ""
                        }
                    }

                    Toggle("Nhập Raw Hex thủ công", isOn: $useRawHexMode)

                    if useRawHexMode {
                        TextField("VD: 5A 00 03 00 01 08 61 6C", text: $rawHexInput)
                            .font(.caption.monospaced())
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    } else {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("ServiceID (Hex)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextField("01", text: $serviceHex)
                                    .font(.subheadline.monospaced())
                                    .textInputAutocapitalization(.characters)
                            }
                            VStack(alignment: .leading) {
                                Text("CommandID (Hex)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextField("08", text: $commandHex)
                                    .font(.subheadline.monospaced())
                                    .textInputAutocapitalization(.characters)
                            }
                        }

                        if let preview = buildProbeData() {
                            Text("Khung 0x5A + CRC16: \(preview.map { String(format: "%02X", $0) }.joined(separator: " "))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.cyan)
                        }
                    }

                    Button {
                        if let data = buildProbeData(), !selectedTargetID.isEmpty {
                            bleManager.writeCharacteristic(id: selectedTargetID, data: data)
                        }
                    } label: {
                        Label("Gửi gói thăm dò", systemImage: "paperplane.fill")
                    }
                    .disabled(buildProbeData() == nil || selectedTargetID.isEmpty)

                    Text("Cảnh báo: Gửi gói Write lên 0xFE01 trong lúc Huawei Health đang chạy có thể khiến Band từ chối hoặc tạm ngắt phiên Huawei Health (chỉ cần mở lại Huawei Health để nối lại).")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("2. Thử gửi gói khung 0x5A (Nâng cao)")
            }

            Section {
                HStack {
                    Button {
                        UIPasteboard.general.string = bleManager.exportProtocolLogsText()
                        copiedFeedback = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedFeedback = false
                        }
                    } label: {
                        Label(copiedFeedback ? "Đã copy!" : "Copy toàn bộ Log", systemImage: "doc.on.doc")
                    }
                    .disabled(bleManager.protocolLogs.isEmpty)

                    Spacer()

                    Button(role: .destructive) {
                        bleManager.clearProtocolLogs()
                    } label: {
                        Text("Xóa Log")
                    }
                    .disabled(bleManager.protocolLogs.isEmpty)
                }

                if bleManager.protocolLogs.isEmpty {
                    Text("Chưa có gói tin nào. Hãy bật Notify và đồng bộ thử.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bleManager.protocolLogs) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.direction.rawValue)
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(entry.direction == .rx ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                                    .foregroundStyle(entry.direction == .rx ? .green : .orange)
                                    .clipShape(Capsule())
                                Text(entry.characteristicUUID)
                                    .font(.caption.bold())
                                Spacer()
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.decodedSummary)
                                .font(.caption)
                                .foregroundStyle(.cyan)
                            Text(entry.rawHex)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 3)
                    }
                }
            } header: {
                Text("3. Nhật ký gói tin RX/TX (\(bleManager.protocolLogs.count))")
            }
        }
        .navigationTitle("0xFE86 Protocol Lab")
    }

    private func buildProbeData() -> Data? {
        if useRawHexMode {
            return HuaweiProtocolDecoder.dataFromHexString(rawHexInput)
        }
        guard let svc = UInt8(serviceHex.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16),
              let cmd = UInt8(commandHex.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else {
            return nil
        }
        return HuaweiProtocolDecoder.buildFrame(serviceID: svc, commandID: cmd)
    }
}
