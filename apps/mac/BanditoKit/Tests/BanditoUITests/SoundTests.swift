import Foundation
import Testing

@testable import BanditoUI

private func peak(_ samples: [Float]) -> Float {
    samples.map { abs($0) }.max() ?? 0
}

@Suite struct SoundSynthTests {
    /// Every set makes every event: short (20 to 200 ms), finite, not clipped, and not silent.
    @Test func everyEventIsShortAndDoesNotClip() {
        for kit in SoundKit.allCases {
            for event in SoundEvent.allCases {
                let samples = SoundSynth.samples(event, kit: kit)
                let seconds = Double(samples.count) / SoundSynth.sampleRate
                #expect(seconds >= 0.02 && seconds <= 0.2, "\(kit) \(event) lasts \(seconds) s")
                #expect(samples.allSatisfy { $0.isFinite && abs($0) <= 1.0 }, "\(kit) \(event) clips")
                #expect(peak(samples) > 0.05, "\(kit) \(event) is almost silent")
            }
        }
    }

    /// Waiting for the person is the most noticeable sound of its set.
    @Test func needsYouIsLouderThanAClick() {
        for kit in SoundKit.allCases {
            let needsYou = peak(SoundSynth.samples(.needsYou, kit: kit))
            let click = peak(SoundSynth.samples(.click, kit: kit))
            #expect(needsYou > click, "\(kit)")
        }
    }

    /// The same input renders the same buffer every time: no random state between calls.
    @Test func renderingIsDeterministic() {
        for kit in SoundKit.allCases {
            #expect(SoundSynth.samples(.type, kit: kit) == SoundSynth.samples(.type, kit: kit))
        }
    }

    @Test func pitchVariantsDiffer() {
        let low = SoundSynth.samples(.type, kit: .soft, pitch: SoundPitch.factors[0])
        let high = SoundSynth.samples(.type, kit: .soft, pitch: SoundPitch.factors[SoundPitch.factors.count - 1])
        #expect(low != high)
    }

    @Test func pitchStaysWithinThreePercent() {
        #expect(SoundPitch.factors.count == 7)
        #expect(SoundPitch.factors.allSatisfy { abs($0 - 1) <= 0.03 + 1e-9 })
        #expect(SoundPitch.factors.contains(1.0))
    }
}

@Suite struct TypeThrottleTests {
    /// Typing never plays more than 25 times a second: a full second of key presses 1 ms apart gives 25.
    @Test func atMostTwentyFivePerSecond() {
        var throttle = TypeThrottle()
        var allowed = 0
        for millisecond in 0..<1000 {
            if throttle.allow(atMillisecond: millisecond) {
                allowed += 1
            }
        }
        #expect(allowed == 25)
    }

    @Test func aBurstIsCutToOneSoundPerFortyMilliseconds() {
        var throttle = TypeThrottle()
        let first = throttle.allow(atMillisecond: 1000)
        let tooSoon = throttle.allow(atMillisecond: 1010)
        let stillTooSoon = throttle.allow(atMillisecond: 1039)
        let atGap = throttle.allow(atMillisecond: 1040)
        #expect(first)
        #expect(!tooSoon)
        #expect(!stillTooSoon)
        #expect(atGap)
    }
}

@Suite struct SoundRulesTests {
    private func settings(
        enabled: Bool = true, background: Bool = false, events: Set<SoundEvent> = Set(SoundEvent.allCases)
    ) -> SoundSettings {
        SoundSettings(enabled: enabled, events: events, playsInBackground: background)
    }

    @Test func theMainSwitchSilencesEverything() {
        let off = settings(enabled: false)
        for event in SoundEvent.allCases {
            #expect(!SoundRules.shouldPlay(event, settings: off, windowActive: true, windowVisible: true))
        }
    }

    @Test func aTurnedOffEventStaysSilent() {
        let s = settings(events: Set(SoundEvent.allCases).subtracting([.click]))
        #expect(!SoundRules.shouldPlay(.click, settings: s, windowActive: true, windowVisible: true))
        #expect(SoundRules.shouldPlay(.type, settings: s, windowActive: true, windowVisible: true))
    }

    /// The person's own actions (click, type, tab, send) need the window in front.
    @Test func ownActionsPlayOnlyInTheActiveWindow() {
        let s = settings(background: true)
        #expect(SoundRules.shouldPlay(.click, settings: s, windowActive: true, windowVisible: true))
        #expect(!SoundRules.shouldPlay(.click, settings: s, windowActive: false, windowVisible: true))
        #expect(!SoundRules.shouldPlay(.send, settings: s, windowActive: false, windowVisible: false))
        #expect(!SoundRules.shouldPlay(.tab, settings: s, windowActive: false, windowVisible: true))
    }

    @Test func agentEventsPlayInTheActiveWindow() {
        let s = settings(background: false)
        for event in [SoundEvent.done, .needsYou, .error] {
            #expect(SoundRules.shouldPlay(event, settings: s, windowActive: true, windowVisible: true))
        }
    }

    /// Without the background toggle, agent events play only while the window is in front.
    @Test func agentEventsInTheBackgroundNeedTheToggle() {
        let s = settings(background: false)
        for event in [SoundEvent.done, .needsYou, .error] {
            #expect(!SoundRules.shouldPlay(event, settings: s, windowActive: false, windowVisible: true))
            #expect(!SoundRules.shouldPlay(event, settings: s, windowActive: false, windowVisible: false))
        }
    }

    @Test func aBackgroundWindowPlaysAllAgentEvents() {
        let s = settings(background: true)
        for event in [SoundEvent.done, .needsYou, .error] {
            #expect(SoundRules.shouldPlay(event, settings: s, windowActive: false, windowVisible: true))
        }
    }

    /// A closed window: only "done" and "needs you", never errors.
    @Test func aClosedWindowPlaysOnlyDoneAndNeedsYou() {
        let s = settings(background: true)
        #expect(SoundRules.shouldPlay(.done, settings: s, windowActive: false, windowVisible: false))
        #expect(SoundRules.shouldPlay(.needsYou, settings: s, windowActive: false, windowVisible: false))
        #expect(!SoundRules.shouldPlay(.error, settings: s, windowActive: false, windowVisible: false))
    }

    @Test func aTypedCharacterIsOneMoreCharacter() {
        #expect(SoundRules.isTypedCharacter(old: "", new: "a"))
        #expect(SoundRules.isTypedCharacter(old: "ab", new: "abc"))
        #expect(!SoundRules.isTypedCharacter(old: "a", new: ""))
        #expect(!SoundRules.isTypedCharacter(old: "ab", new: "ab"))
        #expect(!SoundRules.isTypedCharacter(old: "ab", new: "abcd"))
    }
}

/// Round trip through a scratch defaults suite, so the test never touches the app's real preferences.
@Suite struct SoundSettingsTests {
    private func scratch() -> (defaults: UserDefaults, domain: String) {
        let domain = "bandito.tests.sounds.\(UUID().uuidString)"
        return (UserDefaults(suiteName: domain)!, domain)
    }

    @Test func emptyStoreReadsTheDefaults() {
        let (defaults, domain) = scratch()
        defer { defaults.removePersistentDomain(forName: domain) }
        let s = SoundSettings(defaults: defaults)
        #expect(s.enabled == false)
        #expect(s.kit == .soft)
        #expect(s.volume == 0.6)
        #expect(s.events == Set(SoundEvent.allCases))
        #expect(s.playsInBackground == false)
    }

    @Test func storedChoicesAreRead() {
        let (defaults, domain) = scratch()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: SoundSettings.enabledKey)
        defaults.set(SoundKit.glass.rawValue, forKey: SoundSettings.kitKey)
        defaults.set(0.25, forKey: SoundSettings.volumeKey)
        defaults.set(false, forKey: SoundSettings.eventKey(.tab))
        defaults.set(true, forKey: SoundSettings.backgroundKey)
        let s = SoundSettings(defaults: defaults)
        #expect(s.enabled)
        #expect(s.kit == .glass)
        #expect(s.volume == 0.25)
        #expect(!s.events.contains(.tab))
        #expect(s.events.contains(.click))
        #expect(s.playsInBackground)
    }

    @Test func volumeIsKeptInZeroToOne() {
        #expect(SoundSettings(volume: 3).volume == 1)
        #expect(SoundSettings(volume: -1).volume == 0)
        let (defaults, domain) = scratch()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(7.0, forKey: SoundSettings.volumeKey)
        #expect(SoundSettings(defaults: defaults).volume == 1)
    }

    @Test func anUnknownKitFallsBackToSoft() {
        let (defaults, domain) = scratch()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("laser", forKey: SoundSettings.kitKey)
        #expect(SoundSettings(defaults: defaults).kit == .soft)
    }
}
