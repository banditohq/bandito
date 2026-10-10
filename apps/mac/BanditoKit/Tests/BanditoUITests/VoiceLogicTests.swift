import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

@Suite struct SpeechTextTests {
    private let skipped = "code skipped"

    @Test func plainSentenceIsUnchanged() {
        #expect(SpeechText.plain("Hello there.", codeSkipped: skipped) == "Hello there.")
    }

    @Test func headingsBulletsAndNumbersLoseTheirMarks() {
        let text = "## Title\n- one\n1. two"
        #expect(SpeechText.plain(text, codeSkipped: skipped) == "Title\none\ntwo")
    }

    @Test func linksKeepTheirLabelAndEmphasisIsDropped() {
        let text = "See [docs](https://example.com) **now** and `code` and *soon*."
        #expect(SpeechText.plain(text, codeSkipped: skipped) == "See docs now and code and soon.")
    }

    @Test func codeBlockIsReplacedByThePhraseAndItsCodeIsNotRead() {
        let text = "Before\n```swift\nlet answer = 42\n```\nAfter"
        let spoken = SpeechText.plain(text, codeSkipped: skipped)
        #expect(spoken.contains("Before"))
        #expect(spoken.contains(skipped))
        #expect(spoken.contains("After"))
        #expect(!spoken.contains("answer"))
    }

    @Test func tableSeparatorRowIsDropped() {
        #expect(SpeechText.cleanLine("|---|---|") == "")
        #expect(SpeechText.cleanLine("| a | b |").contains("a"))
    }
}

@Suite struct SpeechLanguageTests {
    @Test func tagsOfTheAppLanguages() {
        #expect(SpeechLanguage.tags["zh-Hans"] == "zh-CN")
        #expect(SpeechLanguage.tags["pt-BR"] == "pt-BR")
        #expect(SpeechLanguage.dictationTag(appLanguage: "ru") == "ru-RU")
        #expect(SpeechLanguage.dictationTag(appLanguage: "xx") == "en-US")
    }

    @Test func portugueseIsReadAsBrazilian() {
        #expect(SpeechLanguage.tag(forRecognized: "pt") == "pt-BR")
        #expect(SpeechLanguage.tag(forRecognized: "xx") == nil)
    }

    @Test func voiceFollowsTheTextLanguage() {
        let russian = "Это длинное предложение на русском языке, и оно должно прочитаться русским голосом."
        #expect(SpeechLanguage.voiceTag(for: russian, appLanguage: "en") == "ru-RU")
    }

    @Test func voiceFallsBackToTheAppLanguageWhenTheTextHasNoLanguage() {
        #expect(SpeechLanguage.voiceTag(for: "123 456", appLanguage: "ru") == "ru-RU")
    }
}

@Suite struct DictationInsertionTests {
    @Test func startAtTheEndAfterAWordAddsALead() {
        let span = DictationInsertion.start(in: "hello", caret: nil)
        #expect(span == DictationSpan(location: 5, length: 0, lead: " "))
    }

    @Test func startAfterASpaceAddsNoLead() {
        let span = DictationInsertion.start(in: "hello ", caret: nil)
        #expect(span.lead == "")
    }

    @Test func startAtTheStartOfTheDraftAddsNoLead() {
        #expect(DictationInsertion.start(in: "hello", caret: 0).lead == "")
    }

    @Test func partialsReplaceEachOtherAtTheCaret() {
        var span = DictationInsertion.start(in: "", caret: nil)
        var draft = ""
        (draft, span) = DictationInsertion.update(draft, span: span, partial: "hi")
        #expect(draft == "hi")
        (draft, span) = DictationInsertion.update(draft, span: span, partial: "hi there")
        #expect(draft == "hi there")
        #expect(span.end == 8)
    }

    @Test func textGoesIntoTheMiddleOfTheDraft() {
        let span = DictationInsertion.start(in: "hello world", caret: 5)
        let result = DictationInsertion.update("hello world", span: span, partial: "dictated")
        #expect(result.draft == "hello dictated world")
        #expect(result.span.end == 5 + " dictated".utf16.count)
    }

    @Test func emptyPartialLeavesNothingBehind() {
        var span = DictationInsertion.start(in: "a", caret: nil)
        var draft = "a"
        (draft, span) = DictationInsertion.update(draft, span: span, partial: "b")
        (draft, span) = DictationInsertion.update(draft, span: span, partial: "")
        #expect(draft == "a")
        #expect(span.length == 0)
    }

    @Test func caretPastTheEndIsClamped() {
        let span = DictationSpan(location: 99, length: 5, lead: "")
        let result = DictationInsertion.update("abc", span: span, partial: "x")
        #expect(result.draft == "abcx")
    }

    @Test func emojiCountsAsTwoUTF16Units() {
        let span = DictationInsertion.start(in: "🙂", caret: 2)
        let result = DictationInsertion.update("🙂", span: span, partial: "x")
        #expect(result.draft == "🙂 x")
    }
}

@Suite struct DictationStateTests {
    @Test func startAsksForPermissionThenRecords() {
        var phase = DictationState.next(.idle, .start)
        #expect(phase == .requesting)
        phase = DictationState.next(phase, .granted)
        #expect(phase == .recording)
    }

    @Test func secondPressStopsAndFinishGoesIdle() {
        var phase = DictationState.next(.recording, .start)
        #expect(phase == .stopping)
        phase = DictationState.next(phase, .finished)
        #expect(phase == .idle)
    }

    @Test func escOrSilenceStopTheRecording() {
        #expect(DictationState.next(.recording, .stop) == .stopping)
    }

    @Test func refusedPermissionEndsIdle() {
        #expect(DictationState.next(.requesting, .failed(.denied(.microphone))) == .idle)
        #expect(DictationState.next(.requesting, .failed(.denied(.speech))) == .idle)
    }

    @Test func offlineModelMissingEndsIdle() {
        #expect(DictationState.next(.requesting, .failed(.onDeviceUnavailable(language: "Russian"))) == .idle)
    }

    @Test func stopDuringThePromptHoldsUntilPermissionIsAnswered() {
        var phase = DictationState.next(.requesting, .stop)
        #expect(phase == .stopping)
        phase = DictationState.next(phase, .granted)
        #expect(phase == .stopping)
    }

    @Test func eventsThatMeanNothingInIdleAreIgnored() {
        #expect(DictationState.next(.idle, .stop) == .idle)
        #expect(DictationState.next(.idle, .granted) == .idle)
    }

    @Test func twoSecondsAfterTheLastFragmentEndTheDictation() {
        let start = Date(timeIntervalSince1970: 1_000)
        var watch = SilenceWatch(since: start)
        watch.recognised("hello", at: start.addingTimeInterval(1))
        #expect(!watch.isSilent(at: start.addingTimeInterval(2.9)))
        #expect(watch.isSilent(at: start.addingTimeInterval(3)))
        // A newer fragment starts the two seconds again.
        watch.recognised("hello there", at: start.addingTimeInterval(4))
        #expect(!watch.isSilent(at: start.addingTimeInterval(5.9)))
        #expect(watch.isSilent(at: start.addingTimeInterval(6)))
    }

    @Test func withNoSpeechAtAllTheDictationEndsAfterEightSeconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        var watch = SilenceWatch(since: start)
        #expect(!watch.isSilent(at: start.addingTimeInterval(7.9)))
        #expect(watch.isSilent(at: start.addingTimeInterval(8)))
        // Whitespace is not speech: it does not count as a fragment.
        watch.recognised("   ", at: start.addingTimeInterval(7))
        #expect(watch.lastFragment == nil)
        #expect(watch.isSilent(at: start.addingTimeInterval(8)))
    }

    @Test func escBelongsToTheDictationOnlyWhileItRecords() {
        #expect(DictationEscape.takesEscape(.recording))
        #expect(!DictationEscape.takesEscape(.idle))
        #expect(!DictationEscape.takesEscape(.requesting))
        #expect(!DictationEscape.takesEscape(.stopping))
    }
}

@Suite struct ReadAloudRulesTests {
    @Test func theReplyAfterTheLastPersonMessageIsRead() {
        let items: [ThreadItem] = [
            .user(id: "u1", text: "Hi", source: .user, from: nil, ts: 1),
            .assistant(id: "a1", text: "Hello", ts: 2),
            .note(id: "n1", text: "session", kind: .info, ts: 3),
            .assistant(id: "a2", text: "Done", ts: 4),
        ]
        let reply = ReadAloudRules.finalReply(in: items)
        #expect(reply?.id == "a2")
        #expect(reply?.text == "Done")
    }

    @Test func aTurnWithoutAReplyReadsNothing() {
        let items: [ThreadItem] = [
            .assistant(id: "a1", text: "Old", ts: 1),
            .user(id: "u2", text: "Stop", source: .user, from: nil, ts: 2),
        ]
        #expect(ReadAloudRules.finalReply(in: items) == nil)
    }

    private let person = ThreadItem.user(id: "u1", text: "Hi", source: .user, from: nil, ts: 1)

    @Test func historyIsNotReadButTheReplyOfATurnSeenRunningIs() {
        let tracker = ReadAloudTracker()
        let history: [ThreadItem] = [.assistant(id: "s1", text: "Old", ts: 1)]
        #expect(tracker.observe(items: history, turnRunning: false) == nil)
        let sent = history + [person]
        #expect(tracker.observe(items: sent, turnRunning: true) == nil)
        let answered = sent + [.assistant(id: "s2", text: "New", ts: 3)]
        // The reply arrives while the turn still runs: it waits for the turn to end.
        #expect(tracker.observe(items: answered, turnRunning: true) == nil)
        #expect(tracker.observe(items: answered, turnRunning: false) == SpokenReply(id: "s2", text: "New"))
        // Read once, however often the thread changes afterwards.
        #expect(tracker.observe(items: answered, turnRunning: false) == nil)
        #expect(tracker.read == ["s2"])
    }

    @Test func aReplyThatArrivesAfterTheTurnEndedIsReadAtOnce() {
        let tracker = ReadAloudTracker()
        _ = tracker.observe(items: [person], turnRunning: true)
        let items = [person, .assistant(id: "s3", text: "Done", ts: 4)]
        #expect(tracker.observe(items: items, turnRunning: false) == SpokenReply(id: "s3", text: "Done"))
    }

    @Test func streamedTextFinalisedByAnotherEventIsNotAFinalReply() {
        let tracker = ReadAloudTracker()
        let items: [ThreadItem] = [person, .assistant(id: "s5-s", text: "Half", ts: 5)]
        _ = tracker.observe(items: [person], turnRunning: true)
        #expect(tracker.observe(items: items, turnRunning: false) == nil)
    }

    @Test func aReplyBeforeThePersonsLastMessageIsNotReadWhenATurnStarts() {
        let tracker = ReadAloudTracker()
        let items: [ThreadItem] = [.assistant(id: "s1", text: "Old", ts: 1), person]
        #expect(tracker.observe(items: items, turnRunning: true) == nil)
        #expect(tracker.observe(items: items, turnRunning: false) == nil)
    }

    @Test func resetForgetsTheTurnsOfTheAgent() {
        let tracker = ReadAloudTracker()
        _ = tracker.observe(items: [person], turnRunning: true)
        tracker.reset()
        #expect(!tracker.sawTurn)
        let items = [person, .assistant(id: "s9", text: "Hi", ts: 9)]
        #expect(tracker.observe(items: items, turnRunning: false) == nil)
    }
}
