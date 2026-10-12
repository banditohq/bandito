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
                TileMood(
                    name: name, size: size, mood: mood, tint: look.tintColor,
                    pictureKey: "picture|\(ObjectIdentifier(picture).hashValue)|\(size)"
                ) {
                    Image(decorative: picture, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(tileShape)
                }
            } else if case let .emoji(emoji) = AvatarPresentation.choose(hasPicture: false, emoji: look.emoji) {
                TileMood(
                    name: name, size: size, mood: mood, tint: look.tintColor,
                    pictureKey: "emoji|\(emoji)|\(look.customHex ?? look.palette.rawValue)|\(size)"
                ) { emojiTile(emoji) }
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
    /// Names what the tile shows (the picture, or the emoji and its colour): the moving copy is drawn once per key.
    let pictureKey: String
    @ViewBuilder var content: Content
    /// The Core Animation copy of the moving tile is in a window and shows.
    @State private var layerShown = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue
    @State private var onScreen = true

    private var still: Bool { reduceMotion || !MotionLevel(stored: motionLevel).allowsRepeatingMotion }

    var body: some View {
        let phase = AvatarPose.phase(for: name)
        let paused = AvatarSleepPolicy.paused(
            mood: mood, still: still, onScreen: onScreen, windowActive: scenePhase == .active)
        ZStack {
            posed(
                AvatarPose.make(
                    mood: mood, time: Date().timeIntervalSinceReferenceDate, phase: phase, reduceMotion: still))
                .opacity(!still && layerShown ? 0 : 1)
            #if os(macOS)
            // While the mood moves, Core Animation moves a picture of the tile (see `LayerMotion`).
            if !still {
                AvatarMotion(
                    spec: AvatarMotionSpec(
                        body: .tile(key: pictureKey), tintKey: pictureKey, size: size, mood: mood, phase: phase),
                    tint: tint, picture: TileMoodPictures.shared.picture(key: pictureKey, size: size) { content },
                    running: !paused, onShown: { shown in if layerShown != shown { layerShown = shown } })
            }
            #endif
        }
        .frame(width: size, height: size)
        .avatarPresence($onScreen)
    }
}

extension TileMood {
    fileprivate func posed(_ pose: AvatarPose) -> some View {
        content
            .scaleEffect(TileMotion.scale(pose))
            .offset(x: pose.shakeX * size / DesignGrid.edge, y: pose.bodyOffsetY * size / DesignGrid.edge)
            .opacity(pose.opacity)
            .overlay { AvatarMarks(pose: pose, tint: tint, size: size) }
    }
}

/// The pictures of moving tiles, drawn once from their SwiftUI content at the screen's scale.
@MainActor
final class TileMoodPictures {
    static let shared = TileMoodPictures()
    private let cache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.countLimit = 200
        return cache
    }()

    final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    func picture<Content: View>(key: String, size: CGFloat, @ViewBuilder content: () -> Content) -> CGImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit.image }
        let renderer = ImageRenderer(content: content().frame(width: size, height: size))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        cache.setObject(CGImageBox(image), forKey: key as NSString)
        return image
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
