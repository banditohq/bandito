import AVFoundation
import Foundation
import os
#if os(macOS)
import AppKit
#endif

/// Plays the synthesised sounds through one AVAudioEngine. The engine starts on the first sound and stops 30 s after
/// the last one, so an idle app holds no audio hardware. Each set is rendered once, on its first use.
@MainActor
public final class SoundEngine {
    public static let shared = SoundEngine()

    /// Silence after which the engine stops.
    static let idleTimeout: Duration = .seconds(30)

    private static let logger = Logger(subsystem: "app.bandito", category: "sounds")

    private let format = AVAudioFormat(standardFormatWithSampleRate: SoundSynth.sampleRate, channels: 1)
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var idleStop: Task<Void, Never>?
    /// The rendered buffers of each set: for each event, its variants (only `type` has several).
    private var rendered: [SoundKit: [SoundEvent: [AVAudioPCMBuffer]]] = [:]
    private var variant = 0
    private var typing = TypeThrottle()

    init() {}

    /// Plays one sound of `event` in `kit` at `volume`. A `type` sound is dropped when it comes within 40 ms of the
    /// last one. `millisecond` is any steady clock in milliseconds.
    func play(_ event: SoundEvent, kit: SoundKit, volume: Double, atMillisecond millisecond: Int) {
        if event == .type, !typing.allow(atMillisecond: millisecond) { return }
        guard let buffer = nextBuffer(event, kit: kit), start() else { return }
        player?.volume = Float(volume)
        player?.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player?.play()
        scheduleIdleStop()
    }

    /// The buffer to play: the next variant of the event, rendering the set first if it is new.
    private func nextBuffer(_ event: SoundEvent, kit: SoundKit) -> AVAudioPCMBuffer? {
        guard let format else { return nil }
        if rendered[kit] == nil {
            rendered[kit] = render(kit, format: format)
        }
        guard let variants = rendered[kit]?[event], !variants.isEmpty else { return nil }
        variant &+= 1
        return variants[variant % variants.count]
    }

    private func render(_ kit: SoundKit, format: AVAudioFormat) -> [SoundEvent: [AVAudioPCMBuffer]] {
        var result: [SoundEvent: [AVAudioPCMBuffer]] = [:]
        for event in SoundEvent.allCases {
            let pitches = event == .type ? SoundPitch.factors : [1]
            result[event] = pitches.compactMap { pitch in
                let samples = SoundSynth.samples(event, kit: kit, pitch: pitch)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
                else { return nil }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                if let channel = buffer.floatChannelData?[0] {
                    for index in samples.indices {
                        channel[index] = samples[index]
                    }
                }
                return buffer
            }
        }
        return result
    }

    /// Starts the engine if it is not running. False when the audio system refuses (the sound is then skipped).
    private func start() -> Bool {
        if engine?.isRunning == true, player != nil { return true }
        guard let format else { return false }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            Self.logger.error("sound engine did not start: \(String(describing: type(of: error)), privacy: .public)")
            return false
        }
        player.play()
        self.engine = engine
        self.player = player
        return true
    }

    private func scheduleIdleStop() {
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }
}

/// What the app calls to play a sound. It reads the person's settings and the window, then plays through `SoundEngine`.
@MainActor
public enum SoundPlayer {
    /// Plays `event` if the settings and the window allow it now (see `SoundRules.shouldPlay`).
    public static func play(_ event: SoundEvent) {
        let settings = SoundSettings(defaults: .standard)
        guard SoundRules.shouldPlay(
            event, settings: settings, windowActive: windowActive, windowVisible: windowVisible)
        else { return }
        SoundEngine.shared.play(event, kit: settings.kit, volume: settings.volume, atMillisecond: now)
    }

    /// The Settings "listen" button: one sound of `kit` at `volume`. It ignores the on and off switches, so the person
    /// can hear a set before turning sounds on.
    public static func preview(_ kit: SoundKit, volume: Double) {
        SoundEngine.shared.play(.done, kit: kit, volume: volume, atMillisecond: now)
    }

    private static var windowActive: Bool {
        #if os(macOS)
        NSApplication.shared.isActive
        #else
        true
        #endif
    }

    /// Any window of the app is on screen (Settings included). False when the window is closed.
    private static var windowVisible: Bool {
        #if os(macOS)
        NSApplication.shared.windows.contains { $0.isVisible }
        #else
        true
        #endif
    }

    private static var now: Int {
        Int(ProcessInfo.processInfo.systemUptime * 1000)
    }
}
