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
        let threshold = speed ? WalkThresholds.speed(reference) : WalkThresholds.rotation(reference)
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
    /// Monthly exports contain abnormal events only. No normal/speed-only/gyro-only rows
    /// or whole-walk averages are included in either chart or event table.
    static func writeMonthly(report: MonthlyMovementReport, archive: SavedState) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PathLightReports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = DateFormatter()
        filename.locale = Locale(identifier: "en_US_POSIX")
        filename.calendar = report.calendar
        filename.timeZone = report.calendar.timeZone
        filename.dateFormat = "yyyy-MM"
        let url = folder.appendingPathComponent("PathLight-Monthly-\(filename.string(from: report.month))-\(UUID().uuidString.prefix(8)).pdf")
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "PathLight - \(report.title) - Abnormal movement",
                               kCGPDFContextCreator as String: "PathLight"]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: format)
        let days = report.days
        let pageCount = 1 + Int(ceil(Double(report.entries.count) / 6))
        var references: [UUID: WalkRecord] = [:]
        for baseline in (archive.baselineHistory ?? []) + (archive.baseline.map { [$0] } ?? []) {
            references[baseline.id] = baseline
        }
        try renderer.writePDF(to: url) { pdf in
            var page = 0
            func label(_ text: String, _ rect: CGRect, size: CGFloat = 10, bold: Bool = false,
                       color: UIColor = .black) {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                (text as NSString).draw(in: rect, withAttributes: [
                    .font: UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                    .foregroundColor: color, .paragraphStyle: paragraph])
            }
            func newPage(_ title: String) {
                pdf.beginPage(); page += 1
                label("PATHLIGHT / MONTHLY ABNORMAL MOVEMENT", CGRect(x: 36, y: 25, width: 540, height: 16), size: 10, bold: true)
                label(title, CGRect(x: 36, y: 49, width: 540, height: 32), size: 24, bold: true)
                label("Sensor threshold flags - not a diagnosis. Page \(page) of \(pageCount)",
                      CGRect(x: 36, y: 759, width: 540, height: 15), size: 9, color: .darkGray)
            }
            newPage(report.title)
            let metrics = [("ABNORMAL EVENTS", String(report.entries.count)),
                           ("WALKS WITH EVENTS", String(report.walkCount)),
                           ("FLAGGED TIME", WalkRecord.clock(report.totalSeconds)),
                           ("DAYS WITH EVENTS", String(days.filter { $0.count > 0 }.count))]
            for (index, metric) in metrics.enumerated() {
                let x = 36 + CGFloat(index) * 137
                label(metric.0, CGRect(x: x, y: 94, width: 130, height: 16), size: 8, color: .darkGray)
                label(metric.1, CGRect(x: x, y: 113, width: 130, height: 30), size: 23, bold: true)
            }
            label("Confirmed abnormal events across saved walks. Dates use \(report.calendar.timeZone.identifier).",
                  CGRect(x: 36, y: 153, width: 540, height: 28), size: 10)
            MonthlyWalkCharts.draw(days: days, duration: false, rect: CGRect(x: 36, y: 188, width: 540, height: 196), context: pdf.cgContext)
            MonthlyWalkCharts.draw(days: days, duration: true, rect: CGRect(x: 36, y: 395, width: 540, height: 196), context: pdf.cgContext)
            label(WalkThresholds.explanation, CGRect(x: 36, y: 607, width: 540, height: 62), size: 9)
            label("Events start at the first qualifying evaluation after confirmation; durations cover confirmed evaluation timestamps. Counts and full event durations are assigned to the event's start day/month. Turns, pauses and nearby obstructions are retained as context.",
                  CGRect(x: 36, y: 674, width: 540, height: 42), size: 9, color: .darkGray)
            label("Zero means no saved abnormal event, not verified normal walking. Only retained recordings are included.",
                  CGRect(x: 36, y: 724, width: 540, height: 24), size: 9, color: .darkGray)

            for first in stride(from: 0, to: report.entries.count, by: 6) {
                newPage("Abnormal movement records")
                label("START / END (UTC OFFSET)", CGRect(x: 46, y: 96, width: 196, height: 15), size: 8, bold: true)
                label("EVENT / WALK", CGRect(x: 247, y: 96, width: 180, height: 15), size: 8, bold: true)
                label("SPEED m/s", CGRect(x: 435, y: 96, width: 64, height: 15), size: 8, bold: true)
                label("GYRO rad/s", CGRect(x: 503, y: 96, width: 70, height: 15), size: 8, bold: true)
                for (row, entry) in report.entries[first..<min(first + 6, report.entries.count)].enumerated() {
                    let y = 120 + CGFloat(row) * 96
                    let event = entry.event
                    let baseline = entry.baselineID.flatMap { references[$0] }
                    UIColor(white: 0.965, alpha: 1).setFill()
                    pdf.cgContext.fill(CGRect(x: 36, y: y, width: 540, height: 90))
                    UIColor(red: 0.72, green: 0.10, blue: 0.30, alpha: 1).setFill()
                    pdf.cgContext.fill(CGRect(x: 36, y: y, width: 3, height: 90))
                    label(WalkTimestamp.string(entry.date, timeZone: report.calendar.timeZone),
                          CGRect(x: 46, y: y + 7, width: 196, height: 14), size: 9)
                    label(WalkTimestamp.string(entry.endDate, timeZone: report.calendar.timeZone),
                          CGRect(x: 46, y: y + 22, width: 196, height: 14), size: 9)
                    label("Abnormal movement #\(first + row + 1)", CGRect(x: 247, y: y + 7, width: 180, height: 15), size: 10, bold: true)
                    let baselineID = entry.baselineID.map { String($0.uuidString.prefix(8)) } ?? "unavailable"
                    label("Walk \(entry.walkID.uuidString.prefix(8)) / ref \(baselineID)",
                          CGRect(x: 247, y: y + 23, width: 180, height: 13), size: 8, color: .darkGray)
                    func reading(_ value: Double?) -> String {
                        guard let value = value, value.isFinite else { return "--" }
                        return String(format: "%.2f", value)
                    }
                    label(reading(event.speed), CGRect(x: 435, y: y + 7, width: 64, height: 15), size: 11, bold: true)
                    label(reading(event.rotation), CGRect(x: 503, y: y + 7, width: 70, height: 15), size: 11, bold: true)
                    label("ref " + reading(event.baselineSpeed ?? baseline?.meanSpeed),
                          CGRect(x: 435, y: y + 23, width: 64, height: 13), size: 8, color: .darkGray)
                    label("ref " + reading(event.baselineRotation ?? baseline?.rotationRMS),
                          CGRect(x: 503, y: y + 23, width: 70, height: 13), size: 8, color: .darkGray)
                    func axes(_ values: [Double]?) -> String {
                        guard let values = values, values.count == 3, values.allSatisfy(\.isFinite) else { return "not stored" }
                        return values.map { String(format: "%.2f", $0) }.joined(separator: " / ")
                    }
                    label("Gyro X/Y/Z: \(axes(event.axes))   |   ref: \(axes(event.baselineAxes ?? baseline?.axisRMS)) rad/s RMS",
                          CGRect(x: 46, y: y + 39, width: 520, height: 13), size: 8)
                    let measured = event.measuredAt.map {
                        WalkTimestamp.string(entry.walkDate.addingTimeInterval($0), timeZone: report.calendar.timeZone)
                    } ?? "not stored (legacy event)"
                    label(String(format: "Duration %.1f s   |   Last confirmed window: ", event.duration) + measured,
                          CGRect(x: 46, y: y + 53, width: 520, height: 13), size: 8)
                    let labels = event.contextLabels ?? []
                    let context = labels.isEmpty ? "No additional context stored" : labels.joined(separator: "; ")
                    label(context, CGRect(x: 46, y: y + 67, width: 520, height: 22), size: 8, color: .darkGray)
                }
                label("Readings are from the last confirmed 3-second window; ref is the baseline used for that walk. Gyro is RMS phone rotation. An axis can cross its threshold even if total gyro RMS does not. '--' / 'not stored' indicates unavailable historical data.",
                      CGRect(x: 36, y: 709, width: 540, height: 38), size: 9, color: .darkGray)
            }
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        return url
    }

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
                           ("ABNORMAL MOVEMENTS", "\(current.abnormalMovementEvents.count)")]
            for (index, metric) in metrics.enumerated() {
                let x = 36 + CGFloat(index) * 137
                label(metric.0, CGRect(x: x, y: 92, width: 132, height: 16), size: 8, color: .darkGray)
                label(metric.1, CGRect(x: x, y: 112, width: 132, height: 28), size: 21, bold: true)
            }
            chart(.speed, y: 153, height: 205)
            chart(.rotation, y: 364, height: 205)
            chart(.timeline, y: 578, height: 110)
            label("Pink: abnormal movement   Orange: obstruction slowdown   Green: within thresholds\nCyan: speed change   Purple: gyro change   Yellow: turn / pause\nRed: harness angle   Gray: gathering data / tracking gap",
                  CGRect(x: 48, y: 698, width: 516, height: 48), size: 9)
            let events = current.events ?? []
            func eventHeader(_ y: CGFloat) {
                for (title, x, width) in [("DATE / TIME (UTC OFFSET)", CGFloat(48), CGFloat(164)), ("EVENT", 218, 196), ("SPEED", 420, 76), ("GYRO", 500, 76)] {
                    label(title, CGRect(x: x, y: y, width: width, height: 18), size: 9, bold: true)
                }
            }
            func eventRow(_ event: WalkEvent, y: CGFloat) {
                WalkCharts.color(event.kind).setFill()
                pdf.cgContext.fill(CGRect(x: 36, y: y + 2, width: 4, height: 44))
                let stamp = WalkTimestamp.string(current.date.addingTimeInterval(event.start)).split(separator: " ")
                label(String(stamp[0]), CGRect(x: 48, y: y, width: 164, height: 15), size: 10)
                label(stamp.dropFirst().joined(separator: " "), CGRect(x: 48, y: y + 15, width: 164, height: 15), size: 10)
                label("Elapsed \(WalkRecord.clock(event.start))-\(WalkRecord.clock(event.end))", CGRect(x: 48, y: y + 30, width: 164, height: 15), size: 8, color: .darkGray)
                label(event.kind.title, CGRect(x: 218, y: y, width: 196, height: 18), size: 11, bold: true)
                let context = (event.contextLabels ?? []).joined(separator: "; ")
                label(context.isEmpty ? (event.obstructionName ?? "") : context,
                      CGRect(x: 218, y: y + 18, width: 196, height: 28), size: 8, color: .darkGray)
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
            label(status + "\nEvent readings come from the last confirmed window.",
                  CGRect(x: 36, y: 326, width: 540, height: 32), size: 9)
            eventHeader(370)
            if events.isEmpty {
                label("No events recorded. This does not establish normal movement.", CGRect(x: 48, y: 402, width: 516, height: 35), size: 11)
            }
            for (row, event) in events.prefix(4).enumerated() { eventRow(event, y: 400 + CGFloat(row) * 58) }
            label(WalkThresholds.explanation,
                  CGRect(x: 36, y: 645, width: 540, height: 48), size: 9)
            label("Obstruction timing does not prove cause. Chest-phone motion is not joint motion or an arthritis test. Tracked distance excludes gaps. A 5-second baseline is a short reference.",
                  CGRect(x: 36, y: 698, width: 540, height: 30), size: 9)
            label("Ended: \(current.endReason ?? "Legacy recording") · Session \(current.id.uuidString.prefix(8)) · Baseline \(baseline.id.uuidString.prefix(8))",
                  CGRect(x: 36, y: 737, width: 540, height: 14), size: 8, color: .darkGray)
            if events.count > 4 {
                for first in stride(from: 4, to: events.count, by: 10) {
                    newPage("Events / continued")
                    eventHeader(98)
                    for (row, event) in events[first..<min(first + 10, events.count)].enumerated() {
                        eventRow(event, y: 130 + CGFloat(row) * 58)
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

/// Vector charts keep printed/exported monthly graphs sharp at any zoom level.
private enum MonthlyWalkCharts {
    static func draw(days: [MonthlyMovementReport.Day], duration: Bool, rect: CGRect, context: CGContext) {
        guard !days.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        let width = rect.width, height = rect.height
        func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat = 80, size: CGFloat = 9) {
            (value as NSString).draw(in: CGRect(x: x, y: y, width: width, height: 18), withAttributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
                .foregroundColor: UIColor.darkGray])
        }
        text(duration ? "Flagged duration by start day (seconds)" : "Abnormal movement events by start day",
             x: 0, y: 0, width: width, size: 13)
        let plot = CGRect(x: 48, y: 35, width: width - 62, height: height - 67)
        let values = days.map { duration ? $0.seconds : Double($0.count) }
        let maximum = max(duration ? 10.0 : 2.0, (values.max() ?? 0) * 1.15)
        // Integer event ticks; durations are seconds, never a mislabeled health score.
        let step = max(1, ceil(maximum / 4))
        let top = step * 4
        for index in 0...4 {
            let y = plot.maxY - CGFloat(index) * plot.height / 4
            context.setStrokeColor(UIColor(white: 0.85, alpha: 1).cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: plot.minX, y: y))
            context.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.strokePath()
            text(String(format: "%.0f", step * Double(index)), x: 0, y: y - 6, width: 44)
        }
        let slot = plot.width / CGFloat(days.count)
        let tint = duration ? UIColor(red: 0.12, green: 0.35, blue: 0.58, alpha: 1)
                            : UIColor(red: 0.72, green: 0.10, blue: 0.30, alpha: 1)
        for (index, day) in days.enumerated() {
            let x = plot.minX + CGFloat(index) * slot
            let barHeight = CGFloat(values[index] / top) * plot.height
            tint.setFill()
            context.fill(CGRect(x: x + 2, y: plot.maxY - barHeight, width: max(1, slot - 4), height: barHeight))
            text(String(day.number), x: x + 1, y: plot.maxY + 6, width: slot + 1, size: 7)
        }
        text("Day of month", x: plot.minX, y: height - 13, width: 180, size: 8)
    }
}
