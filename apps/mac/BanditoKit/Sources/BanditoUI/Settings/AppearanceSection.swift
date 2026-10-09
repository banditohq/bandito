import BanditoDesign
import BanditoL10n
import SwiftUI

/// Settings → Appearance. Only the dark theme exists for now; motion can be reduced.
struct AppearanceSection: View {
    @AppStorage(MotionLevel.storageKey) private var motionRaw = MotionLevel.full.rawValue

    private var motion: Binding<MotionLevel> {
        Binding(get: { MotionLevel(stored: motionRaw) }, set: { motionRaw = $0.rawValue })
    }

    var body: some View {
        SettingsPage(title: SettingsSection.appearance.title, intro: L10n.Settings.Appearance.intro) {
            VStack(spacing: 0) {
                SettingsRow(title: L10n.Settings.Appearance.motion, hint: L10n.Settings.Appearance.motionHint) {
                    SegmentedPicker(
                        selection: motion,
                        options: [
                            (MotionLevel.full, L10n.Settings.Appearance.motionFull),
                            (MotionLevel.less, L10n.Settings.Appearance.motionLess),
                            (MotionLevel.off, L10n.Settings.Appearance.motionOff),
                        ]
                    )
                    .fixedSize()
                }
            }
            .banditoCard()
        }
    }
}
