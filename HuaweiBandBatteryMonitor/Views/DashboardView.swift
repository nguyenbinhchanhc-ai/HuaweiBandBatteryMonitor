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
                VStack(spacing: 16) {
                    statusHeader
                    batteryRingCard
                    liveCurrentAndForecastCard
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
            VStack(alignment: .trailing, spacing: 4) {
                if let rssi = bleManager.currentRSSI {
                    Text("\(rssi) dBm")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let bpm = bleManager.liveHeartRateBPM {
                    Label("\(bpm)", systemImage: "heart.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.red)
                } else if bleManager.supportsNotify {
                    Text("Notify")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                }
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
                Text("Cập nhật lúc \(updated.formatted(date: .omitted, time: .shortened)) • \(store.latestSample?.source.label ?? "BLE") • Pin 300 mAh")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var liveCurrentAndForecastCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let charge = store.chargeEstimate {
                HStack {
                    Label("Dòng sạc & Dự báo đầy", systemImage: "bolt.batteryblock.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Spacer()
                    confidenceBadge(charge.confidence)
                }

                if charge.minutesToFull <= 0 {
                    Text("Pin đã đạt 100% — có thể rút sạc")
                        .font(.title3.bold())
                } else {
                    Text("Còn ~\(DurationFormatter.formatMinutes(charge.minutesToFull))")
                        .font(.title2.bold())
                    Text("Dự kiến đầy 100% lúc \(charge.estimatedFullDate.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()
                HStack {
                    metricTile(
                        title: "Dòng nạp (quy đổi)",
                        value: String(format: "+%.0f mA", charge.effectiveCurrentmA),
                        accent: .green
                    )
                    Spacer()
                    metricTile(
                        title: "Tức thời",
                        value: String(format: "+%.0f mA", charge.instantCurrentmA)
                    )
                    Spacer()
                    metricTile(
                        title: "Tốc độ",
                        value: String(format: "+%.2f%%/ph", charge.ratePerMinute)
                    )
                }
                Text("Tính trực tiếp từ biến thiên % BLE trên cell \(Int(BatteryHardwareSpec.capacitymAh)) mAh (~" +
                     String(format: "%.0f mW", BatteryHardwareSpec.effectivePowermW(currentmA: charge.effectiveCurrentmA)) +
                     ").")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let discharge = store.dischargeEstimate {
                HStack {
                    Label("Dòng xả thực tế & Thời lượng", systemImage: "waveform.path.ecg")
                        .font(.headline)
                        .foregroundStyle(.cyan)
                    Spacer()
                    confidenceBadge(discharge.confidence)
                }

                Text("Còn ~\(DurationFormatter.formatRemainingHours(discharge.remainingHours))")
                    .font(.title2.bold())
                Text("Dự kiến hết pin: \(discharge.estimatedEmptyDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()
                HStack {
                    metricTile(
                        title: "Dòng xả TB",
                        value: String(format: "-%.2f mA", discharge.effectiveCurrentmA),
                        accent: .cyan
                    )
                    Spacer()
                    metricTile(
                        title: "Tức thời",
                        value: String(format: "-%.2f mA", discharge.instantCurrentmA)
                    )
                    Spacer()
                    metricTile(
                        title: "Hao pin/ngày",
                        value: String(format: "%.1f%%/ngày", discharge.drainPerDay)
                    )
                }

                if discharge.isUsingFallbackPrior {
                    Text("Đang chờ mẫu % thay đổi đầu tiên qua BLE để thay thế hoàn toàn mốc tham chiếu ban đầu.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text("Hồi quy tuyến tính realtime từ lịch sử BLE (chu kỳ tương đương ~\(String(format: "%.1f", discharge.estimatedFullCycleDays)) ngày / 100%).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Chưa có dữ liệu BLE", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Text("Bấm Đồng bộ ở góc trên để đọc mức pin 0x180F từ HUAWEI Band 11 và bắt đầu đo realtime.")
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
        HStack(spacing: 10) {
            Button {
                let nextType: SessionType = isCharging ? .discharging : .charging
                store.toggleSession(to: nextType)
                bleManager.updateAdaptivePolling(isCharging: nextType == .charging)
            } label: {
                Label(
                    isCharging ? "Đã rút sạc" : "Đánh dấu sạc",
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
                    metricTile(title: "Mốc đầu", value: "\(session.startLevel)% • \(session.startTime.formatted(date: .abbreviated, time: .shortened))")
                    Spacer()
                    metricTile(title: "Đã trôi qua", value: DurationFormatter.formatRemainingHours(session.duration() / 3600.0))
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
                        bleManager.updateAdaptivePolling(isCharging: store.activeSession?.type == .charging)
                        showingManualLogSheet = false
                    }
                }
            }
        }
        .presentationDetents([.height(240)])
    }

    private func confidenceBadge(_ confidence: PredictionConfidence) -> some View {
        let color: Color = switch confidence {
        case .realTimeHigh: .green
        case .measuring: .cyan
        case .awaitingDelta: .orange
        }
        return Text(confidence.displayName)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func metricTile(title: String, value: String, accent: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.bold())
                .foregroundStyle(accent)
        }
    }
}
