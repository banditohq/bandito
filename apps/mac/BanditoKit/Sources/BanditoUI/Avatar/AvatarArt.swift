import BanditoDesign
import BanditoKit
import CoreGraphics
import SwiftUI

/// An avatar drawn from its parts: the picture when there is one, else the emoji on the tile color, else the raccoon
/// face. Pure drawing; loading the picture is the caller's job (see `AgentAvatarView`).
struct AvatarArtView: View {
    let name: String
    let look: AvatarLook
    let picture: CGImage?
    var size: CGFloat = 40
    var mood: AvatarMood = .idle

    var body: some View {
        Group {
            if let picture {
                TileMood(name: name, size: size, mood: mood, tint: look.tintColor) {
                    Image(decorative: picture, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(tileShape)
                }
            } else if case let .emoji(emoji) = AvatarPresentation.choose(hasPicture: false, emoji: look.emoji) {
                TileMood(name: name, size: size, mood: mood, tint: look.tintColor) { emojiTile(emoji) }
            } else {
                RaccoonAvatar(
                    name: name, color: look.palette, face: look.face, size: size, mood: mood,
                    customHex: look.customHex)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 17 / 52, style: .continuous)
    }

    /// The emoji on the tile the raccoon would have: the custom color, else the palette color.
    private func emojiTile(_ emoji: String) -> some View {
        tileShape
            .fill(look.tintColor)
            .overlay {
                Text(emoji)
                    .font(BanditoFont.text(size: size * 0.52, weight: 400))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
    }
}

extension AvatarLook {
    /// The colour of the tile: the custom colour, else the palette's.
    var tintColor: Color {
        customHex.flatMap(AvatarHex.value).map { Color(hex: $0) } ?? palette.color
    }
}

/// The mood of an avatar that is a picture or an emoji, which has no face to move: the whole tile hops, shakes and
/// breathes, and the dots of a thinking agent and the "z" of a sleeping one are drawn over it, from the same pose as the
/// raccoon's (`AvatarPose`). The tile and the marks are the only things redrawn; a rest pose (Reduce Motion, "Less" or
/// "Off", scrolled out of view) is drawn once.
struct TileMood<Content: View>: View {
    let name: String
    let size: CGFloat
    let mood: AvatarMood
    let tint: Color
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue
    @State private var onScreen = true

    private var still: Bool { reduceMotion || !MotionLevel(stored: motionLevel).allowsRepeatingMotion }

    var body: some View {
        let phase = AvatarPose.phase(for: name)
        let paused = AvatarSleepPolicy.paused(
            mood: mood, still: still, onScreen: onScreen, windowActive: scenePhase == .active)
        TimelineView(AvatarSchedule(mood: mood, phase: phase, paused: paused)) { context in
            let pose = AvatarPose.make(
                mood: mood, time: context.date.timeIntervalSinceReferenceDate, phase: phase, reduceMotion: still)
            content
                .scaleEffect(TileMotion.scale(pose))
                .offset(x: pose.shakeX * size / DesignGrid.edge, y: pose.bodyOffsetY * size / DesignGrid.edge)
                .opacity(pose.opacity)
                .overlay { AvatarMarks(pose: pose, tint: tint, size: size) }
        }
        .frame(width: size, height: size)
        .avatarPresence($onScreen)
    }
}

/// How a still tile shows what a face shows by its eyes.
enum TileMotion {
    /// A working agent's tile breathes: the scan of the raccoon's eyes (-3...3 grid points, 2.4 s) becomes a swell of
    /// at most 3% in size. Other moods keep their size.
    static func scale(_ pose: AvatarPose) -> Double {
        1 + pose.eyeOffsetX / 3 * 0.03
    }
}
