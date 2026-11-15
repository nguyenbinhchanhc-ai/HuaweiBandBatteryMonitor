import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: BatteryStore
    @ObservedObject var bleManager: BLEBatteryManager

    @State private var showingManualLogSheet = false
    @State private var manualLevel: Double = 88

    private var activeLevel: Int {
        store.currentLevel ?? bleManager.lastBatteryLevel ?? 0
    }

    private var hasAnyReading: Bool {
        store.currentLevel != nil || bleManager.lastBatteryLevel != nil
    }

    private var isCharging: Bool {
        store.activeSession?.type == .charging
    }

    private var ringColor: Color {
        if isCharging { return .green }
        if activeLevel <= 20 { return .red }
        if activeLevel <= 40 { return .orange }
        return .cyan
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    statusHeader
                    batteryRingCard
                    forecastCard
                    quickActionsCard
                    sessionMetricsCard
                }
                .padding()
            }
            .navigationTitle("BandPulse")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        bleManager.refreshBatteryNow()
                    } label: {
                        Label("Đồng bộ", systemImage: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showingManualLogSheet) {
                manualLogSheet
            }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(bleManager.connectionState == .connected ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(bleManager.connectedDeviceName ?? "HUAWEI Band 11")
                    .font(.headline)
                Text(bleManager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if bleManager.supportsNotify {
                Text("Notify")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.15))
                    .foregroundStyle(.green)
                    .clipShape(Capsule())
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var batteryRingCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(ringColor.opacity(0.18), lineWidth: 16)
                    .frame(width: 170, height: 170)

                Circle()
                    .trim(from: 0, to: hasAnyReading ? CGFloat(activeLevel) / 100.0 : 0)
                    .stroke(
                        AngularGradient(
                            colors: [ringColor.opacity(0.75), ringColor],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 16, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 170, height: 170)
                    .animation(.easeOut(duration: 0.5), value: activeLevel)

                VStack(spacing: 4) {
                    Image(systemName: isCharging ? "bolt.fill" : "applewatch")
                        .font(.title3)
                        .foregroundStyle(ringColor)
                    Text(hasAnyReading ? "\(activeLevel)%" : "--%")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                    Text(store.activeSession?.type.displayName ?? "Chờ dữ liệu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let updated = store.latestSample?.timestamp ?? bleManager.lastUpdatedAt {
                Text("Cập nhật lúc \(updated.formatted(date: .omitted, time: .shortened)) • \(store.latestSample?.source.label ?? "BLE")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var forecastCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let charge = store.chargeEstimate {
                HStack {
                    Label("Dự báo sạc đầy", systemImage: "bolt.batteryblock.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Spacer()
                    confidenceBadge(charge.confidence)
                }

                if charge.minutesToFull <= 0 {
                    Text("Pin đã đạt 100% — bạn có thể rút sạc.")
                        .font(.title3.bold())
                } else {
                    Text("Còn khoảng \(DurationFormatter.formatMinutes(charge.minutesToFull))")
                        .font(.title2.bold())
                    Text("Dự kiến đầy 100% lúc \(charge.estimatedFullDate.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()
                HStack {
                    metricTile(title: "Tốc độ nạp", value: String(format: "+%.2f%%/phút", charge.ratePerMinute))
                    Spacer()
                    metricTile(title: "Đã sạc", value: DurationFormatter.formatMinutes(charge.elapsedMinutes))
                }
            } else if let discharge = store.dischargeEstimate {
                HStack {
                    Label("Dự báo thời gian dùng", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                        .foregroundStyle(.cyan)
                    Spacer()
                    confidenceBadge(discharge.confidence)
                }

                Text("Còn khoảng \(DurationFormatter.formatRemainingHours(discharge.remainingHours))")
                    .font(.title2.bold())
                Text("Dự kiến hết pin: \(discharge.estimatedEmptyDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()
                HStack {
                    metricTile(title: "Hao pin/giờ", value: String(format: "%.2f%%/h", discharge.drainPerHour))
                    Spacer()
                    metricTile(title: "Hao pin/ngày", value: String(format: "%.1f%%/ngày", discharge.drainPerDay))
                    Spacer()
                    metricTile(title: "Chu kỳ 100%", value: String(format: "%.1f ngày", discharge.estimatedFullCycleDays))
                }
            } else {
                Label("Chưa có dữ liệu dự báo", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Text("Bấm Đồng bộ hoặc kết nối HUAWEI Band 11 qua Bluetooth để bắt đầu ghi nhận mức pin.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var quickActionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Điều khiển phiên & Chế độ đeo")
                .font(.headline)

            HStack(spacing: 10) {
                Button {
                    store.toggleSession(to: isCharging ? .discharging : .charging)
                } label: {
                    Label(
                        isCharging ? "Đánh dấu rút sạc" : "Đánh dấu đang sạc",
                        systemImage: isCharging ? "battery.100" : "bolt.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isCharging ? .orange : .green)

                Button {
                    manualLevel = Double(activeLevel > 0 ? activeLevel : 88)
                    showingManualLogSheet = true
                } label: {
                    Label("Nhập %", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
            }

            Picker("Chế độ sử dụng Band 11", selection: $store.usageProfile) {
                ForEach(UsageProfile.allCases) { profile in
                    Text(profile.shortName).tag(profile)
                }
            }
            .pickerStyle(.segmented)

            Text("Mốc tham chiếu: \(store.usageProfile.displayName) — thuật toán sẽ tự hiệu chỉnh theo mức hao thực tế.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var sessionMetricsCard: some View {
        if let session = store.activeSession {
            VStack(alignment: .leading, spacing: 8) {
                Text("Phiên hiện tại (\(session.type.displayName))")
                    .font(.headline)
                HStack {
                    metricTile(title: "Bắt đầu", value: "\(session.startLevel)% • \(session.startTime.formatted(date: .abbreviated, time: .shortened))")
                    Spacer()
                    metricTile(title: "Thời lượng", value: DurationFormatter.formatRemainingHours(session.duration() / 3600.0))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var manualLogSheet: some View {
        NavigationStack {
            Form {
                Section("Ghi nhận mức pin thủ công") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Mức pin hiện tại: \(Int(manualLevel))%")
                            .font(.title3.bold())
                        Slider(value: $manualLevel, in: 0...100, step: 1)
                    }
                }
            }
            .navigationTitle("Nhập % pin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { showingManualLogSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        store.recordReading(
                            level: Int(manualLevel),
                            source: .manual,
                            deviceName: bleManager.connectedDeviceName,
                            isConnected: bleManager.connectionState == .connected
                        )
                        showingManualLogSheet = false
                    }
                }
            }
        }
        .presentationDetents([.height(240)])
    }

    private func confidenceBadge(_ confidence: PredictionConfidence) -> some View {
        let color: Color = switch confidence {
        case .high: .green
        case .medium: .orange
        case .low: .secondary
        }
        return Text(confidence.displayName)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func metricTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.bold())
        }
    }
}
