import AVFoundation
import Combine

/// Main-thread audio scheduler. Stale sensor data never keeps a proximity tone alive.
final class AudioGuide: NSObject, ObservableObject {
    @Published var route = "Audio not started"
    @Published var stereoAvailable = false
    @Published var error: String?
    @Published var muted = false
    private let speech = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var obstacles: [Obstacle] = []
    private var updatedAt = Date.distantPast
    private var lastBeep = Date.distantPast
    private var lastSpoken = Date.distantPast
    private var lastPhrase = ""
    private var sideIndex = 0
    private var testingUntil = Date.distantPast

    func start() {
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

    func update(_ found: [Obstacle]) { obstacles = found; updatedAt = Date() }

    func clear() {
        obstacles = []
        updatedAt = .distantPast
        player?.stop()
        speech.stopSpeaking(at: .immediate)
        testingUntil = .distantPast
        lastSpoken = .distantPast
        lastPhrase = ""
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
              let nearest = obstacles.first else { return }
        // Alternate occupied sectors so a persistent left obstacle cannot hide a right one.
        let sectors = Side.allCases.compactMap { side in obstacles.first { $0.side == side } }
        let interval = min(1.4, max(0.16, 0.16 + (nearest.distance - 0.35) * 0.34))
        if now.timeIntervalSince(lastBeep) >= interval, !sectors.isEmpty {
            beep(sectors[sideIndex % sectors.count].side)
            sideIndex += 1
            lastBeep = now
        }
        let phrase = nearest.phrase
        let delay = phrase == lastPhrase ? 7.0 : 3.5
        if now.timeIntervalSince(lastSpoken) > delay, !speech.isSpeaking {
            say(phrase)
            lastPhrase = phrase
            lastSpoken = now
        }
    }
}
