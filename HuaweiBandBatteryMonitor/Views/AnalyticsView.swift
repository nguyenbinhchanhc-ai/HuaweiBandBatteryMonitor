import Charts
import SwiftUI

enum ChartRange: String, CaseIterable, Identifiable {
    case day = "24 giờ"
    case week = "7 ngày"
    case month = "30 ngày"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        }
    }
}

struct ForecastPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: Double
    let series: String
}

struct AnalyticsView: View {
    @ObservedObject var store: BatteryStore
    @State private var selectedRange: ChartRange = .week

    private var filteredSamples: [BatterySampleRecord] {
        let cutoff = Date().addingTimeInterval(-selectedRange.seconds)
        return store.samples.filter { $0.timestamp >= cutoff }
    }

    private var forecastLinePoints: [ForecastPoint] {
        guard let latest = store.latestSample else { return [] }
        var points = [
            ForecastPoint(timestamp: latest.timestamp, level: Double(latest.level), series: "Dự báo")
        ]
        if let charge = store.chargeEstimate, charge.minutesToFull > 0 {
            points.append(
                ForecastPoint(timestamp: charge.estimatedFullDate, level: 100, series: "Dự báo")
            )
        } else if let discharge = store.dischargeEstimate, discharge.remainingHours > 0 {
            points.append(
                ForecastPoint(timestamp: discharge.estimatedEmptyDate, level: 0, series: "Dự báo")
            )
        }
        return points.count > 1 ? points : []
    }

    private var completedCharges: [BatterySessionRecord] {
        store.sessions.filter { $0.type == .charging }.reversed()
    }

    private var completedDischarges: [BatterySessionRecord] {
        store.sessions.filter { $0.type == .discharging }.reversed()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Khoảng thời gian", selection: $selectedRange) {
                            ForEach(ChartRange.allCases) { range in
                                Text(range.rawValue).tag(range)
                            }
                        }
                        .pickerStyle(.segmented)

                        if filteredSamples.isEmpty {
                            ContentUnavailableView(
                                "Chưa có mẫu dữ liệu",
                                systemImage: "chart.xyaxis.line",
                                description: Text("Biểu đồ sẽ tự cập nhật khi Band 11 gửi dữ liệu pin.")
                            )
                            .frame(height: 200)
                        } else {
                            Chart {
                                ForEach(filteredSamples) { sample in
                                    LineMark(
                                        x: .value("Thời gian", sample.timestamp),
                                        y: .value("Pin (%)", sample.level),
                                        series: .value("Chuỗi", "Thực tế")
                                    )
                                    .foregroundStyle(.cyan)
                                    .interpolationMethod(.monotone)

                                    AreaMark(
                                        x: .value("Thời gian", sample.timestamp),
                                        y: .value("Pin (%)", sample.level)
                                    )
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.cyan.opacity(0.28), .clear],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                }

                                ForEach(forecastLinePoints) { point in
                                    LineMark(
                                        x: .value("Thời gian", point.timestamp),
                                        y: .value("Pin (%)", point.level),
                                        series: .value("Chuỗi", point.series)
                                    )
                                    .foregroundStyle(.orange)
                                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 5]))
                                }
                            }
                            .chartYScale(domain: 0...100)
                            .frame(height: 220)
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("Biểu đồ pin & Đường dự báo")
                }

                Section("Chu kỳ sạc (\(completedCharges.count))") {
                    if completedCharges.isEmpty {
                        Text("Chưa ghi nhận lần sạc nào.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(completedCharges) { session in
                            sessionRow(session)
                        }
                    }
                }

                Section("Chu kỳ xả (\(completedDischarges.count))") {
                    if completedDischarges.isEmpty {
                        Text("Chưa ghi nhận chu kỳ xả nào.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(completedDischarges) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
            .navigationTitle("Lịch sử & Phân tích")
        }
    }

    private func sessionRow(_ session: BatterySessionRecord) -> some View {
        let durationSeconds = session.duration()
        let delta = session.levelDelta
        let isCharge = session.type == .charging
        let durationText = isCharge
            ? DurationFormatter.formatMinutes(durationSeconds / 60.0)
            : DurationFormatter.formatRemainingHours(durationSeconds / 3600.0)

        return HStack {
            Image(systemName: isCharge ? "bolt.fill" : "battery.75")
                .foregroundStyle(isCharge ? .green : .cyan)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("\(session.startLevel)% → \(session.endLevel)%")
                        .font(.subheadline.bold())
                    Text(delta >= 0 ? "(+\(delta)%)" : "(\(delta)%)")
                        .font(.caption.bold())
                        .foregroundStyle(isCharge ? .green : .orange)
                    if session.isActive {
                        Text("Đang diễn ra")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text("\(session.startTime.formatted(date: .abbreviated, time: .shortened)) • Thời lượng: \(durationText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
