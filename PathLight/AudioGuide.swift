import AVFoundation
import Combine

/// Main-thread scheduler. A single clock owns the beep cadence, independently of inference.
final class AudioGuide: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var route = "Audio not started"
    @Published var stereoAvailable = false
    @Published var error: String?
    @Published var muted = false {
        didSet { if muted { player?.stop(); speech.stopSpeaking(at: .immediate) } }
    }
    private let speech = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var target: Obstacle?
    private var announcementID = 0
    private var targetID = 0
    private var spokenTargetID: Int?
    private var speechGate = DetectionSpeechGate()
    private var lastBeep = -Double.infinity
    private var detectionUtterance: AVSpeechUtterance?
    private var testingUntil = -Double.infinity
    private var urgentPending = false
    private var warnedCloseTargetID: Int?

    override init() {
        super.init()
        speech.delegate = self
    }

    func start() {
        speechGate = DetectionSpeechGate()
        lastBeep = -.infinity
        warnedCloseTargetID = nil
        spokenTargetID = nil
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audio.setActive(true)
            guard let url = Bundle.main.url(forResource: "beep", withExtension: "wav") else {
                throw NSError(domain: "PathLight", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing beep.wav resource."])
            }
            player = try AVAudioPlayer(contentsOf: url)
            player?.volume = 0.35
            player?.prepareToPlay()
            error = nil
            refreshRoute()
            if timer == nil {
                let clock = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in self?.tick() }
                RunLoop.main.add(clock, forMode: .common) // Keep ticking while the screen scrolls.
                timer = clock
            }
        } catch { self.error = "Audio could not start: \(error.localizedDescription)" }
    }

    func refreshRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        route = outputs.map(\.portName).joined(separator: ", ")
        stereoAvailable = outputs.contains { $0.portType == .bluetoothA2DP || $0.portType == .headphones }
    }

    func update(_ found: Obstacle?, announcementID: Int, targetID: Int) {
        let changed = self.targetID != targetID
        // Range/announcement changes on the SAME target never cancel its spoken direction.
        if changed && detectionUtterance != nil { speech.stopSpeaking(at: .immediate) }
        if found == nil {
            if target != nil {
                player?.stop()
                if detectionUtterance != nil { speech.stopSpeaking(at: .immediate) }
            }
            urgentPending = false
        } else if changed || target == nil {
            lastBeep = -.infinity
            urgentPending = (found?.range ?? .infinity) <= 2.5
        }
        if let found = found, found.range <= 1.2, warnedCloseTargetID != targetID {
            urgentPending = true
            warnedCloseTargetID = targetID
            // Interrupt once on entering very close range, never on each camera update.
            if speech.isSpeaking && (detectionUtterance == nil || changed) {
                speech.stopSpeaking(at: .immediate)
            }
        }
        target = found
        self.targetID = targetID
        self.announcementID = announcementID
        tick()
    }

    func clear() {
        target = nil
        urgentPending = false
        player?.stop()
        speech.stopSpeaking(at: .immediate)
        testingUntil = -.infinity
    }

    func stop() {
        clear()
        timer?.invalidate()
        timer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func say(_ text: String, interrupt: Bool = false) {
        guard !muted else { return }
        if interrupt { speech.stopSpeaking(at: .immediate) }
        guard !speech.isSpeaking else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        speech.speak(utterance)
    }

    func test(_ side: Side) {
        if timer == nil { start() }
        testingUntil = ProcessInfo.processInfo.systemUptime + 1.3
        speech.stopSpeaking(at: .immediate)
        player?.stop()
        beep(side)
    }

    private func beep(_ side: Side) {
        guard !muted, player?.isPlaying != true else { return }
        player?.currentTime = 0
        player?.pan = side.pan
        player?.play()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !muted, now > testingUntil else { return }
        guard let nearest = target, now >= nearest.observedAt,
              now - nearest.observedAt <= NavigationPolicy.freshness else {
            player?.stop()
            if detectionUtterance != nil { speech.stopSpeaking(at: .immediate) }
            return
        }
        if let distance = nearest.distance,
           now - lastBeep >= NavigationPolicy.beepInterval(distance: distance),
           player?.isPlaying != true {
            beep(nearest.side)
            lastBeep = now
        }
        // Give the first very-close warning its own token, even if rounded range barely changed.
        let speechID = announcementID * 2 + (warnedCloseTargetID == targetID ? 1 : 0)
        if speechGate.consume(id: speechID, time: now, speechBusy: speech.isSpeaking,
                              urgent: urgentPending || (nearest.range <= 2.5 && spokenTargetID != targetID)) {
            let utterance = AVSpeechUtterance(string: nearest.phrase)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = 0.52
            detectionUtterance = utterance
            spokenTargetID = targetID
            urgentPending = false
            speech.speak(utterance)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        detectionEnded(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        detectionEnded(utterance)
    }

    private func detectionEnded(_ utterance: AVSpeechUtterance) {
        if utterance === detectionUtterance {
            speechGate.ended(at: ProcessInfo.processInfo.systemUptime)
            detectionUtterance = nil
        }
    }
}
