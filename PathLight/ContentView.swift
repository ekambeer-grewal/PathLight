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
                .tabItem { Label("Reports", systemImage: "doc.text") }
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("A little more awareness.").font(.largeTitle.bold())
                Text("PATHLIGHT / PROTOTYPE 01").font(.caption.bold()).tracking(2).foregroundStyle(mint)
                if !model.acknowledged {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Supervised demo only", systemImage: "exclamationmark.triangle.fill").font(.headline)
                        Text("This prototype can miss obstacles, especially low or overhead hazards. It does not detect stairs, curbs, drop-offs, traffic, or clear routes. Keep using your mobility aid and test with a sighted partner.")
                        Button("I understand — enable prototype") { model.acknowledged = true }
                            .buttonStyle(.borderedProminent).tint(mint).foregroundStyle(ink)
                    }.card()
                }
                HStack(spacing: 12) {
                    Circle().fill(model.trackingReady ? mint : .orange).frame(width: 10, height: 10).accessibilityHidden(true)
                    Text(model.status).font(.headline)
                }
                if model.running {
                    CameraPreview(model: model)
                        .frame(height: 300)
                        .overlay { TargetOverlay(target: model.obstacles.first) }
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .overlay(alignment: .bottomLeading) {
                            Text("LIVE · REAR CAMERA").font(.caption.bold()).padding(10).background(.black.opacity(0.7)).clipShape(Capsule()).padding()
                        }.accessibilityLabel("Live rear camera preview")
                }
                Button {
                    if model.running { model.stop() } else { model.start() }
                } label: {
                    Label(model.running ? "Stop sensors" : "Start sensors", systemImage: model.running ? "stop.fill" : "play.fill")
                        .font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.borderedProminent).tint(model.running ? .orange : mint).foregroundStyle(ink)
                    .disabled(!model.acknowledged)
                VStack(alignment: .leading, spacing: 14) {
                    Text("SELECTED SURFACE").font(.caption.bold()).foregroundStyle(mint)
                    Text(model.detectionCooldown > 0 ? "One target · next selection in \(model.detectionCooldown)s" : "Looking for one nearby target")
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
                                    Text(obstacle.side == .center ? "Ahead" : obstacle.side.rawValue.capitalized).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(String(format: "%.1f m", obstacle.distance)).font(.title2.monospacedDigit().bold())
                            }.accessibilityElement(children: .ignore).accessibilityLabel(obstacle.phrase)
                        }
                    }
                    Text("The box marks an approximate detected surface region. Distance is from the camera, not body clearance.").font(.footnote).foregroundStyle(.secondary)
                }.card()
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Audio guide", systemImage: "airpodspro").font(.headline)
                        Spacer()
                        RoutePicker().frame(width: 44, height: 44).accessibilityLabel("Choose audio output")
                    }
                    Text(audio.route).foregroundStyle(.secondary)
                    if !audio.stereoAvailable {
                        Text("Connect both AirPods for left/right cues. Speaker audio cannot provide reliable directional cues.").foregroundStyle(.orange)
                    }
                    if let error = audio.error { Text(error).foregroundStyle(.orange) }
                    Toggle("Speak and beep nearby surfaces", isOn: $model.navigationAudio)
                        .onChange(of: model.navigationAudio) { enabled in if !enabled { audio.clear() } }
                    HStack {
                        Button("Test left") { audio.test(.left) }
                        Button("Test right") { audio.test(.right) }
                    }.buttonStyle(.bordered).disabled(!model.acknowledged)
                    Text("Confirm each beep is in the correct ear before walking. Turn off Mono Audio and head-tracked Spatial Audio for this test. Faster beeps mean a closer detected surface; beeps indicate object location, not a direction to walk.").font(.footnote).foregroundStyle(.secondary)
                }.card()
            }.padding(20)
        }.background(ink).navigationTitle("PathLight").navigationBarTitleDisplayMode(.inline)
    }
}

struct WalkingView: View {
    @ObservedObject var model: AppModel
    @State private var replacing = false
    private var busy: Bool { model.recording != nil || model.countdown > 0 }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Your walk.\nYour reference.").font(.largeTitle.bold())
                Text("Compare two short walks under similar conditions.").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Label("5-second baseline · 30-second comparison", systemImage: "figure.walk").font(.title3.bold())
                    Text("Mount the phone upright in portrait, with its rear camera facing forward and the lenses uncovered. Use a clear, well-lit, level route. Keep the same harness height, tilt, footwear, and comfortable pace for both walks. Pause at the end; do not deliberately limp for the demo.")
                    Text("Start sensors in Navigate first. Begin walking during the five-second countdown, then keep your usual pace while recording. Fast turns and poor tracking are excluded.").foregroundStyle(.secondary)
                }.card()
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TRACKED SPEED").font(.caption.bold()).foregroundStyle(mint)
                        Text(model.speed.map { String(format: "%.2f m/s", $0) } ?? "—")
                            .font(.largeTitle.monospacedDigit().bold())
                        Text(model.speedNote).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "waveform.path").font(.system(size: 35)).foregroundStyle(mint).accessibilityHidden(true)
                }.card()
                Text(model.trackingReady && model.motionReady ? "Camera and motion ready" : "Waiting for camera and motion tracking").foregroundStyle(model.trackingReady && model.motionReady ? mint : .orange)
                TextField("Optional notes: shoes, fatigue, route…", text: $model.sessionNotes, axis: .vertical)
                    .lineLimit(2...4).padding().background(.white.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 16))
                    .disabled(busy)
                    .onChange(of: model.sessionNotes) { text in
                        if text.count > 600 { model.sessionNotes = String(text.prefix(600)) }
                    }
                if busy {
                    VStack(spacing: 14) {
                        Text(model.countdown > 0 ? "Begin walking · settling in" : "Walk at your usual pace").font(.title2.bold())
                        Text("\(model.countdown > 0 ? model.countdown : model.remaining)")
                            .font(.system(size: 70, weight: .bold, design: .rounded).monospacedDigit())
                            .accessibilityLabel("\(model.countdown > 0 ? model.countdown : model.remaining) seconds remaining")
                        Text(model.recording == .baseline ? "Recording baseline" : model.recording == .assessment ? "Recording assessment" : "Countdown")
                        Button("Cancel walk", role: .destructive) { model.cancelWalk() }.buttonStyle(.bordered)
                    }.frame(maxWidth: .infinity).card()
                } else {
                    Button {
                        if model.saved.baseline == nil { model.prepareWalk(.baseline) } else { replacing = true }
                    } label: {
                        Label(model.saved.baseline == nil ? "Record baseline" : "Replace baseline", systemImage: "record.circle")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent).tint(mint).foregroundStyle(ink)
                    .disabled(!model.trackingReady || !model.motionReady)
                    Button { model.prepareWalk(.assessment) } label: {
                        Label("Record comparison walk", systemImage: "figure.walk")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.bordered).disabled(model.saved.baseline == nil || !model.trackingReady || !model.motionReady)
                }
                if let baseline = model.saved.baseline {
                    Label("Baseline saved \(baseline.date.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle.fill").foregroundStyle(mint)
                    if (baseline.algorithmVersion ?? 1) < 2 {
                        Text("Replace your baseline to use the updated speed tracking.").foregroundStyle(.orange)
                    }
                }
                Text("Movement changes can have many causes. This prototype does not detect arthritis or measure joint health.").font(.footnote).foregroundStyle(.secondary)
            }.padding(20)
        }.background(ink).navigationTitle("Walking").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Replace baseline? A successful new baseline also clears previous assessments. An unusable recording keeps your existing data.", isPresented: $replacing, titleVisibility: .visible) {
                Button("Record new baseline", role: .destructive) { model.prepareWalk(.baseline) }
            }
    }
}

struct ReportsView: View {
    @ObservedObject var model: AppModel
    @State private var deleting = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Observations,\nready to share.").font(.largeTitle.bold())
                Text("Reports summarize measured changes for a clinician to review. No diagnosis is generated.").foregroundStyle(.secondary)
                if model.saved.assessments.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(mint)
                        Text("Your first report starts with two walks.").font(.title2.bold())
                        Text("Record a baseline and a comparison walk in the Walking tab.").foregroundStyle(.secondary)
                    }.card()
                }
                if let baseline = model.saved.baseline {
                    ForEach(model.saved.assessments) { record in
                        let comparison = Comparison(baseline: baseline, current: record)
                        VStack(alignment: .leading, spacing: 14) {
                            Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Text(comparison.headline).font(.title2.bold())
                            HStack {
                                metric("BASELINE", value: baseline.meanSpeed)
                                Spacer()
                                Image(systemName: "arrow.right").accessibilityHidden(true)
                                Spacer()
                                metric("THIS WALK", value: record.meanSpeed)
                            }
                            Text(String(format: "Usable position %.0f%% · motion %.0f%%", record.coverage * 100, record.motionCoverage * 100)).font(.footnote).foregroundStyle(.secondary)
                            ForEach(comparison.comparabilityIssues + comparison.flags, id: \.self) { Text($0).font(.callout) }
                            if comparison.comparabilityIssues.isEmpty && comparison.flags.isEmpty {
                                Text("No demo threshold crossed does not mean movement is medically normal.").font(.footnote).foregroundStyle(.secondary)
                            }
                            Button { model.export(record) } label: { Label("Share PDF report", systemImage: "square.and.arrow.up") }
                                .buttonStyle(.borderedProminent).tint(mint).foregroundStyle(ink)
                        }.card()
                    }
                }
                Text("Camera images are not saved. Sensor-derived walks stay on this device until you share a report. Up to 20 assessments are kept with the current baseline.").font(.footnote).foregroundStyle(.secondary)
                Button("Delete all local walks and reports", role: .destructive) { deleting = true }
                    .disabled(model.recording != nil || model.countdown > 0)
            }.padding(20)
        }.background(ink).navigationTitle("Reports").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Delete baseline, assessments, notes, and generated reports on this device? Shared copies are unaffected.", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete local data", role: .destructive) { model.eraseData() }
            }
    }
    private func metric(_ title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2.bold()).foregroundStyle(mint)
            Text(String(format: "%.2f m/s", value)).font(.title3.monospacedDigit().bold())
        }
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
                    Text("\(target.name) · \(String(format: "%.1f m", target.distance))")
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
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}
