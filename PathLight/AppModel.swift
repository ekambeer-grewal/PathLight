import ARKit
import AVFoundation
import Combine
import CoreMotion
import UIKit
import simd

final class AppModel: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()
    let audio = AudioGuide()
    private let motionManager = CMMotionManager()
    @Published var running = false
    @Published var trackingReady = false
    @Published var status = "Ready when you are"
    @Published var obstacles: [Obstacle] = []
    @Published var speed: Double?
    @Published var saved = SavedState()
    @Published var recording: WalkKind?
    @Published var remaining = 0
    @Published var countdown = 0
    @Published var message: String?
    @Published var reportURL: URL?
    @Published var sessionNotes = ""
    @Published var acknowledged = false
    @Published var navigationAudio = true
    @Published var motionReady = false

    private var observers: [NSObjectProtocol] = []
    private var controlTimer: Timer?
    private var lastFrame = Date.distantPast
    private var lastScan = 0.0
    private var latestRotation = 0.0
    private var positionIntervalHadTurn = false
    private var mountUpright = true
    private var lastMotionTime = Date.distantPast
    private var previousPosition: (SIMD3<Float>, Double)?
    private var pendingKind: WalkKind?
    private var recordStart: Double?
    private var samples: [WalkSample] = []
    private var motionSamples: [MotionSample] = []
    private let storeURL: URL
    private var starting = false
    private var startGeneration = 0

    override init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        storeURL = folder.appendingPathComponent("pathlight-records.json")
        super.init()
        session.delegateQueue = .main
        session.delegate = self
        do {
            if FileManager.default.fileExists(atPath: storeURL.path) {
                saved = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: storeURL))
            }
        } catch { message = "Saved walks could not be loaded: \(error.localizedDescription)" }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.audio.refreshRoute()
            self?.audio.clear()
            if self?.running == true { self?.audio.say("Audio route changed. Check left and right before continuing.") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.stop(reason: "Audio interrupted. Tap Start to resume.")
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func start() {
        guard !running, !starting, acknowledged else { return }
        guard ARWorldTrackingConfiguration.isSupported,
              ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
              ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
            message = "Live scanning requires a LiDAR iPhone or iPad. Use your iPhone 15 Pro Max; the Simulator cannot run these sensors."
            return
        }
        starting = true
        startGeneration += 1
        let generation = startGeneration
        let begin: (Bool) -> Void = { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self = self, self.startGeneration == generation else { return }
                self.starting = false
                guard UIApplication.shared.applicationState == .active else {
                    self.status = "Tap Start when the app is active"
                    return
                }
                guard allowed else {
                    self.message = "Camera access is off. Enable Camera for PathLight in Settings, then try again."
                    return
                }
                self.beginSession()
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: begin(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video, completionHandler: begin)
        default: begin(false)
        }
    }

    private func beginSession() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = [.sceneDepth]
        configuration.sceneReconstruction = .meshWithClassification
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal, .vertical]
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        UIApplication.shared.isIdleTimerDisabled = true
        running = true
        trackingReady = false
        status = "Move gently to initialize tracking"
        lastFrame = Date()
        lastScan = 0
        previousPosition = nil
        positionIntervalHadTurn = false
        audio.start()
        audio.say("Prototype started. Scan slowly. This does not detect stairs or drop offs.")
        startMotion()
        controlTimer?.invalidate()
        controlTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.clockTick() }
    }

    private func startMotion() {
        guard motionManager.isDeviceMotionAvailable else {
            message = "Motion sensors are unavailable. Walking assessments are disabled."
            return
        }
        motionManager.deviceMotionUpdateInterval = 1.0 / 50
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] value, error in
            guard let self = self else { return }
            guard let value = value, error == nil else {
                self.motionReady = false
                if self.recording != nil || self.pendingKind != nil { self.cancelWalk() }
                self.message = "Motion data unavailable. Check Motion & Fitness permission in Settings."
                return
            }
            self.lastMotionTime = Date()
            self.motionReady = true
            self.mountUpright = -value.gravity.y > 0.75
            let r = value.rotationRate
            self.latestRotation = sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
            if self.latestRotation >= 0.8 { self.positionIntervalHadTurn = true }
            guard let start = self.recordStart, self.trackingReady else { return }
            let a = value.userAcceleration
            let tilt = acos(min(1, max(-1, -value.gravity.y))) * 180 / .pi
            let t = value.timestamp - start
            guard t >= 0, t <= 30, self.latestRotation < 0.8 else { return }
            self.motionSamples.append(MotionSample(time: t, rotation: self.latestRotation,
                acceleration: sqrt(a.x * a.x + a.y * a.y + a.z * a.z) * 9.80665, tilt: tilt))
        }
    }

    func stop(reason: String = "Paused") {
        startGeneration += 1
        starting = false
        if recording != nil || pendingKind != nil { cancelWalk() }
        session.pause()
        motionManager.stopDeviceMotionUpdates()
        controlTimer?.invalidate()
        controlTimer = nil
        audio.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        running = false
        trackingReady = false
        motionReady = false
        obstacles = []
        speed = nil
        previousPosition = nil
        status = reason
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard running else { return }
        lastFrame = Date()
        if motionReady && !mountUpright {
            if trackingReady { audio.clear(); audio.say("Mount the phone upright in portrait.") }
            trackingReady = false
            status = "Mount phone upright in portrait"
            obstacles = []
            speed = nil
            previousPosition = nil
            return
        }
        guard case .normal = frame.camera.trackingState, frame.sceneDepth != nil else {
            if trackingReady { audio.clear(); audio.say("Tracking limited. Pause and scan slowly.") }
            trackingReady = false
            status = "Tracking limited — measurements paused"
            obstacles = []
            speed = nil
            previousPosition = nil
            return
        }
        trackingReady = true
        status = recording == nil ? "Live · camera + LiDAR" : "Recording a walking sample"
        updatePosition(frame)
        guard frame.timestamp - lastScan >= 0.25 else { return }
        lastScan = frame.timestamp
        obstacles = SceneScanner.scan(frame)
        if navigationAudio { audio.update(obstacles) }
    }

    private func updatePosition(_ frame: ARFrame) {
        let p = frame.camera.transform.columns.3
        let position = SIMD3<Float>(p.x, 0, p.z)
        let time = frame.timestamp
        guard let previous = previousPosition else {
            previousPosition = (position, time)
            positionIntervalHadTurn = false
            return
        }
        let dt = time - previous.1
        guard dt >= 0.5 else { return }
        previousPosition = (position, time)
        let hadTurn = positionIntervalHadTurn
        positionIntervalHadTurn = false
        let velocity = Double(simd_distance(position, previous.0)) / dt
        guard dt <= 0.8, velocity.isFinite, velocity < 3,
              !hadTurn, latestRotation < 0.8, Date().timeIntervalSince(lastMotionTime) < 0.3 else {
            speed = nil
            return
        }
        // This deadband reduces stationary tracking jitter; it also hides very slow movement.
        let measured = velocity < 0.05 ? 0 : velocity
        speed = measured
        if let start = recordStart, previous.1 >= start, time - start <= 30 {
            samples.append(WalkSample(time: time - start, interval: dt, speed: measured))
        }
    }

    func prepareWalk(_ kind: WalkKind) {
        guard running, trackingReady, motionReady, recording == nil, pendingKind == nil else {
            message = "Start sensors and wait for live tracking and motion before recording."
            return
        }
        if kind == .assessment && saved.baseline == nil {
            message = "Record a usable baseline first."
            return
        }
        pendingKind = kind
        countdown = 5
        remaining = 30
        audio.say("Walk begins in five seconds. Use the same clear, level route and harness position.", interrupt: true)
    }

    private func clockTick() {
        guard running else { return }
        if Date().timeIntervalSince(lastFrame) > 1.2 {
            trackingReady = false
            obstacles = []
            speed = nil
            previousPosition = nil
            audio.clear()
            status = "No fresh camera frames — pause walking"
        }
        if Date().timeIntervalSince(lastMotionTime) > 0.5 { motionReady = false }
        if let kind = pendingKind {
            guard trackingReady, motionReady else {
                cancelWalk()
                message = "Countdown canceled because sensor tracking was lost. Try again."
                return
            }
            countdown -= 1
            if countdown == 0 {
                pendingKind = nil
                recording = kind
                samples = []
                motionSamples = []
                previousPosition = nil
                recordStart = ProcessInfo.processInfo.systemUptime
                audio.say("Start walking.", interrupt: true)
            }
        }
        if let start = recordStart {
            remaining = max(0, Int(ceil(30 - (ProcessInfo.processInfo.systemUptime - start))))
            if remaining == 0 { finishWalk() }
        }
    }

    func cancelWalk() {
        recording = nil
        pendingKind = nil
        recordStart = nil
        countdown = 0
        remaining = 0
        samples = []
        motionSamples = []
        audio.say("Walk canceled. No recording saved.", interrupt: true)
    }

    private func finishWalk() {
        guard let kind = recording else { return }
        let record = WalkRecord(id: UUID(), date: Date(), kind: kind, duration: 30,
            samples: samples, motion: motionSamples,
            baselineID: kind == .assessment ? saved.baseline?.id : nil,
            device: "\(UIDevice.current.model); iOS \(UIDevice.current.systemVersion)", notes: sessionNotes)
        recording = nil
        recordStart = nil
        remaining = 0
        if kind == .baseline {
            guard record.usable else {
                message = "Baseline not saved. " + record.qualityIssues.joined(separator: " ")
                audio.say("Baseline quality is insufficient. Please repeat.", interrupt: true)
                return
            }
            // UI asks before replacing; old assessments must not silently compare with a new baseline.
            saved.baseline = record
            saved.assessments = []
        } else {
            saved.assessments.insert(record, at: 0)
            saved.assessments = Array(saved.assessments.prefix(20))
        }
        if persist() {
            audio.say(kind == .baseline ? "Baseline saved." : "Assessment saved. Review your results.", interrupt: true)
        }
    }

    @discardableResult private func persist() -> Bool {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(saved)
            try data.write(to: storeURL, options: [.atomic, .completeFileProtection])
            var protectedURL = storeURL
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try protectedURL.setResourceValues(resourceValues)
            return true
        } catch {
            message = "Walk is available in memory but could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    func eraseData() {
        do {
            if FileManager.default.fileExists(atPath: storeURL.path) { try FileManager.default.removeItem(at: storeURL) }
            let reports = FileManager.default.temporaryDirectory.appendingPathComponent("PathLightReports")
            if FileManager.default.fileExists(atPath: reports.path) { try FileManager.default.removeItem(at: reports) }
            saved = SavedState()
            reportURL = nil
            sessionNotes = ""
        } catch { message = "Could not delete local data: \(error.localizedDescription)" }
    }

    func export(_ assessment: WalkRecord) {
        guard let baseline = saved.baseline else { return }
        do { reportURL = try ReportWriter.write(baseline: baseline, current: assessment) }
        catch { message = "Report could not be created: \(error.localizedDescription)" }
    }

    func sessionWasInterrupted(_ session: ARSession) { stop(reason: "Session interrupted. Tap Start to resume.") }
    func session(_ session: ARSession, didFailWithError error: Error) {
        stop(reason: "Sensor session stopped")
        message = error.localizedDescription
    }
}
