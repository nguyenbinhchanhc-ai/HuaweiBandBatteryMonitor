import Foundation

/// Data-driven real-time battery predictor using Ordinary Least Squares (OLS) regression
/// over real Bluetooth percentage transitions and effective current (mA) conversion for 300 mAh cells.
public enum BatteryPredictor {
    private static let defaultBulkChargeRatePerMin = 1.8
    private static let defaultCVTaperFactor = 0.65
    private static let cvPhaseThreshold = 80

    /// Estimates real-time charging speed, effective mA current, and time remaining to 100%.
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
                instantRatePerMinute: 0,
                effectiveCurrentmA: 0,
                instantCurrentmA: 0,
                elapsedMinutes: elapsedMinutes,
                confidence: .realTimeHigh
            )
        }

        let transitions = extractTransitionPoints(from: ordered)
        let olsRatePerMin = linearRegressionRatePerHour(points: transitions).map { $0 / 60.0 }
        let instantRatePerMin = computeInstantChargeRatePerMinute(from: transitions)
        let historicalRate = computeHistoricalChargeRate(from: historicalChargeSessions)

        let ratePerMinute: Double
        let instantRate: Double
        let confidence: PredictionConfidence

        if let olsRatePerMin {
            // Prioritize live measured slope; blend mildly with instant jump for responsiveness.
            if let instantRatePerMin {
                ratePerMinute = 0.65 * olsRatePerMin + 0.35 * instantRatePerMin
                instantRate = instantRatePerMin
            } else {
                ratePerMinute = olsRatePerMin
                instantRate = olsRatePerMin
            }
            let gained = currentLevel - activeSession.startLevel
            confidence = gained >= 3 ? .realTimeHigh : .measuring
        } else if let instantRatePerMin {
            ratePerMinute = instantRatePerMin
            instantRate = instantRatePerMin
            confidence = .measuring
        } else if let historicalRate {
            ratePerMinute = historicalRate
            instantRate = historicalRate
            confidence = .measuring
        } else {
            ratePerMinute = defaultBulkChargeRatePerMin
            instantRate = defaultBulkChargeRatePerMin
            confidence = .awaitingDelta
        }

        let safeRate = min(5.0, max(0.15, ratePerMinute))
        let safeInstantRate = min(5.0, max(0.15, instantRate))

        let minutesRemaining: Double
        if currentLevel < cvPhaseThreshold {
            let bulkRemaining = Double(cvPhaseThreshold - currentLevel)
            let cvRemaining = Double(100 - cvPhaseThreshold)
            let cvRate = safeRate * defaultCVTaperFactor
            minutesRemaining = (bulkRemaining / safeRate) + (cvRemaining / cvRate)
        } else {
            let remaining = Double(100 - currentLevel)
            let hasLiveRate = olsRatePerMin != nil || instantRatePerMin != nil
            let effectiveRate = hasLiveRate ? safeRate : safeRate * defaultCVTaperFactor
            minutesRemaining = remaining / max(0.12, effectiveRate)
        }

        let effectiveCurrent = BatteryHardwareSpec.effectiveCurrentmA(percentPerHour: safeRate * 60.0)
        let instantCurrent = BatteryHardwareSpec.effectiveCurrentmA(percentPerHour: safeInstantRate * 60.0)

        return ChargeEstimate(
            currentLevel: currentLevel,
            minutesToFull: minutesRemaining,
            estimatedFullDate: now.addingTimeInterval(minutesRemaining * 60.0),
            ratePerMinute: safeRate,
            instantRatePerMinute: safeInstantRate,
            effectiveCurrentmA: effectiveCurrent,
            instantCurrentmA: instantCurrent,
            elapsedMinutes: elapsedMinutes,
            confidence: confidence
        )
    }

    /// Estimates real-time discharge rate, effective mA draw, and remaining runtime purely from observed BLE transitions
    /// (falling back to baseline prior ONLY before the first 1% change is detected).
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
                drainPerHour: 0,
                drainPerDay: 0,
                instantDrainPerHour: 0,
                effectiveCurrentmA: 0,
                instantCurrentmA: 0,
                estimatedFullCycleDays: 0,
                confidence: .realTimeHigh,
                isUsingFallbackPrior: false
            )
        }

        // Focus on the recent 12h sliding window if it has >= 2 transitions; otherwise use full session transitions.
        let allTransitions = extractTransitionPoints(from: ordered)
        let cutoff12h = now.addingTimeInterval(-12 * 3600)
        let recent12h = allTransitions.filter { $0.timestamp >= cutoff12h }
        let regressionWindow = recent12h.count >= 3 ? recent12h : allTransitions

        let liveSlopeDrain = linearRegressionRatePerHour(points: regressionWindow).map { -$0 }
        let instantDropDrain = computeInstantDischargeRatePerHour(from: allTransitions)
        let historicalDrain = computeHistoricalDischargeRate(from: historicalDischargeSessions)

        let chosenRate: Double
        let instantRate: Double
        let confidence: PredictionConfidence
        let usingPrior: Bool

        if let live = liveSlopeDrain, live > 0.02 {
            // Real measured BLE drain rate drives the prediction directly without forcing preset limits.
            let instant = instantDropDrain ?? live
            if let history = historicalDrain, allTransitions.count < 4 {
                chosenRate = 0.70 * live + 0.30 * history
            } else {
                chosenRate = 0.80 * live + 0.20 * instant
            }
            instantRate = instant
            let spanHours = (allTransitions.last?.timestamp.timeIntervalSince(allTransitions.first?.timestamp ?? now) ?? 0) / 3600.0
            confidence = (allTransitions.count >= 4 || spanHours >= 4.0) ? .realTimeHigh : .measuring
            usingPrior = false
        } else if let instant = instantDropDrain, instant > 0.02 {
            chosenRate = instant
            instantRate = instant
            confidence = .measuring
            usingPrior = false
        } else if let history = historicalDrain, history > 0.02 {
            chosenRate = history
            instantRate = history
            confidence = .measuring
            usingPrior = false
        } else {
            chosenRate = profile.baselineDrainPerHour
            instantRate = profile.baselineDrainPerHour
            confidence = .awaitingDelta
            usingPrior = true
        }

        let safeDrainPerHour = min(20.0, max(0.05, chosenRate))
        let safeInstantPerHour = min(20.0, max(0.05, instantRate))
        let remainingHours = Double(currentLevel) / safeDrainPerHour
        let drainPerDay = safeDrainPerHour * 24.0

        return DischargeEstimate(
            currentLevel: currentLevel,
            remainingHours: remainingHours,
            estimatedEmptyDate: now.addingTimeInterval(remainingHours * 3600.0),
            drainPerHour: safeDrainPerHour,
            drainPerDay: drainPerDay,
            instantDrainPerHour: safeInstantPerHour,
            effectiveCurrentmA: BatteryHardwareSpec.effectiveCurrentmA(percentPerHour: safeDrainPerHour),
            instantCurrentmA: BatteryHardwareSpec.effectiveCurrentmA(percentPerHour: safeInstantPerHour),
            estimatedFullCycleDays: 100.0 / drainPerDay,
            confidence: confidence,
            isUsingFallbackPrior: usingPrior
        )
    }

    // MARK: - Transition Extraction & Ordinary Least Squares Regression

    /// Reduces flat plateau duplicates down to the first timestamp where each integer % was entered,
    /// eliminating timing bias from polling intervals.
    private static func extractTransitionPoints(from orderedSamples: [BatterySampleRecord]) -> [BatterySampleRecord] {
        var transitions: [BatterySampleRecord] = []
        for sample in orderedSamples {
            if let last = transitions.last, last.level == sample.level {
                continue
            }
            transitions.append(sample)
        }
        return transitions
    }

    /// Computes Ordinary Least Squares slope (% per hour) across >= 2 transition points.
    private static func linearRegressionRatePerHour(points: [BatterySampleRecord]) -> Double? {
        guard points.count >= 2, let origin = points.first?.timestamp else { return nil }

        let xs = points.map { $0.timestamp.timeIntervalSince(origin) / 3600.0 }
        let ys = points.map { Double($0.level) }

        guard let spanHours = xs.last, spanHours >= (1.0 / 60.0) else { return nil }

        let n = Double(points.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n

        var numerator = 0.0
        var denominator = 0.0
        for i in 0..<points.count {
            let dx = xs[i] - meanX
            numerator += dx * (ys[i] - meanY)
            denominator += dx * dx
        }

        guard denominator > 1e-9 else { return nil }
        return numerator / denominator
    }

    private static func computeInstantChargeRatePerMinute(from transitions: [BatterySampleRecord]) -> Double? {
        guard transitions.count >= 2 else { return nil }
        let prev = transitions[transitions.count - 2]
        let latest = transitions[transitions.count - 1]
        let delta = latest.level - prev.level
        let minutes = latest.timestamp.timeIntervalSince(prev.timestamp) / 60.0
        guard delta > 0, minutes >= 0.1 else { return nil }
        return Double(delta) / minutes
    }

    private static func computeInstantDischargeRatePerHour(from transitions: [BatterySampleRecord]) -> Double? {
        guard transitions.count >= 2 else { return nil }
        let prev = transitions[transitions.count - 2]
        let latest = transitions[transitions.count - 1]
        let drop = prev.level - latest.level
        let hours = latest.timestamp.timeIntervalSince(prev.timestamp) / 3600.0
        guard drop > 0, hours >= (1.0 / 120.0) else { return nil }
        return Double(drop) / hours
    }

    private static func computeHistoricalChargeRate(from sessions: [BatterySessionRecord]) -> Double? {
        let validRates: [Double] = sessions.compactMap { session in
            guard session.type == .charging, !session.isActive else { return nil }
            let minutes = session.duration() / 60.0
            let gain = session.endLevel - session.startLevel
            guard minutes >= 3.0, gain >= 5 else { return nil }
            return Double(gain) / minutes
        }
        guard !validRates.isEmpty else { return nil }
        return validRates.reduce(0, +) / Double(validRates.count)
    }

    private static func computeHistoricalDischargeRate(from sessions: [BatterySessionRecord]) -> Double? {
        let weightedPairs: [(rate: Double, weight: Double)] = sessions.compactMap { session in
            guard session.type == .discharging, !session.isActive else { return nil }
            let hours = session.duration() / 3600.0
            let drop = session.startLevel - session.endLevel
            guard hours >= 2.0, drop >= 2 else { return nil }
            return (Double(drop) / hours, hours)
        }
        guard !weightedPairs.isEmpty else { return nil }
        let totalWeight = weightedPairs.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }
        let weightedSum = weightedPairs.reduce(0) { $0 + ($1.rate * $1.weight) }
        return weightedSum / totalWeight
    }
}
