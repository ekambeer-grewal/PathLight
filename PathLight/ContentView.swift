import SwiftUI
import ARKit
import AVKit

private let mint = Color(red: 0.44, green: 0.92, blue: 0.77)
private let ink = Color(red: 0.035, green: 0.07, blue: 0.12)

struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        TabView {
            NavigationView { NavigateView(model: model, audio: model.audio) }
                .tabItem { Label("Navigate", systemImage: "viewfinder") }
            NavigationView { WalkingView(model: model) }
                .tabItem { Label("Walking", systemImage: "figure.walk") }
            NavigationView { ReportsView(model: model) }
                .tabItem { Label("Summary", systemImage: "chart.xyaxis.line") }
        }
        .tint(mint)
        .alert("PathLight", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .sheet(isPresented: Binding(get: { model.reportURL != nil }, set: { if !$0 { model.reportURL = nil } })) {
            if let url = model.reportURL { ShareSheet(url: url) }
        }
    }
}

struct NavigateView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var audio: AudioGuide
    private var distanceBinding: Binding<DistanceUnit> {
        Binding<DistanceUnit>(get: { model.distanceUnit }, set: { model.distanceUnit = $0 })
    }
    private var navigationAudioBinding: Binding<Bool> {
        Binding<Bool>(get: { model.navigationAudio }, set: { model.navigationAudio = $0 })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A little more awareness.").font(.largeTitle.bold())
                    Text("PATHLIGHT / PROTOTYPE 01").font(.caption.bold()).tracking(2).foregroundStyle(mint)
                }
                safetyCard
                sensorStatus
                cameraCard
                sensorButton
                detectorCard
                distanceCard
                targetCard
                audioCard
            }.padding(20)
        }.background(ink).navigationTitle("PathLight").navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var safetyCard: some View {
        if !model.acknowledged {
            VStack(alignment: .leading, spacing: 12) {
                Label("Supervised demo only", systemImage: "exclamationmark.triangle.fill").font(.headline)
                Text("This prototype can miss obstacles, especially low or overhead hazards. It does not detect stairs, curbs, drop-offs, traffic, or clear routes. Keep using your mobility aid and test with a sighted partner.")
                Button("I understand — enable prototype") { model.acknowledged = true }
                    .buttonStyle(.borderedProminent).tint(mint).foregroundStyle(ink)
            }.card()
        }
    }

    @ViewBuilder
    private var sensorStatus: some View {
        HStack(spacing: 12) {
            Circle().fill(model.trackingReady ? mint : .orange).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(model.status).font(.headline)
        }
    }

    @ViewBuilder
    private var cameraCard: some View {
        if model.running {
            CameraPreview(model: model)
                .frame(height: 300)
                .overlay { TargetOverlay(target: model.obstacles.first) }
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(alignment: .bottomLeading) {
                    Text("LIVE · REAR CAMERA").font(.caption.bold()).padding(10).background(Color.black.opacity(0.7)).clipShape(Capsule()).padding()
                }.accessibilityLabel("Live rear camera preview")
        }
    }

    @ViewBuilder
    private var sensorButton: some View {
        Button {
            if model.running { model.stop() } else { model.start() }
        } label: {
            Label(model.running ? "Stop sensors" : "Start sensors", systemImage: model.running ? "stop.fill" : "play.fill")
                .font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 12)
        }.buttonStyle(.borderedProminent).tint(model.running ? .orange : mint).foregroundStyle(ink)
            .disabled(!model.acknowledged)
    }

    @ViewBuilder
    private var detectorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.detectorStatus).font(.headline)
            if let milliseconds = model.inferenceMilliseconds {
                Text(String(format: "Last model + ranging pass: %.0f ms", milliseconds))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("Chairs and tables: YOLO11n. Walls ahead: direct LiDAR plane estimates plus ARKit. Flat furniture can also resemble a wall.")
                .font(.footnote).foregroundStyle(.secondary)
        }.card()
    }

    @ViewBuilder
    private var distanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Distance units", selection: distanceBinding) {
                Text("Meters").tag(DistanceUnit.meters)
                Text("Feet").tag(DistanceUnit.feet)
            }.pickerStyle(.segmented)
            if let distance = model.centerDistance {
                Text("CENTER DEPTH CHECK").font(.caption.bold()).foregroundStyle(mint)
                Text(String(format: "%.2f m = %.2f ft", distance, DistanceUnit.feet.value(distance)))
                    .font(.title3.monospacedDigit())
            }
            Text("Aim the camera center at a flat wall and compare with a tape measure from the camera lens. Object distances measure visible surfaces; they are approximate.")
                .font(.footnote).foregroundStyle(.secondary)
        }.card()
    }

    @ViewBuilder
    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SELECTED OBJECT").font(.caption.bold()).foregroundStyle(mint)
            Text("One stable target · spoken direction first · closer hazards can interrupt")
                .font(.footnote).foregroundStyle(.secondary)
            if model.obstacles.isEmpty {
                Text(model.running ? "No reliable reading right now" : "Start scanning to see nearby surfaces").font(.title3)
                Text("No reading does not mean the path is clear.").foregroundStyle(.secondary)
            } else {
                ForEach(model.obstacles) { obstacle in
                    HStack {
                        Image(systemName: obstacle.side == .left ? "arrow.left" : obstacle.side == .right ? "arrow.right" : "arrow.up")
                            .font(.title2).foregroundStyle(mint).frame(width: 30).accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text(obstacle.name).font(.title3.bold())
                            Text(obstacle.source).font(.caption).foregroundStyle(.secondary)
                            Text(obstacle.side == .center ? "Ahead" : obstacle.side.rawValue.capitalized).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(obstacle.distanceText).font(.title2.monospacedDigit().bold())
                    }.accessibilityElement(children: .ignore).accessibilityLabel(obstacle.phrase)
                }
            }
            Text("Alerts focus on chairs, tables, and walls in the walking corridor, up to about 4.5 m with reliable depth. Wall boxes mark surface regions. Detection distance is not guaranteed.").font(.footnote).foregroundStyle(.secondary)
        }.card()
    }

    @ViewBuilder
    private var audioCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Audio guide", systemImage: "airpodspro").font(.headline)
                Spacer()
                RoutePicker().frame(width: 44, height: 44).accessibilityLabel("Choose audio output")
            }
            Text(audio.route).foregroundStyle(.secondary)
            if !audio.stereoAvailable {
                Text("Connect both AirPods for left/right cues. Speaker audio cannot provide reliable directional cues.").foregroundStyle(Color.orange)
            }
            if let error = audio.error { Text(error).foregroundStyle(Color.orange) }
            Toggle("Speak and beep selected objects", isOn: navigationAudioBinding)
                .onChange(of: model.navigationAudio) { _, enabled in
                    if !enabled { audio.clear() }
                }
            HStack {
                Button("Test left") { audio.test(.left) }
                Button("Test right") { audio.test(.right) }
            }.buttonStyle(.bordered).disabled(!model.acknowledged)
            Text("Confirm each beep is in the correct ear before walking. Turn off Mono Audio and head-tracked Spatial Audio for this test. Indoor beeps range from slow at about 4.5 m to very rapid below 0.5 m; beeps indicate object location, not a direction to walk.").font(.footnote).foregroundStyle(.secondary)
        }.card()
    }

}

struct WalkingView: View {
    @ObservedObject var model: AppModel
    @State private var replacing = false
    @State private var discarding = false
    private var busy: Bool { model.recording != nil || model.countdown > 0 }
    private var notesBinding: Binding<String> {
        Binding<String>(get: { model.sessionNotes }, set: { model.sessionNotes = String($0.prefix(600)) })
    }
    private var liveSpeedText: String {
        guard let speed = model.speed else { return "--" }
        return String(format: "%.2f", speed)
    }
    private var canStartWalk: Bool {
        model.trackingReady && model.motionReady && (model.saved.baseline?.algorithmVersion ?? 1) >= 3
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Every walk.\nYour own baseline.").font(.largeTitle.bold())
                Text("Record 5 seconds of usual walking, then start a walk that lasts until you end it.")
                    .foregroundStyle(.secondary)
                speedCard
                recordingControls
                notesField
                setupCard
            }.padding(20)
        }.background(Color.black).navigationTitle("Walking").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Replace the baseline? A successful new baseline clears earlier walks.", isPresented: $replacing, titleVisibility: .visible) {
                Button("Record new baseline", role: .destructive) { model.prepareWalk(.baseline) }
            }
            .confirmationDialog("Discard this walk without saving?", isPresented: $discarding, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { model.cancelWalk() }
            }
    }

    @ViewBuilder
    private var speedCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("LIVE SPEED").font(.caption.bold()).foregroundStyle(Color.green)
                Text(liveSpeedText)
                    .font(.system(size: 58, weight: .semibold, design: .rounded).monospacedDigit())
                Text("m/s · " + model.speedNote).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "figure.walk").font(.system(size: 44)).foregroundStyle(Color.green)
        }.card()
    }

    @ViewBuilder
    private var recordingControls: some View {
        if model.recording == .assessment {
            activeWalkCard
        } else if busy {
            waitingCard
        } else {
            startControls
        }
    }

    @ViewBuilder
    private var notesField: some View {
        TextField("Optional walk notes", text: notesBinding, axis: .vertical)
            .lineLimit(2...4).padding().background(Color.white.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 16))
            .disabled(busy)
    }

    @ViewBuilder
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Chest harness · portrait · camera forward", systemImage: "iphone").font(.headline)
            Text("Start sensors in Navigate. Use a clear, level route for the baseline. Keep the harness position the same for your walk.")
            Text("Keep the app open. Leaving the app or a sensor interruption ends and saves a continuous walk. Missing measurements are shown as gaps.")
            Text("Flags are experimental changes in speed and chest-phone motion. They do not diagnose arthritis or measure joint motion.")
        }.font(.footnote).foregroundStyle(.secondary).card()
    }

    @ViewBuilder
    private var activeWalkCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("WALK IN PROGRESS").font(.caption.bold()).foregroundStyle(Color.pink)
            Text(WalkRecord.clock(Double(model.elapsed))).font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
            if let window = model.liveWindow {
                LiveWalkStatus(window: window, eventCount: model.liveEventCount)
            }
            Button { model.finishWalk() } label: {
                Label("End walk & save", systemImage: "stop.fill").font(.headline)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }.buttonStyle(.borderedProminent).tint(Color.pink)
            Button("Discard walk", role: .destructive) { discarding = true }
        }.card()
    }

    @ViewBuilder
    private var waitingCard: some View {
        VStack(spacing: 12) {
            Text(model.countdown > 0 ? "Begin walking at your usual pace" : "Recording speed + gyro baseline")
                .font(.headline)
            Text("\(model.countdown > 0 ? model.countdown : model.remaining)")
                .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
            Button("Cancel") { model.cancelWalk() }.buttonStyle(.bordered)
        }.frame(maxWidth: .infinity).card()
    }

    @ViewBuilder
    private var startControls: some View {
        if let baseline = model.saved.baseline {
            VStack(alignment: .leading, spacing: 8) {
                Label("Your baseline", systemImage: "checkmark.circle.fill").foregroundStyle(Color.green)
                Text(String(format: "%.2f m/s  ·  %.2f rad/s", baseline.meanSpeed, baseline.rotationRMS)).font(.title3.bold())
                if (baseline.algorithmVersion ?? 1) < 3 {
                    Text("Record a new baseline to include the gyro axes.").foregroundStyle(Color.orange)
                }
            }.card()
        }
        Button {
            if model.saved.baseline == nil { model.prepareWalk(.baseline) } else { replacing = true }
        } label: {
            Label(model.saved.baseline == nil ? "Record 5-second baseline" : "Replace baseline", systemImage: "waveform.path")
                .frame(maxWidth: .infinity).padding(.vertical, 10)
        }.buttonStyle(.bordered).disabled(!model.trackingReady || !model.motionReady)
        Button { model.prepareWalk(.assessment) } label: {
            Label("Start walk", systemImage: "figure.walk").font(.headline)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
        }.buttonStyle(.borderedProminent).tint(Color.green).foregroundStyle(Color.black)
            .disabled(!canStartWalk)
    }

}

struct ReportsView: View {
    @ObservedObject var model: AppModel
    @State private var deleting = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Summary").font(.system(size: 36, weight: .bold, design: .rounded))
                Text("YOUR WALKS").font(.caption.bold()).tracking(2).foregroundStyle(Color.pink)
                emptyCard
                savedWalks
                Text("Saved locally. Charts describe tracked movement, not a medical assessment.").font(.footnote).foregroundStyle(.secondary)
                Button("Delete local walks and reports", role: .destructive) { deleting = true }
                    .disabled(model.recording != nil || model.countdown > 0)
            }.padding(20)
        }.background(Color.black).navigationBarHidden(true)
            .confirmationDialog("Delete baseline, walks and local reports?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete local data", role: .destructive) { model.eraseData() }
            }
    }

    @ViewBuilder
    private var emptyCard: some View {
        if model.saved.assessments.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "figure.walk.circle.fill").font(.system(size: 65)).foregroundStyle(Color.green)
                Text("Your next walk starts here.").font(.title2.bold())
                Text("Record a baseline, start a walk, and tap End walk & save. Your charts and events will appear here.").foregroundStyle(.secondary)
            }.card()
        }
    }

    @ViewBuilder
    private var savedWalks: some View {
        if let baseline = model.saved.baseline {
            ForEach(model.saved.assessments) { record in
                NavigationLink {
                    WalkDetailView(model: model, record: record, baseline: baseline)
                } label: {
                    WalkSummaryRow(record: record)
                }.buttonStyle(.plain)
            }
        }
    }

}

private struct WalkDetailView: View {
    @ObservedObject var model: AppModel
    let record: WalkRecord
    let baseline: WalkRecord
    private var events: [WalkEvent] { record.events ?? [] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(record.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                coverageCard
                metricsGrid
                qualityCard
                chartCards
                timelineKey
                eventsCard
                shareButton
                Text("Lines use 3-second windows. Missing data breaks the line. Obstruction slowdowns indicate timing, not a proven cause. Gyroscope measurements are chest-phone motion, not direct joint or clinical gait measurements.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(20)
        }.background(Color.black).navigationTitle("Walk details").navigationBarTitleDisplayMode(.inline).navigationBarHidden(false)
    }
    private func summaryStat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption2.bold()).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).foregroundStyle(color)
                .minimumScaleFactor(0.65).lineLimit(1)
        }.card()
    }

    @ViewBuilder
    private var coverageCard: some View {
        HStack(spacing: 28) {
            CoverageRings(position: record.coverage, motion: record.motionCoverage)
                .frame(width: 120, height: 120)
            VStack(alignment: .leading, spacing: 8) {
                Text("TRACKING COVERAGE").font(.caption.bold())
                Text(String(format: "Position %.0f%%", record.coverage * 100)).foregroundStyle(Color.green)
                Text(String(format: "Motion %.0f%%", record.motionCoverage * 100)).foregroundStyle(Color.cyan)
                Text("Data coverage, not a health score").font(.caption).foregroundStyle(.secondary)
            }
        }.card()
    }

    @ViewBuilder
    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            summaryStat("DURATION", record.durationText, .cyan)
            summaryStat("TRACKED DISTANCE", record.trackedDistanceText, .green)
            summaryStat("MEAN SPEED", String(format: "%.2f m/s", record.meanSpeed), .yellow)
            summaryStat("COMBINED EVENTS", "\(record.reviewEvents.count)", .pink)
        }
    }

    @ViewBuilder
    private var qualityCard: some View {
        if !record.qualityIssues.isEmpty {
            Text(record.qualityIssues.joined(separator: " ")).font(.footnote).foregroundStyle(Color.orange).card()
        }
    }

    @ViewBuilder
    private var chartCards: some View {
        ForEach(WalkChartKind.allCases, id: \.rawValue) { kind in
            WalkChartCard(record: record, baseline: baseline, kind: kind)
        }
    }

    @ViewBuilder
    private var timelineKey: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TIMELINE KEY").font(.caption.bold())
            ForEach(WalkState.allCases, id: \.rawValue) { state in
                HStack {
                    Circle().fill(Color(uiColor: WalkCharts.color(state))).frame(width: 9, height: 9)
                    Text(state.title).font(.caption)
                }
            }
        }.card()
    }

    @ViewBuilder
    private var eventsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Events").font(.title2.bold())
            if (record.events ?? []).isEmpty {
                Text("No events recorded. This does not establish normal movement.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(events) { event in
                WalkEventRow(event: event)
            }
        }.card()
    }

    @ViewBuilder
    private var shareButton: some View {
        Button { model.export(record) } label: {
            Label("Share PDF with charts", systemImage: "square.and.arrow.up")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
        }.buttonStyle(.borderedProminent).tint(Color.green).foregroundStyle(Color.black)
    }

}

private struct WalkSummaryRow: View {
    let record: WalkRecord
    private var eventSummary: String {
        let combined: Int = record.reviewEvents.count
        let slowdowns: Int = (record.events ?? []).filter { $0.kind == .obstructionSlowdown }.count
        return "\(combined) combined movement events · \(slowdowns) obstruction slowdowns"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "figure.walk").foregroundStyle(Color.green)
                Text("Indoor walk").font(.headline)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            Text(record.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(record.trackedDistanceText)
                    .font(.system(size: 32, weight: .semibold, design: .rounded)).foregroundStyle(Color.green)
                Spacer()
                Text(record.durationText).font(.title2.monospacedDigit()).foregroundStyle(Color.cyan)
            }
            Text(eventSummary).font(.footnote).foregroundStyle(.secondary)
        }.card()
    }
}

private struct WalkEventRow: View {
    let event: WalkEvent
    private var timeText: String {
        WalkRecord.clock(event.start) + "–" + WalkRecord.clock(event.end)
    }
    private var readingsText: String {
        let speed: String = event.speed.map { String(format: "%.2f m/s", $0) } ?? "Speed unavailable"
        let gyro: String = event.rotation.map { String(format: "%.2f rad/s", $0) } ?? "Gyro unavailable"
        return speed + " · " + gyro
    }
    private var contextText: String {
        let name: String = event.obstructionName ?? "a nearby surface"
        let extra: String = event.gyroAlsoChanged ? "; gyro also changed" : ""
        return "Possibly related to " + name + extra + "."
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(uiColor: WalkCharts.color(event.kind))).frame(width: 4, height: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.kind.title).font(.headline)
                Text(timeText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(readingsText).font(.caption).foregroundStyle(.secondary)
                if event.kind == .obstructionSlowdown {
                    Text(contextText).font(.caption).foregroundStyle(Color.orange)
                }
            }
        }
    }
}

private struct LiveWalkStatus: View {
    let window: WalkWindow
    let eventCount: Int
    private var gyroText: String {
        guard let rotation = window.rotation else { return "Waiting for usable motion data" }
        return String(format: "Gyro %.2f rad/s", rotation) + " · \(eventCount) combined events"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(window.state.title, systemImage: "waveform.path")
                .foregroundStyle(Color(uiColor: WalkCharts.color(window.state))).font(.headline)
            Text(gyroText).font(.footnote).foregroundStyle(.secondary)
            if window.obstruction == .detected {
                Text("Nearby obstruction detected. A slowdown may be related.").font(.footnote).foregroundStyle(Color.orange)
            } else if window.obstruction == .unavailable {
                Text("Obstruction context unavailable.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CoverageRings: View {
    let position: Double
    let motion: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.green.opacity(0.16), lineWidth: 14)
            Circle().trim(from: 0, to: min(1, max(0, position)))
                .stroke(Color.green, style: StrokeStyle(lineWidth: 14, lineCap: .round)).rotationEffect(.degrees(-90))
            Circle().stroke(Color.cyan.opacity(0.16), lineWidth: 12).padding(21)
            Circle().trim(from: 0, to: min(1, max(0, motion)))
                .stroke(Color.cyan, style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90)).padding(21)
            Image(systemName: "figure.walk").foregroundStyle(Color.green).font(.title2)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: "Tracking coverage: position %.0f percent, motion %.0f percent", position * 100, motion * 100))
    }
}

private struct WalkChartCard: View {
    let record: WalkRecord
    let baseline: WalkRecord
    let kind: WalkChartKind
    @State private var rendered: UIImage?
    private var chartDescription: String {
        switch kind {
        case .speed:
            return String(format: "Walking speed chart. Mean %.2f meters per second; baseline %.2f.", record.meanSpeed, baseline.meanSpeed)
        case .rotation:
            return String(format: "Gyroscope chart. RMS %.2f radians per second; baseline %.2f.", record.rotationRMS, baseline.rotationRMS)
        case .axes:
            let axes = record.axisRMS
            return String(format: "Gyroscope axes. X %.2f, Y %.2f, Z %.2f radians per second RMS.", axes[0], axes[1], axes[2])
        case .timeline:
            return "Walk timeline. \((record.events ?? []).count) events. Times and readings are listed below."
        }
    }
    var body: some View {
        VStack {
            if let rendered = rendered {
                Image(uiImage: rendered).resizable().scaledToFit()
                    .accessibilityLabel(chartDescription)
            } else { ProgressView().frame(height: 130) }
        }.padding(8).background(Color(white: 0.085)).clipShape(RoundedRectangle(cornerRadius: 22))
            .task(id: record.id) { rendered = WalkCharts.image(record: record, baseline: baseline, kind: kind) }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let model: AppModel
    func makeUIView(context: Context) -> ARSCNView {
        let view = CameraSurface(frame: .zero)
        view.sizeChanged = { size in
            DispatchQueue.main.async { model.previewSize = size }
        }
        view.session = model.session
        view.session.delegateQueue = .main
        view.session.delegate = model
        view.preferredFramesPerSecond = 30
        view.isAccessibilityElement = false
        return view
    }
    func updateUIView(_ view: ARSCNView, context: Context) {}
}

private final class CameraSurface: ARSCNView {
    var sizeChanged: ((CGSize) -> Void)?
    private var previousSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != previousSize, bounds.width > 1, bounds.height > 1 {
            previousSize = bounds.size
            sizeChanged?(bounds.size)
        }
    }
}

private struct TargetOverlay: View {
    let target: Obstacle?
    var body: some View {
        GeometryReader { geometry in
            if let target = target {
                let box = CGRect(x: target.bounds.minX * geometry.size.width,
                                 y: target.bounds.minY * geometry.size.height,
                                 width: target.bounds.width * geometry.size.width,
                                 height: target.bounds.height * geometry.size.height)
                ZStack(alignment: .topLeading) {
                    Path { $0.addRect(box) }.stroke(mint, lineWidth: 3)
                    Text("\(target.name) · \(target.side == .center ? "Ahead" : target.side.rawValue.capitalized) · \(target.distanceText)")
                        .font(.caption.bold()).foregroundStyle(ink)
                        .padding(.horizontal, 8).padding(.vertical, 5).background(mint)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .position(x: min(max(box.midX, 90), max(90, geometry.size.width - 90)),
                                  y: max(15, box.minY - 15))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor(mint)
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

private extension View {
    func card() -> some View {
        padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}
