import Foundation

enum DistanceUnit: String, CaseIterable, Identifiable {
    case meters, feet
    var id: String { rawValue }
    static var current: DistanceUnit {
        DistanceUnit(rawValue: UserDefaults.standard.string(forKey: "distance-unit") ?? "meters") ?? .meters
    }
    func value(_ meters: Double) -> Double { self == .meters ? meters : meters * 3.280839895 }
    var symbol: String { self == .meters ? "m" : "ft" }
    func label(_ meters: Double) -> String { String(format: "%.1f %@", value(meters), symbol) }
    func spoken(_ meters: Double) -> String { String(format: "%.1f %@", value(meters), rawValue) }
}

enum Side: String, Codable, CaseIterable {
    case left, center, right
    var pan: Float { self == .left ? -1 : self == .right ? 1 : 0 }
    static func from(screenX: Double) -> Side {
        screenX < 0.30 ? .left : screenX > 0.70 ? .right : .center
    }
}

struct Obstacle: Identifiable {
    var name: String
    var side: Side
    var distance: Double?
    var bounds: CGRect = .zero
    var worldPosition: SIMD3<Float> = .zero
    var hasWorldPosition = true
    var source = "ARKit"
    var confidence: Double? = nil
    // Capture timestamps, not callback timestamps: repeated UI refreshes cannot revive old data.
    var observedAt = 0.0
    var bearing = 0.0
    var forwardDistance = 0.0
    var lateralDistance = 0.0
    var range: Double { distance ?? .infinity }
    var distanceText: String { distance.map { DistanceUnit.current.label($0) } ?? "Distance unavailable" }
    var id: String { name + side.rawValue }
    var phrase: String {
        let direction = side == .center ? "ahead" : "on your " + side.rawValue
        if let distance = distance { return "\(name) \(direction), \(DistanceUnit.current.spoken(distance))" }
        return "\(name), \(direction). Distance unavailable."
    }
}

enum WalkKind: String, Codable {
    case baseline, assessment
    // Only a baseline has a deadline; assessments end through End walk.
    var duration: Double { self == .baseline ? 5 : .infinity }
    var minimumDuration: Double { 5 }
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
    // Version 3 stores time-weighted 0.2-second buckets from 50 Hz motion, not decimated peaks.
    var interval: Double? = nil
    var rotationX: Double? = nil
    var rotationY: Double? = nil
    var rotationZ: Double? = nil
    var turnRate: Double? = nil
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
    var windows: [WalkWindow]? = nil
    var events: [WalkEvent]? = nil
    var endReason: String? = nil

    var validSeconds: Double { samples.reduce(0) { $0 + $1.interval } }
    var coverage: Double { min(1, validSeconds / max(duration, 0.001)) }
    var distance: Double { samples.reduce(0) { $0 + $1.speed * $1.interval } }
    var meanSpeed: Double { distance / max(validSeconds, 0.001) }
    var speedSD: Double {
        sqrt(samples.reduce(0) { $0 + pow($1.speed - meanSpeed, 2) * $1.interval } / max(validSeconds, 0.001))
    }
    var rotationRMS: Double {
        let total = motion.reduce(0.0) { $0 + ($1.interval ?? 0.02) }
        return sqrt(motion.reduce(0.0) { $0 + $1.rotation * $1.rotation * ($1.interval ?? 0.02) } / max(total, 0.001))
    }
    var axisRMS: [Double] {
        [\MotionSample.rotationX, \MotionSample.rotationY, \MotionSample.rotationZ].map { key in
            let usable = motion.filter { $0[keyPath: key] != nil }
            let total = usable.reduce(0.0) { $0 + ($1.interval ?? 0.02) }
            return sqrt(usable.reduce(0.0) { sum, sample in
                let value = sample[keyPath: key] ?? 0
                return sum + value * value * (sample.interval ?? 0.02)
            } / max(total, 0.001))
        }
    }
    var durationText: String { Self.clock(duration) }
    static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
    var abnormalMovementEvents: [WalkEvent] { (events ?? []).filter(\.isAbnormalMovement) }
    var reviewEvents: [WalkEvent] { abnormalMovementEvents }
    var trackedDistanceText: String { DistanceUnit.current.label(distance) }
    var accelerationRMS: Double { rms(motion.map(\.acceleration)) }
    var meanTilt: Double { motion.map(\.tilt).reduce(0, +) / Double(max(1, motion.count)) }
    var movingFraction: Double {
        samples.filter { $0.speed >= 0.2 }.reduce(0) { $0 + $1.interval } / max(validSeconds, 0.001)
    }
    var motionCoverage: Double {
        if motion.contains(where: { $0.interval != nil }) {
            return min(1, motion.reduce(0.0) { $0 + ($1.interval ?? 0) } / max(duration, 0.001))
        }
        // Legacy recordings used individual 50 Hz motion samples.
        guard motion.count > 1 else { return 0 }
        let seconds = zip(motion, motion.dropFirst()).reduce(0.0) { sum, pair in
            let dt = pair.1.time - pair.0.time
            return sum + (dt > 0 && dt <= 0.1 ? dt : 0)
        }
        return min(1, seconds / max(duration, 0.001))
    }
    var qualityIssues: [String] {
        var issues: [String] = []
        let minimum = kind == .assessment && (algorithmVersion ?? 1) < 3 ? 25.0 : kind.minimumDuration
        if duration < minimum { issues.append("Record at least \(Int(minimum)) seconds.") }
        if coverage < 0.7 { issues.append("Too little usable position tracking (minimum 70%).") }
        if motionCoverage < 0.7 { issues.append("Too little usable motion data (minimum 70%).") }
        if (kind == .baseline || (algorithmVersion ?? 1) < 3) && movingFraction < 0.6 { issues.append("Too little walking in the recording (minimum 60%).") }
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
        if (current.algorithmVersion ?? 1) >= 3 {
            return current.abnormalMovementEvents.map {
                "Abnormal movement at " + WalkTimestamp.string(current.date.addingTimeInterval($0.start))
            }
        }
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
        if (current.algorithmVersion ?? 1) >= 3 {
            return flags.isEmpty ? "No abnormal movement flagged" : "Abnormal movement — review suggested"
        }
        return flags.isEmpty ? "No movement change flagged" : "Movement change — review suggested"
    }
    static let limitation = "Experimental, unvalidated thresholds show changes in phone-derived measurements. They do not detect, diagnose, rule out, or estimate the risk of arthritis or any other disease. A single walk is not an established clinical baseline. Speed, fatigue, route, footwear, turns, and harness movement can change results."
}

struct SavedState: Codable {
    var baseline: WalkRecord?
    var assessments: [WalkRecord] = []
    // Optional so archives made before monthly reporting continue to decode.
    var baselineHistory: [WalkRecord]? = nil

    func baseline(for record: WalkRecord) -> WalkRecord? {
        guard let id = record.baselineID else { return nil }
        if baseline?.id == id { return baseline }
        return baselineHistory?.first { $0.id == id }
    }

    mutating func replaceBaseline(with record: WalkRecord) {
        if let previous = baseline, previous.id != record.id {
            var history = baselineHistory ?? []
            if !history.contains(where: { $0.id == previous.id }) { history.append(previous) }
            baselineHistory = history
        }
        baseline = record
    }
}


enum WalkState: String, Codable, CaseIterable {
    case steady, speedChange, gyroChange, combinedChange, obstructionSlowdown
    case turning, paused, trackingGap, mountChanged, warmingUp
    var title: String {
        switch self {
        case .steady: return "Within demo thresholds"
        case .speedChange: return "Speed change"
        case .gyroChange: return "Gyroscope change"
        // Keep the stored raw value for compatibility with existing recordings.
        case .combinedChange: return "Abnormal movement"
        case .obstructionSlowdown: return "Slowdown near obstruction"
        case .turning: return "Turning"
        case .paused: return "Pause / very slow movement"
        case .trackingGap: return "Tracking gap"
        case .mountChanged: return "Harness angle changed"
        case .warmingUp: return "Gathering a walking window"
        }
    }
    var recordsEvent: Bool { self != .steady && self != .warmingUp }
}

enum ObstructionState: String, Codable { case detected, noneDetected, unavailable }
struct WalkContext {
    var state: ObstructionState = .unavailable
    var name: String? = nil
    var distance: Double? = nil
}
struct WalkWindow: Codable, Identifiable {
    var id: Double { time }
    let time: Double
    let speed: Double?
    let rotation: Double?
    let axes: [Double]
    let positionCoverage: Double
    let motionCoverage: Double
    let obstruction: ObstructionState
    let obstructionName: String?
    let obstructionDistance: Double?
    let speedChanged: Bool
    let gyroChanged: Bool
    var state: WalkState
}
struct WalkEvent: Codable, Identifiable {
    var id: Double { start }
    var start: Double
    var end: Double
    let kind: WalkState
    var speed: Double?
    var rotation: Double?
    var obstructionName: String?
    var gyroAlsoChanged: Bool
    // Readings are from the last confirmed window, not peak values or a whole-event average.
    // Optional additions preserve decoding of older saved events.
    var measuredAt: Double? = nil
    var axes: [Double]? = nil
    var baselineSpeed: Double? = nil
    var baselineRotation: Double? = nil
    var baselineAxes: [Double]? = nil
    var contextLabels: [String]? = nil
    var duration: Double { max(0, end - start) }
    var isAbnormalMovement: Bool { kind == .combinedChange }
}

/// Shared engineering thresholds for live classification and report explanations.
enum WalkThresholds {
    static let windowSeconds = 3.0
    static let minimumCoverage = 0.7
    static let maximumEvaluationGap = 1.6
    static func speed(_ baseline: Double) -> Double { max(0.15, baseline * 0.2) }
    static func rotation(_ baseline: Double) -> Double { max(0.08, baseline * 0.3) }
    static func axis(_ baseline: Double) -> Double { max(0.10, baseline * 0.4) }
    static let explanation = "Abnormal movement means both speed and gyroscope changes exceeded their baseline thresholds in two consecutive evaluations of 3-second windows. Speed: >20% and >0.15 m/s. Gyro RMS: >30% and >0.08 rad/s, or an axis: >40% and >0.10 rad/s. These are unvalidated sensor flags, not a diagnosis."
}

enum WalkTimestamp {
    static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss XXX"
        return formatter.string(from: date)
    }
}

/// Only confirmed abnormal events enter this report. Month membership uses event onset,
/// not the date the walk began, so walks spanning midnight/month boundaries are handled.
struct MonthlyMovementReport {
    struct Entry: Identifiable {
        let walkID: UUID
        let walkDate: Date
        let baselineID: UUID?
        let event: WalkEvent
        var id: String { "\(walkID.uuidString)-\(event.start)" }
        var date: Date { walkDate.addingTimeInterval(event.start) }
        var endDate: Date { walkDate.addingTimeInterval(event.end) }
    }
    struct Day {
        let number: Int
        let count: Int
        let seconds: Double
    }
    let month: Date
    let calendar: Calendar
    let entries: [Entry]

    init(records: [WalkRecord], month: Date, calendar: Calendar = .current) {
        self.calendar = calendar
        let interval = calendar.dateInterval(of: .month, for: month)
            ?? DateInterval(start: month, duration: 0)
        self.month = interval.start
        entries = records.filter { $0.kind == .assessment }.flatMap { record in
            record.abnormalMovementEvents.compactMap { event -> Entry? in
                guard event.start.isFinite, event.end.isFinite,
                      event.start >= 0, event.end >= event.start else { return nil }
                let entry = Entry(walkID: record.id, walkDate: record.date,
                                  baselineID: record.baselineID, event: event)
                guard entry.date >= interval.start, entry.date < interval.end else { return nil }
                return entry
            }
        }.sorted { $0.date < $1.date }
    }

    var walkCount: Int { Set(entries.map(\.walkID)).count }
    var totalSeconds: Double { entries.reduce(0) { $0 + $1.event.duration } }
    var days: [Day] {
        let grouped = Dictionary(grouping: entries) { calendar.component(.day, from: $0.date) }
        return (calendar.range(of: .day, in: .month, for: month) ?? 1..<1).map { day in
            let values = grouped[day] ?? []
            return Day(number: day, count: values.count, seconds: values.reduce(0) { $0 + $1.event.duration })
        }
    }
    var title: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: month)
    }
    static func availableMonths(records: [WalkRecord], now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        let dates = [now] + records.map(\.date) + records.flatMap { record in
            record.abnormalMovementEvents.filter { $0.start.isFinite && $0.start >= 0 }
                .map { record.date.addingTimeInterval($0.start) }
        }
        return Array(Set(dates.compactMap { calendar.dateInterval(of: .month, for: $0)?.start })).sorted(by: >)
    }
}
