import Foundation

enum Side: String, Codable, CaseIterable {
    case left, center, right
    var pan: Float { self == .left ? -1 : self == .right ? 1 : 0 }
    static func from(screenX: Double) -> Side {
        screenX < 0.38 ? .left : screenX > 0.62 ? .right : .center
    }
}

struct Obstacle: Identifiable {
    var name: String
    var side: Side
    var distance: Double
    var bounds: CGRect = .zero
    var worldPosition: SIMD3<Float> = .zero
    var id: String { name + side.rawValue }
    var phrase: String {
        "\(name), \(String(format: "%.1f", distance)) meters, \(side == .center ? "ahead" : "on your " + side.rawValue)"
    }
}

enum WalkKind: String, Codable {
    case baseline, assessment
    var duration: Double { self == .baseline ? 5 : 30 }
    var minimumDuration: Double { self == .baseline ? 5 : 25 }
}

struct WalkSample: Codable {
    let time: Double
    let interval: Double
    let speed: Double
}

struct MotionSample: Codable {
    let time: Double
    let rotation: Double
    let acceleration: Double
    let tilt: Double
}

struct WalkRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let kind: WalkKind
    let duration: Double
    let samples: [WalkSample]
    let motion: [MotionSample]
    let baselineID: UUID?
    let device: String
    let notes: String
    var algorithmVersion: Int? = nil

    var validSeconds: Double { samples.reduce(0) { $0 + $1.interval } }
    var coverage: Double { min(1, validSeconds / max(duration, 0.001)) }
    var distance: Double { samples.reduce(0) { $0 + $1.speed * $1.interval } }
    var meanSpeed: Double { distance / max(validSeconds, 0.001) }
    var speedSD: Double {
        sqrt(samples.reduce(0) { $0 + pow($1.speed - meanSpeed, 2) * $1.interval } / max(validSeconds, 0.001))
    }
    var rotationRMS: Double { rms(motion.map(\.rotation)) }
    var accelerationRMS: Double { rms(motion.map(\.acceleration)) }
    var meanTilt: Double { motion.map(\.tilt).reduce(0, +) / Double(max(1, motion.count)) }
    var movingFraction: Double {
        samples.filter { $0.speed >= 0.2 }.reduce(0) { $0 + $1.interval } / max(validSeconds, 0.001)
    }
    var motionCoverage: Double {
        // Count only consecutive samples within 100 ms; gaps do not count as coverage.
        guard motion.count > 1 else { return 0 }
        let seconds = zip(motion, motion.dropFirst()).reduce(0.0) { sum, pair in
            let dt = pair.1.time - pair.0.time
            return sum + (dt > 0 && dt <= 0.1 ? dt : 0)
        }
        return min(1, seconds / max(duration, 0.001))
    }
    var qualityIssues: [String] {
        var issues: [String] = []
        if duration < kind.minimumDuration { issues.append("Record at least \(Int(kind.minimumDuration)) seconds.") }
        if coverage < 0.7 { issues.append("Too little usable position tracking (minimum 70%).") }
        if motionCoverage < 0.7 { issues.append("Too little usable motion data (minimum 70%).") }
        if movingFraction < 0.6 { issues.append("Too little walking in the recording (minimum 60%).") }
        return issues
    }
    var usable: Bool { qualityIssues.isEmpty }

    private func rms(_ values: [Double]) -> Double {
        sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(max(1, values.count)))
    }
}

struct Comparison {
    let baseline: WalkRecord
    let current: WalkRecord

    var comparabilityIssues: [String] {
        var issues = baseline.qualityIssues.map { "Baseline: " + $0 }
        issues += current.qualityIssues.map { "Assessment: " + $0 }
        if current.baselineID != baseline.id { issues.append("The selected baseline does not match this assessment.") }
        if (baseline.algorithmVersion ?? 1) != (current.algorithmVersion ?? 1) {
            issues.append("Speed tracking changed. Record a new baseline using this app version.")
        }
        if abs(current.meanTilt - baseline.meanTilt) > 15 {
            issues.append("Phone tilt differs by more than 15 degrees. Match harness placement and repeat.")
        }
        return issues
    }
    var flags: [String] {
        guard comparabilityIssues.isEmpty else { return [] }
        var result: [String] = []
        if abs(current.meanSpeed - baseline.meanSpeed) > max(0.15, baseline.meanSpeed * 0.2) {
            result.append("Average tracked speed changed by more than 20% and 0.15 m/s.")
        }
        if current.speedSD - baseline.speedSD > max(0.08, baseline.speedSD * 0.4) {
            result.append("Within-walk speed variability increased by more than 40% and 0.08 m/s.")
        }
        if abs(current.rotationRMS - baseline.rotationRMS) > max(0.08, baseline.rotationRMS * 0.3) {
            result.append("Phone rotation RMS changed by more than 30% and 0.08 rad/s.")
        }
        if abs(current.accelerationRMS - baseline.accelerationRMS) > max(0.15, baseline.accelerationRMS * 0.3) {
            result.append("Phone acceleration RMS changed by more than 30% and 0.15 m/s².")
        }
        return result
    }
    var headline: String {
        if !comparabilityIssues.isEmpty { return "Repeat recording — comparison unavailable" }
        return flags.isEmpty ? "No demo threshold crossed" : "Movement change — review suggested"
    }
    static let limitation = "Experimental, unvalidated thresholds show changes in phone-derived measurements. They do not detect, diagnose, rule out, or estimate the risk of arthritis or any other disease. A single walk is not an established clinical baseline. Speed, fatigue, route, footwear, turns, and harness movement can change results."
}

struct SavedState: Codable {
    var baseline: WalkRecord?
    var assessments: [WalkRecord] = []
}
