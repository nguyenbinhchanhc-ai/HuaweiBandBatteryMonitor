import Foundation

/// Forecasts charging completion time and remaining battery runtime from historical and active telemetry.
public enum BatteryPredictor {
    /// Default Huawei Band 11 magnetic charging prior (~1.6% / min in bulk phase, tapered above 80%).
    private static let defaultBulkChargeRatePerMin = 1.6
    private static let defaultCVTaperFactor = 0.65
    private static let cvPhaseThreshold = 80

    /// Estimates remaining time to 100% during an active charging session.
    public static func estimateCharge(
        activeSession: BatterySessionRecord,
        sessionSamples: [BatterySampleRecord],
        historicalChargeSessions: [BatterySessionRecord],
        now: Date = Date()
    ) -> ChargeEstimate? {
        guard activeSession.type == .charging else { return nil }

        let ordered = sessionSamples.sorted { $0.timestamp < $1.timestamp }
        let currentLevel = ordered.last?.level ?? activeSession.endLevel
        let elapsedMinutes = max(0, now.timeIntervalSince(activeSession.startTime) / 60.0)

        if currentLevel >= 100 {
            return ChargeEstimate(
                currentLevel: 100,
                minutesToFull: 0,
                estimatedFullDate: now,
                ratePerMinute: 0,
                elapsedMinutes: elapsedMinutes,
                confidence: .high
            )
        }

        let observedRate = computeChargeRatePerMinute(
            activeSession: activeSession,
            orderedSamples: ordered
        )
        let historicalRate = computeHistoricalChargeRate(from: historicalChargeSessions)

        let ratePerMinute: Double
        let confidence: PredictionConfidence
        if let observedRate {
            if let historicalRate {
                ratePerMinute = 0.75 * observedRate + 0.25 * historicalRate
            } else {
                ratePerMinute = observedRate
            }
            let gained = currentLevel - activeSession.startLevel
            confidence = gained >= 10 ? .high : .medium
        } else if let historicalRate {
            ratePerMinute = historicalRate
            confidence = .medium
        } else {
            ratePerMinute = defaultBulkChargeRatePerMin
            confidence = .low
        }

        let safeRate = min(5.0, max(0.2, ratePerMinute))
        let minutesRemaining: Double
        if currentLevel < cvPhaseThreshold {
            let bulkRemaining = Double(cvPhaseThreshold - currentLevel)
            let cvRemaining = Double(100 - cvPhaseThreshold)
            let cvRate = safeRate * defaultCVTaperFactor
            minutesRemaining = (bulkRemaining / safeRate) + (cvRemaining / cvRate)
        } else {
            let remaining = Double(100 - currentLevel)
            // If we already entered >= 80% before any observation, apply taper only when relying on a prior bulk rate.
            let effectiveRate = observedRate != nil ? safeRate : safeRate * defaultCVTaperFactor
            minutesRemaining = remaining / max(0.15, effectiveRate)
        }

        return ChargeEstimate(
            currentLevel: currentLevel,
            minutesToFull: minutesRemaining,
            estimatedFullDate: now.addingTimeInterval(minutesRemaining * 60.0),
            ratePerMinute: safeRate,
            elapsedMinutes: elapsedMinutes,
            confidence: confidence
        )
    }

    /// Estimates remaining runtime until 0% during an active discharging session.
    public static func estimateDischarge(
        activeSession: BatterySessionRecord?,
        sessionSamples: [BatterySampleRecord],
        historicalDischargeSessions: [BatterySessionRecord],
        profile: UsageProfile,
        now: Date = Date()
    ) -> DischargeEstimate {
        let ordered = sessionSamples.sorted { $0.timestamp < $1.timestamp }
        let currentLevel = ordered.last?.level ?? activeSession?.endLevel ?? 0

        if currentLevel <= 0 {
            return DischargeEstimate(
                currentLevel: 0,
                remainingHours: 0,
                estimatedEmptyDate: now,
                drainPerHour: profile.baselineDrainPerHour,
                drainPerDay: profile.baselineDrainPerHour * 24.0,
                estimatedFullCycleDays: 100.0 / (profile.baselineDrainPerHour * 24.0),
                confidence: .high
            )
        }

        let recentRate = computeRecentDischargeRate(
            activeSession: activeSession,
            orderedSamples: ordered,
            now: now
        )
        let historicalRate = computeHistoricalDischargeRate(from: historicalDischargeSessions)
        let priorRate = profile.baselineDrainPerHour

        let sessionSpanHours = activeSession.map { max(0, now.timeIntervalSince($0.startTime) / 3600.0) } ?? 0
        let levelDropped = activeSession.map { max(0, $0.startLevel - currentLevel) } ?? 0

        let blendedRate: Double
        let confidence: PredictionConfidence

        switch (recentRate, historicalRate) {
        case let (.some(recent), .some(history)):
            // Smoothly ramp recent weight up as the current discharge session accumulates time and drops.
            let maturity = min(1.0, max(sessionSpanHours / 24.0, Double(levelDropped) / 10.0))
            let recentWeight = 0.25 + 0.45 * maturity
            blendedRate = recentWeight * recent + (1.0 - recentWeight) * history
            confidence = (sessionSpanHours >= 12.0 || levelDropped >= 5) ? .high : .medium

        case let (.some(recent), .none):
            let maturity = min(1.0, max(sessionSpanHours / 18.0, Double(levelDropped) / 8.0))
            blendedRate = maturity * recent + (1.0 - maturity) * priorRate
            confidence = (sessionSpanHours >= 18.0 && levelDropped >= 5) ? .high : (levelDropped >= 2 ? .medium : .low)

        case let (.none, .some(history)):
            blendedRate = 0.75 * history + 0.25 * priorRate
            confidence = .medium

        case (.none, .none):
            blendedRate = priorRate
            confidence = .low
        }

        let safeDrainPerHour = min(15.0, max(0.08, blendedRate))
        let remainingHours = Double(currentLevel) / safeDrainPerHour
        let drainPerDay = safeDrainPerHour * 24.0

        return DischargeEstimate(
            currentLevel: currentLevel,
            remainingHours: remainingHours,
            estimatedEmptyDate: now.addingTimeInterval(remainingHours * 3600.0),
            drainPerHour: safeDrainPerHour,
            drainPerDay: drainPerDay,
            estimatedFullCycleDays: 100.0 / drainPerDay,
            confidence: confidence
        )
    }

    // MARK: - Private Rate Helpers

    private static func computeChargeRatePerMinute(
        activeSession: BatterySessionRecord,
        orderedSamples: [BatterySampleRecord]
    ) -> Double? {
        guard orderedSamples.count >= 2 else { return nil }
        // Use a recent sliding window (up to last 6 samples) to capture current phase speed accurately.
        let window = orderedSamples.suffix(6)
        guard let first = window.first, let last = window.last else { return nil }
        let minutes = last.timestamp.timeIntervalSince(first.timestamp) / 60.0
        let gain = last.level - first.level
        guard minutes >= 1.0, gain >= 2 else {
            let totalMinutes = last.timestamp.timeIntervalSince(activeSession.startTime) / 60.0
            let totalGain = last.level - activeSession.startLevel
            guard totalMinutes >= 1.0, totalGain >= 2 else { return nil }
            return Double(totalGain) / totalMinutes
        }
        return Double(gain) / minutes
    }

    private static func computeHistoricalChargeRate(from sessions: [BatterySessionRecord]) -> Double? {
        let validRates: [Double] = sessions.compactMap { session in
            guard session.type == .charging, !session.isActive else { return nil }
            let minutes = session.duration() / 60.0
            let gain = session.endLevel - session.startLevel
            guard minutes >= 5.0, gain >= 10 else { return nil }
            return Double(gain) / minutes
        }
        guard !validRates.isEmpty else { return nil }
        return validRates.reduce(0, +) / Double(validRates.count)
    }

    private static func computeRecentDischargeRate(
        activeSession: BatterySessionRecord?,
        orderedSamples: [BatterySampleRecord],
        now: Date
    ) -> Double? {
        guard orderedSamples.count >= 2 else { return nil }

        // Prefer the last 24 hours of samples within the active session.
        let cutoff = now.addingTimeInterval(-24 * 3600)
        let recentWindow = orderedSamples.filter { $0.timestamp >= cutoff }
        let window = recentWindow.count >= 2 ? recentWindow : orderedSamples

        guard let first = window.first, let last = window.last else { return nil }
        let hours = last.timestamp.timeIntervalSince(first.timestamp) / 3600.0
        let drop = first.level - last.level
        if hours >= 1.0, drop >= 2 {
            return Double(drop) / hours
        }

        if let activeSession {
            let totalHours = last.timestamp.timeIntervalSince(activeSession.startTime) / 3600.0
            let totalDrop = activeSession.startLevel - last.level
            if totalHours >= 1.5, totalDrop >= 2 {
                return Double(totalDrop) / totalHours
            }
        }
        return nil
    }

    private static func computeHistoricalDischargeRate(from sessions: [BatterySessionRecord]) -> Double? {
        let weightedPairs: [(rate: Double, weight: Double)] = sessions.compactMap { session in
            guard session.type == .discharging, !session.isActive else { return nil }
            let hours = session.duration() / 3600.0
            let drop = session.startLevel - session.endLevel
            guard hours >= 6.0, drop >= 5 else { return nil }
            return (Double(drop) / hours, hours)
        }
        guard !weightedPairs.isEmpty else { return nil }
        let totalWeight = weightedPairs.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }
        let weightedSum = weightedPairs.reduce(0) { $0 + ($1.rate * $1.weight) }
        return weightedSum / totalWeight
    }
}
