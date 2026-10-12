import AppKit
import SwiftUI
import Testing

@testable import BanditoDesign
@testable import BanditoUI

/// Pictures of the Welcome screen for review: the raccoon of points of light in the middle and at the end of its
/// assembly, dark in Russian and light in English. Written to `$BANDITO_SNAPSHOTS` (see `SnapshotSupport`).
/// The window is borderless, off every screen, transparent, and never shown: the pictures come from `cacheDisplay`.
/// The lights are placed at the moment asked for (`RaccoonLightsLayer.show(at:)`), so the picture is the same every run.
@MainActor
@Suite struct WelcomeRaccoonSnapshots {
    private let size = CGSize(width: 1100, height: 700)
    private static let pictureSize = CGSize(width: 600, height: 700)

    @Test(.language("ru")) func midAssemblyDarkRussian() throws {
        _ = try render("onb-welcome-mid-dark-ru", at: 0.7, dark: true)
    }

    @Test(.language("ru")) func endOfAssemblyDarkRussian() throws {
        _ = try render("onb-welcome-end-dark-ru", at: 2.4, dark: true)
    }

    @Test(.language("en")) func midAssemblyLightEnglish() throws {
        _ = try render("onb-welcome-mid-light-en", at: 0.7, dark: false)
    }

    @Test(.language("en")) func endOfAssemblyLightEnglish() throws {
        _ = try render("onb-welcome-end-light-en", at: 2.4, dark: false)
    }

    private func render(_ name: String, at elapsed: CFTimeInterval, dark: Bool) throws -> URL {
        let scheme: ColorScheme = dark ? .dark : .light
        let root = ZStack {
            BlurOrbs()
            WelcomeView(onContinue: {}, onHaveServer: {})
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, scheme)

        // The pictures are put together: the background (BlurOrbs) and the screen are drawn by SwiftUI (`ImageRenderer`,
        // fast). The raccoon is a layer view, which that renderer draws as a stand-in: its place is left to the
        // background, and the raccoon's own layers are drawn there. The window is borderless, off every screen,
        // transparent, and never shown.
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let raccoon = try #require(Self.findRaccoon(in: hosting), "the welcome shows the raccoon")
        let lights = try #require(raccoon.layer as? RaccoonLightsLayer, "the raccoon is the shared layer")
        lights.layoutIfNeeded()
        lights.show(at: elapsed)
        let place = raccoon.convert(raccoon.bounds, to: nil)

        let screenRenderer = ImageRenderer(content: root)
        screenRenderer.scale = 2
        let screen = try #require(screenRenderer.nsImage, "the screen for \(name)")
        let backgroundRenderer = ImageRenderer(content: BlurOrbs().frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme))
        backgroundRenderer.scale = 2
        let background = try #require(backgroundRenderer.nsImage, "the background for \(name)")

        let raccoonRep = try #require(Self.bitmap(size: raccoon.bounds.size), "a bitmap for the raccoon")
        raccoon.cacheDisplay(in: raccoon.bounds, to: raccoonRep)
        let raccoonImage = NSImage(size: raccoon.bounds.size)
        raccoonImage.addRepresentation(raccoonRep)

        // The left column only: the demo on the right is drawn by its own views, which the renderer above cannot draw
        // (it shows them as stand-ins), so the picture keeps to the intro, where the raccoon is.
        let picture = try #require(Self.bitmap(size: Self.pictureSize), "a bitmap for \(name)")
        let context = try #require(NSGraphicsContext(bitmapImageRep: picture), "a context for \(name)")
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        background.draw(in: NSRect(origin: .zero, size: size))
        // The screen everywhere but on the raccoon's place, which shows the background and then the raccoon.
        let outside = NSBezierPath(rect: NSRect(origin: .zero, size: size))
        outside.append(NSBezierPath(rect: place))
        outside.windingRule = .evenOdd
        NSGraphicsContext.saveGraphicsState()
        outside.addClip()
        screen.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        raccoonImage.draw(in: place)
        NSGraphicsContext.restoreGraphicsState()

        let png = try #require(picture.representation(using: .png, properties: [:]), "a PNG for \(name)")
        let url = SnapshotSupport.outDir.appending(path: "\(name).png")
        try png.write(to: url)
        return url
    }

    /// A transparent bitmap of `size` points, at two pixels a point.
    private static func bitmap(size: CGSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }

    private static func findRaccoon(in view: NSView) -> RaccoonLightsNSView? {
        if let raccoon = view as? RaccoonLightsNSView { return raccoon }
        for child in view.subviews {
            if let found = findRaccoon(in: child) { return found }
        }
        return nil
    }
}
