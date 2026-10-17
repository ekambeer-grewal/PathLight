import UIKit

enum ReportWriter {
    static func write(baseline: WalkRecord, current: WalkRecord) throws -> URL {
        let comparison = Comparison(baseline: baseline, current: current)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PathLightReports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("PathLight-Walk-\(current.id.uuidString.prefix(8)).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let date = DateFormatter()
        date.dateStyle = .medium
        date.timeStyle = .short
        try renderer.writePDF(to: url) { context in
            var y: CGFloat = 50
            var page = 0
            func newPage() {
                context.beginPage()
                page += 1
                y = 50
                let footer = "PathLight • Experimental walking report • Page \(page)"
                (footer as NSString).draw(at: CGPoint(x: 42, y: 758), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.darkGray])
            }
            func text(_ value: String, size: CGFloat = 11, bold: Bool = false, space: CGFloat = 9) {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
                    .foregroundColor: UIColor.black]
                let height = ceil((value as NSString).boundingRect(with: CGSize(width: 528, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil).height)
                if y + height > 730 { newPage() }
                (value as NSString).draw(in: CGRect(x: 42, y: y, width: 528, height: height + 2), withAttributes: attributes)
                y += height + space
            }
            func metric(_ title: String, _ first: Double, _ second: Double, unit: String) {
                text(String(format: "%@: baseline %.3f %@ | assessment %.3f %@ | change %+.3f %@",
                            title, first, unit, second, unit, second - first, unit))
            }
            newPage()
            text("PATHLIGHT", size: 13, bold: true)
            text("Walking observation report", size: 25, bold: true, space: 16)
            text("For discussion with a clinician. Not a diagnostic or arthritis screening result.", bold: true)
            text("Assessment: \(date.string(from: current.date))\nBaseline: \(date.string(from: baseline.date))\nDevice: \(current.device)\nSetup: chest-mounted, portrait, rear camera forward; level walking.")
            text(comparison.headline, size: 17, bold: true)
            if !comparison.comparabilityIssues.isEmpty {
                for issue in comparison.comparabilityIssues { text("• " + issue) }
                text("Measurements below are descriptive only. No change flag is generated for this pair.")
            } else if comparison.flags.isEmpty {
                text("None of the prototype's change thresholds were crossed. This does not establish normal movement or exclude a medical condition.")
            } else {
                for flag in comparison.flags { text("• " + flag) }
            }
            text("Measurements", size: 16, bold: true)
            metric("Mean tracked speed", baseline.meanSpeed, current.meanSpeed, unit: "m/s")
            metric("Within-walk speed SD", baseline.speedSD, current.speedSD, unit: "m/s")
            metric("Phone rotation RMS", baseline.rotationRMS, current.rotationRMS, unit: "rad/s")
            metric("Phone acceleration RMS", baseline.accelerationRMS, current.accelerationRMS, unit: "m/s²")
            metric("Tracked horizontal distance", baseline.distance, current.distance, unit: "m")
            text(String(format: "Usable position time: baseline %.0f%% | assessment %.0f%%\nUsable motion time: baseline %.0f%% | assessment %.0f%%\nWalking fraction of usable position time: baseline %.0f%% | assessment %.0f%%\nMean phone tilt from upright: baseline %.1f° | assessment %.1f°\nEach recording lasts 30 seconds.",
                        baseline.coverage * 100, current.coverage * 100,
                        baseline.motionCoverage * 100, current.motionCoverage * 100,
                        baseline.movingFraction * 100, current.movingFraction * 100,
                        baseline.meanTilt, current.meanTilt))
            if !baseline.notes.isEmpty || !current.notes.isEmpty {
                text("Participant notes (self-reported)", size: 16, bold: true)
                if !baseline.notes.isEmpty { text("Baseline: " + baseline.notes) }
                if !current.notes.isEmpty { text("Assessment: " + current.notes) }
            }
            text("How this prototype measures movement", size: 16, bold: true)
            text("Camera and motion tracking estimate the phone's horizontal displacement over approximately 0.5-second intervals. LiDAR supplies scene depth for nearby surfaces; speed comes from ARKit world-tracking poses, not changing distance to a single object. Distance is the sum of accepted intervals, not the full route when data is missing. Handset movement is a proxy for the chest, not direct measurement of joints or legs.")
            text("Core Motion records rotation rate and gravity-removed acceleration at a requested 50 Hz. Frames with limited tracking, missing motion, implausible speed (3 m/s or more), gaps, and fast turns (0.8 rad/s or more) are excluded. A 0.05 m/s speed deadband suppresses jitter. RMS means root mean square; SD means standard deviation.")
            text("Quality gate: at least 25 seconds, at least 70% usable position and motion time, and at least 60% walking in accepted position time. Mean tilt must match within 15 degrees. These engineering gates do not establish clinical validity.")
            text("Demo thresholds", size: 16, bold: true)
            text("A flag requires exceeding both the relative and absolute change limits. Speed: 20% and 0.15 m/s (either direction). Speed SD: 40% and 0.08 m/s increase. Rotation RMS: 30% and 0.08 rad/s (either direction). Acceleration RMS: 30% and 0.15 m/s² (either direction). These thresholds were chosen for a hackathon demonstration and are not medically validated.")
            text("Limitations", size: 16, bold: true)
            text(Comparison.limitation)
            text("No joint angles, gait asymmetry, pain, arthritis probability, or disease severity are measured. Lighting, reflective surfaces, tracking drift, body sway, and phone placement affect estimates. Discuss symptoms and observations with a qualified clinician.")
            text("Privacy", size: 16, bold: true)
            text("Processing is on device. The app stores sensor-derived samples and notes locally; it does not save camera images or send reports automatically. This report contains no required patient identifier. Sharing is initiated by the user through the iOS share sheet.")
            text("Baseline ID: \(baseline.id.uuidString)\nAssessment ID: \(current.id.uuidString)\nApp algorithm: PathLight prototype 1.0", size: 9)
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        return url
    }
}
