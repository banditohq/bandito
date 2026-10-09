import Foundation

/// One frame of the Welcome demo: which parts of the script are already on screen.
/// Every flag only turns on as time passes, never back off.
struct WelcomeDemoFrame: Equatable, Sendable {
    var userMessageVisible = false
    var typingVisible = false
    /// How many of the three command lines have a check mark (0...3).
    var visibleCommands = 0
    var approvalVisible = false
    /// The cursor has clicked "Allow".
    var allowPressed = false
    var resultVisible = false
    var confettiActive = false
}

/// Timing of the Welcome screen as pure functions of elapsed time, so the tests need no clock.
/// The numbers are the ones in docs/design/Welcome.dc.html (the CSS delays of the demo).
enum WelcomeTimeline {
    static let storyDuration: TimeInterval = 6
    static let storyCount = 4

    // Start times of the demo steps, in seconds since the demo started (or was replayed).
    static let userMessageAt: TimeInterval = 0.6
    static let typingAt: TimeInterval = 1.3
    static let typingEndsAt: TimeInterval = 2.4
    static let commandsAt: [TimeInterval] = [2.5, 3.1, 3.7]
    static let approvalAt: TimeInterval = 4.4
    /// The cursor reaches "Allow" at about 6.3 s and clicks at 6.5 s.
    static let allowAt: TimeInterval = 6.5
    static let resultAt: TimeInterval = 7.0
    static let confettiAt: TimeInterval = 7.05

    /// Seconds since the demo started (or was replayed).
    static func demo(at t: TimeInterval) -> WelcomeDemoFrame {
        var frame = WelcomeDemoFrame()
        frame.userMessageVisible = t >= userMessageAt
        frame.typingVisible = t >= typingAt && t < typingEndsAt
        frame.visibleCommands = commandsAt.filter { t >= $0 }.count
        frame.approvalVisible = t >= approvalAt
        frame.allowPressed = t >= allowAt
        frame.resultVisible = t >= resultAt
        frame.confettiActive = t >= confettiAt
        return frame
    }

    /// The demo after its last step. Reduce Motion shows this frame at once.
    static let finalFrame = demo(at: 60)

    /// The story shown after `elapsed` seconds since `anchorIndex` was picked (or the carousel started).
    /// Stories loop. `progress` is how far the current story's bar has filled, from 0 to 1.
    static func storyPosition(anchorIndex: Int, elapsed: TimeInterval) -> (index: Int, progress: Double) {
        let total = max(elapsed, 0)
        let steps = Int(total / storyDuration)
        let index = (anchorIndex + steps) % storyCount
        let progress = (total - Double(steps) * storyDuration) / storyDuration
        return (index, min(max(progress, 0), 1))
    }

    /// Opacity and rise of an element that appears at `start`: 0 before, 1 after `duration` seconds.
    static func entrance(at t: TimeInterval, start: TimeInterval, duration: TimeInterval = 0.35) -> Double {
        guard duration > 0 else { return t >= start ? 1 : 0 }
        return min(max((t - start) / duration, 0), 1)
    }
}
