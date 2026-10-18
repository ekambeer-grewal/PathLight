import UIKit

// The app and PDF use the same chart renderer and underlying measurements.
enum WalkChartKind: String, CaseIterable {
    case speed, rotation, timeline, axes
    var title: String {
        switch self {
        case .speed: return "Walking speed"
        case .rotation: return "Gyroscope movement"
        case .timeline: return "Walk timeline"
        case .axes: return "Gyroscope by axis"
        }
    }
}

enum WalkCharts {
    private struct Point { let time: Double; let value: Double? }
    static func color(_ state: WalkState) -> UIColor {
        switch state {
        case .steady: return .systemGreen
        case .combinedChange: return .systemPink
        case .obstructionSlowdown: return .systemOrange
        case .speedChange: return .systemCyan
        case .gyroChange: return .systemPurple
        case .turning, .paused: return .systemYellow
        case .mountChanged: return .systemRed
        case .trackingGap, .warmingUp: return .systemGray
        }
    }

    static func image(record: WalkRecord, baseline: WalkRecord, kind: WalkChartKind) -> UIImage {
        let size = CGSize(width: 360, height: kind == .timeline ? 140 : 230)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            draw(record: record, baseline: baseline, kind: kind,
                 rect: CGRect(origin: .zero, size: size), context: renderer.cgContext, dark: true)
        }
    }

    static func draw(record: WalkRecord, baseline: WalkRecord, kind: WalkChartKind,
                     rect: CGRect, context: CGContext, dark: Bool) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        let width = rect.width, height = rect.height
        let foreground: UIColor = dark ? .white : .black
        let secondary: UIColor = dark ? .lightGray : .darkGray
        let background = dark ? UIColor(white: 0.085, alpha: 1) : UIColor.white
        background.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func text(_ value: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 11, color: UIColor? = nil) {
            (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
                .foregroundColor: color ?? secondary])
        }
        text(kind.title, 12, 8, size: 16, color: foreground)
        let plot = CGRect(x: 52, y: 42, width: width - 72, height: height - 80)
        let duration = max(record.duration, 1)
        func x(_ time: Double) -> CGFloat { plot.minX + CGFloat(min(1, max(0, time / duration))) * plot.width }
        func axisTimes() {
            for fraction in [0.0, 0.5, 1.0] {
                text(WalkRecord.clock(duration * fraction), x(duration * fraction) - 12, plot.maxY + 8, size: 10)
            }
            text("elapsed", max(12, width - 63), height - 16, size: 9)
        }
        if kind == .timeline {
            let windows = record.windows ?? []
            if windows.isEmpty { text("Timeline unavailable for this recording", 12, 55); return }
            for (index, window) in windows.enumerated() {
                let start = index == 0 ? 0 : windows[index - 1].time
                color(window.state).setFill()
                context.fill(CGRect(x: x(start), y: plot.minY + 6,
                    width: max(1, x(window.time) - x(start)), height: max(14, plot.height - 12)))
            }
            axisTimes()
            return
        }
        if kind == .axes {
            let current = record.axisRMS, reference = baseline.axisRMS
            guard record.motion.contains(where: { $0.rotationX != nil }) else {
                text("Axis data unavailable - record a new walk", 12, 60); return
            }
            let maximum = max(0.1, (current + reference).max() ?? 0.1) * 1.2
            let colors: [UIColor] = [.systemPink, .systemGreen, .systemCyan]
            for index in 0..<3 {
                let middle = plot.minX + plot.width * (CGFloat(index) + 0.5) / 3
                let oldHeight = CGFloat(reference[index] / maximum) * plot.height
                let newHeight = CGFloat(current[index] / maximum) * plot.height
                UIColor.systemGray.setFill()
                context.fill(CGRect(x: middle - 27, y: plot.maxY - oldHeight, width: 22, height: oldHeight))
                colors[index].setFill()
                context.fill(CGRect(x: middle + 5, y: plot.maxY - newHeight, width: 22, height: newHeight))
                text(["X", "Y", "Z"][index], middle - 4, plot.maxY + 7)
                text(String(format: "%.2f", current[index]), middle - 14, max(plot.minY, plot.maxY - newHeight - 17), size: 10)
            }
            text("rad/s RMS · gray = baseline · color = walk", 12, height - 17, size: 10)
            return
        }
        let speed = kind == .speed
        var points: [Point]
        if let windows = record.windows, !windows.isEmpty {
            points = windows.map {
                let coverage = speed ? $0.positionCoverage : $0.motionCoverage
                return Point(time: $0.time, value: coverage >= 0.7 ? (speed ? $0.speed : $0.rotation) : nil)
            }
        } else if speed {
            points = record.samples.map { Point(time: $0.time, value: $0.speed) }
        } else {
            points = record.motion.map { Point(time: $0.time, value: $0.rotation) }
        }
        let reference = speed ? baseline.meanSpeed : baseline.rotationRMS
        let threshold = speed ? max(0.15, reference * 0.2) : max(0.08, reference * 0.3)
        let maximum = max(0.15, max(reference + threshold, points.compactMap(\.value).max() ?? 0)) * 1.15
        func y(_ value: Double) -> CGFloat { plot.maxY - CGFloat(value / maximum) * plot.height }
        let tint: UIColor = speed ? .systemGreen : .systemCyan
        tint.withAlphaComponent(dark ? 0.12 : 0.08).setFill()
        context.fill(CGRect(x: plot.minX, y: y(reference + threshold), width: plot.width,
            height: y(max(0, reference - threshold)) - y(reference + threshold)))
        for fraction in [0.0, 0.5, 1.0] {
            let value = maximum * fraction
            context.setStrokeColor(secondary.withAlphaComponent(0.2).cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: plot.minX, y: y(value)))
            context.addLine(to: CGPoint(x: plot.maxX, y: y(value)))
            context.strokePath()
            text(String(format: "%.2f", value), 8, y(value) - 6, size: 10)
        }
        context.setStrokeColor(secondary.cgColor)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.move(to: CGPoint(x: plot.minX, y: y(reference)))
        context.addLine(to: CGPoint(x: plot.maxX, y: y(reference)))
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        // Keep extreme values during downsampling; missing buckets break the line.
        let strideSize = max(1, Int(ceil(Double(points.count) / 900)))
        if strideSize > 1 {
            var reduced: [Point] = []
            for first in stride(from: 0, to: points.count, by: strideSize) {
                let bucket = Array(points[first..<min(points.count, first + strideSize)])
                if bucket.contains(where: { $0.value == nil }) {
                    reduced.append(Point(time: bucket[0].time, value: nil))
                } else if let low = bucket.min(by: { ($0.value ?? 0) < ($1.value ?? 0) }),
                          let high = bucket.max(by: { ($0.value ?? 0) < ($1.value ?? 0) }) {
                    reduced += [low, high].sorted { $0.time < $1.time }
                }
            }
            points = reduced
        }
        context.setStrokeColor(tint.cgColor)
        context.setLineWidth(2)
        var connected = false
        var lastTime = -Double.infinity
        for point in points {
            guard let value = point.value else { connected = false; continue }
            let coordinate = CGPoint(x: x(point.time), y: y(value))
            let expectedGap = record.windows == nil ? 1.0 : max(2.0, Double(strideSize) * 2)
            if connected && point.time - lastTime <= expectedGap { context.addLine(to: coordinate) }
            else { context.move(to: coordinate) }
            connected = true
            lastTime = point.time
        }
        context.strokePath()
        for event in (record.events ?? []).filter({ $0.kind == .combinedChange || $0.kind == .obstructionSlowdown }) {
            color(event.kind).setFill()
            context.fillEllipse(in: CGRect(x: x(event.start) - 3, y: plot.maxY - 3, width: 6, height: 6))
        }
        axisTimes()
        text(speed ? "m/s" : "rad/s RMS", 12, 28, size: 9)
        text("dashed = baseline · band = demo threshold", 12, height - 17, size: 9)
        if points.compactMap(\.value).isEmpty { text("Not enough usable data", plot.minX + 10, plot.midY, color: foreground) }
    }
}

enum ReportWriter {
    static func write(baseline: WalkRecord, current: WalkRecord) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PathLightReports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("PathLight-Walk-\(current.id.uuidString.prefix(8)).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: url) { pdf in
            var page = 0
            func label(_ text: String, _ rect: CGRect, size: CGFloat = 11, bold: Bool = false, color: UIColor = .black) {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                (text as NSString).draw(in: rect, withAttributes: [
                    .font: UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                    .foregroundColor: color, .paragraphStyle: paragraph])
            }
            func newPage(_ subtitle: String) {
                pdf.beginPage(); page += 1
                label("PATHLIGHT / WALK SUMMARY", CGRect(x: 36, y: 25, width: 540, height: 18), size: 11, bold: true)
                label(subtitle, CGRect(x: 36, y: 49, width: 540, height: 30), size: 24, bold: true)
                label("Experimental movement observations - not a diagnosis. Page \(page)",
                      CGRect(x: 36, y: 760, width: 540, height: 15), size: 9, color: .darkGray)
            }
            func chart(_ kind: WalkChartKind, y: CGFloat, height: CGFloat) {
                WalkCharts.draw(record: current, baseline: baseline, kind: kind,
                    rect: CGRect(x: 36, y: y, width: 540, height: height), context: pdf.cgContext, dark: false)
            }
            newPage(current.date.formatted(date: .abbreviated, time: .shortened))
            let metrics = [("DURATION", current.durationText), ("TRACKED DISTANCE", current.trackedDistanceText),
                           ("MEAN SPEED", String(format: "%.2f m/s", current.meanSpeed)),
                           ("COMBINED EVENTS", "\(current.reviewEvents.count)")]
            for (index, metric) in metrics.enumerated() {
                let x = 36 + CGFloat(index) * 137
                label(metric.0, CGRect(x: x, y: 92, width: 132, height: 16), size: 8, color: .darkGray)
                label(metric.1, CGRect(x: x, y: 112, width: 132, height: 28), size: 21, bold: true)
            }
            chart(.speed, y: 153, height: 205)
            chart(.rotation, y: 364, height: 205)
            chart(.timeline, y: 578, height: 110)
            label("Pink: combined change   Orange: obstruction slowdown   Green: within thresholds\nCyan: speed change   Purple: gyro change   Yellow: turn / pause\nRed: harness angle   Gray: gathering data / tracking gap",
                  CGRect(x: 48, y: 698, width: 516, height: 48), size: 9)
            let events = current.events ?? []
            func eventHeader(_ y: CGFloat) {
                for (title, x, width) in [("TIME", CGFloat(48), CGFloat(95)), ("EVENT", 148, 265), ("SPEED", 420, 76), ("GYRO", 500, 76)] {
                    label(title, CGRect(x: x, y: y, width: width, height: 18), size: 9, bold: true)
                }
            }
            func eventRow(_ event: WalkEvent, y: CGFloat) {
                WalkCharts.color(event.kind).setFill()
                pdf.cgContext.fill(CGRect(x: 36, y: y + 2, width: 4, height: 28))
                label("\(WalkRecord.clock(event.start))-\(WalkRecord.clock(event.end))", CGRect(x: 48, y: y, width: 95, height: 20), size: 10)
                label(event.kind.title, CGRect(x: 148, y: y, width: 265, height: 18), size: 11, bold: true)
                if let name = event.obstructionName, event.kind == .obstructionSlowdown {
                    label(name + (event.gyroAlsoChanged ? " · gyro also changed" : ""), CGRect(x: 148, y: y + 18, width: 265, height: 17), size: 9, color: .darkGray)
                }
                label(event.speed.map { String(format: "%.2f m/s", $0) } ?? "--", CGRect(x: 420, y: y, width: 76, height: 20), size: 10)
                label(event.rotation.map { String(format: "%.2f rad/s", $0) } ?? "--", CGRect(x: 500, y: y, width: 76, height: 20), size: 10)
            }
            newPage("Motion & events")
            chart(.axes, y: 88, height: 200)
            let quality = String(format: "Usable position: %.0f%%     Usable motion: %.0f%%     Baseline: %.0f seconds",
                                 current.coverage * 100, current.motionCoverage * 100, baseline.duration)
            label(quality, CGRect(x: 36, y: 302, width: 540, height: 20), size: 11, bold: true)
            let status = current.qualityIssues.isEmpty ? "Recording quality gates met; gaps remain visible."
                : "Limited data: " + current.qualityIssues.joined(separator: " ")
            label(status, CGRect(x: 36, y: 326, width: 540, height: 32), size: 9)
            eventHeader(370)
            if events.isEmpty {
                label("No events recorded. This does not establish normal movement.", CGRect(x: 48, y: 402, width: 516, height: 35), size: 11)
            }
            for (row, event) in events.prefix(6).enumerated() { eventRow(event, y: 400 + CGFloat(row) * 40) }
            label("3-second windows; changes persist across two evaluations. Speed: >20% and >0.15 m/s. Gyro: >30% and >0.08 rad/s, or axis >40% and >0.10 rad/s. Unvalidated demo thresholds.",
                  CGRect(x: 36, y: 656, width: 540, height: 35), size: 9)
            label("Obstruction timing does not prove cause. Chest-phone motion is not joint motion or an arthritis test. Tracked distance excludes gaps. A 5-second baseline is a short reference.",
                  CGRect(x: 36, y: 698, width: 540, height: 30), size: 9)
            label("Ended: \(current.endReason ?? "Legacy recording") · Session \(current.id.uuidString.prefix(8)) · Baseline \(baseline.id.uuidString.prefix(8))",
                  CGRect(x: 36, y: 737, width: 540, height: 14), size: 8, color: .darkGray)
            if events.count > 6 {
                for first in stride(from: 6, to: events.count, by: 14) {
                    newPage("Events / continued")
                    eventHeader(98)
                    for (row, event) in events[first..<min(first + 14, events.count)].enumerated() {
                        eventRow(event, y: 130 + CGFloat(row) * 43)
                    }
                }
            }
            if !current.notes.isEmpty {
                newPage("Your notes")
                label(current.notes, CGRect(x: 36, y: 100, width: 540, height: 570), size: 13)
            }
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        return url
    }
}
