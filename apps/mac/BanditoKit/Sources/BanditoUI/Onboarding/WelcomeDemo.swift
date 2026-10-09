import BanditoDesign
import BanditoL10n
import SwiftUI

/// The live demo on the Welcome screen: a crew sidebar and one agent's chat that plays the script in
/// `WelcomeTimeline` (message, typing, commands, approval, the click on "Allow", the result, confetti).
/// Starts when it appears; "Replay" restarts it. Reduce Motion shows the finished frame.
struct WelcomeDemoCard: View {
    /// How long one run lasts, the confetti included. After it nothing moves.
    static let runLength: TimeInterval = WelcomeTimeline.confettiAt + 3

    /// When the current run started.
    var start: Date
    var onReplay: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue
    /// True once the run is over (confetti included): the clock stops and the last frame stays on screen.
    @State private var finished = false

    private var reduced: Bool {
        MotionLevel(stored: motionLevel).reducesMotion(systemReduceMotion: reduceMotion)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduced || finished)) { context in
            // Reduce Motion: the finished frame, far enough in that every step is already visible.
            let t = reduced ? 60 : context.date.timeIntervalSince(start)
            let frame = reduced ? WelcomeTimeline.finalFrame : WelcomeTimeline.demo(at: t)
            HStack(spacing: 0) {
                CrewSidebar(t: t)
                chat(frame: frame, t: t)
            }
        }
        .frame(width: 460, height: 520)
        .background(Color.Bandito.surface1.opacity(0.9), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.Bandito.text.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 40, y: 24)
        .accessibilityElement(children: .contain)
        .task(id: start) {
            finished = false
            try? await Task.sleep(for: .seconds(WelcomeDemoCard.runLength))
            if !Task.isCancelled { finished = true }
        }
    }

    private func chat(frame: WelcomeDemoFrame, t: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.Onboarding.Demo.header)
                    .font(BanditoFont.font(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                Spacer()
                Button(L10n.Onboarding.Demo.replay, action: onReplay)
                    .banditoButton(.quiet())
            }
            if frame.userMessageVisible {
                bubble(L10n.Onboarding.Demo.user, mine: true)
                    .opacity(WelcomeTimeline.entrance(at: t, start: WelcomeTimeline.userMessageAt))
            }
            if frame.typingVisible {
                TypingDots(t: t)
            }
            if frame.visibleCommands > 0 {
                commands(visible: frame.visibleCommands, t: t)
            }
            if frame.approvalVisible {
                approvalCard(frame: frame, t: t)
                    .opacity(WelcomeTimeline.entrance(at: t, start: WelcomeTimeline.approvalAt, duration: 0.45))
            }
            if frame.resultVisible {
                bubble(L10n.Onboarding.Demo.done, mine: false)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(AvatarColor.sage.color.opacity(0.25)))
                    .opacity(WelcomeTimeline.entrance(at: t, start: WelcomeTimeline.resultAt, duration: 0.4))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if frame.confettiActive {
                ConfettiView(elapsed: t - WelcomeTimeline.confettiAt)
            }
        }
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 60) }
            Text(text)
                .font(BanditoFont.font(size: 13.5, weight: 400))
                .foregroundStyle(Color.Bandito.text)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(
                    mine ? Color(red: 0.17, green: 0.15, blue: 0.13) : Color.Bandito.surface2,
                    in: RoundedRectangle(cornerRadius: 16))
            if !mine { Spacer(minLength: 60) }
        }
    }

    private func commands(visible: Int, t: TimeInterval) -> some View {
        let lines: [(command: String, note: String)] = [
            ("cargo update", L10n.Onboarding.Demo.updateNote),
            ("cargo test", L10n.Onboarding.Demo.testNote),
            ("git commit -m \"chore: deps\"", "+38 −41"),
        ]
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(0..<min(visible, lines.count), id: \.self) { k in
                HStack(spacing: 8) {
                    Text("✓").foregroundStyle(AvatarColor.sage.color)
                    Text(lines[k].command).frame(maxWidth: .infinity, alignment: .leading)
                    Text(lines[k].note).foregroundStyle(Color.Bandito.text3)
                }
                .font(BanditoFont.font(size: 12, weight: 400, mono: true))
                .foregroundStyle(Color.Bandito.text2)
                .opacity(WelcomeTimeline.entrance(at: t, start: WelcomeTimeline.commandsAt[k], duration: 0.3))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.Bandito.text.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.Bandito.text.opacity(0.07)))
    }

    private func approvalCard(frame: WelcomeDemoFrame, t: TimeInterval) -> some View {
        let cursor = min(max((t - 5.2) / 1.12, 0), 1)
        let pressing = t >= WelcomeTimeline.allowAt && t < WelcomeTimeline.allowAt + 0.3
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PulseDot(t: t, color: Color.Bandito.signal)
                Text(L10n.Onboarding.Demo.askPush).font(BanditoFont.font(size: 13, weight: 600))
            }
            HStack(spacing: 0) {
                Text("git push").foregroundStyle(Color.Bandito.signal)
                Text(" origin ")
                Text("chore/deps-oct").foregroundStyle(AvatarColor.sky.color)
            }
            .font(BanditoFont.font(size: 12, weight: 400, mono: true))
            .foregroundStyle(Color.Bandito.text2)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            HStack(spacing: 8) {
                // Decorative: the demo's "Deny" is not a control, so it is neither focusable nor read out.
                Text(L10n.Approval.deny)
                    .font(BanditoFont.font(size: 12.5, weight: 500))
                    .foregroundStyle(Color.Bandito.text)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Color.Bandito.text.opacity(0.05), in: Capsule())
                    .overlay(Capsule().stroke(Color.Bandito.text.opacity(0.12), lineWidth: 1))
                    .focusable(false)
                    .accessibilityHidden(true)
                Text(L10n.Onboarding.Demo.allow)
                    .font(BanditoFont.font(size: 12.5, weight: 600))
                    .foregroundStyle(Color.Bandito.onSignal)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background(
                        LinearGradient(
                            colors: [Color.Bandito.signalFill, Color.Bandito.signalFillEnd],
                            startPoint: .top, endPoint: .bottom),
                        in: Capsule())
                    .brightness(pressing ? 0.3 : 0)
                    .overlay(alignment: .leading) {
                        Image(systemName: "cursorarrow")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.Bandito.text)
                            .shadow(color: .black, radius: 1)
                            .offset(x: 150 * (1 - cursor), y: 60 * (1 - cursor))
                            .opacity(t >= 5.2 ? 1 : 0)
                    }
            }
        }
        .padding(14)
        .background(Color(red: 0.13, green: 0.11, blue: 0.09), in: RoundedRectangle(cornerRadius: 15))
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(Color.Bandito.signal.opacity(0.5), lineWidth: 1))
    }
}

/// The three dots of "is typing", each on its own phase.
private struct TypingDots: View {
    var t: TimeInterval

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { k in
                let phase = (t / 1.2 - Double(k) * 0.2).truncatingRemainder(dividingBy: 1)
                Circle()
                    .fill(Color.Bandito.text3)
                    .frame(width: 5, height: 5)
                    .opacity(0.25 + 0.75 * (1 - abs(phase * 2 - 1)))
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A status dot with a ring that expands and fades, like the design's "pulse".
struct PulseDot: View {
    var t: TimeInterval
    var color: Color

    var body: some View {
        let phase = t.truncatingRemainder(dividingBy: 1.8) / 1.8
        ZStack {
            Circle().stroke(color.opacity(0.6 * (1 - phase)), lineWidth: 2)
                .frame(width: 7 + 10 * phase, height: 7 + 10 * phase)
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 18, height: 18)
    }
}

/// The four agents on the left, with a status dot each (the first one is working).
private struct CrewSidebar: View {
    var t: TimeInterval

    private static let crew: [(name: String, color: AvatarColor, working: Bool)] = [
        ("Forge", .peach, true), ("Scout", .sky, false), ("Watch", .rose, false), ("Quill", .sage, false),
    ]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Self.crew, id: \.name) { agent in
                ZStack(alignment: .bottomTrailing) {
                    RaccoonAvatar(name: agent.name, color: agent.color, size: 40)
                    if agent.working {
                        PulseDot(t: t, color: Color.Bandito.signal).scaleEffect(0.6)
                    } else {
                        Circle()
                            .fill(AvatarColor.sage.color)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color.Bandito.surface1, lineWidth: 2.5))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .frame(width: 78)
        .background(Color.Bandito.surface2.opacity(0.6))
    }
}
