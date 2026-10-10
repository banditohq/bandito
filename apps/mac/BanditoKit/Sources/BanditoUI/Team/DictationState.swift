import Foundation

/// Where a dictation is: idle, asking for permission, listening, or finishing.
enum DictationPhase: Equatable {
    case idle
    case requesting
    case recording
    case stopping
}

/// Which permission was refused.
enum DictationDenial: Equatable {
    case microphone
    case speech
}

/// Why a dictation did not run, or ended on its own.
enum DictationFailure: Equatable {
    case denied(DictationDenial)
    /// This Mac has no offline model for the language. Audio is never sent over the network instead.
    case onDeviceUnavailable(language: String)
    case engine
}

enum DictationEvent: Equatable {
    /// The button or ⌥⌘D. While a dictation runs it means stop.
    case start
    /// Permissions and the offline recogniser are there; audio runs.
    case granted
    /// Stop asked for: the button, Esc, or two seconds of silence.
    case stop
    /// The engine released the microphone.
    case finished
    /// The dictation did not run, or broke off.
    case failed(DictationFailure)
}

/// The dictation state machine: idle → requesting → recording → stopping → idle. Pure.
enum DictationState {
    static func next(_ phase: DictationPhase, _ event: DictationEvent) -> DictationPhase {
        switch event {
        case .start:
            switch phase {
            case .idle: return .requesting
            case .requesting, .recording: return .stopping
            case .stopping: return .stopping
            }
        case .granted:
            return phase == .requesting ? .recording : phase
        case .stop:
            return phase == .idle ? .idle : .stopping
        case .finished, .failed:
            return .idle
        }
    }
}

/// Two seconds without voice end a dictation. Voice is a buffer whose level reaches `threshold`, or new recognised text.
struct SilenceWatch {
    static let threshold: Float = 0.02
    static let window: TimeInterval = 2

    private(set) var lastVoice: Date

    init(since start: Date) {
        lastVoice = start
    }

    mutating func heard(level: Float, at time: Date) {
        if level >= Self.threshold { lastVoice = time }
    }

    mutating func heardText(at time: Date) {
        lastVoice = time
    }

    func isSilent(at time: Date) -> Bool {
        time.timeIntervalSince(lastVoice) >= Self.window
    }
}
