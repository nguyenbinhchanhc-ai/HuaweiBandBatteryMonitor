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

    func testDoesNotDeduplicateWhenLevelChangesImmediately() {
        let first = BatterySessionStateMachine.processReading(
            level: 88,
            timestamp: baseDate,
            source: .bleNotify,
            activeSession: nil,
            lastSample: nil,
            usageProfile: .typical
        )

        let second = BatterySessionStateMachine.processReading(
            level: 87,
            timestamp: baseDate.addingTimeInterval(30),
            source: .bleNotify,
            activeSession: first.activeSession,
            lastSample: first.recordedSample,
            usageProfile: .typical
        )

        XCTAssertEqual(second.recordedSample?.level, 87)
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

    func testChargeEstimatorComputesEffectiveMilliampsAndCVTaper() {
        let session = BatterySessionRecord(
            type: .charging,
            startTime: baseDate,
            startLevel: 40,
            endLevel: 60,
            isActive: true
        )
        let samples = [
            BatterySampleRecord(timestamp: baseDate, level: 40, source: .bleNotify, sessionID: session.id),
            BatterySampleRecord(timestamp: baseDate.addingTimeInterval(5 * 60), level: 50, source: .bleNotify, sessionID: session.id),
            BatterySampleRecord(timestamp: baseDate.addingTimeInterval(10 * 60), level: 60, source: .bleNotify, sessionID: session.id)
        ]

        let estimate = BatteryPredictor.estimateCharge(
            activeSession: session,
            sessionSamples: samples,
            historicalChargeSessions: [],
            now: baseDate.addingTimeInterval(10 * 60)
        )

        XCTAssertNotNil(estimate)
        // Rate = 2.0%/min = 120%/hour -> 1.2 * 300 mAh = 360 mA effective charge current
        XCTAssertEqual(estimate?.ratePerMinute ?? 0, 2.0, accuracy: 0.05)
        XCTAssertEqual(estimate?.effectiveCurrentmA ?? 0, 360.0, accuracy: 5.0)
        XCTAssertEqual(estimate?.minutesToFull ?? 0, 25.38, accuracy: 0.5)
        XCTAssertEqual(estimate?.confidence, .realTimeHigh)
    }

    func testDischargeEstimatorUsesLiveOLSRegressionWithoutPresetClamp() {
        // Simulate real heavy usage (~2.0%/hour = 6.0 mA on 300 mAh cell) even though profile is .light
        let activeStart = baseDate.addingTimeInterval(-6 * 3600)
        let activeSession = BatterySessionRecord(
            type: .discharging,
            startTime: activeStart,
            startLevel: 88,
            endLevel: 76,
            isActive: true,
            usageProfile: .light
        )
        let samples = [
            BatterySampleRecord(timestamp: activeStart, level: 88, source: .bleNotify, sessionID: activeSession.id),
            BatterySampleRecord(timestamp: activeStart.addingTimeInterval(2 * 3600), level: 84, source: .bleNotify, sessionID: activeSession.id),
            BatterySampleRecord(timestamp: activeStart.addingTimeInterval(4 * 3600), level: 80, source: .bleNotify, sessionID: activeSession.id),
            BatterySampleRecord(timestamp: baseDate, level: 76, source: .bleNotify, sessionID: activeSession.id)
        ]

        let estimate = BatteryPredictor.estimateDischarge(
            activeSession: activeSession,
            sessionSamples: samples,
            historicalDischargeSessions: [],
            profile: .light,
            now: baseDate
        )

        XCTAssertFalse(estimate.isUsingFallbackPrior)
        XCTAssertEqual(estimate.drainPerHour, 2.0, accuracy: 0.05)
        XCTAssertEqual(estimate.effectiveCurrentmA, 6.0, accuracy: 0.2)
        XCTAssertEqual(estimate.remainingHours, 38.0, accuracy: 1.0)
        XCTAssertEqual(estimate.confidence, .realTimeHigh)
    }

    func testWidgetSnapshotRoundTripEncoding() {
        let snapshot = WidgetBatterySnapshot(
            deviceName: "HUAWEI Band 11-C63",
            level: 88,
            sessionType: .discharging,
            updatedAt: baseDate,
            etaSummary: "Còn ~7 ngày 1 giờ",
            rateSummary: "-12.5%/ngày",
            currentSummary: "-1.56 mA",
            isConnected: true
        )

        SharedSnapshotStore.save(snapshot)
        let loaded = SharedSnapshotStore.load()
        XCTAssertEqual(loaded, snapshot)
    }

    func testHuaweiCRC16XModemStandardVector() {
        let payload = Data("123456789".utf8)
        XCTAssertEqual(HuaweiCRC16.xmodem(payload), 0x31C3)
    }

    func testHuaweiProtocolFrameBuildAndParseRoundTrip() {
        let frameData = HuaweiProtocolDecoder.buildFrame(
            serviceID: 0x01,
            commandID: 0x08,
            tlvs: [
                (tag: 0x01, value: Data([0x58])), // 88%
                (tag: 0x02, value: Data([0x01]))
            ]
        )

        let parsed = HuaweiProtocolDecoder.parseFrame(frameData)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.crcValid, true)
        XCTAssertEqual(parsed?.serviceID, 0x01)
        XCTAssertEqual(parsed?.commandID, 0x08)
        XCTAssertEqual(parsed?.tlvs.count, 2)
        XCTAssertEqual(parsed?.tlvs[0].tag, 0x01)
        XCTAssertEqual(parsed?.tlvs[0].integerValue, 88)
        XCTAssertEqual(parsed?.tlvs[1].tag, 0x02)
        XCTAssertEqual(parsed?.tlvs[1].integerValue, 1)
    }
}
