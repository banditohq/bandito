import AVFoundation
import Foundation
import Observation

/// Reads text aloud with the system voice. One reading at a time: a new one stops the last. `speakingKey` is the row
/// being read, so its menu says "Stop reading".
@MainActor
@Observable
final class SpeechOutput: NSObject {
    static let shared = SpeechOutput()

    /// The row id of the message being read; nil when nothing is read.
    private(set) var speakingKey: String?

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    /// The utterance that was spoken last. A callback from an older one must not clear the newer reading.
    @ObservationIgnored private var current: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, key: String, voiceTag: String) {
        stop()
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: voiceTag)
        current = ObjectIdentifier(utterance)
        speakingKey = key
        synthesizer.speak(utterance)
    }

    func stop() {
        current = nil
        speakingKey = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    fileprivate func ended(_ utterance: ObjectIdentifier) {
        guard current == utterance else { return }
        current = nil
        speakingKey = nil
    }
}

extension SpeechOutput: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }
}
