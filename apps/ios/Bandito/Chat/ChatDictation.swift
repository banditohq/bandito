import AVFoundation
import Foundation
import Speech

/// Dictation into the message box: the microphone feeds Apple's speech recognition, and the words come back as they are
/// recognised. Permission is asked here, at the first use, after the screen has said why (`hasAsked`); a refusal is an
/// outcome the screen explains, not a crash.
@MainActor
final class ChatDictation {
    enum Outcome: Equatable {
        case started
        case finished
        case deniedMicrophone
        case deniedSpeech
        case unavailable
        case failed
    }

    private static let askedKey = "chat.dictation.asked"

    /// Whether the person has been through the explanation and the system's questions once.
    static var hasAsked: Bool { UserDefaults.standard.bool(forKey: askedKey) }

    private(set) var isListening = false
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onEnd: (() -> Void)?

    /// Starts listening. `onPartial` gets the whole text recognised so far each time it grows.
    func start(onPartial: @escaping (String) -> Void, onEnd: @escaping () -> Void = {}) async -> Outcome {
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        guard await Self.speechAllowed() else { return .deniedSpeech }
        guard await Self.microphoneAllowed() else { return .deniedMicrophone }
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else { return .unavailable }
        stop()
        self.onEnd = onEnd

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let sink = BufferSink(request)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }
            engine.prepare()
            try engine.start()
        } catch {
            teardown()
            return .failed
        }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self else { return }
                if let text, self.isListening { onPartial(text) }
                if final || error != nil { self.finish() }
            }
        }
        isListening = true
        return .started
    }

    func stop() {
        guard isListening || request != nil else { return }
        request?.endAudio()
        teardown()
    }

    private func finish() {
        let handler = onEnd
        teardown()
        handler?()
    }

    private func teardown() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        task = nil
        request = nil
        isListening = false
        onEnd = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func speechAllowed() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        default: return false
        }
    }
}

/// Hands the microphone's buffers to the recognition request from the audio thread.
private final class BufferSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest

    init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }
}
