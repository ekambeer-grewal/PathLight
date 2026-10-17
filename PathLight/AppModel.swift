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
    @Published var speedNote = "Waiting for tracking"
    @Published var detectorStatus = "Loading YOLO11n…"
    @Published var detectorReady = false
    @Published var inferenceMilliseconds: Double?
    var previewSize = CGSize(width: 390, height: 220)
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
    private var latestTurnRate = 0.0
    private var lastSpeedTime = -Double.infinity
    private var poseTracker = PoseSpeedTracker()
    private var selector = TargetSelector()
    private let scanQueue = DispatchQueue(label: "PathLight.scene-scanning", qos: .userInitiated)
    private let detector = YOLODetector()
    private let wallQueue = DispatchQueue(label: "PathLight.walls", qos: .utility)
    private var wallInFlight = false
    private var lastWall = 0.0
    private var yoloTargets: [Obstacle] = []
    private var wallTargets: [Obstacle] = []
    private var yoloTime = -Double.infinity
    private var wallTime = -Double.infinity
    private var scanInFlight = false
    private var scanEpoch = 0
    private var navigationReady = false
    private var lastTrackingNotice = Date.distantPast
    private var countdownDeadline: Double?
    private var positionIntervalHadTurn = false
    private var mountUpright = true
    private var lastMotionTime = Date.distantPast
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
        scanQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.detector.load()
                DispatchQueue.main.async {
                    self.detectorReady = true
                    self.detectorStatus = "YOLO11n ready · on-device"
                }
            } catch {
                DispatchQueue.main.async { self.detectorStatus = "YOLO unavailable: \(error.localizedDescription)" }
            }
        }
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
              ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
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
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
            configuration.planeDetection = [.horizontal, .vertical]
        }
        configuration.worldAlignment = .gravity
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        UIApplication.shared.isIdleTimerDisabled = true
        running = true
        trackingReady = false
        status = "Move gently to initialize tracking"
        lastFrame = Date()
        lastScan = 0
        lastWall = 0
        resetCandidates()
        poseTracker.resetContinuity()
        positionIntervalHadTurn = false
        selector = TargetSelector()
        scanEpoch += 1
        speed = nil
        lastSpeedTime = -.infinity
        speedNote = "Waiting for tracking"
        audio.start()
        audio.say("Started.")
        startMotion()
        controlTimer?.invalidate()
        controlTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.clockTick() }
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
            if !self.motionReady { self.motionReady = true }
            self.mountUpright = -value.gravity.y > 0.75
            let r = value.rotationRate
            self.latestRotation = sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
            // Turning about gravity is different from ordinary chest bobbing/pitch/roll.
            let g = value.gravity
            self.latestTurnRate = abs(r.x * g.x + r.y * g.y + r.z * g.z)
            if self.latestTurnRate >= 1.2 { self.positionIntervalHadTurn = true }
            guard let start = self.recordStart, self.trackingReady else { return }
            let a = value.userAcceleration
            let tilt = acos(min(1, max(-1, -value.gravity.y))) * 180 / .pi
            let t = value.timestamp - start
            guard t >= 0, t <= (self.recording?.duration ?? 0), self.latestTurnRate < 1.2 else { return }
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
        poseTracker.resetContinuity()
        speedNote = "Waiting for tracking"
        scanEpoch += 1
        navigationReady = false
        resetCandidates()
        selector.suspend()
        status = reason
    }

    private func resetCandidates() {
        yoloTargets = []; wallTargets = []
        yoloTime = -.infinity; wallTime = -.infinity
    }

    private func clearNavigation() {
        navigationReady = false
        scanEpoch += 1
        resetCandidates()
        selector.suspend()
        obstacles = []
        audio.clear()
    }

    private func trackingNotice(_ text: String) {
        guard Date().timeIntervalSince(lastTrackingNotice) >= 6 else { return }
        audio.say(text)
        lastTrackingNotice = Date()
    }

    private func holdSpeed(_ reason: String) {
        // A clearly labeled last reading is allowed for at most one second, never recorded.
        if ProcessInfo.processInfo.systemUptime - lastSpeedTime <= 1, speed != nil {
            speedNote = "Reacquiring — last reading"
        } else {
            speed = nil
            speedNote = reason
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard running else { return }
        lastFrame = Date()
        if motionReady && !mountUpright {
            if trackingReady { clearNavigation(); trackingNotice("Mount the phone upright in portrait.") }
            trackingReady = false
            status = "Mount phone upright in portrait"
            poseTracker.resetContinuity()
            holdSpeed("Mount phone upright")
            return
        }
        guard case .normal = frame.camera.trackingState else {
            if trackingReady { clearNavigation(); trackingNotice("Tracking limited. Pause and scan slowly.") }
            trackingReady = false
            status = "Tracking limited — measurements paused"
            poseTracker.resetContinuity()
            holdSpeed("Waiting for position tracking")
            return
        }
        // Pose speed remains available even when a LiDAR depth frame is missing.
        if !trackingReady { trackingReady = true }
        updatePosition(frame)
        let liveStatus = recording == nil ? "Live · walking tracking" : "Recording a walking sample"
        if status != liveStatus { status = liveStatus }
        navigationReady = true
        let epoch = scanEpoch
        let viewport = previewSize
        // Each path has at most one frame in flight. Never enqueue a backlog of camera frames.
        if detectorReady, frame.timestamp - lastScan >= 0.1, !scanInFlight {
            lastScan = frame.timestamp
            scanInFlight = true
            scanQueue.async { [weak self] in
                guard let self = self else { return }
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    let detections = try self.detector.detect(frame)
                    let found = DepthSampler.objects(detections, frame: frame, viewport: viewport)
                    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    DispatchQueue.main.async {
                        self.scanInFlight = false
                        guard self.running, self.scanEpoch == epoch else { return }
                        self.inferenceMilliseconds = elapsed
                        guard self.accepts(frame, epoch: epoch, viewport: viewport, maxAge: 0.5) else {
                            self.detectorStatus = "YOLO11n running late · stale result dropped"
                            return
                        }
                        self.detectorStatus = "YOLO11n live · on-device"
                        self.yoloTargets = found
                        self.yoloTime = frame.timestamp
                        self.refreshSelection()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.scanInFlight = false
                        guard self.running, self.scanEpoch == epoch else { return }
                        self.detectorStatus = "YOLO error: \(error.localizedDescription)"
                        self.yoloTargets = []
                        self.yoloTime = -.infinity
                        self.refreshSelection()
                    }
                }
            }
        }
        if frame.timestamp - lastWall >= 0.15, !wallInFlight {
            lastWall = frame.timestamp
            wallInFlight = true
            wallQueue.async { [weak self] in
                let found = WallMeshScanner.scan(frame, viewport: viewport)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.wallInFlight = false
                    guard self.accepts(frame, epoch: epoch, viewport: viewport, maxAge: 0.5) else { return }
                    self.wallTargets = found
                    self.wallTime = frame.timestamp
                    self.refreshSelection()
                }
            }
        }
    }

    private func accepts(_ frame: ARFrame, epoch: Int, viewport: CGSize, maxAge: Double) -> Bool {
        running && navigationReady && trackingReady && scanEpoch == epoch && previewSize == viewport
            && ProcessInfo.processInfo.systemUptime - frame.timestamp < maxAge
    }

    private func refreshSelection() {
        guard running, navigationReady, trackingReady else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let named = now - yoloTime < 0.6 ? yoloTargets : []
        let walls = now - wallTime < 0.6 ? wallTargets : []
        let target = selector.update(named + walls, time: now, walkingSpeed: speed ?? 0)
        obstacles = target.map { [$0] } ?? []
        if navigationAudio { audio.update(target, announcementID: selector.announcementID, targetID: selector.targetID) }
    }

    private func updatePosition(_ frame: ARFrame) {
        let p = frame.camera.transform.columns.3
        guard let measurement = poseTracker.update(position: SIMD3<Float>(p.x, p.y, p.z), time: frame.timestamp) else {
            if !poseTracker.isFresh(at: frame.timestamp) { holdSpeed("Acquiring speed") }
            return
        }
        speed = measurement.displaySpeed
        lastSpeedTime = ProcessInfo.processInfo.systemUptime
        speedNote = "Live · smoothed estimate"
        let hadTurn = positionIntervalHadTurn
        positionIntervalHadTurn = false
        // Live display is independent of gyro filtering. Reports still exclude rapid turns and missing motion.
        if let start = recordStart, let kind = recording,
           measurement.startTime >= start, measurement.endTime - start <= kind.duration,
           !hadTurn, motionReady, latestTurnRate < 1.2,
           Date().timeIntervalSince(lastMotionTime) < 0.5 {
            samples.append(WalkSample(time: measurement.endTime - start,
                interval: measurement.interval, speed: measurement.rawSpeed))
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
        if kind == .assessment && (saved.baseline?.algorithmVersion ?? 1) < 2 {
            message = "Speed tracking has been updated. Record a new five-second baseline before a comparison walk."
            return
        }
        pendingKind = kind
        countdownDeadline = ProcessInfo.processInfo.systemUptime + 5
        countdown = 5
        remaining = Int(kind.duration)
        audio.say("Start walking at your usual pace. Recording starts in five seconds.", interrupt: true)
    }

    private func clockTick() {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if Date().timeIntervalSince(lastFrame) > 0.8 {
            if trackingReady || navigationReady { clearNavigation() }
            trackingReady = false
            poseTracker.resetContinuity()
            holdSpeed("Waiting for camera frames")
            status = "No fresh camera frames — pause walking"
        }
        if now - lastSpeedTime > 1, speed != nil { speed = nil; speedNote = "Acquiring speed" }
        // Expire each source using capture time, including when inference stalls.
        refreshSelection()
        if Date().timeIntervalSince(lastMotionTime) > 0.5, motionReady { motionReady = false }
        if let kind = pendingKind, let deadline = countdownDeadline {
            guard trackingReady, motionReady else {
                cancelWalk()
                message = "Countdown canceled because sensor tracking was lost. Try again."
                return
            }
            let seconds = max(0, Int(ceil(deadline - now)))
            if countdown != seconds { countdown = seconds }
            if now >= deadline {
                pendingKind = nil
                countdownDeadline = nil
                recording = kind
                samples = []
                motionSamples = []
                poseTracker.resetContinuity()
                positionIntervalHadTurn = false
                recordStart = now
                audio.say("Recording for \(Int(kind.duration)) seconds.", interrupt: true)
            }
        }
        if let start = recordStart, let kind = recording {
            let seconds = max(0, Int(ceil(kind.duration - (now - start))))
            if remaining != seconds { remaining = seconds }
            if now - start >= kind.duration { finishWalk() }
        }
    }

    func cancelWalk() {
        recording = nil
        pendingKind = nil
        countdownDeadline = nil
        recordStart = nil
        countdown = 0
        remaining = 0
        samples = []
        motionSamples = []
        audio.say("Walk canceled. No recording saved.", interrupt: true)
    }

    private func finishWalk() {
        guard let kind = recording else { return }
        let record = WalkRecord(id: UUID(), date: Date(), kind: kind, duration: kind.duration,
            samples: samples, motion: motionSamples,
            baselineID: kind == .assessment ? saved.baseline?.id : nil,
            device: "\(UIDevice.current.model); iOS \(UIDevice.current.systemVersion)", notes: sessionNotes, algorithmVersion: 2)
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
