import XCTest
@testable import PathLight

final class PathLightTests: XCTestCase {
    private func walk(kind: WalkKind = .baseline, speed: Double = 1,
                      rotation: Double = 0.2, tilt: Double = 5,
                      baselineID: UUID? = nil, validSeconds: Int = 30,
                      motionGap: Bool = false) -> WalkRecord {
        let positions = (1...(validSeconds * 2)).map {
            WalkSample(time: Double($0) * 0.5, interval: 0.5, speed: speed)
        }
        let motion = (0..<1500).compactMap { i -> MotionSample? in
            if motionGap && i > 200 && i < 1300 { return nil }
            return MotionSample(time: Double(i) / 50, rotation: rotation, acceleration: 0.5, tilt: tilt)
        }
        return WalkRecord(id: UUID(), date: Date(timeIntervalSince1970: 0), kind: kind,
            duration: 30, samples: positions, motion: motion, baselineID: baselineID,
            device: "Test fixture", notes: "")
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
}
