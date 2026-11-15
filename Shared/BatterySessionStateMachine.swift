import Foundation

/// Outcome of processing a new battery percentage observation.
public struct StateTransitionResult: Equatable, Sendable {
    public let recordedSample: BatterySampleRecord?
    public let closedSession: BatterySessionRecord?
    public let activeSession: BatterySessionRecord
}

/// Deterministic state machine that splits raw 0x2A19 percentage readings into charging and discharging sessions.
/// Never drops a percentage change so real-time slope and effective mA calculations remain exact.
public enum BatterySessionStateMachine {
    /// Minimum time interval before logging an identical unchanged percentage within the same session.
    public static let defaultDeduplicationInterval: TimeInterval = 5 * 60

    /// Evaluates a newly observed battery level against the current session and previous sample.
    public static func processReading(
        level: Int,
        timestamp: Date,
        source: SampleSource,
        activeSession: BatterySessionRecord?,
        lastSample: BatterySampleRecord?,
        usageProfile: UsageProfile,
        deduplicationInterval: TimeInterval = defaultDeduplicationInterval
    ) -> StateTransitionResult {
        let clampedLevel = min(100, max(0, level))

        guard var currentSession = activeSession else {
            let newSession = BatterySessionRecord(
                type: .discharging,
                startTime: timestamp,
                startLevel: clampedLevel,
                endLevel: clampedLevel,
                isActive: true,
                usageProfile: usageProfile
            )
            let sample = BatterySampleRecord(
                timestamp: timestamp,
                level: clampedLevel,
                source: source,
                sessionID: newSession.id
            )
            return StateTransitionResult(
                recordedSample: sample,
                closedSession: nil,
                activeSession: newSession
            )
        }

        let previousLevel = lastSample?.level ?? currentSession.endLevel
        let delta = clampedLevel - previousLevel

        // Transition: Discharging -> Charging when percentage rises.
        if currentSession.type == .discharging && delta > 0 {
            let transitionTime = lastSample?.timestamp ?? timestamp
            let anchorLevel = previousLevel
            currentSession.endTime = transitionTime
            currentSession.endLevel = anchorLevel
            currentSession.isActive = false

            let newChargeSession = BatterySessionRecord(
                type: .charging,
                startTime: transitionTime,
                startLevel: anchorLevel,
                endLevel: clampedLevel,
                isActive: true,
                usageProfile: usageProfile
            )
            let sample = BatterySampleRecord(
                timestamp: timestamp,
                level: clampedLevel,
                source: source,
                sessionID: newChargeSession.id
            )
            return StateTransitionResult(
                recordedSample: sample,
                closedSession: currentSession,
                activeSession: newChargeSession
            )
        }

        // Transition: Charging -> Discharging when percentage drops.
        if currentSession.type == .charging && delta < 0 {
            let transitionTime = lastSample?.timestamp ?? timestamp
            let peakLevel = previousLevel
            currentSession.endTime = transitionTime
            currentSession.endLevel = peakLevel
            currentSession.isActive = false

            let newDischargeSession = BatterySessionRecord(
                type: .discharging,
                startTime: transitionTime,
                startLevel: peakLevel,
                endLevel: clampedLevel,
                isActive: true,
                usageProfile: usageProfile
            )
            let sample = BatterySampleRecord(
                timestamp: timestamp,
                level: clampedLevel,
                source: source,
                sessionID: newDischargeSession.id
            )
            return StateTransitionResult(
                recordedSample: sample,
                closedSession: currentSession,
                activeSession: newDischargeSession
            )
        }

        // Same session: always record whenever level changed (delta != 0),
        // and only deduplicate identical flat readings inside the interval.
        currentSession.endLevel = clampedLevel
        let shouldDeduplicate: Bool
        if let lastSample,
           source != .manual,
           delta == 0,
           timestamp.timeIntervalSince(lastSample.timestamp) < deduplicationInterval {
            shouldDeduplicate = true
        } else {
            shouldDeduplicate = false
        }

        let sample = shouldDeduplicate
            ? nil
            : BatterySampleRecord(
                timestamp: timestamp,
                level: clampedLevel,
                source: source,
                sessionID: currentSession.id
            )

        return StateTransitionResult(
            recordedSample: sample,
            closedSession: nil,
            activeSession: currentSession
        )
    }

    /// Explicitly switches the active session type when the user marks charger plugged/unplugged.
    public static func toggleSessionType(
        to targetType: SessionType,
        currentLevel: Int,
        at timestamp: Date,
        activeSession: BatterySessionRecord?,
        usageProfile: UsageProfile
    ) -> StateTransitionResult {
        let clampedLevel = min(100, max(0, currentLevel))

        var closed: BatterySessionRecord?
        if var existing = activeSession {
            if existing.type == targetType {
                let sample = BatterySampleRecord(
                    timestamp: timestamp,
                    level: clampedLevel,
                    source: .manual,
                    sessionID: existing.id
                )
                existing.endLevel = clampedLevel
                return StateTransitionResult(
                    recordedSample: sample,
                    closedSession: nil,
                    activeSession: existing
                )
            }
            existing.endTime = timestamp
            existing.endLevel = clampedLevel
            existing.isActive = false
            closed = existing
        }

        let nextSession = BatterySessionRecord(
            type: targetType,
            startTime: timestamp,
            startLevel: clampedLevel,
            endLevel: clampedLevel,
            isActive: true,
            usageProfile: usageProfile
        )
        let sample = BatterySampleRecord(
            timestamp: timestamp,
            level: clampedLevel,
            source: .manual,
            sessionID: nextSession.id
        )
        return StateTransitionResult(
            recordedSample: sample,
            closedSession: closed,
            activeSession: nextSession
        )
    }
}
