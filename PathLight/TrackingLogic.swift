//
//  TrackingLogic.swift
//  PathLight
//
//  Created by Ekambeer Grewal on 10/17/26.
//


import Foundation
import simd

/// Exactly one displayed target. Refresh its geometry during the lock, but never switch early.
struct TargetSelector {
    private(set) var selected: Obstacle?
    private(set) var announcementID = 0
    private(set) var nextSelectionTime = -Double.infinity
    private var reference: Obstacle?
    private var lastAnnounced: Obstacle?
    private var lastSeenTime = -Double.infinity
    let cooldown = 4.0

    private func matches(_ first: Obstacle, _ second: Obstacle) -> Bool {
        first.name == second.name && simd_distance(first.worldPosition, second.worldPosition) < 0.7
    }

    mutating func update(_ candidates: [Obstacle], time: Double) -> Obstacle? {
        if time < nextSelectionTime {
            if let reference = reference,
               let match = candidates.filter({ matches(reference, $0) }).min(by: {
                   simd_distance($0.worldPosition, reference.worldPosition) < simd_distance($1.worldPosition, reference.worldPosition)
               }) {
                selected = match
                lastSeenTime = time
                return match
            }
            // Do not draw or beep an old observation if it is no longer in the current scan.
            selected = nil
            return nil
        }
        guard let nearest = candidates.min(by: { $0.distance < $1.distance }) else {
            selected = nil
            return nil
        }
        let shouldAnnounce: Bool
        if let previous = lastAnnounced {
            shouldAnnounce = !matches(previous, nearest) || previous.side != nearest.side
                || abs(previous.distance - nearest.distance) >= 0.75 || time - lastSeenTime > 4
        } else { shouldAnnounce = true }
        selected = nearest
        reference = nearest
        lastSeenTime = time
        nextSelectionTime = time + cooldown
        if shouldAnnounce {
            announcementID += 1
            lastAnnounced = nearest
        }
        return nearest
    }

    mutating func suspend() {
        selected = nil
        // Preserve the lock and announcement history across temporary tracking loss.
    }
}

struct SpeedMeasurement {
    let startTime: Double
    let endTime: Double
    let rawSpeed: Double
    let displaySpeed: Double
    var interval: Double { endTime - startTime }
}

struct DetectionSpeechGate {
    private var spokenID: Int?
    private var lastEnd = -Double.infinity

    mutating func consume(id: Int, time: Double, speechBusy: Bool) -> Bool {
        guard !speechBusy, id != spokenID, time - lastEnd >= 4 else { return false }
        spokenID = id
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

