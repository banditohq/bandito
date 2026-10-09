// Generated from tokens.json — do not edit.
import SwiftUI

public extension Color {
    enum Bandito {
        public static let bg = Color("bg", bundle: .module)
        public static let surface1 = Color("surface-1", bundle: .module)
        public static let surface2 = Color("surface-2", bundle: .module)
        public static let surface3 = Color("surface-3", bundle: .module)
        public static let line = Color("line", bundle: .module)
        public static let lineStrong = Color("line-strong", bundle: .module)
        public static let text = Color("text", bundle: .module)
        public static let text2 = Color("text-2", bundle: .module)
        public static let text3 = Color("text-3", bundle: .module)
        public static let signal = Color("signal", bundle: .module)
        public static let signalGlow = Color("signal-glow", bundle: .module)
        public static let signalFill = Color("signal-fill", bundle: .module)
        public static let signalFillEnd = Color("signal-fill-end", bundle: .module)
        public static let onSignal = Color("on-signal", bundle: .module)
        public static let ok = Color("ok", bundle: .module)
        public static let info = Color("info", bundle: .module)
        public static let danger = Color("danger", bundle: .module)
    }
}

public enum BanditoSpace {
    public static let s1: CGFloat = 4
    public static let s2: CGFloat = 8
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16
    public static let s5: CGFloat = 20
    public static let s6: CGFloat = 24
    public static let s8: CGFloat = 32
    public static let s10: CGFloat = 40
    public static let s12: CGFloat = 48
    public static let s16: CGFloat = 64
}

public enum BanditoRadius {
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 18
    public static let xl: CGFloat = 24
    public static let pill: CGFloat = 999
}

public enum BanditoType {
    public static let sans = "Geist"
    public static let mono = "Geist Mono"
    public static let display = (size: CGFloat(80), weight: 700, tracking: CGFloat(-0.05), leading: CGFloat(0.98))
    public static let title = (size: CGFloat(44), weight: 700, tracking: CGFloat(-0.045), leading: CGFloat(1.0))
    public static let heading = (size: CGFloat(22), weight: 600, tracking: CGFloat(-0.02), leading: CGFloat(1.25))
    public static let body = (size: CGFloat(15), weight: 400, tracking: CGFloat(0), leading: CGFloat(1.6))
    public static let small = (size: CGFloat(13), weight: 500, tracking: CGFloat(0), leading: CGFloat(1.45))
    public static let mono = (size: CGFloat(13), weight: 400, tracking: CGFloat(0), leading: CGFloat(1.5))
    public static let label = (size: CGFloat(11), weight: 500, tracking: CGFloat(0.09), leading: CGFloat(1.2))
}

public enum BanditoMotion {
    public static let fast = 0.12
    public static let base = 0.2
    public static let slow = 0.32
    public static let ease = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: base)
}
