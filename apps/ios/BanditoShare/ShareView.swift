import BanditoDesign
import BanditoL10n
import SwiftUI

/// The share sheet: the agents in a row, the text, the pictures, Cancel and Send. Plain SwiftUI, no animation that
/// repeats.
struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.Bandito.line)
            content
        }
        .background(Color.Bandito.bg.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s3) {
            HStack(spacing: BanditoSpace.s3) {
                Button(model.agents.isEmpty || model.stage == .savedNotOpened ? L10n.Common.close : L10n.Common.cancel) {
                    if model.stage == .savedNotOpened { model.finish() } else { model.cancel() }
                }
                .font(BanditoFont.text(size: 16))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(1)
                .fixedSize()
                Spacer(minLength: BanditoSpace.s2)
                if !model.agents.isEmpty && model.stage != .savedNotOpened {
                    Button(action: model.send) { Text(L10n.Thread.send).lineLimit(1).fixedSize() }
                        .buttonStyle(ShareSendStyle())
                        .disabled(!model.canSend)
                        .opacity(model.canSend ? 1 : 0.4)
                }
            }
            Text(L10n.Ios.Share.title)
                .font(BanditoFont.display(size: 20, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, BanditoSpace.s4)
        .padding(.vertical, BanditoSpace.s3)
    }

    @ViewBuilder
    private var content: some View {
        if model.agents.isEmpty {
            message(L10n.Ios.Share.empty)
        } else if model.stage == .savedNotOpened {
            message(L10n.Ios.Share.done)
        } else {
            form
        }
    }

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(BanditoFont.text(size: 16))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
                .padding(BanditoSpace.s6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BanditoSpace.s4) {
                Text(L10n.Ios.NewTask.to)
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.text2)
                    .padding(.horizontal, BanditoSpace.s4)
                agentRow
                TextField(L10n.Thread.placeholder, text: $model.text, axis: .vertical)
                    .lineLimit(3...8)
                    .font(BanditoFont.text(size: 16))
                    .foregroundStyle(Color.Bandito.text)
                    .padding(BanditoSpace.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: BanditoRadius.md, style: .continuous).fill(Color.Bandito.surface1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: BanditoRadius.md, style: .continuous)
                            .stroke(Color.Bandito.line, lineWidth: 1)
                    )
                    .padding(.horizontal, BanditoSpace.s4)
                if !model.images.isEmpty { pictures }
                if model.stage == .failed {
                    Text(L10n.Ios.Share.failed)
                        .font(BanditoFont.text(size: 13))
                        .foregroundStyle(Color.Bandito.signal)
                        .padding(.horizontal, BanditoSpace.s4)
                }
            }
            .padding(.top, BanditoSpace.s4)
            .padding(.bottom, BanditoSpace.s6)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var agentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: BanditoSpace.s2) {
                ForEach(model.agents, id: \.self) { agent in
                    let key = ShareRules.key(agent)
                    ShareAgentChip(agent: agent, selected: key == model.selectedKey) {
                        model.selectedKey = key
                        model.dismissFailure()
                    }
                }
            }
            .padding(.horizontal, BanditoSpace.s4)
        }
    }

    private var pictures: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BanditoSpace.s2) {
                ForEach(model.images) { image in
                    Image(uiImage: image.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: BanditoRadius.sm, style: .continuous))
                        .accessibilityLabel(L10n.Ios.Share.picture)
                }
            }
            .padding(.horizontal, BanditoSpace.s4)
        }
    }
}

/// One agent in the row: the raccoon on its tile color, and the name. The chosen one is outlined.
private struct ShareAgentChip: View {
    let agent: WidgetSnapshot.Listing
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let resolved = AvatarResolver.resolve(name: agent.name, color: nil, face: .auto)
        Button(action: action) {
            VStack(spacing: BanditoSpace.s1) {
                RaccoonFace(resolved: resolved, tint: resolved.color.color, pose: AvatarPose(), size: 40)
                    .accessibilityHidden(true)
                Text(agent.name)
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
            }
            .frame(width: 88)
            .padding(.vertical, BanditoSpace.s2)
            .background(
                RoundedRectangle(cornerRadius: BanditoRadius.md, style: .continuous).fill(Color.Bandito.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BanditoRadius.md, style: .continuous)
                    .stroke(selected ? Color.Bandito.signal : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agent.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The primary action, as the app's Signal button: a cream capsule.
private struct ShareSendStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BanditoFont.display(size: 14, weight: 600))
            .foregroundStyle(Color.Bandito.bg)
            .padding(.horizontal, BanditoSpace.s5)
            .frame(minHeight: 36)
            .background(Capsule().fill(Color.Bandito.text))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
