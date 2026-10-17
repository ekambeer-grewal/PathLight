import ARKit
import CoreVideo
import UIKit
import simd

/// Short-lived, read-only mapping of the depth/confidence buffers belonging to one AR frame.
final class DepthSampler {
    struct Reading {
        let distance: Double
        let world: SIMD3<Float>
        let screen: CGPoint
        let relativeHeight: Double
    }
    private let depth: CVPixelBuffer
    private let confidence: CVPixelBuffer
    private let depthBase: UnsafeMutableRawPointer
    private let confidenceBase: UnsafeMutableRawPointer
    private let width: Int
    private let height: Int
    private let depthStride: Int
    private let confidenceStride: Int
    private let intrinsics: simd_float3x3
    private let cameraTransform: simd_float4x4
    private let resolution: CGSize
    let imageToView: CGAffineTransform

    init?(frame: ARFrame, viewport: CGSize) {
        guard let data = frame.sceneDepth, let quality = data.confidenceMap,
              viewport.width > 0, viewport.height > 0 else { return nil }
        let depthBuffer = data.depthMap
        let confidenceBuffer = quality
        guard CVPixelBufferLockBaseAddress(depthBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        guard CVPixelBufferLockBaseAddress(confidenceBuffer, .readOnly) == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly)
            return nil
        }
        guard let base = CVPixelBufferGetBaseAddress(depthBuffer), let conf = CVPixelBufferGetBaseAddress(confidenceBuffer),
              CVPixelBufferGetWidth(depthBuffer) == CVPixelBufferGetWidth(confidenceBuffer),
              CVPixelBufferGetHeight(depthBuffer) == CVPixelBufferGetHeight(confidenceBuffer) else {
            CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceBuffer, .readOnly)
            return nil
        }
        depth = depthBuffer
        confidence = confidenceBuffer
        depthBase = base
        confidenceBase = conf
        width = CVPixelBufferGetWidth(depthBuffer)
        height = CVPixelBufferGetHeight(depthBuffer)
        depthStride = CVPixelBufferGetBytesPerRow(depthBuffer)
        confidenceStride = CVPixelBufferGetBytesPerRow(confidenceBuffer)
        intrinsics = frame.camera.intrinsics
        cameraTransform = frame.camera.transform
        resolution = frame.camera.imageResolution
        imageToView = frame.displayTransform(for: .portrait, viewportSize: viewport)
    }

    deinit {
        CVPixelBufferUnlockBaseAddress(depth, .readOnly)
        CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
    }

    func reading(raw: CGPoint) -> Reading? {
        guard raw.x >= 0, raw.x < 1, raw.y >= 0, raw.y < 1 else { return nil }
        let x = Int(raw.x * CGFloat(width)), y = Int(raw.y * CGFloat(height))
        let quality = confidenceBase.advanced(by: y * confidenceStride + x).load(as: UInt8.self)
        guard quality >= UInt8(ARConfidenceLevel.medium.rawValue) else { return nil }
        let z = Double(depthBase.advanced(by: y * depthStride + x * MemoryLayout<Float>.size).load(as: Float.self))
        guard z.isFinite, z >= 0.2, z <= 5 else { return nil }
        let rx = (Double(raw.x * resolution.width) - Double(intrinsics[2][0])) / Double(intrinsics[0][0])
        let ry = (Double(raw.y * resolution.height) - Double(intrinsics[2][1])) / Double(intrinsics[1][1])
        let world4 = cameraTransform * SIMD4<Float>(Float(rx * z), Float(-ry * z), Float(-z), 1)
        return Reading(distance: z * sqrt(1 + rx * rx + ry * ry),
            world: SIMD3<Float>(world4.x, world4.y, world4.z), screen: raw.applying(imageToView),
            relativeHeight: Double(world4.y - cameraTransform.columns.3.y))
    }

    func range(in box: CGRect) -> Reading? {
        // The inset reduces background at box edges; this is still approximate box-based ranging.
        let inset = box.insetBy(dx: box.width * 0.18, dy: box.height * 0.18)
        var readings: [Reading] = []
        for row in 0..<7 {
            for column in 0..<7 {
                let raw = CGPoint(x: inset.minX + inset.width * CGFloat(column) / 6,
                                  y: inset.minY + inset.height * CGFloat(row) / 6)
                if let value = reading(raw: raw) { readings.append(value) }
            }
        }
        guard readings.count >= 6 else { return nil }
        readings.sort { $0.distance < $1.distance }
        let near = readings[readings.count / 5].distance
        let coherent = readings.filter { abs($0.distance - near) <= max(0.18, near * 0.1) }
        guard coherent.count >= 4 else { return nil }
        return coherent[coherent.count / 2]
    }

    static func objects(_ detections: [ImageDetection], frame: ARFrame, viewport: CGSize) -> [Obstacle] {
        guard let sampler = DepthSampler(frame: frame, viewport: viewport),
              let corridor = WalkingCorridor(camera: frame.camera.transform) else { return [] }
        return detections.compactMap { detection in
            guard detection.name == "Chair" || detection.name == "Table",
                  let bounds = DetectionGeometry.previewBounds(raw: detection.imageBounds,
                      displayTransform: sampler.imageToView),
                  let range = sampler.range(in: detection.imageBounds) else { return nil }
            let offset = corridor.offset(range.world)
            // A fixed-width corridor avoids treating the entire camera view as the walking path.
            guard NavigationPolicy.inPath(forward: offset.forward, lateral: offset.lateral),
                  range.relativeHeight > -1.25, range.relativeHeight < 0.8 else { return nil }
            let bearing = atan2(offset.lateral, offset.forward) * 180 / .pi
            return Obstacle(name: detection.name, side: NavigationPolicy.side(bearing: bearing),
                distance: range.distance, bounds: bounds, worldPosition: range.world,
                source: "YOLO11n + LiDAR", confidence: detection.confidence,
                observedAt: frame.timestamp, bearing: bearing,
                forwardDistance: offset.forward, lateralDistance: offset.lateral)
        }
    }
}

/// Gravity-aligned direction of the chest-mounted rear camera.
struct WalkingCorridor {
    let origin: SIMD3<Float>
    let forward: SIMD3<Float>
    let right: SIMD3<Float>

    init?(camera: simd_float4x4) {
        origin = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let direction = SIMD3<Float>(-camera.columns.2.x, 0, -camera.columns.2.z)
        guard simd_length(direction) > 0.5 else { return nil }
        forward = simd_normalize(direction)
        right = simd_cross(forward, SIMD3<Float>(0, 1, 0))
    }

    func offset(_ point: SIMD3<Float>) -> (forward: Double, lateral: Double) {
        let delta = point - origin
        return (Double(simd_dot(delta, forward)), Double(simd_dot(delta, right)))
    }
}
