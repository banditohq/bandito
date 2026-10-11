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
        /// The engine is done. Nil when it ended because it was stopped.
        var onEnd: (DictationFailure?) -> Void
    }

    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var stopping = false
    private var callbacks: Callbacks?

    /// Asks for the microphone, then for speech recognition. Nil when both are allowed.
    static func permissions() async -> DictationDenial? {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { return .microphone }
        return await speechAuthorization() == .authorized ? nil : .speech
    }

    // The system calls the handlers below on its own queues. A closure written inside this @MainActor class would be
    // main-actor isolated and trap when it runs there (`dispatch_assert_queue`), so each is made in a nonisolated function.

    nonisolated private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    nonisolated private static func tap(into request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func resultHandler(
        _ deliver: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            deliver(result?.bestTranscription.formattedString, result?.isFinal == true, error != nil)
        }
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
        // A tap left from an earlier run would make installTap raise; remove it before installing ours.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tap(into: request))
        do {
            audio.prepare()
            try audio.start()
        } catch {
            tearDown()
            return .engine
        }
        self.request = request
        stopping = false
        self.callbacks = callbacks
        let handler = Self.resultHandler { [weak self] text, isFinal, failed in
            Task { @MainActor in self?.deliver(text: text, isFinal: isFinal, failed: failed) }
        }
        task = recognizer.recognitionTask(with: request, resultHandler: handler)
        return nil
    }

    private func deliver(text: String?, isFinal: Bool, failed: Bool) {
        guard let callbacks else { return }
        if let text { callbacks.onText(text) }
        guard isFinal || failed else { return }
        let failure: DictationFailure? = failed && !stopping ? .engine : nil
        tearDown()
        self.callbacks = nil
        callbacks.onEnd(failure)
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

    /// Every path ends here, so the tap is always removed: removing one that is not there does nothing, and a dictation
    /// that fails and is started again finds the bus free.
    private func tearDown() {
        audio.inputNode.removeTap(onBus: 0)
        if audio.isRunning { audio.stop() }
        task = nil
        request = nil
    }
}
