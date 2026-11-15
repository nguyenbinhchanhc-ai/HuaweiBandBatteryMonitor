import Foundation

/// App Group identifier and UserDefaults keys shared between the app and Widget extension.
public enum AppConstants {
    public static let appGroupIdentifier = "group.com.bandpulse.battery"
    public static let widgetSnapshotKey = "bandpulse.widget.snapshot.v1"
    public static let selectedDeviceUUIDKey = "bandpulse.ble.device.uuid"
    public static let selectedDeviceNameKey = "bandpulse.ble.device.name"
    public static let usageProfileKey = "bandpulse.usage.profile"
    public static let chargeAlertTargetKey = "bandpulse.alert.chargeTarget"
    public static let lowBatteryAlertKey = "bandpulse.alert.lowBattery"
    public static let readHeartRateKey = "bandpulse.ble.readHeartRate"
    public static let backgroundTaskIdentifier = "com.bandpulse.battery.refresh"
}

/// Physical battery specification for Huawei Band 11 used to derive effective charge/discharge current (mA).
public enum BatteryHardwareSpec {
    public static let capacitymAh: Double = 300.0
    public static let nominalVoltage: Double = 3.85

    /// Converts a percentage rate per hour (%/h) into effective current in milliamperes (mA).
    public static func effectiveCurrentmA(percentPerHour: Double) -> Double {
        (percentPerHour / 100.0) * capacitymAh
    }

    /// Converts effective current in mA to approximate power in milliwatts (mW).
    public static func effectivePowermW(currentmA: Double) -> Double {
        currentmA * nominalVoltage
    }
}

/// Optional initial baseline used ONLY before the first real 1% change is observed via Bluetooth.
public enum UsageProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case light
    case typical
    case alwaysOnDisplay

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .light: return "Nhẹ (~14 ngày)"
        case .typical: return "Thường (~8 ngày)"
        case .alwaysOnDisplay: return "AOD (~3 ngày)"
        }
    }

    public var shortName: String {
        switch self {
        case .light: return "Nhẹ"
        case .typical: return "Thường"
        case .alwaysOnDisplay: return "AOD"
        }
    }

    /// Prior drain rate in %/hour used strictly before any real BLE slope is measured.
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

/// Confidence level based on real Bluetooth sample density rather than static presets.
public enum PredictionConfidence: String, Codable, Sendable {
    case awaitingDelta
    case measuring
    case realTimeHigh

    public var displayName: String {
        switch self {
        case .awaitingDelta: return "Chờ biến thiên 1%"
        case .measuring: return "Đang đo thực tế"
        case .realTimeHigh: return "Realtime chính xác"
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

/// Real-time forecast output while the band is charging.
public struct ChargeEstimate: Equatable, Sendable {
    public let currentLevel: Int
    public let minutesToFull: Double
    public let estimatedFullDate: Date
    /// Blended recent charge rate (%/min).
    public let ratePerMinute: Double
    /// Instantaneous rate from the latest consecutive percentage jump (%/min).
    public let instantRatePerMinute: Double
    /// Effective charging current derived from 300 mAh capacity (+mA).
    public let effectiveCurrentmA: Double
    /// Instantaneous charging current from the most recent +1% interval (+mA).
    public let instantCurrentmA: Double
    public let elapsedMinutes: Double
    public let confidence: PredictionConfidence
}

/// Real-time forecast output while the band is discharging.
public struct DischargeEstimate: Equatable, Sendable {
    public let currentLevel: Int
    public let remainingHours: Double
    public let estimatedEmptyDate: Date
    /// Regression / sliding-window drain rate (%/hour).
    public let drainPerHour: Double
    public let drainPerDay: Double
    /// Instantaneous drain rate from the most recent consecutive percentage drop (%/hour).
    public let instantDrainPerHour: Double
    /// Effective average discharge current derived from 300 mAh capacity (-mA, returned as positive magnitude).
    public let effectiveCurrentmA: Double
    /// Instantaneous discharge current from the latest drop interval (mA).
    public let instantCurrentmA: Double
    public let estimatedFullCycleDays: Double
    public let confidence: PredictionConfidence
    public let isUsingFallbackPrior: Bool
}

/// Live GATT characteristic inspection snapshot for debugging all readable and writable BLE channels.
public struct GATTCharacteristicSnapshot: Identifiable, Equatable, Sendable {
    public let id: String
    public let uuid: String
    public let name: String
    public let propertiesDescription: String
    public let hexValue: String
    public let decodedSummary: String
    public let isNotifying: Bool
    public let canRead: Bool
    public let canNotify: Bool
    public let canWrite: Bool
    public let updatedAt: Date?

    public init(
        id: String,
        uuid: String,
        name: String,
        propertiesDescription: String,
        hexValue: String,
        decodedSummary: String,
        isNotifying: Bool,
        canRead: Bool,
        canNotify: Bool,
        canWrite: Bool = false,
        updatedAt: Date?
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.propertiesDescription = propertiesDescription
        self.hexValue = hexValue
        self.decodedSummary = decodedSummary
        self.isNotifying = isNotifying
        self.canRead = canRead
        self.canNotify = canNotify
        self.canWrite = canWrite
        self.updatedAt = updatedAt
    }
}

/// Live GATT service inspection snapshot.
public struct GATTServiceSnapshot: Identifiable, Equatable, Sendable {
    public let id: String
    public let uuid: String
    public let title: String
    public var characteristics: [GATTCharacteristicSnapshot]

    public init(id: String, uuid: String, title: String, characteristics: [GATTCharacteristicSnapshot]) {
        self.id = id
        self.uuid = uuid
        self.title = title
        self.characteristics = characteristics
    }
}

/// Lightweight snapshot serialized to App Group defaults for WidgetKit.
public struct WidgetBatterySnapshot: Codable, Equatable, Sendable {
    public let deviceName: String
    public let level: Int
    public let sessionType: SessionType
    public let updatedAt: Date
    public let etaSummary: String
    public let rateSummary: String
    public let currentSummary: String
    public let isConnected: Bool

    public init(
        deviceName: String,
        level: Int,
        sessionType: SessionType,
        updatedAt: Date,
        etaSummary: String,
        rateSummary: String,
        currentSummary: String = "",
        isConnected: Bool
    ) {
        self.deviceName = deviceName
        self.level = level
        self.sessionType = sessionType
        self.updatedAt = updatedAt
        self.etaSummary = etaSummary
        self.rateSummary = rateSummary
        self.currentSummary = currentSummary
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
