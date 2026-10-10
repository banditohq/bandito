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

/// When a dictation ends by itself: two seconds after its last recognised fragment; with no fragment at all, eight
/// seconds after it started. Only recognised text counts, not the sound level.
struct SilenceWatch {
    static let afterText: TimeInterval = 2
    static let noSpeech: TimeInterval = 8

    private(set) var started: Date
    /// When the newest non-empty fragment was recognised; nil while nothing has been.
    private(set) var lastFragment: Date?

    init(since start: Date) {
        started = start
    }

    /// A partial result. Whitespace-only text is not speech.
    mutating func recognised(_ fragment: String, at time: Date) {
        guard !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastFragment = time
    }

    func isSilent(at time: Date) -> Bool {
        if let lastFragment {
            return time.timeIntervalSince(lastFragment) >= Self.afterText
        }
        return time.timeIntervalSince(started) >= Self.noSpeech
    }
}

/// Esc belongs to the dictation while it records and the composer's field has the focus: it stops the dictation, and the
/// app's Esc command (deny an approval) steps aside. Pure.
enum DictationEscape {
    static func takesEscape(_ phase: DictationPhase, fieldFocused: Bool) -> Bool {
        phase == .recording && fieldFocused
    }
}

/// The field of the composer is read-only while a dictation runs (from the start until the last words are in), so
/// typing and paste cannot be eaten by the dictated text. Pure.
enum DictationFreeze {
    static func isFrozen(_ phase: DictationPhase) -> Bool {
        phase != .idle
    }

    /// The text the field must show: the dictated text when the person changed it during a dictation, else nil.
    static func restored(current: String, dictated: String?, phase: DictationPhase) -> String? {
        guard isFrozen(phase), let dictated, current != dictated else { return nil }
        return dictated
    }
}
