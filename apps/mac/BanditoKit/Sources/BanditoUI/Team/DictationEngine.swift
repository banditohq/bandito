import AVFoundation
import Foundation
import Speech

/// Speech recognition on this Mac. Microphone audio goes to `SFSpeechRecognizer` with `requiresOnDeviceRecognition`,
/// so nothing is sent over the network; a language without an offline model is refused instead.
@MainActor
final class DictationEngine {
    struct Callbacks {
        /// The newest best transcription of everything said so far in this dictation.
        var onText: (String) -> Void
        /// A buffer of microphone audio with its level (RMS, 0 to 1).
        var onLevel: (Float) -> Void
        /// The engine is done. Nil when it ended because it was stopped.
        var onEnd: (DictationFailure?) -> Void
    }

    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var stopping = false

    /// Asks for the microphone, then for speech recognition. Nil when both are allowed.
    static func permissions() async -> DictationDenial? {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { return .microphone }
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return status == .authorized ? nil : .speech
    }

    /// Starts listening in `tag`'s language. Returns the failure when it cannot start.
    func start(tag: String, languageName: String, _ callbacks: Callbacks) -> DictationFailure? {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: tag)), recognizer.isAvailable,
            recognizer.supportsOnDeviceRecognition
        else {
            return .onDeviceUnavailable(language: languageName)
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let input = audio.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
            let level = Self.level(of: buffer)
            DispatchQueue.main.async { callbacks.onLevel(level) }
        }
        do {
            audio.prepare()
            try audio.start()
        } catch {
            input.removeTap(onBus: 0)
            return .engine
        }
        self.request = request
        stopping = false
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result { callbacks.onText(result.bestTranscription.formattedString) }
                guard result?.isFinal == true || error != nil else { return }
                self?.tearDown()
                let failed = error != nil && self?.stopping != true
                callbacks.onEnd(failed ? .engine : nil)
            }
        }
        return nil
    }

    /// Ends the audio; the recogniser then delivers its last text and `onEnd`.
    func stop() {
        guard audio.isRunning else {
            tearDown()
            return
        }
        stopping = true
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
    }

    private func tearDown() {
        if audio.isRunning { audio.stop() }
        task = nil
        request = nil
    }

    /// Root mean square of the first channel, clamped to 0 to 1.
    private nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            sum += samples[index] * samples[index]
        }
        return min(1, (sum / Float(buffer.frameLength)).squareRoot())
    }
}
