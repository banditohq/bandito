import Foundation

/// Renders the sounds from short notes: no sound files. Each set is a voice (how a note sounds), a reverb amount and a
/// peak level. A render is deterministic (the noise has a fixed seed), so the same call gives the same samples.
public enum SoundSynth {
    public static let sampleRate: Double = 44_100

    /// Mono samples for `event` in `kit`, from 0 to the end of its last note. `pitch` scales every frequency.
    /// The peak is the set's level times the event's loudness, so it never clips.
    public static func samples(
        _ event: SoundEvent, kit: SoundKit, pitch: Double = 1, sampleRate: Double = sampleRate
    ) -> [Float] {
        let voice = Voice.of(kit)
        let parts = notes(kit: kit, event: event)
        let duration = parts.map { $0.start + $0.length }.max() ?? 0
        var out = [Double](repeating: 0, count: Int((duration * sampleRate).rounded(.up)))
        var noise = Noise()
        for note in parts {
            let tone = render(note, voice: voice.wave, pitch: pitch, sampleRate: sampleRate, noise: &noise)
            let offset = Int(note.start * sampleRate)
            for (index, value) in tone.enumerated() where offset + index < out.count {
                out[offset + index] += value
            }
        }
        addReverb(&out, mix: voice.reverb, sampleRate: sampleRate)
        normalize(&out, to: voice.peak * event.loudness)
        return out.map(Float.init)
    }

    // MARK: - Voices

    private enum Wave {
        /// Warm sine with a soft second harmonic, decaying.
        case warm
        /// Bell: three inharmonic partials, the higher ones dying first.
        case bell
        /// Square wave with a hard on and off, no decay (8-bit).
        case square
        /// A noise burst through a resonant band-pass at the note's frequency: a keyboard click.
        case click
    }

    private struct Voice {
        let wave: Wave
        /// Share of the reverb taps in the mix, 0 for none.
        let reverb: Double
        /// Peak level of the set before the event's loudness.
        let peak: Double

        static func of(_ kit: SoundKit) -> Voice {
            switch kit {
            case .soft: Voice(wave: .warm, reverb: 0.3, peak: 0.3)
            case .mechanics: Voice(wave: .click, reverb: 0.1, peak: 0.5)
            case .glass: Voice(wave: .bell, reverb: 0.35, peak: 0.4)
            case .retro: Voice(wave: .square, reverb: 0, peak: 0.4)
            }
        }
    }

    // MARK: - Notes

    /// One tone: `frequency` in Hz, `start` and `length` in seconds, `gain` relative to the others.
    private struct Note {
        let frequency: Double
        let start: Double
        let length: Double
        let gain: Double
    }

    private static func note(_ frequency: Double, _ start: Double, _ length: Double, _ gain: Double = 1) -> Note {
        Note(frequency: frequency, start: start, length: length, gain: gain)
    }

    /// The notes of each event in each set. Every event ends within 0.2 s.
    private static func notes(kit: SoundKit, event: SoundEvent) -> [Note] {
        switch kit {
        case .soft:
            switch event {
            case .click: [note(660, 0, 0.035)]
            case .type: [note(520, 0, 0.022, 0.8)]
            case .tab: [note(392, 0, 0.06, 0.8)]
            case .send: [note(523, 0, 0.06, 0.7), note(784, 0.05, 0.09, 0.7)]
            case .done: [note(523, 0, 0.18, 0.6), note(659, 0, 0.18, 0.5)]
            case .needsYou: [note(784, 0, 0.09, 0.9), note(988, 0.1, 0.09, 0.9)]
            case .error: [note(220, 0, 0.18, 0.8), note(233, 0, 0.18, 0.6)]
            }
        case .mechanics:
            switch event {
            case .click: [note(2800, 0, 0.04)]
            case .type: [note(3400, 0, 0.022, 0.8)]
            case .tab: [note(1900, 0, 0.06, 0.9)]
            case .send: [note(2200, 0, 0.03, 0.9), note(2900, 0.05, 0.04, 0.7)]
            case .done: [note(1500, 0, 0.15, 0.8)]
            case .needsYou: [note(1800, 0, 0.05), note(1800, 0.09, 0.05)]
            case .error: [note(600, 0, 0.16)]
            }
        case .glass:
            switch event {
            case .click: [note(1760, 0, 0.04)]
            case .type: [note(2637, 0, 0.022, 0.8)]
            case .tab: [note(1976, 0, 0.06, 0.8)]
            case .send: [note(1568, 0, 0.06, 0.7), note(2349, 0.05, 0.09, 0.7)]
            case .done: [note(1319, 0, 0.18, 0.7), note(1976, 0, 0.18, 0.5)]
            case .needsYou: [note(1760, 0, 0.09, 0.9), note(2217, 0.1, 0.09, 0.9)]
            case .error: [note(880, 0, 0.2, 0.8), note(831, 0, 0.2, 0.7)]
            }
        case .retro:
            switch event {
            case .click: [note(1000, 0, 0.025)]
            case .type: [note(1400, 0, 0.02, 0.7)]
            case .tab: [note(700, 0, 0.04, 0.8)]
            case .send: [note(523, 0, 0.025, 0.8), note(659, 0.03, 0.025, 0.8), note(784, 0.06, 0.03, 0.8)]
            case .done:
                [note(523, 0, 0.035, 0.8), note(659, 0.035, 0.035, 0.8), note(784, 0.07, 0.035, 0.8),
                 note(1046, 0.105, 0.04, 0.8)]
            case .needsYou: [note(784, 0, 0.04), note(784, 0.05, 0.04), note(988, 0.1, 0.06)]
            case .error: [note(330, 0, 0.08, 0.9), note(220, 0.085, 0.08, 0.9)]
            }
        }
    }

    // MARK: - Rendering

    private static func render(
        _ note: Note, voice: Wave, pitch: Double, sampleRate: Double, noise: inout Noise
    ) -> [Double] {
        let count = Int(note.length * sampleRate)
        let frequency = note.frequency * pitch
        var tone = [Double](repeating: 0, count: count)
        var filter = Biquad.bandpass(frequency: frequency, q: 6, sampleRate: sampleRate)
        for index in 0..<count {
            let t = Double(index) / sampleRate
            let value: Double
            switch voice {
            case .warm:
                value = (sin(2 * .pi * frequency * t) + 0.18 * sin(4 * .pi * frequency * t))
                    * exp(-3.5 * t / note.length) * attack(t) * release(t, note.length)
            case .bell:
                value = (sin(2 * .pi * frequency * t) * exp(-t / (note.length / 3))
                    + 0.5 * sin(2 * .pi * 2.76 * frequency * t) * exp(-t / (note.length / 6))
                    + 0.2 * sin(2 * .pi * 5.4 * frequency * t) * exp(-t / (note.length / 12)))
                    * attack(t) * release(t, note.length)
            case .square:
                let phase = sin(2 * .pi * frequency * t) >= 0 ? 1.0 : -1.0
                value = 0.5 * phase * attack(t, length: 0.001) * release(t, note.length)
            case .click:
                let burst = noise.next() * exp(-t / 0.003)
                value = filter.process(burst) * exp(-4 * t / note.length) * release(t, note.length)
            }
            tone[index] = value * note.gain
        }
        return tone
    }

    /// A short ramp up, so a sound never starts with a click.
    private static func attack(_ t: Double, length: Double = 0.002) -> Double {
        min(1, t / length)
    }

    /// A short ramp down at the end, so a sound never stops with a click.
    private static func release(_ t: Double, _ noteLength: Double) -> Double {
        min(1, (noteLength - t) / 0.004)
    }

    /// Three early echoes at 11, 19 and 31 ms. Inside the sound's own length, so the sound does not get longer.
    private static func addReverb(_ x: inout [Double], mix: Double, sampleRate: Double) {
        guard mix > 0 else { return }
        let dry = x
        let taps: [(seconds: Double, gain: Double)] = [(0.011, 0.5), (0.019, 0.3), (0.031, 0.15)]
        for (seconds, gain) in taps {
            let delay = Int(seconds * sampleRate)
            guard delay < dry.count else { continue }
            for index in delay..<dry.count {
                x[index] += dry[index - delay] * gain * mix
            }
        }
    }

    /// Scales so the largest sample has magnitude `peak`.
    private static func normalize(_ x: inout [Double], to peak: Double) {
        let current = x.map { abs($0) }.max() ?? 0
        guard current > 0 else { return }
        let scale = peak / current
        for index in x.indices {
            x[index] *= scale
        }
    }

    // MARK: - Building blocks

    /// Linear congruential noise in -1...1, with a fixed seed so renders repeat.
    private struct Noise {
        private var state: UInt32 = 0x2545_F491

        mutating func next() -> Double {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state) / Double(UInt32.max) * 2 - 1
        }
    }

    /// Second-order band-pass (constant peak gain), one sample at a time.
    private struct Biquad {
        private let b0: Double
        private let b2: Double
        private let a1: Double
        private let a2: Double
        private var x1 = 0.0
        private var x2 = 0.0
        private var y1 = 0.0
        private var y2 = 0.0

        private init(b0: Double, b2: Double, a1: Double, a2: Double) {
            self.b0 = b0
            self.b2 = b2
            self.a1 = a1
            self.a2 = a2
        }

        static func bandpass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
            let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha
            return Biquad(b0: alpha / a0, b2: -alpha / a0, a1: -2 * cos(w0) / a0, a2: (1 - alpha) / a0)
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            return y
        }
    }
}
