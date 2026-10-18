import Foundation
import simd

/// Demo tuning values, in meters and seconds; not a validated safety envelope.
enum NavigationPolicy {
    static let freshness = 0.65
    static func inPath(forward: Double, lateral: Double, wall: Bool = false) -> Bool {
        forward.isFinite && lateral.isFinite && forward >= 0.2 && forward <= 4.5
            && abs(lateral) <= (wall ? 0.55 : 0.95)
    }
    static func lookAhead(speed: Double) -> Double {
        min(4.5, max(3.5, max(0, speed) * 3 + 0.5))
    }
    static func side(bearing: Double, previous: Side? = nil) -> Side {
        // Hysteresis prevents left/ahead/right chatter near a boundary.
        if previous == .left && bearing < -16 { return .left }
        if previous == .right && bearing > 16 { return .right }
        return bearing < -22 ? .left : bearing > 22 ? .right : .center
    }
    static func beepInterval(distance: Double) -> Double {
        let points: [(Double, Double)] = [(0.35, 0.10), (0.75, 0.14), (1, 0.20),
            (1.5, 0.34), (2, 0.55), (3, 1.0), (4.5, 1.8)]
        guard distance.isFinite else { return 1.8 }
        if distance <= points[0].0 { return points[0].1 }
        for index in 1..<points.count {
            let left = points[index - 1], right = points[index]
            if distance <= right.0 {
                let progress = (distance - left.0) / (right.0 - left.0)
                return left.1 + progress * (right.1 - left.1)
            }
        }
        return 1.8
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

/// Condense 50 Hz motion into 0.2-second RMS buckets without losing rotational energy.
struct MotionBucket {
    private var previousTime: Double?
    private var seconds = 0.0
    private var squares = SIMD3<Double>.zero
    private var accelerationSquare = 0.0
    private var tiltSum = 0.0
    private var turnMaximum = 0.0

    mutating func add(time: Double, rotation: SIMD3<Double>, acceleration: Double,
                      tilt: Double, turnRate: Double) -> MotionSample? {
        guard time.isFinite, rotation.x.isFinite, rotation.y.isFinite, rotation.z.isFinite,
              acceleration.isFinite, tilt.isFinite, turnRate.isFinite else { self = MotionBucket(); return nil }
        guard let previous = previousTime else { previousTime = time; return nil }
        let dt = time - previous
        previousTime = time
        guard dt > 0, dt <= 0.1 else { self = MotionBucket(); previousTime = time; return nil }
        seconds += dt
        squares += rotation * rotation * dt
        accelerationSquare += acceleration * acceleration * dt
        tiltSum += tilt * dt
        turnMaximum = max(turnMaximum, turnRate)
        guard seconds >= 0.2 else { return nil }
        let axes = SIMD3<Double>(sqrt(squares.x / seconds), sqrt(squares.y / seconds), sqrt(squares.z / seconds))
        let output = MotionSample(time: time, rotation: sqrt((squares.x + squares.y + squares.z) / seconds),
            acceleration: sqrt(accelerationSquare / seconds), tilt: tiltSum / seconds,
            interval: seconds, rotationX: axes.x, rotationY: axes.y, rotationZ: axes.z, turnRate: turnMaximum)
        seconds = 0; squares = .zero; accelerationSquare = 0; tiltSum = 0; turnMaximum = 0
        return output
    }
}

/// Engineering thresholds, not clinical gait classification. All inputs use SI units.
struct WalkAnalyzer {
    private(set) var events: [WalkEvent] = []
    private var pending: WalkState = .steady
    private var pendingCount = 0
    private var lastTime = -Double.infinity

    mutating func evaluate(time: Double, baseline: WalkRecord, samples: [WalkSample],
                           motion: [MotionSample], contexts: [(Double, WalkContext)]) -> WalkWindow {
        let span = 3.0
        let start = max(0, time - span)
        func overlap(end: Double, length: Double) -> Double {
            max(0, min(time, end) - max(start, end - length))
        }
        let position = samples.suffix(24).map { ($0, overlap(end: $0.time, length: $0.interval)) }
        let gyro = motion.suffix(40).map { ($0, overlap(end: $0.time, length: $0.interval ?? 0.02)) }
        let pSeconds = position.reduce(0.0) { $0 + $1.1 }
        let mSeconds = gyro.reduce(0.0) { $0 + $1.1 }
        let speed = pSeconds > 0 ? position.reduce(0.0) { $0 + $1.0.speed * $1.1 } / pSeconds : nil
        let rotation = mSeconds > 0 ? sqrt(gyro.reduce(0.0) { $0 + pow($1.0.rotation, 2) * $1.1 } / mSeconds) : nil
        let keys: [KeyPath<MotionSample, Double?>] = [\.rotationX, \.rotationY, \.rotationZ]
        let axes = keys.map { key in
            sqrt(gyro.reduce(0.0) { sum, pair in sum + pow(pair.0[keyPath: key] ?? 0, 2) * pair.1 } / max(mSeconds, 0.001))
        }
        let tilt = gyro.reduce(0.0) { $0 + $1.0.tilt * $1.1 } / max(mSeconds, 0.001)
        let turn = gyro.filter { $0.1 > 0 }.map { $0.0.turnRate ?? 0 }.max() ?? 0
        let contextValues = contexts.filter { $0.0 >= start && $0.0 <= time }.map { $0.1 }
        let obstruction = contextValues.last(where: { $0.state == .detected })
            ?? contextValues.last ?? WalkContext()
        let speedChanged = speed.map { abs($0 - baseline.meanSpeed) > max(0.15, baseline.meanSpeed * 0.2) } ?? false
        let baselineAxes = baseline.axisRMS
        let axisChanged = zip(axes, baselineAxes).contains { abs($0.0 - $0.1) > max(0.1, $0.1 * 0.4) }
        let gyroChanged = rotation.map { abs($0 - baseline.rotationRMS) > max(0.08, baseline.rotationRMS * 0.3) } ?? false
        let changedGyro = gyroChanged || axisChanged
        let pCoverage = min(1, pSeconds / span), mCoverage = min(1, mSeconds / span)
        var state: WalkState
        if time < span { state = .warmingUp }
        else if pCoverage < 0.7 || mCoverage < 0.7 { state = .trackingGap }
        else if abs(tilt - baseline.meanTilt) > 15 { state = .mountChanged }
        else if turn >= 0.8 { state = .turning }
        else if speedChanged && (speed ?? 0) < baseline.meanSpeed && obstruction.state == .detected { state = .obstructionSlowdown }
        else if (speed ?? 0) < 0.12 { state = .paused }
        else if speedChanged && changedGyro { state = .combinedChange }
        else if speedChanged { state = .speedChange }
        else if changedGyro { state = .gyroChange }
        else { state = .steady }
        let needsPersistence: [WalkState] = [.combinedChange, .speedChange, .gyroChange, .obstructionSlowdown]
        if needsPersistence.contains(state) {
            pendingCount = pending == state && time - lastTime <= 1.6 ? pendingCount + 1 : 1
            pending = state
            if pendingCount < 2 { state = .warmingUp }
        } else { pending = state; pendingCount = 0 }
        if state.recordsEvent {
            if let index = events.indices.last, events[index].kind == state, time - events[index].end <= 1.6 {
                events[index].end = time
                events[index].speed = speed
                events[index].rotation = rotation
                events[index].gyroAlsoChanged = events[index].gyroAlsoChanged || changedGyro
            } else {
                events.append(WalkEvent(start: max(0, lastTime.isFinite ? lastTime : time - 1), end: time, kind: state,
                    speed: speed, rotation: rotation, obstructionName: obstruction.name, gyroAlsoChanged: changedGyro))
            }
        }
        lastTime = time
        return WalkWindow(time: time, speed: speed, rotation: rotation, axes: axes,
            positionCoverage: pCoverage, motionCoverage: mCoverage, obstruction: obstruction.state,
            obstructionName: obstruction.name, obstructionDistance: obstruction.distance,
            speedChanged: speedChanged, gyroChanged: changedGyro, state: state)
    }
}

/// Points use local coordinates (lateral, height relative to camera, forward), in meters.
/// A forward-facing plane must span the central path and a substantial vertical extent.
enum WallPlaneFit {
    static func inliers(_ points: [SIMD3<Double>]) -> [Int] {
        guard points.count >= 24 else { return [] }
        var best: [Int] = []
        var score = -Double.infinity
        for index in 0..<96 {
            let a = points[(index * 17) % points.count]
            let b = points[(index * 43 + points.count / 2) % points.count]
            let delta = b - a
            let length = sqrt(delta.x * delta.x + delta.z * delta.z)
            guard length > 0.3 else { continue }
            let nx = delta.z / length, nz = -delta.x / length
            guard abs(nz) > 0.55 else { continue } // Parallel hallway walls are not ahead.
            let tolerance = min(0.12, 0.045 + a.z * 0.015)
            let all = points.indices.filter {
                abs((points[$0].x - a.x) * nx + (points[$0].z - a.z) * nz) < tolerance
            }
            guard all.count >= max(20, points.count / 4) else { continue }
            let xs = all.map { points[$0].x }, ys = all.map { points[$0].y }
            guard (xs.min() ?? 0) < -0.18, (xs.max() ?? 0) > 0.18,
                  (ys.max() ?? 0) - (ys.min() ?? 0) > 0.5 else { continue }
            let middle = all.filter { abs(points[$0].x) <= 0.55 && points[$0].z >= 0.2 && points[$0].z <= 4.5 }
            guard middle.count >= 12 else { continue }
            let depths = middle.map { points[$0].z }.sorted()
            let candidateScore = Double(middle.count) / max(depths[depths.count / 2], 0.5)
            if candidateScore > score { score = candidateScore; best = middle }
        }
        return best
    }
}
