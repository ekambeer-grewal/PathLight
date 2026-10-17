import Foundation
import simd

/// Demo tuning values, in meters and seconds; not a validated safety envelope.
enum NavigationPolicy {
    static let freshness = 0.65
    static func inPath(forward: Double, lateral: Double, wall: Bool = false) -> Bool {
        forward.isFinite && lateral.isFinite && forward >= 0.2 && forward <= 4.5
            && abs(lateral) <= (wall ? 0.55 : 0.8)
    }
    static func lookAhead(speed: Double) -> Double {
        min(4.5, max(3.5, max(0, speed) * 3 + 0.5))
    }
    static func side(bearing: Double, previous: Side? = nil) -> Side {
        // Hysteresis prevents left/ahead/right chatter near a boundary.
        if previous == .left && bearing < -6 { return .left }
        if previous == .right && bearing > 6 { return .right }
        return bearing < -12 ? .left : bearing > 12 ? .right : .center
    }
    static func beepInterval(distance: Double) -> Double {
        min(1.1, max(0.2, 0.2 + (distance - 0.5) * 0.24))
    }
}

/// Retain one physical target. Only new sensor frames can confirm or refresh a target.
struct TargetSelector {
    private(set) var selected: Obstacle?
    private(set) var announcementID = 0
    private(set) var targetID = 0
    private var lastAnnounced: Obstacle?
    private var pending: Obstacle?
    private var pendingSince = 0.0
    private var pendingFrames = 0

    private func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let area = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - area
        return union > 0 ? Double(area / union) : 0
    }

    private func matches(_ first: Obstacle, _ second: Obstacle) -> Bool {
        guard first.name == second.name else { return false }
        let iou = overlap(first.bounds, second.bounds)
        if first.hasWorldPosition && second.hasWorldPosition {
            let separation = simd_distance(first.worldPosition, second.worldPosition)
            return separation < 0.45 || (separation < 0.9 && iou > 0.25)
        }
        return iou > 0.4
    }

    private func associationCost(_ first: Obstacle, _ second: Obstacle) -> Double {
        Double(simd_distance(first.worldPosition, second.worldPosition))
            + 0.25 * (1 - overlap(first.bounds, second.bounds))
    }

    private mutating func confirmed(_ candidate: Obstacle) -> Bool {
        if let old = pending, matches(old, candidate) {
            if candidate.observedAt > old.observedAt {
                pendingFrames += 1
                pending = candidate
            }
        } else {
            pending = candidate
            pendingSince = candidate.observedAt
            pendingFrames = 1
        }
        // Two independent frames, not two calls using a cached detection.
        return pendingFrames >= 2 && candidate.observedAt - pendingSince >= 0.08
    }

    private mutating func select(_ candidate: Obstacle) {
        selected = candidate
        targetID += 1
        announcementID += 1
        lastAnnounced = candidate
        pending = nil
        pendingFrames = 0
    }

    private func smooth(_ old: Obstacle, _ new: Obstacle) -> Obstacle {
        var value = new
        let dt = max(0.01, new.observedAt - old.observedAt)
        let alpha = CGFloat(min(1, 1 - exp(-dt / 0.2)))
        value.bounds = CGRect(x: old.bounds.minX + alpha * (new.bounds.minX - old.bounds.minX),
            y: old.bounds.minY + alpha * (new.bounds.minY - old.bounds.minY),
            width: old.bounds.width + alpha * (new.bounds.width - old.bounds.width),
            height: old.bounds.height + alpha * (new.bounds.height - old.bounds.height))
        // Do not smooth away an approaching object's closer range.
        value.distance = new.range < old.range ? new.distance : old.range + Double(alpha) * (new.range - old.range)
        value.side = NavigationPolicy.side(bearing: new.bearing, previous: old.side)
        return value
    }

    mutating func update(_ candidates: [Obstacle], time: Double, walkingSpeed: Double = 0) -> Obstacle? {
        let limit = NavigationPolicy.lookAhead(speed: walkingSpeed)
        let valid = candidates.filter {
            ["Chair", "Table", "Wall"].contains($0.name)
                && $0.range.isFinite && $0.range >= 0.2 && $0.range <= 4.8
                && $0.observedAt <= time && time - $0.observedAt <= NavigationPolicy.freshness
                && NavigationPolicy.inPath(forward: $0.forwardDistance, lateral: $0.lateralDistance, wall: $0.name == "Wall")
        }.sorted { $0.range < $1.range }
        if let old = selected {
            let match = valid.filter { matches(old, $0) }.min {
                associationCost(old, $0) < associationCost(old, $1)
            }
            if let match = match, match.observedAt > old.observedAt {
                selected = smooth(old, match)
            }
            if let current = selected, time - current.observedAt <= NavigationPolicy.freshness {
                // A slightly nearer chair must not steal the announcement. A substantially nearer
                // hazard may replace it after confirmation even during the speech cooldown.
                if let challenger = valid.first(where: { !matches(current, $0)
                    && $0.range <= 1.6 && $0.range + 0.7 < current.range }) {
                    if confirmed(challenger) { select(challenger) }
                } else { pending = nil; pendingFrames = 0 }
                if let current = selected, let spoken = lastAnnounced,
                   (current.side != spoken.side || abs(current.range - spoken.range) >= 1.0) {
                    announcementID += 1
                    lastAnnounced = current
                }
                return selected
            }
            selected = nil
        }
        guard let nearest = valid.first(where: { $0.forwardDistance <= limit }) else {
            pending = nil
            pendingFrames = 0
            return nil
        }
        if confirmed(nearest) { select(nearest) }
        return selected
    }

    mutating func suspend() {
        selected = nil
        pending = nil
        pendingFrames = 0
        lastAnnounced = nil
    }
}

struct SpeedMeasurement {
    let startTime: Double
    let endTime: Double
    let rawSpeed: Double
    let displaySpeed: Double
    var interval: Double { endTime - startTime }
}

/// One utterance at a time; confirmed close hazards can bypass repeat-description cooldown.
struct DetectionSpeechGate {
    private var spokenID: Int?
    private var lastEnd = -Double.infinity
    private var lastStart = -Double.infinity

    mutating func consume(id: Int, time: Double, speechBusy: Bool, urgent: Bool = false) -> Bool {
        guard !speechBusy, id != spokenID,
              time - lastStart >= 1.5,
              urgent || time - lastEnd >= 4 else { return false }
        spokenID = id
        lastStart = time
        return true
    }

    mutating func ended(at time: Double) { lastEnd = time }
}

/// Pose-only estimation. Display smoothing never fills gaps in the recorded samples.
struct PoseSpeedTracker {
    private var previous: (position: SIMD3<Float>, time: Double)?
    private var filtered: Double?
    private var acceptedTime: Double?

    mutating func resetContinuity() {
        previous = nil
        filtered = nil
        acceptedTime = nil
    }

    mutating func update(position: SIMD3<Float>, time: Double) -> SpeedMeasurement? {
        guard position.x.isFinite, position.z.isFinite, time.isFinite else {
            resetContinuity()
            return nil
        }
        let planar = SIMD3<Float>(position.x, 0, position.z)
        guard let old = previous else { previous = (planar, time); return nil }
        let dt = time - old.time
        if dt <= 0 { resetContinuity(); previous = (planar, time); return nil }
        guard dt >= 0.25 else { return nil }
        previous = (planar, time)
        guard dt <= 1 else { filtered = nil; acceptedTime = nil; return nil }
        let raw = Double(simd_distance(planar, old.position)) / dt
        guard raw.isFinite, raw < 3 else { filtered = nil; acceptedTime = nil; return nil }
        let measured = raw < 0.05 ? 0 : raw
        let alpha = 1 - exp(-dt / 0.6)
        let smoothed = filtered.map { $0 + alpha * (measured - $0) } ?? measured
        filtered = smoothed
        acceptedTime = time
        return SpeedMeasurement(startTime: old.time, endTime: time, rawSpeed: measured, displaySpeed: smoothed)
    }

    func isFresh(at time: Double) -> Bool {
        guard let accepted = acceptedTime else { return false }
        return time >= accepted && time - accepted < 0.6
    }
}
