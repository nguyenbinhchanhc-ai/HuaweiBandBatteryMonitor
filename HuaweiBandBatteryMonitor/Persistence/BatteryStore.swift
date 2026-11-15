import Foundation
import SwiftData
import WidgetKit

@Model
final class SDBatterySample {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var level: Int
    var sourceRaw: String
    var sessionID: UUID?

    init(record: BatterySampleRecord) {
        self.id = record.id
        self.timestamp = record.timestamp
        self.level = record.level
        self.sourceRaw = record.source.rawValue
        self.sessionID = record.sessionID
    }

    var record: BatterySampleRecord {
        BatterySampleRecord(
            id: id,
            timestamp: timestamp,
            level: level,
            source: SampleSource(rawValue: sourceRaw) ?? .bleRead,
            sessionID: sessionID
        )
    }
}

@Model
final class SDBatterySession {
    @Attribute(.unique) var id: UUID
    var typeRaw: String
    var startTime: Date
    var endTime: Date?
    var startLevel: Int
    var endLevel: Int
    var isActive: Bool
    var usageProfileRaw: String

    init(record: BatterySessionRecord) {
        self.id = record.id
        self.typeRaw = record.type.rawValue
        self.startTime = record.startTime
        self.endTime = record.endTime
        self.startLevel = record.startLevel
        self.endLevel = record.endLevel
        self.isActive = record.isActive
        self.usageProfileRaw = record.usageProfile.rawValue
    }

    func apply(from record: BatterySessionRecord) {
        self.typeRaw = record.type.rawValue
        self.startTime = record.startTime
        self.endTime = record.endTime
        self.startLevel = record.startLevel
        self.endLevel = record.endLevel
        self.isActive = record.isActive
        self.usageProfileRaw = record.usageProfile.rawValue
    }

    var record: BatterySessionRecord {
        BatterySessionRecord(
            id: id,
            type: SessionType(rawValue: typeRaw) ?? .discharging,
            startTime: startTime,
            endTime: endTime,
            startLevel: startLevel,
            endLevel: endLevel,
            isActive: isActive,
            usageProfile: UsageProfile(rawValue: usageProfileRaw) ?? .typical
        )
    }
}

/// Central reactive store managing SwiftData persistence, real-time regression forecasts, and widget sync.
@MainActor
final class BatteryStore: ObservableObject {
    @Published private(set) var samples: [BatterySampleRecord] = []
    @Published private(set) var sessions: [BatterySessionRecord] = []
    @Published private(set) var activeSession: BatterySessionRecord?
    @Published private(set) var chargeEstimate: ChargeEstimate?
    @Published private(set) var dischargeEstimate: DischargeEstimate?
    @Published var usageProfile: UsageProfile {
        didSet {
            UserDefaults.standard.set(usageProfile.rawValue, forKey: AppConstants.usageProfileKey)
            recomputeForecasts(isConnected: lastKnownConnected)
        }
    }
    @Published var chargeAlertTarget: Int {
        didSet {
            UserDefaults.standard.set(chargeAlertTarget, forKey: AppConstants.chargeAlertTargetKey)
        }
    }
    @Published var lowBatteryAlertThreshold: Int {
        didSet {
            UserDefaults.standard.set(lowBatteryAlertThreshold, forKey: AppConstants.lowBatteryAlertKey)
        }
    }

    let container: ModelContainer
    private let context: ModelContext
    private var lastKnownDeviceName: String = "HUAWEI Band 11"
    private var lastKnownConnected: Bool = false

    init(inMemory: Bool = false) {
        let savedProfile = UserDefaults.standard.string(forKey: AppConstants.usageProfileKey)
        self.usageProfile = savedProfile.flatMap(UsageProfile.init(rawValue:)) ?? .typical

        let savedTarget = UserDefaults.standard.integer(forKey: AppConstants.chargeAlertTargetKey)
        self.chargeAlertTarget = savedTarget > 0 ? savedTarget : 100

        let savedLow = UserDefaults.standard.integer(forKey: AppConstants.lowBatteryAlertKey)
        self.lowBatteryAlertThreshold = savedLow > 0 ? savedLow : 15

        self.lastKnownDeviceName = UserDefaults.standard.string(forKey: AppConstants.selectedDeviceNameKey) ?? "HUAWEI Band 11"

        let schema = Schema([SDBatterySample.self, SDBatterySession.self])
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier) {
            let dbURL = groupURL.appendingPathComponent("bandpulse.sqlite")
            config = ModelConfiguration(schema: schema, url: dbURL)
        } else {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        }

        do {
            self.container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            let fallbackConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            do {
                self.container = try ModelContainer(for: schema, configurations: [fallbackConfig])
            } catch {
                fatalError("Không thể khởi tạo SwiftData container: \(error)")
            }
        }
        self.context = ModelContext(container)
        loadFromDatabase()
    }

    var latestSample: BatterySampleRecord? {
        samples.last
    }

    var currentLevel: Int? {
        latestSample?.level ?? activeSession?.endLevel
    }

    func updateDeviceMetadata(name: String?, isConnected: Bool) {
        if let name, !name.isEmpty {
            lastKnownDeviceName = name
        }
        lastKnownConnected = isConnected
        recomputeForecasts(isConnected: isConnected)
    }

    func recordReading(level: Int, source: SampleSource, timestamp: Date = Date(), deviceName: String? = nil, isConnected: Bool = true) {
        if let deviceName, !deviceName.isEmpty {
            lastKnownDeviceName = deviceName
        }
        lastKnownConnected = isConnected

        let result = BatterySessionStateMachine.processReading(
            level: level,
            timestamp: timestamp,
            source: source,
            activeSession: activeSession,
            lastSample: latestSample,
            usageProfile: usageProfile
        )

        persistTransition(result)
        recomputeForecasts(isConnected: isConnected)
        evaluateAlerts(level: level)
    }

    func toggleSession(to targetType: SessionType) {
        let level = currentLevel ?? 50
        let result = BatterySessionStateMachine.toggleSessionType(
            to: targetType,
            currentLevel: level,
            at: Date(),
            activeSession: activeSession,
            usageProfile: usageProfile
        )
        persistTransition(result)
        recomputeForecasts(isConnected: lastKnownConnected)
    }

    func clearHistory() {
        do {
            try context.delete(model: SDBatterySample.self)
            try context.delete(model: SDBatterySession.self)
            try context.save()
        } catch {
            print("Lỗi xóa dữ liệu: \(error)")
        }
        samples = []
        sessions = []
        activeSession = nil
        chargeEstimate = nil
        dischargeEstimate = nil
    }

    func exportCSV() -> String {
        var lines = ["timestamp,level_percent,source,session_id,session_type"]
        let sessionLookup = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.type.rawValue) })
        let iso = ISO8601DateFormatter()
        for sample in samples {
            let typeLabel = sample.sessionID.flatMap { sessionLookup[$0] } ?? ""
            lines.append("\(iso.string(from: sample.timestamp)),\(sample.level),\(sample.source.rawValue),\(sample.sessionID?.uuidString ?? ""),\(typeLabel)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Private Persistence & Forecasting

    private func loadFromDatabase() {
        let sampleDescriptor = FetchDescriptor<SDBatterySample>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let sessionDescriptor = FetchDescriptor<SDBatterySession>(
            sortBy: [SortDescriptor(\.startTime, order: .forward)]
        )

        let sdSamples = (try? context.fetch(sampleDescriptor)) ?? []
        let sdSessions = (try? context.fetch(sessionDescriptor)) ?? []

        self.samples = sdSamples.map(\.record)
        self.sessions = sdSessions.map(\.record)
        self.activeSession = self.sessions.last(where: \.isActive)
        recomputeForecasts(isConnected: lastKnownConnected)
    }

    private func persistTransition(_ result: StateTransitionResult) {
        if let closed = result.closedSession {
            upsertSession(closed)
        }
        upsertSession(result.activeSession)

        if let sample = result.recordedSample {
            let sdSample = SDBatterySample(record: sample)
            context.insert(sdSample)
            samples.append(sample)
        }

        do {
            try context.save()
        } catch {
            print("Lỗi lưu SwiftData: \(error)")
        }
    }

    private func upsertSession(_ record: BatterySessionRecord) {
        let targetID = record.id
        let descriptor = FetchDescriptor<SDBatterySession>(
            predicate: #Predicate { $0.id == targetID }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.apply(from: record)
        } else {
            context.insert(SDBatterySession(record: record))
        }

        if let idx = sessions.firstIndex(where: { $0.id == record.id }) {
            sessions[idx] = record
        } else {
            sessions.append(record)
        }

        if record.isActive {
            activeSession = record
        }
    }

    private func recomputeForecasts(isConnected: Bool) {
        let now = Date()
        let activeSamples: [BatterySampleRecord]
        if let activeID = activeSession?.id {
            activeSamples = samples.filter { $0.sessionID == activeID }
        } else {
            activeSamples = []
        }

        if let activeSession, activeSession.type == .charging {
            let historicalCharges = sessions.filter { $0.type == .charging && !$0.isActive }
            self.chargeEstimate = BatteryPredictor.estimateCharge(
                activeSession: activeSession,
                sessionSamples: activeSamples,
                historicalChargeSessions: historicalCharges,
                now: now
            )
            self.dischargeEstimate = nil
        } else {
            self.chargeEstimate = nil
            let historicalDischarges = sessions.filter { $0.type == .discharging && !$0.isActive }
            if !samples.isEmpty || activeSession != nil {
                self.dischargeEstimate = BatteryPredictor.estimateDischarge(
                    activeSession: activeSession,
                    sessionSamples: activeSamples,
                    historicalDischargeSessions: historicalDischarges,
                    profile: usageProfile,
                    now: now
                )
            } else {
                self.dischargeEstimate = nil
            }
        }

        syncWidgetSnapshot(isConnected: isConnected, now: now)
    }

    private func syncWidgetSnapshot(isConnected: Bool, now: Date) {
        guard let level = currentLevel else { return }
        let mode = activeSession?.type ?? .discharging
        let etaSummary: String
        let rateSummary: String
        let currentSummary: String

        if let charge = chargeEstimate {
            etaSummary = charge.minutesToFull <= 0
                ? "Đã sạc đầy 100%"
                : "Đầy sau ~\(DurationFormatter.formatMinutes(charge.minutesToFull))"
            rateSummary = String(format: "+%.2f%%/phút", charge.ratePerMinute)
            currentSummary = String(format: "+%.0f mA", charge.effectiveCurrentmA)
        } else if let discharge = dischargeEstimate {
            etaSummary = discharge.isUsingFallbackPrior
                ? "Ước tính ~\(DurationFormatter.formatRemainingHours(discharge.remainingHours))"
                : "Còn ~\(DurationFormatter.formatRemainingHours(discharge.remainingHours))"
            rateSummary = String(format: "-%.2f%%/h", discharge.drainPerHour)
            currentSummary = String(format: "-%.2f mA", discharge.effectiveCurrentmA)
        } else {
            etaSummary = "Đang thu thập dữ liệu"
            rateSummary = "--"
            currentSummary = "-- mA"
        }

        let snapshot = WidgetBatterySnapshot(
            deviceName: lastKnownDeviceName,
            level: level,
            sessionType: mode,
            updatedAt: now,
            etaSummary: etaSummary,
            rateSummary: rateSummary,
            currentSummary: currentSummary,
            isConnected: isConnected
        )
        SharedSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func evaluateAlerts(level: Int) {
        guard let session = activeSession else { return }
        if session.type == .charging, level >= chargeAlertTarget {
            NotificationManager.shared.sendChargeTargetAlertIfNeeded(
                sessionID: session.id,
                level: level,
                target: chargeAlertTarget
            )
        } else if session.type == .discharging, level <= lowBatteryAlertThreshold {
            NotificationManager.shared.sendLowBatteryAlertIfNeeded(
                sessionID: session.id,
                level: level
            )
        }
    }
}
