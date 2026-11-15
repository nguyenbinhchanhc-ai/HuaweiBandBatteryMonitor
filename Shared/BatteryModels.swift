import Foundation

/// App Group identifier shared between the main app and the Widget extension.
public enum AppConstants {
    public static let appGroupIdentifier = "group.com.bandpulse.battery"
    public static let widgetSnapshotKey = "bandpulse.widget.snapshot.v1"
    public static let selectedDeviceUUIDKey = "bandpulse.ble.device.uuid"
    public static let selectedDeviceNameKey = "bandpulse.ble.device.name"
    public static let usageProfileKey = "bandpulse.usage.profile"
    public static let chargeAlertTargetKey = "bandpulse.alert.chargeTarget"
    public static let lowBatteryAlertKey = "bandpulse.alert.lowBattery"
    public static let backgroundTaskIdentifier = "com.bandpulse.battery.refresh"
}

/// Usage profile presets calibrated against Huawei Band 11 official endurance benchmarks.
public enum UsageProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case light
    case typical
    case alwaysOnDisplay

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .light: return "Tiết kiệm (~14 ngày)"
        case .typical: return "Thường ngày (~8 ngày)"
        case .alwaysOnDisplay: return "Bật AOD (~3 ngày)"
        }
    }

    public var shortName: String {
        switch self {
        case .light: return "Tiết kiệm"
        case .typical: return "Thường"
        case .alwaysOnDisplay: return "AOD"
        }
    }

    /// Prior baseline drain rate in percentage points per hour.
    public var baselineDrainPerHour: Double {
        switch self {
        case .light: return 100.0 / (14.0 * 24.0)
        case .typical: return 100.0 / (8.0 * 24.0)
        case .alwaysOnDisplay: return 100.0 / (3.0 * 24.0)
        }
    }
}

/// Active battery session mode.
public enum SessionType: String, Codable, Sendable {
    case charging
    case discharging

    public var displayName: String {
        switch self {
        case .charging: return "Đang sạc"
        case .discharging: return "Đang sử dụng"
        }
    }
}

/// Origin of a recorded battery reading.
public enum SampleSource: String, Codable, Sendable {
    case bleNotify
    case bleRead
    case manual

    public var label: String {
        switch self {
        case .bleNotify: return "BLE Notify"
        case .bleRead: return "BLE Read"
        case .manual: return "Thủ công"
        }
    }
}

/// Confidence level for battery life and charge duration predictions.
public enum PredictionConfidence: String, Codable, Sendable {
    case low
    case medium
    case high

    public var displayName: String {
        switch self {
        case .low: return "Ước tính sơ bộ"
        case .medium: return "Độ tin cậy khá"
        case .high: return "Độ tin cậy cao"
        }
    }
}

/// Pure value representation of a battery reading sample.
public struct BatterySampleRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: Int
    public let source: SampleSource
    public let sessionID: UUID?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        level: Int,
        source: SampleSource,
        sessionID: UUID? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = min(100, max(0, level))
        self.source = source
        self.sessionID = sessionID
    }
}

/// Pure value representation of a charging or discharging cycle.
public struct BatterySessionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let type: SessionType
    public let startTime: Date
    public var endTime: Date?
    public let startLevel: Int
    public var endLevel: Int
    public var isActive: Bool
    public let usageProfile: UsageProfile

    public init(
        id: UUID = UUID(),
        type: SessionType,
        startTime: Date,
        endTime: Date? = nil,
        startLevel: Int,
        endLevel: Int,
        isActive: Bool = true,
        usageProfile: UsageProfile = .typical
    ) {
        self.id = id
        self.type = type
        self.startTime = startTime
        self.endTime = endTime
        self.startLevel = min(100, max(0, startLevel))
        self.endLevel = min(100, max(0, endLevel))
        self.isActive = isActive
        self.usageProfile = usageProfile
    }

    public func duration(until referenceDate: Date = Date()) -> TimeInterval {
        let end = endTime ?? referenceDate
        return max(0, end.timeIntervalSince(startTime))
    }

    public var levelDelta: Int {
        endLevel - startLevel
    }
}

/// Forecast output while the band is charging.
public struct ChargeEstimate: Equatable, Sendable {
    public let currentLevel: Int
    public let minutesToFull: Double
    public let estimatedFullDate: Date
    public let ratePerMinute: Double
    public let elapsedMinutes: Double
    public let confidence: PredictionConfidence
}

/// Forecast output while the band is discharging.
public struct DischargeEstimate: Equatable, Sendable {
    public let currentLevel: Int
    public let remainingHours: Double
    public let estimatedEmptyDate: Date
    public let drainPerHour: Double
    public let drainPerDay: Double
    public let estimatedFullCycleDays: Double
    public let confidence: PredictionConfidence
}

/// Lightweight snapshot serialized to App Group defaults for WidgetKit.
public struct WidgetBatterySnapshot: Codable, Equatable, Sendable {
    public let deviceName: String
    public let level: Int
    public let sessionType: SessionType
    public let updatedAt: Date
    public let etaSummary: String
    public let rateSummary: String
    public let isConnected: Bool

    public init(
        deviceName: String,
        level: Int,
        sessionType: SessionType,
        updatedAt: Date,
        etaSummary: String,
        rateSummary: String,
        isConnected: Bool
    ) {
        self.deviceName = deviceName
        self.level = level
        self.sessionType = sessionType
        self.updatedAt = updatedAt
        self.etaSummary = etaSummary
        self.rateSummary = rateSummary
        self.isConnected = isConnected
    }
}

/// Safe UserDefaults store for sharing widget snapshots across App Group boundaries.
public enum SharedSnapshotStore {
    public static func save(_ snapshot: WidgetBatterySnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        if let groupDefaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier) {
            groupDefaults.set(data, forKey: AppConstants.widgetSnapshotKey)
        }
        UserDefaults.standard.set(data, forKey: AppConstants.widgetSnapshotKey)
    }

    public static func load() -> WidgetBatterySnapshot? {
        let data = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.data(forKey: AppConstants.widgetSnapshotKey)
            ?? UserDefaults.standard.data(forKey: AppConstants.widgetSnapshotKey)
        guard let data else { return nil }
        return try? JSONDecoder().decode(WidgetBatterySnapshot.self, from: data)
    }
}

/// Shared Vietnamese duration formatter used across views, widgets, and tests.
public enum DurationFormatter {
    public static func formatRemainingHours(_ hours: Double) -> String {
        let safeHours = max(0, hours)
        let totalMinutes = Int((safeHours * 60).rounded())
        let days = totalMinutes / (24 * 60)
        let remHours = (totalMinutes % (24 * 60)) / 60
        let mins = totalMinutes % 60

        if days > 0 {
            return "\(days) ngày \(remHours) giờ"
        }
        if remHours > 0 {
            return "\(remHours) giờ \(mins) phút"
        }
        return "\(mins) phút"
    }

    public static func formatMinutes(_ minutes: Double) -> String {
        let rounded = max(0, Int(minutes.rounded()))
        let hours = rounded / 60
        let mins = rounded % 60
        if hours > 0 {
            return "\(hours) giờ \(mins) phút"
        }
        return "\(mins) phút"
    }
}
