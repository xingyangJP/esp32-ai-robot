import Foundation
import Speech
import AVFoundation

/// iPhone-side voice I/O (the car has no mic/speaker).
/// STT: tap the mic, transcribe to a goal string. TTS: speak the robot's words.
@MainActor
final class Speech: NSObject, ObservableObject {
    @Published var transcript = ""
    @Published var listening = false

    var langCode = "en-US"   // BCP-47, e.g. "en-US" or "ja-JP"; set by RobotController
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synth = AVSpeechSynthesizer()
    private var speakUntil = Date.distantPast   // after a line ENDS, hold this brief cooldown breath before the next
    private var speakHardCap = Date.distantPast // absolute upper bound for the CURRENT line (stuck-synth safety)
    private var lastSpoken = ""
    private let speechCooldown = 0.4            // a breath between spoken lines (seconds)

    override init() {
        super.init()
        synth.delegate = self                // stamp lastSpeechEndedAt on finish/cancel
    }

    /// Mic-button entry point: stop if listening, else request permissions and start
    /// ONLY once both speech + mic are granted (hopping back to the main actor).
    func toggle() {
        if listening { stopListening(); return }
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioApplication.requestRecordPermission { micOK in
                let ok = (status == .authorized) && micOK
                Task { @MainActor in if ok { self.startListening() } }
            }
        }
    }

    /// Start listening; returns final transcript via the `transcript` published property.
    func startListening() {
        guard !listening,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: langCode)),
              recognizer.isAvailable else { return }
        transcript = ""
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.request?.append(buf)
        }
        engine.prepare()
        try? engine.start()
        listening = true

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result { Task { @MainActor in self.transcript = result.bestTranscription.formattedString } }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in self.stopListening() }
            }
        }
    }

    func stopListening() {
        guard listening else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if t == lastSpoken { return }                    // don't repeat the exact same line back-to-back
        let now = Date()
        if now < speakUntil { return }                   // a breath after the PREVIOUS line ended
        // Let the CURRENT line finish before starting a new one. Gate on the synth's OWN speaking
        // state (it clears itself even if our didFinish callback is missed), bounded by a generous
        // time cap so a wedged synth can never silence us forever. This is the fix for
        // "前方には… 前方には…": the old time-ONLY estimate under-ran long Japanese lines, so the next
        // decision cut the sentence mid-word via stopSpeaking. Now we never cut a line that is
        // genuinely still speaking (until the hard cap), so each observation is spoken to the end.
        if synth.isSpeaking && now < speakHardCap { return }
        lastSpoken = t
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }   // only reached PAST the hard cap (stuck synth)
        let u = AVSpeechUtterance(string: t)
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.voice = AVSpeechSynthesisVoice(language: langCode)
        // Generous UPPER bound for this line; the real end arrives via didFinish (which sets the
        // cooldown breath). Japanese at the default rate runs ~0.16-0.2 s/char, so over-estimate.
        speakHardCap = now.addingTimeInterval(max(2.0, Double(t.count) * 0.18) + 3.0)
        speakUntil = .distantPast                        // no cooldown yet — didFinish opens the next line
        synth.speak(u)
    }

    /// Immediately silence speech AND flush everything queued behind it — without this a
    /// STOP leaves a backlog of "見えません" draining for seconds.
    func stopSpeaking() {
        _ = synth.stopSpeaking(at: .immediate)
        lastSpoken = ""
        speakUntil = Date.distantPast          // allow the next line right after a STOP-clear
        speakHardCap = Date.distantPast
    }
}

extension Speech: AVSpeechSynthesizerDelegate {
    // When a line actually finishes (or is cancelled), only a breath remains before the next —
    // shorten speakUntil so we don't over-wait the (upper-bound) estimate.
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.speakUntil = Date().addingTimeInterval(self.speechCooldown) }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.speakUntil = Date().addingTimeInterval(self.speechCooldown) }
    }
}
