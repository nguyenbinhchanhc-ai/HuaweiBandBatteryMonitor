import XCTest

final class BatteryEngineTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_760_000_000)

    func testInitialReadingStartsDischargingSession() {
        let result = BatterySessionStateMachine.processReading(
            level: 88,
            timestamp: baseDate,
            source: .bleRead,
            activeSession: nil,
            lastSample: nil,
            usageProfile: .typical
        )

        XCTAssertEqual(result.activeSession.type, .discharging)
        XCTAssertEqual(result.activeSession.startLevel, 88)
        XCTAssertEqual(result.activeSession.endLevel, 88)
        XCTAssertNil(result.closedSession)
        XCTAssertEqual(result.recordedSample?.level, 88)
    }

    func testDeduplicatesIdenticalReadingWithinFiveMinutes() {
        let first = BatterySessionStateMachine.processReading(
            level: 88,
            timestamp: baseDate,
            source: .bleRead,
            activeSession: nil,
            lastSample: nil,
            usageProfile: .typical
        )

        let second = BatterySessionStateMachine.processReading(
            level: 88,
            timestamp: baseDate.addingTimeInterval(60),
            source: .bleRead,
            activeSession: first.activeSession,
            lastSample: first.recordedSample,
            usageProfile: .typical
        )

        XCTAssertNil(second.recordedSample)
        XCTAssertNil(second.closedSession)
        XCTAssertEqual(second.activeSession.id, first.activeSession.id)
    }

    func testRisingLevelTransitionsDischargingToChargingAndBackOnDrop() {
        let t0 = baseDate
        let s1 = BatterySessionStateMachine.processReading(
            level: 30,
            timestamp: t0,
            source: .bleRead,
            activeSession: nil,
            lastSample: nil,
            usageProfile: .typical
        )

        // Battery rises -> starts charging anchored at t0 / 30%
        let t1 = t0.addingTimeInterval(600)
        let s2 = BatterySessionStateMachine.processReading(
            level: 38,
            timestamp: t1,
            source: .bleNotify,
            activeSession: s1.activeSession,
            lastSample: s1.recordedSample,
            usageProfile: .typical
        )

        XCTAssertEqual(s2.closedSession?.type, .discharging)
        XCTAssertEqual(s2.closedSession?.isActive, false)
        XCTAssertEqual(s2.activeSession.type, .charging)
        XCTAssertEqual(s2.activeSession.startLevel, 30)
        XCTAssertEqual(s2.activeSession.endLevel, 38)

        // Battery drops -> closes charging at 38% and starts discharging
        let t2 = t1.addingTimeInterval(3600)
        let s3 = BatterySessionStateMachine.processReading(
            level: 37,
            timestamp: t2,
            source: .bleNotify,
            activeSession: s2.activeSession,
            lastSample: s2.recordedSample,
            usageProfile: .typical
        )

        XCTAssertEqual(s3.closedSession?.type, .charging)
        XCTAssertEqual(s3.closedSession?.endLevel, 38)
        XCTAssertEqual(s3.activeSession.type, .discharging)
        XCTAssertEqual(s3.activeSession.startLevel, 38)
        XCTAssertEqual(s3.activeSession.endLevel, 37)
    }

    func testChargeEstimatorAccountsForCVTaperAboveEightyPercent() {
        let session = BatterySessionRecord(
            type: .charging,
            startTime: baseDate,
            startLevel: 40,
            endLevel: 60,
            isActive: true
        )
        let samples = [
            BatterySampleRecord(timestamp: baseDate, level: 40, source: .bleNotify, sessionID: session.id),
            BatterySampleRecord(timestamp: baseDate.addingTimeInterval(10 * 60), level: 60, source: .bleNotify, sessionID: session.id)
        ]

        let estimate = BatteryPredictor.estimateCharge(
            activeSession: session,
            sessionSamples: samples,
            historicalChargeSessions: [],
            now: baseDate.addingTimeInterval(10 * 60)
        )

        XCTAssertNotNil(estimate)
        // Rate = 2.0%/min -> 60->80 takes 10 min; 80->100 at 0.65x (1.3%/min) takes ~15.38 min => ~25.38 min
        XCTAssertEqual(estimate?.ratePerMinute ?? 0, 2.0, accuracy: 0.05)
        XCTAssertEqual(estimate?.minutesToFull ?? 0, 25.38, accuracy: 0.5)
        XCTAssertEqual(estimate?.confidence, .high)
    }

    func testDischargeEstimatorBlendsRecentRateWithProfileAndHistory() {
        let historySession = BatterySessionRecord(
            type: .discharging,
            startTime: baseDate.addingTimeInterval(-100 * 3600),
            endTime: baseDate.addingTimeInterval(-50 * 3600),
            startLevel: 100,
            endLevel: 50, // 1.0% / hour
            isActive: false
        )

        let activeStart = baseDate.addingTimeInterval(-24 * 3600)
        let activeSession = BatterySessionRecord(
            type: .discharging,
            startTime: activeStart,
            startLevel: 100,
            endLevel: 76, // 1.0% / hour over 24h
            isActive: true
        )
        let samples = [
            BatterySampleRecord(timestamp: activeStart, level: 100, source: .bleRead, sessionID: activeSession.id),
            BatterySampleRecord(timestamp: baseDate, level: 76, source: .bleRead, sessionID: activeSession.id)
        ]

        let estimate = BatteryPredictor.estimateDischarge(
            activeSession: activeSession,
            sessionSamples: samples,
            historicalDischargeSessions: [historySession],
            profile: .typical,
            now: baseDate
        )

        XCTAssertEqual(estimate.drainPerHour, 1.0, accuracy: 0.05)
        XCTAssertEqual(estimate.remainingHours, 76.0, accuracy: 3.0)
        XCTAssertEqual(estimate.confidence, .high)
    }

    func testWidgetSnapshotRoundTripEncoding() {
        let snapshot = WidgetBatterySnapshot(
            deviceName: "HUAWEI Band 11-C63",
            level: 88,
            sessionType: .discharging,
            updatedAt: baseDate,
            etaSummary: "Còn ~7 ngày 1 giờ",
            rateSummary: "-12.5%/ngày",
            isConnected: true
        )

        SharedSnapshotStore.save(snapshot)
        let loaded = SharedSnapshotStore.load()
        XCTAssertEqual(loaded, snapshot)
    }
}
