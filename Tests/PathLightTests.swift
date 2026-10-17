import XCTest
@testable import PathLight

final class PathLightTests: XCTestCase {
    private func walk(kind: WalkKind = .baseline, speed: Double = 1,
                      rotation: Double = 0.2, tilt: Double = 5,
                      baselineID: UUID? = nil, validSeconds: Int = 30,
                      motionGap: Bool = false, duration: Double = 30) -> WalkRecord {
        let positions = (1...(validSeconds * 2)).map {
            WalkSample(time: Double($0) * 0.5, interval: 0.5, speed: speed)
        }
        let motion = (0..<Int(duration * 50)).compactMap { i -> MotionSample? in
            if motionGap && i > 200 && i < 1300 { return nil }
            return MotionSample(time: Double(i) / 50, rotation: rotation, acceleration: 0.5, tilt: tilt)
        }
        return WalkRecord(id: UUID(), date: Date(timeIntervalSince1970: 0), kind: kind,
            duration: duration, samples: positions, motion: motion, baselineID: baselineID,
            device: "Test fixture", notes: "", algorithmVersion: 2)
    }

    func testIdenticalWalksDoNotFlagChange() {
        let baseline = walk()
        let result = Comparison(baseline: baseline, current: walk(kind: .assessment, baselineID: baseline.id))
        XCTAssertTrue(result.comparabilityIssues.isEmpty)
        XCTAssertTrue(result.flags.isEmpty)
        XCTAssertEqual(baseline.distance, 30, accuracy: 0.001)
        XCTAssertEqual(baseline.meanSpeed, 1, accuracy: 0.001)
    }

    func testLargeSpeedChangeFlagsWithoutDiseaseLabel() {
        let baseline = walk()
        let result = Comparison(baseline: baseline, current: walk(kind: .assessment, speed: 0.6, baselineID: baseline.id))
        XCTAssertTrue(result.comparabilityIssues.isEmpty)
        XCTAssertEqual(result.flags.count, 1)
        XCTAssertEqual(result.headline, "Movement change — review suggested")
    }

    func testTrackingLossBlocksComparisonRatherThanCallingItNormal() {
        let baseline = walk()
        let result = Comparison(baseline: baseline,
            current: walk(kind: .assessment, speed: 0.6, baselineID: baseline.id, validSeconds: 10))
        XCTAssertFalse(result.comparabilityIssues.isEmpty)
        XCTAssertTrue(result.flags.isEmpty)
        XCTAssertTrue(result.headline.contains("unavailable"))
    }

    func testMotionGapsAreNotCountedAsCoverage() {
        let record = walk(motionGap: true)
        XCTAssertLessThan(record.motionCoverage, 0.3)
        XCTAssertFalse(record.usable)
    }

    func testStationaryRecordingCannotBecomeBaseline() {
        XCTAssertFalse(walk(speed: 0).usable)
    }

    func testChangedHarnessAngleBlocksComparison() {
        let baseline = walk()
        let result = Comparison(baseline: baseline,
            current: walk(kind: .assessment, tilt: 35, baselineID: baseline.id))
        XCTAssertTrue(result.comparabilityIssues.contains { $0.contains("tilt") })
        XCTAssertTrue(result.flags.isEmpty)
    }

    func testWrongBaselineIDBlocksComparison() {
        let result = Comparison(baseline: walk(), current: walk(kind: .assessment, baselineID: UUID()))
        XCTAssertFalse(result.comparabilityIssues.isEmpty)
    }

    func testWeightedSpeedWithUnequalIntervals() {
        let template = walk()
        let record = WalkRecord(id: UUID(), date: template.date, kind: .baseline, duration: 1.1,
            samples: [WalkSample(time: 0.5, interval: 0.5, speed: 1), WalkSample(time: 1.1, interval: 0.6, speed: 2)],
            motion: [], baselineID: nil, device: "Test", notes: "")
        XCTAssertEqual(record.distance, 1.7, accuracy: 0.0001)
        XCTAssertEqual(record.meanSpeed, 1.7 / 1.1, accuracy: 0.0001)
    }

    func testAbsoluteFloorPreventsTinyRotationChangeFlag() {
        let baseline = walk(rotation: 0.02)
        let current = walk(kind: .assessment, rotation: 0.04, baselineID: baseline.id)
        XCTAssertTrue(Comparison(baseline: baseline, current: current).flags.isEmpty)
    }

    func testArchiveRoundTripPreservesBaselineLinkAndSamples() throws {
        let baseline = walk()
        let state = SavedState(baseline: baseline, assessments: [walk(kind: .assessment, baselineID: baseline.id)])
        let decoded = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.assessments[0].baselineID, decoded.baseline?.id)
        XCTAssertEqual(decoded.assessments[0].motion.count, 1500)
    }

    func testDirectionBoundariesAndStereoPan() {
        XCTAssertEqual(Side.from(screenX: 0.1), .left)
        XCTAssertEqual(Side.from(screenX: 0.5), .center)
        XCTAssertEqual(Side.from(screenX: 0.9), .right)
        XCTAssertEqual(Side.left.pan, -1)
        XCTAssertEqual(Side.right.pan, 1)
    }

    func testFiveSecondBaselinePassesWithGoodWalkingData() {
        let baseline = walk(validSeconds: 5, duration: 5)
        XCTAssertTrue(baseline.usable)
        XCTAssertEqual(WalkKind.baseline.duration, 5)
        XCTAssertEqual(WalkKind.assessment.duration, 30)
    }

    func testFiveSecondBaselineStillRejectsStationaryData() {
        XCTAssertFalse(walk(speed: 0, validSeconds: 5, duration: 5).usable)
    }

    func testFiveSecondsDoesNotPassAssessmentDurationGate() {
        XCTAssertFalse(walk(kind: .assessment, validSeconds: 5, duration: 5).usable)
    }

    func testLegacyRecordDecodesAndCannotCompareToNewAlgorithm() throws {
        let baseline = walk()
        let encoded = try JSONEncoder().encode(baseline)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "algorithmVersion")
        let legacy = try JSONDecoder().decode(WalkRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.algorithmVersion)
        let current = walk(kind: .assessment, baselineID: legacy.id)
        let result = Comparison(baseline: legacy, current: current)
        XCTAssertTrue(result.comparabilityIssues.contains { $0.contains("Speed tracking changed") })
        XCTAssertTrue(result.flags.isEmpty)
    }

    private func target(_ name: String, distance: Double, x: Float = 0) -> Obstacle {
        Obstacle(name: name, side: .center, distance: distance,
            bounds: CGRect(x: 0.3, y: 0.2, width: 0.2, height: 0.4),
            worldPosition: SIMD3<Float>(x, 0, -2))
    }

    func testCloserTargetSwitchesImmediatelyDuringSpeechCooldown() {
        var selector = TargetSelector()
        let seat = target("Seat", distance: 2)
        let table = target("Table", distance: 3, x: 1)
        XCTAssertEqual(selector.update([table, seat], time: 0)?.name, "Seat")
        let closerTable = target("Table", distance: 1, x: 1)
        XCTAssertEqual(selector.update([closerTable, seat], time: 0.1)?.name, "Table")
        XCTAssertEqual(selector.update([closerTable, seat], time: 4)?.name, "Table")
    }

    func testLostTargetCanBeReplacedImmediately() {
        var selector = TargetSelector()
        _ = selector.update([target("Seat", distance: 2)], time: 10)
        XCTAssertEqual(selector.update([target("Table", distance: 1, x: 1)], time: 11)?.name, "Table")
        XCTAssertNil(selector.update([], time: 13.99))
        XCTAssertEqual(selector.update([target("Table", distance: 1, x: 1)], time: 14)?.name, "Table")
    }

    func testSameTargetDoesNotRepeatedlyAnnounceAtEachCooldown() {
        var selector = TargetSelector()
        let seat = target("Seat", distance: 2)
        _ = selector.update([seat], time: 0)
        let firstID = selector.announcementID
        for i in 1...20 { _ = selector.update([seat], time: Double(i)) }
        XCTAssertEqual(selector.announcementID, firstID)
    }

    func testTrackingRecoveryCanSelectWithoutCooldown() {
        var selector = TargetSelector()
        _ = selector.update([target("Seat", distance: 2)], time: 0)
        selector.suspend()
        XCTAssertEqual(selector.update([target("Table", distance: 1, x: 1)], time: 1)?.name, "Table")
    }

    func testDifferentSameClassTargetGetsNewAnnouncement() {
        var selector = TargetSelector()
        _ = selector.update([target("Seat", distance: 2)], time: 0)
        let oldID = selector.announcementID
        XCTAssertNotNil(selector.update([target("Seat", distance: 1, x: 2)], time: 1))
        XCTAssertGreaterThan(selector.announcementID, oldID)
    }

    func testSpeechCooldownStartsAfterSpeechEndsAndDoesNotQueueDuplicates() {
        var gate = DetectionSpeechGate()
        XCTAssertTrue(gate.consume(id: 1, time: 0, speechBusy: false))
        gate.ended(at: 2)
        XCTAssertFalse(gate.consume(id: 2, time: 5.99, speechBusy: false))
        XCTAssertTrue(gate.consume(id: 2, time: 6, speechBusy: false))
        XCTAssertFalse(gate.consume(id: 2, time: 20, speechBusy: false))
        XCTAssertFalse(gate.consume(id: 3, time: 20, speechBusy: true))
        XCTAssertTrue(gate.consume(id: 3, time: 21, speechBusy: false))
    }

    func testSteadyPoseMotionHasContinuousSpeedMeasurements() {
        var tracker = PoseSpeedTracker()
        XCTAssertNil(tracker.update(position: .zero, time: 0))
        for i in 1...20 {
            let time = Double(i) * 0.25
            let measurement = tracker.update(position: SIMD3<Float>(Float(time), 0, 0), time: time)
            XCTAssertNotNil(measurement)
            XCTAssertEqual(measurement?.displaySpeed ?? -1, 1, accuracy: 0.001)
        }
    }

    func testSpeedSmoothingDoesNotAlterRawRecordedSpeed() throws {
        var tracker = PoseSpeedTracker()
        _ = tracker.update(position: .zero, time: 0)
        _ = tracker.update(position: SIMD3<Float>(0.25, 0, 0), time: 0.25)
        let measurement = try XCTUnwrap(tracker.update(position: SIMD3<Float>(0.75, 0, 0), time: 0.5))
        XCTAssertEqual(measurement.rawSpeed, 2, accuracy: 0.001)
        XCTAssertGreaterThan(measurement.displaySpeed, 1)
        XCTAssertLessThan(measurement.displaySpeed, 2)
    }

    func testTrackingGapNeverProducesSyntheticDistance() throws {
        var tracker = PoseSpeedTracker()
        _ = tracker.update(position: .zero, time: 0)
        _ = tracker.update(position: SIMD3<Float>(0.25, 0, 0), time: 0.25)
        tracker.resetContinuity()
        XCTAssertNil(tracker.update(position: SIMD3<Float>(10, 0, 0), time: 3))
        let measurement = try XCTUnwrap(tracker.update(position: SIMD3<Float>(10.25, 0, 0), time: 3.25))
        XCTAssertEqual(measurement.startTime, 3)
        XCTAssertEqual(measurement.rawSpeed, 1, accuracy: 0.001)
    }

    func testPoseJumpIsRejectedAndTrackerCanRecover() throws {
        var tracker = PoseSpeedTracker()
        _ = tracker.update(position: .zero, time: 0)
        XCTAssertNil(tracker.update(position: SIMD3<Float>(10, 0, 0), time: 0.25))
        XCTAssertFalse(tracker.isFresh(at: 0.25))
        let recovered = try XCTUnwrap(tracker.update(position: SIMD3<Float>(10.25, 0, 0), time: 0.5))
        XCTAssertEqual(recovered.rawSpeed, 1, accuracy: 0.001)
    }

    func testNearbyToneBypassesDescriptionCooldownButDoesNotSpam() {
        var gate = ProximityToneGate()
        XCTAssertFalse(gate.consume(target("Chair", distance: 3), time: 0))
        XCTAssertTrue(gate.consume(target("Chair", distance: 1.9), time: 0.1))
        XCTAssertFalse(gate.consume(target("Chair", distance: 1.9), time: 0.2))
        XCTAssertTrue(gate.consume(target("Chair", distance: 1.4), time: 0.4))
    }

    func testUnrangedObjectNeverTriggersProximityTone() {
        var gate = ProximityToneGate()
        let object = Obstacle(name: "Chair", side: .left, distance: nil, hasWorldPosition: false)
        XCTAssertFalse(gate.consume(object, time: 10))
        XCTAssertTrue(object.phrase.contains("Distance unavailable"))
        var selector = TargetSelector()
        XCTAssertEqual(selector.update([object], time: 10)?.name, "Chair")
    }

    func testNewDepthWithinNamedBoxTriggersTwoMeterThreshold() throws {
        let chair = target("Chair", distance: 2.1)
        let depth = target("Obstacle", distance: 1.9)
        let fused = TargetFusion.candidates(named: [chair], nearby: [depth])
        XCTAssertEqual(fused.count, 1)
        XCTAssertEqual(fused.first?.name, "Chair")
        XCTAssertEqual(try XCTUnwrap(fused.first?.distance), 1.9, accuracy: 0.001)
        var gate = ProximityToneGate()
        XCTAssertTrue(gate.consume(fused.first, time: 0))
    }

    func testUnmatchedCloseDepthRemainsAvailableWithNamedObject() {
        var depth = target("Obstacle", distance: 1.1)
        depth.bounds = CGRect(x: 0.8, y: 0.2, width: 0.1, height: 0.2)
        let objects = TargetFusion.candidates(named: [target("Chair", distance: 3)], nearby: [depth])
        var selector = TargetSelector()
        XCTAssertEqual(selector.update(objects, time: 0)?.name, "Obstacle")
    }

    func testSmallFarRangeDifferencesDoNotFlickerTargets() {
        var selector = TargetSelector()
        _ = selector.update([target("Chair", distance: 3)], time: 0)
        XCTAssertEqual(selector.update([target("Chair", distance: 3), target("Table", distance: 2.9, x: 2)], time: 0.1)?.name, "Chair")
    }

    func testFullPortraitModelBoxUnletterboxesToRawCamera() throws {
        let geometry = DetectionGeometry(rawSize: CGSize(width: 1920, height: 1440), modelSize: CGSize(width: 384, height: 640))
        XCTAssertEqual(geometry.padding.y, 64, accuracy: 0.001)
        let box = try XCTUnwrap(geometry.rawBounds(centerX: 0.5, centerY: 0.5, width: 1, height: 0.8))
        XCTAssertEqual(box.minX, 0, accuracy: 0.001)
        XCTAssertEqual(box.minY, 0, accuracy: 0.001)
        XCTAssertEqual(box.width, 1, accuracy: 0.001)
        XCTAssertEqual(box.height, 1, accuracy: 0.001)
    }

    func testPortraitTopLeftQuarterMapsToCorrectRawQuarter() throws {
        let geometry = DetectionGeometry(rawSize: CGSize(width: 1920, height: 1440), modelSize: CGSize(width: 384, height: 640))
        let box = try XCTUnwrap(geometry.rawBounds(centerX: 0.25, centerY: 0.3, width: 0.5, height: 0.4))
        XCTAssertEqual(box.minX, 0, accuracy: 0.001)
        XCTAssertEqual(box.minY, 0.5, accuracy: 0.001)
        XCTAssertEqual(box.width, 0.5, accuracy: 0.001)
        XCTAssertEqual(box.height, 0.5, accuracy: 0.001)
    }

    func testPaddingOnlyAndNonfiniteModelBoxesAreRejected() {
        let geometry = DetectionGeometry(rawSize: CGSize(width: 1920, height: 1440), modelSize: CGSize(width: 384, height: 640))
        XCTAssertNil(geometry.rawBounds(centerX: 0.5, centerY: 0.02, width: 0.5, height: 0.02))
        XCTAssertNil(geometry.rawBounds(centerX: .nan, centerY: 0.5, width: 0.5, height: 0.5))
    }

    func testBundledYOLOModelLoadsWithItsLabels() throws {
        // Integration test: checks Xcode compiled/copied the real model and label resource.
        let detector = YOLODetector()
        try detector.load()
    }
}
