import ARKit
import UIKit
import simd

/// Called on the main queue at 4 Hz. Never retains Metal buffer pointers across frames.
enum SceneScanner {
    static let viewport = CGSize(width: 390, height: 844)

    static func scan(_ frame: ARFrame) -> [Obstacle] {
        guard let depth = frame.sceneDepth, let confidence = depth.confidenceMap else { return [] }
        let map = depth.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        CVPixelBufferLockBaseAddress(confidence, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(map, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
        }
        guard let base = CVPixelBufferGetBaseAddress(map),
              let conf = CVPixelBufferGetBaseAddress(confidence) else { return [] }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        let confRow = CVPixelBufferGetBytesPerRow(confidence)
        guard CVPixelBufferGetWidth(confidence) == width,
              CVPixelBufferGetHeight(confidence) == height else { return [] }

        let viewToImage = frame.displayTransform(for: .portrait, viewportSize: viewport).inverted()
        let intrinsics = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution

        // LiDAR values are camera-axis depth. Convert them to radial camera-to-surface distance.
        func reading(at screen: CGPoint) -> (depth: Double, distance: Double, relativeHeight: Double)? {
            let image = screen.applying(viewToImage)
            guard image.x >= 0, image.x < 1, image.y >= 0, image.y < 1 else { return nil }
            let x = Int(image.x * CGFloat(width)), y = Int(image.y * CGFloat(height))
            let quality = conf.advanced(by: y * confRow + x).load(as: UInt8.self)
            guard quality == UInt8(ARConfidenceLevel.high.rawValue) else { return nil }
            let z = Double(base.advanced(by: y * rowBytes + x * 4).load(as: Float.self))
            guard z.isFinite, z >= 0.2, z <= 4.5 else { return nil }
            let rx = (Double(image.x * resolution.width) - Double(intrinsics[2][0])) / Double(intrinsics[0][0])
            let ry = (Double(image.y * resolution.height) - Double(intrinsics[2][1])) / Double(intrinsics[1][1])
            let cameraPoint = SIMD4<Float>(Float(rx * z), Float(-ry * z), Float(-z), 1)
            let worldPoint = frame.camera.transform * cameraPoint
            return (z, z * sqrt(1 + rx * rx + ry * ry), Double(worldPoint.y - frame.camera.transform.columns.3.y))
        }

        // Use the lower 20th percentile of a grid, not a single noisy pixel.
        var ranges: [Side: [Double]] = [:]
        for column in 0..<21 {
            for row in 0..<11 {
                let p = CGPoint(x: 0.08 + Double(column) * 0.042,
                                y: 0.20 + Double(row) * 0.047)
                // Exclude floor/ceiling-like heights from generic proximity cues.
                // This chest-height corridor intentionally does NOT cover low or overhead hazards.
                if let value = reading(at: p), value.relativeHeight > -0.9, value.relativeHeight < 0.8 {
                    ranges[Side.from(screenX: Double(p.x)), default: []].append(value.distance)
                }
            }
        }
        var generic: [Obstacle] = []
        for side in Side.allCases {
            let values = (ranges[side] ?? []).sorted()
            if values.count >= 8 {
                generic.append(Obstacle(name: "Obstacle", side: side, distance: values[values.count / 5]))
            }
        }

        let inverseCamera = frame.camera.transform.inverse
        var groups: [String: [Double]] = [:]
        var groupMetadata: [String: (String, Side)] = [:]
        let meshes = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            .sorted { simd_distance($0.transform.columns.3, frame.camera.transform.columns.3)
                < simd_distance($1.transform.columns.3, frame.camera.transform.columns.3) }
        var budget = 6000
        for anchor in meshes {
            guard budget > 0 else { break }
            let geometry = anchor.geometry
            guard let classes = geometry.classification, geometry.faces.indexCountPerPrimitive == 3 else { continue }
            let step = max(1, geometry.faces.count / 450)
            for face in stride(from: 0, to: geometry.faces.count, by: step) {
                budget -= 1
                if budget < 0 { break }
                let raw = classes.buffer.contents().advanced(by: classes.offset + face * classes.stride).load(as: UInt8.self)
                let name: String
                switch ARMeshClassification(rawValue: Int(raw)) {
                case .door: name = "Door"
                case .seat: name = "Seat"
                case .table: name = "Table"
                default: continue
                }
                var center = SIMD3<Float>(repeating: 0)
                for corner in 0..<3 {
                    let ptr = geometry.faces.buffer.contents().advanced(by: (face * 3 + corner) * geometry.faces.bytesPerIndex)
                    let index = geometry.faces.bytesPerIndex == 4 ? Int(ptr.load(as: UInt32.self)) : Int(ptr.load(as: UInt16.self))
                    let vertex = geometry.vertices.buffer.contents().advanced(by: geometry.vertices.offset + index * geometry.vertices.stride)
                    center += SIMD3<Float>(vertex.load(as: Float.self), vertex.advanced(by: 4).load(as: Float.self), vertex.advanced(by: 8).load(as: Float.self)) / 3
                }
                let world = anchor.transform * SIMD4<Float>(center.x, center.y, center.z, 1)
                let local = inverseCamera * world
                guard local.z < -0.2, local.z > -4.5 else { continue }
                let point = frame.camera.projectPoint(SIMD3<Float>(world.x, world.y, world.z), orientation: .portrait, viewportSize: viewport)
                let screen = CGPoint(x: point.x / viewport.width, y: point.y / viewport.height)
                guard screen.x > 0.05, screen.x < 0.95, screen.y > 0.15, screen.y < 0.85,
                      let current = reading(at: screen),
                      abs(current.depth - Double(-local.z)) < 0.25 else { continue }
                let side = Side.from(screenX: Double(screen.x))
                let key = name + side.rawValue
                groups[key, default: []].append(current.distance)
                groupMetadata[key] = (name, side)
            }
        }
        var labeled: [Obstacle] = []
        for (key, values) in groups where values.count >= 3 {
            guard let (name, side) = groupMetadata[key] else { continue }
            let sorted = values.sorted()
            labeled.append(Obstacle(name: name, side: side, distance: sorted[sorted.count / 5]))
        }
        // Keep a generic alert if it is materially closer than a named surface in that sector.
        let additional = generic.filter { obstacle in
            !labeled.contains { $0.side == obstacle.side && $0.distance <= obstacle.distance + 0.35 }
        }
        return (labeled + additional).filter { $0.distance <= 4 }.sorted { $0.distance < $1.distance }
    }
}
