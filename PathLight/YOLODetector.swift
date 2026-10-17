import Foundation
import CoreML
import CoreImage
import CoreVideo
import ARKit

struct ImageDetection {
    let name: String
    let confidence: Double
    /// Top-left-origin normalized coordinates in the ORIGINAL AR camera buffer.
    let imageBounds: CGRect
}

/// Explicit letterboxing keeps model, depth, and preview coordinates consistent.
struct DetectionGeometry {
    let rawSize: CGSize
    let modelSize: CGSize
    var uprightSize: CGSize { CGSize(width: rawSize.height, height: rawSize.width) }
    var scale: CGFloat { min(modelSize.width / uprightSize.width, modelSize.height / uprightSize.height) }
    var padding: CGPoint {
        CGPoint(x: (modelSize.width - uprightSize.width * scale) / 2,
                y: (modelSize.height - uprightSize.height * scale) / 2)
    }

    /// YOLO/NMS outputs center-x, center-y, width, height normalized to the letterboxed input.
    func rawBounds(centerX: Double, centerY: Double, width: Double, height: Double) -> CGRect? {
        guard rawSize.width > 0, rawSize.height > 0, modelSize.width > 0, modelSize.height > 0,
              [centerX, centerY, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        let upright = CGRect(
            x: (CGFloat(centerX - width / 2) * modelSize.width - padding.x) / scale / uprightSize.width,
            y: (CGFloat(centerY - height / 2) * modelSize.height - padding.y) / scale / uprightSize.height,
            width: CGFloat(width) * modelSize.width / scale / uprightSize.width,
            height: CGFloat(height) * modelSize.height / scale / uprightSize.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !upright.isNull, upright.width > 0.005, upright.height > 0.005 else { return nil }
        // Rear camera, portrait: upright image is raw buffer rotated 90° clockwise.
        return CGRect(x: upright.minY, y: 1 - upright.maxX,
                      width: upright.height, height: upright.width)
    }

    static func previewBounds(raw: CGRect, displayTransform: CGAffineTransform) -> CGRect? {
        let result = raw.applying(displayTransform).standardized
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return !result.isNull && result.width > 0.005 && result.height > 0.005 ? result : nil
    }
}

/// Own and call this object on one serial queue. The compiled model and render buffer are reused.
final class YOLODetector {
    private var model: MLModel?
    private var inputBuffer: CVPixelBuffer?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var inputSize = CGSize(width: 384, height: 640)
    private var labels: [String] = []

    func load() throws {
        guard model == nil else { return }
        guard let url = Bundle.main.url(forResource: "yolo11n", withExtension: "mlmodelc") else {
            throw failure("yolo11n.mlmodelc is missing. Add the supplied yolo11n.mlpackage to the PathLight target's Compile Sources, then rebuild.")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let loaded = try MLModel(contentsOf: url, configuration: configuration)
        guard let image = loaded.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              loaded.modelDescription.outputDescriptionsByName["confidence"] != nil,
              loaded.modelDescription.outputDescriptionsByName["coordinates"] != nil else {
            throw failure("Unexpected YOLO model format. Use the bundled YOLO11n NMS model.")
        }
        guard let labelsURL = Bundle.main.url(forResource: "yolo11n-labels", withExtension: "json") else {
            throw failure("yolo11n-labels.json is missing from app resources.")
        }
        labels = try JSONDecoder().decode([String].self, from: Data(contentsOf: labelsURL))
        guard labels.count == 80 else { throw failure("YOLO11n requires the supplied 80-class label list.") }
        inputSize = CGSize(width: image.pixelsWide, height: image.pixelsHigh)
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:],
                                          kCVPixelBufferMetalCompatibilityKey: true]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, image.pixelsWide, image.pixelsHigh,
                                        kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer = buffer else { throw failure("Could not allocate the model input buffer.") }
        inputBuffer = buffer
        model = loaded
    }

    func detect(_ frame: ARFrame) throws -> [ImageDetection] {
        guard let model = model, let buffer = inputBuffer else { throw failure("YOLO11n is not loaded.") }
        let pixels = frame.capturedImage
        let geometry = DetectionGeometry(rawSize: CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)), modelSize: inputSize)
        let upright = CIImage(cvPixelBuffer: pixels).oriented(.right)
        let normalized = upright.transformed(by: CGAffineTransform(translationX: -upright.extent.minX, y: -upright.extent.minY))
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: geometry.scale, y: geometry.scale))
            .transformed(by: CGAffineTransform(translationX: geometry.padding.x, y: geometry.padding.y))
        let canvas = CGRect(origin: .zero, size: inputSize)
        let background = CIImage(color: CIColor(red: 114.0 / 255, green: 114.0 / 255, blue: 114.0 / 255)).cropped(to: canvas)
        context.render(scaled.composited(over: background).cropped(to: canvas), to: buffer, bounds: canvas, colorSpace: colorSpace)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: buffer),
            "iouThreshold": MLFeatureValue(double: 0.45),
            "confidenceThreshold": MLFeatureValue(double: 0.35)])
        let output = try model.prediction(from: input)
        guard let boxes = output.featureValue(for: "coordinates")?.multiArrayValue,
              let scores = output.featureValue(for: "confidence")?.multiArrayValue,
              boxes.shape.count == 2, scores.shape.count == 2,
              boxes.shape[1].intValue == 4, scores.shape[1].intValue == labels.count,
              boxes.shape[0].intValue == scores.shape[0].intValue else {
            throw failure("Unexpected YOLO11n output dimensions.")
        }
        var result: [ImageDetection] = []
        for row in 0..<min(boxes.shape[0].intValue, 100) {
            var bestIndex = 0
            var bestScore = 0.0
            for column in 0..<labels.count {
                let score = scores[[NSNumber(value: row), NSNumber(value: column)]].doubleValue
                if score > bestScore { bestIndex = column; bestScore = score }
            }
            // Filter the winning class; never relabel an unrelated object as a chair/table.
            guard bestScore >= 0.45,
                  labels[bestIndex] == "chair" || labels[bestIndex] == "dining table" else { continue }
            func coordinate(_ column: Int) -> Double { boxes[[NSNumber(value: row), NSNumber(value: column)]].doubleValue }
            guard let raw = geometry.rawBounds(centerX: coordinate(0), centerY: coordinate(1), width: coordinate(2), height: coordinate(3)) else { continue }
            let label = labels[bestIndex] == "dining table" ? "Table" : labels[bestIndex].capitalized
            result.append(ImageDetection(name: label, confidence: bestScore, imageBounds: raw))
        }
        return result
    }

    private func failure(_ description: String) -> NSError {
        NSError(domain: "PathLight.YOLO", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
