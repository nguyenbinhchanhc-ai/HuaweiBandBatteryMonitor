import SwiftUI
import WidgetKit

struct BatteryWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetBatterySnapshot
}

struct BatteryWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BatteryWidgetEntry {
        BatteryWidgetEntry(
            date: Date(),
            snapshot: WidgetBatterySnapshot(
                deviceName: "HUAWEI Band 11",
                level: 88,
                sessionType: .discharging,
                updatedAt: Date(),
                etaSummary: "Còn ~7 ngày 1 giờ",
                rateSummary: "-12.5%/ngày",
                currentSummary: "-1.56 mA",
                isConnected: true
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (BatteryWidgetEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BatteryWidgetEntry>) -> Void) {
        let entry = loadEntry()
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadEntry() -> BatteryWidgetEntry {
        let snapshot = SharedSnapshotStore.load() ?? WidgetBatterySnapshot(
            deviceName: "HUAWEI Band 11",
            level: 0,
            sessionType: .discharging,
            updatedAt: Date(),
            etaSummary: "Mở app để đồng bộ",
            rateSummary: "--",
            currentSummary: "-- mA",
            isConnected: false
        )
        return BatteryWidgetEntry(date: Date(), snapshot: snapshot)
    }
}

struct BatteryWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BatteryWidgetEntry

    private var accent: Color {
        if entry.snapshot.sessionType == .charging { return .green }
        if entry.snapshot.level <= 20 { return .red }
        return .cyan
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(entry.snapshot.level), in: 0...100) {
                Image(systemName: entry.snapshot.sessionType == .charging ? "bolt.fill" : "applewatch")
            } currentValueLabel: {
                Text("\(entry.snapshot.level)%")
                    .font(.caption.bold())
            }
            .gaugeStyle(.accessoryCircular)

        case .systemMedium:
            HStack(spacing: 16) {
                ringBadge
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.snapshot.deviceName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(entry.snapshot.etaSummary)
                        .font(.subheadline.bold())
                        .foregroundStyle(accent)
                    Text("\(entry.snapshot.currentSummary) • \(entry.snapshot.rateSummary) • \(entry.snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .containerBackground(.fill.tertiary, for: .widget)

        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: entry.snapshot.sessionType == .charging ? "bolt.fill" : "applewatch")
                        .foregroundStyle(accent)
                    Spacer()
                    Text("\(entry.snapshot.level)%")
                        .font(.title2.bold())
                }
                Spacer()
                Text(entry.snapshot.currentSummary.isEmpty ? entry.snapshot.deviceName : entry.snapshot.currentSummary)
                    .font(.caption.bold())
                    .lineLimit(1)
                Text(entry.snapshot.etaSummary)
                    .font(.caption)
                    .foregroundStyle(accent)
                    .lineLimit(2)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }

    private var ringBadge: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.2), lineWidth: 8)
                .frame(width: 68, height: 68)
            Circle()
                .trim(from: 0, to: CGFloat(entry.snapshot.level) / 100.0)
                .stroke(accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 68, height: 68)
            Text("\(entry.snapshot.level)%")
                .font(.headline.bold())
        }
    }
}

@main
struct HuaweiBandBatteryWidget: Widget {
    let kind: String = "HuaweiBandBatteryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BatteryWidgetProvider()) { entry in
            BatteryWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Pin Huawei Band 11")
        .description("Theo dõi % pin, dòng sạc/xả và thời gian dùng dự kiến của Huawei Band 11.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}
