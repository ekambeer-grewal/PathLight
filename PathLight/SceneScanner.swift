import ARKit
import UIKit
import simd

/// Wall labels come from ARKit, never from YOLO's COCO model.
/// Require a facing wall, inside the walking corridor, verified by current LiDAR.
enum WallMeshScanner {
    private struct Hit {
        let reading: DepthSampler.Reading
        let lateral: Double
        let forward: Double
    }

    static func scan(_ frame: ARFrame, viewport: CGSize) -> [Obstacle] {
        guard let sampler = DepthSampler(frame: frame, viewport: viewport),
              let corridor = WalkingCorridor(camera: frame.camera.transform) else { return [] }
        let viewToImage = sampler.imageToView.inverted()
        let inverseCamera = frame.camera.transform.inverse
        var hits: [Hit] = []
        var budget = 3000
        let meshes = frame.anchors.compactMap { $0 as? ARMeshAnchor }.sorted {
            simd_distance($0.transform.columns.3, frame.camera.transform.columns.3)
                < simd_distance($1.transform.columns.3, frame.camera.transform.columns.3)
        }
        for anchor in meshes {
            guard budget > 0 else { break }
            let geometry = anchor.geometry
            guard let classes = geometry.classification,
                  geometry.faces.indexCountPerPrimitive == 3 else { continue }
            let step = max(1, geometry.faces.count / 750)
            for face in stride(from: 0, to: geometry.faces.count, by: step) {
                budget -= 1
                if budget < 0 { break }
                let raw = classes.buffer.contents()
                    .advanced(by: classes.offset + face * classes.stride).load(as: UInt8.self)
                guard ARMeshClassification(rawValue: Int(raw)) == .wall else { continue }
                var vertices: [SIMD3<Float>] = []
                for corner in 0..<3 {
                    let ptr = geometry.faces.buffer.contents()
                        .advanced(by: (face * 3 + corner) * geometry.faces.bytesPerIndex)
                    let index = geometry.faces.bytesPerIndex == 4
                        ? Int(ptr.load(as: UInt32.self)) : Int(ptr.load(as: UInt16.self))
                    let ptrV = geometry.vertices.buffer.contents()
                        .advanced(by: geometry.vertices.offset + index * geometry.vertices.stride)
                    let local = SIMD4<Float>(ptrV.load(as: Float.self),
                        ptrV.advanced(by: 4).load(as: Float.self),
                        ptrV.advanced(by: 8).load(as: Float.self), 1)
                    let world = anchor.transform * local
                    vertices.append(SIMD3<Float>(world.x, world.y, world.z))
                }
                let normal = simd_cross(vertices[1] - vertices[0], vertices[2] - vertices[0])
                guard simd_length(normal) > 0.0001 else { continue }
                let facing = abs(Double(simd_dot(simd_normalize(normal), corridor.forward)))
                guard facing >= 0.55 else { continue } // Reject parallel hallway walls.
                let world = (vertices[0] + vertices[1] + vertices[2]) / 3
                let offset = corridor.offset(world)
                guard NavigationPolicy.inPath(forward: offset.forward, lateral: offset.lateral, wall: true) else { continue }
                let local = inverseCamera * SIMD4<Float>(world.x, world.y, world.z, 1)
                guard local.z < -0.2 else { continue }
                let projected = frame.camera.projectPoint(world, orientation: .portrait, viewportSize: viewport)
                let screen = CGPoint(x: projected.x / viewport.width, y: projected.y / viewport.height)
                guard screen.x > 0, screen.x < 1, screen.y > 0, screen.y < 1,
                      let current = sampler.reading(raw: screen.applying(viewToImage)),
                      current.relativeHeight > -0.85, current.relativeHeight < 0.65,
                      simd_distance(current.world, world) < 0.2 else { continue }
                hits.append(Hit(reading: current, lateral: offset.lateral, forward: offset.forward))
            }
        }
        // Group by distance; never combine two different walls to fabricate a blockage.
        var remaining = hits.sorted { $0.forward < $1.forward }
        var result: [Obstacle] = []
        while !remaining.isEmpty && result.count < 3 {
            let seed = remaining.removeFirst()
            var group = [seed]
            remaining.removeAll {
                let belongs = abs($0.forward - seed.forward) < 0.3
                if belongs { group.append($0) }
                return belongs
            }
            guard group.count >= 5,
                  let low = group.map(\.lateral).min(), let high = group.map(\.lateral).max(),
                  low < 0.15, high > -0.15, high - low >= 0.3 else { continue }
            let ordered = group.sorted { $0.reading.distance < $1.reading.distance }
            let measured = ordered[ordered.count / 4].reading
            let center = group.reduce(SIMD3<Float>.zero) { $0 + $1.reading.world } / Float(group.count)
            let offset = corridor.offset(center)
            let bearing = atan2(offset.lateral, offset.forward) * 180 / .pi
            let minX = max(0, (group.map { $0.reading.screen.x }.min() ?? 0) - 0.02)
            let maxX = min(1, (group.map { $0.reading.screen.x }.max() ?? 1) + 0.02)
            let minY = max(0, (group.map { $0.reading.screen.y }.min() ?? 0) - 0.02)
            let maxY = min(1, (group.map { $0.reading.screen.y }.max() ?? 1) + 0.02)
            result.append(Obstacle(name: "Wall", side: NavigationPolicy.side(bearing: bearing),
                distance: measured.distance,
                bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                worldPosition: center, source: "ARKit wall + LiDAR", observedAt: frame.timestamp,
                bearing: bearing, forwardDistance: offset.forward, lateralDistance: offset.lateral))
        }
        return result
    }
}
