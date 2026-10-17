import AVFoundation
import Combine

/// Main-thread audio scheduler. Stale sensor data never keeps a proximity tone alive.
final class AudioGuide: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var route = "Audio not started"
    @Published var stereoAvailable = false
    @Published var error: String?
    @Published var muted = false
    private let speech = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var target: Obstacle?
    private var announcementID: Int?
    private var speechGate = DetectionSpeechGate()
    private var updatedAt = Date.distantPast
    private var lastBeep = Date.distantPast
    private var detectionUtterance: AVSpeechUtterance?
    private var testingUntil = Date.distantPast

    override init() {
        super.init()
        speech.delegate = self
    }

    func start() {
        speechGate = DetectionSpeechGate()
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audio.setActive(true)
            guard let url = Bundle.main.url(forResource: "beep", withExtension: "wav") else {
                throw NSError(domain: "PathLight", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing beep.wav resource."])
            }
            player = try AVAudioPlayer(contentsOf: url)
            player?.volume = 0.35
            player?.prepareToPlay()
            error = nil
            refreshRoute()
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
            }
        } catch { self.error = "Audio could not start: \(error.localizedDescription)" }
    }

    func refreshRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        route = outputs.map(\.portName).joined(separator: ", ")
        // An A2DP/headphone route is necessary, but mono audio or system processing can still defeat panning.
        stereoAvailable = outputs.contains { $0.portType == .bluetoothA2DP || $0.portType == .headphones }
    }

    func update(_ found: Obstacle?, announcementID: Int) {
        target = found
        self.announcementID = announcementID
        updatedAt = Date()
    }

    func clear() {
        target = nil
        updatedAt = .distantPast
        player?.stop()
        speech.stopSpeaking(at: .immediate)
        testingUntil = .distantPast
        // A brief tracking interruption must not bypass the four-second speech cooldown.
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
        utterance.rate = 0.48
        speech.speak(utterance)
    }

    func test(_ side: Side) {
        if timer == nil { start() }
        testingUntil = Date().addingTimeInterval(1.3)
        speech.stopSpeaking(at: .immediate)
        beep(side)
    }

    private func beep(_ side: Side) {
        guard !muted else { return }
        player?.stop()
        player?.currentTime = 0
        player?.pan = side.pan
        player?.play()
    }

    private func tick() {
        let now = Date()
        guard !muted, now > testingUntil,
              now.timeIntervalSince(updatedAt) < 0.85,
              let nearest = target else { return }
        let interval = min(1.4, max(0.16, 0.16 + (nearest.distance - 0.35) * 0.34))
        if now.timeIntervalSince(lastBeep) >= interval {
            beep(nearest.side)
            lastBeep = now
        }
        if let id = announcementID,
           speechGate.consume(id: id, time: now.timeIntervalSinceReferenceDate, speechBusy: speech.isSpeaking) {
            let utterance = AVSpeechUtterance(string: nearest.phrase)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = 0.48
            detectionUtterance = utterance
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
            speechGate.ended(at: Date().timeIntervalSinceReferenceDate)
            detectionUtterance = nil
        }
    }
}
