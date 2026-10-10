import BanditoL10n
import Foundation
import Observation
import SwiftUI

/// Runs one dictation for the composer: asks for permission, listens, writes the text into the draft at the caret, and
/// ends on a second press, Esc, or two seconds of silence. The rules are `DictationState`, `DictationInsertion` and
/// `SilenceWatch`; this type only connects them to the engine.
@MainActor
@Observable
final class DictationController {
    private(set) var phase: DictationPhase = .idle
    /// Why the last dictation did not run; the composer shows it above the field until the next start.
    private(set) var failure: DictationFailure?

    @ObservationIgnored private let engine = DictationEngine()
    @ObservationIgnored private var span: DictationSpan?
    @ObservationIgnored private var text: Binding<String>?
    @ObservationIgnored private var placeCaret: ((Int) -> Void)?
    @ObservationIgnored private var silence: SilenceWatch?
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    var isActive: Bool { phase != .idle }

    /// Starts a dictation into `text` at `caret`, or stops the one that runs.
    func toggle(text: Binding<String>, caret: Int?, placeCaret: @escaping (Int) -> Void) {
        if isActive {
            stop()
            return
        }
        failure = nil
        phase = DictationState.next(phase, .start)
        self.text = text
        self.placeCaret = placeCaret
        span = DictationInsertion.start(in: text.wrappedValue, caret: caret)
        Task { await begin() }
    }

    /// Ends the dictation: the engine delivers its last words and `onEnd` takes the state to idle. Stopped while the
    /// permission prompt is up, nothing has started yet: `begin` sees the stop and finishes there.
    func stop() {
        guard isActive else { return }
        apply(.stop)
        watchdog?.cancel()
        watchdog = nil
        engine.stop()
        // Safety net: the recogniser may never send its final text. The state must not stay in `stopping`.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.phase == .stopping else { return }
            self.finish()
        }
    }

    /// The composer went away: the dictation ends without a message.
    func cancel() {
        guard isActive else { return }
        watchdog?.cancel()
        engine.stop()
        finish()
    }

    private func begin() async {
        let language = SpeechLanguage.appLanguage
        let tag = SpeechLanguage.dictationTag(appLanguage: language)
        let name = Locale(identifier: tag).localizedString(forIdentifier: tag) ?? tag
        if let denial = await DictationEngine.permissions() {
            fail(.denied(denial))
            return
        }
        guard phase == .requesting else {
            // Stopped while the permission prompt was up: nothing starts.
            finish()
            return
        }
        let callbacks = DictationEngine.Callbacks(
            onText: { [weak self] partial in self?.received(partial) },
            onLevel: { [weak self] level in self?.heard(level) },
            onEnd: { [weak self] failure in
                if let failure { self?.fail(failure) } else { self?.finish() }
            })
        if let failure = engine.start(tag: tag, languageName: name, callbacks) {
            fail(failure)
            return
        }
        apply(.granted)
        silence = SilenceWatch(since: Date())
        startWatchdog()
    }

    private func received(_ partial: String) {
        guard let current = span, let text else { return }
        let result = DictationInsertion.update(text.wrappedValue, span: current, partial: partial)
        if result.draft != text.wrappedValue { text.wrappedValue = result.draft }
        span = result.span
        placeCaret?(result.span.end)
        silence?.heardText(at: Date())
    }

    private func heard(_ level: Float) {
        silence?.heard(level: level, at: Date())
    }

    /// Two seconds without voice stop the dictation. Checked four times a second.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                if let silence = self.silence, silence.isSilent(at: Date()), self.phase == .recording {
                    self.stop()
                    return
                }
            }
        }
    }

    private func fail(_ failure: DictationFailure) {
        self.failure = failure
        apply(.failed(failure))
        finish()
    }

    /// Back to idle: the span, the silence watch and the watchdog are dropped.
    private func finish() {
        apply(.finished)
        watchdog?.cancel()
        watchdog = nil
        silence = nil
        span = nil
        text = nil
        placeCaret = nil
    }

    private func apply(_ event: DictationEvent) {
        let next = DictationState.next(phase, event)
        if next != phase { phase = next }
    }
}
