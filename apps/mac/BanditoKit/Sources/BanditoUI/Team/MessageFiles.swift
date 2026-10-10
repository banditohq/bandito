import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The files of a message in the thread: pictures as a grid of miniatures, other files as chips. A click opens the
/// file in a tab of the workbench panel beside the chat.
struct MessageFiles: View {
    var files: [AgentAttachment]
    var agentID: String
    var server: ServerModel

    /// Optional, like the thread's: without a router a click does nothing.
    @Environment(Router.self) private var router: Router?

    /// Edge of a miniature in the thread.
    static let miniature: CGFloat = 96

    var body: some View {
        let pictures = files.filter { AttachmentRules.isImage(name: $0.name) }
        let others = files.filter { !AttachmentRules.isImage(name: $0.name) }
        VStack(alignment: .trailing, spacing: 8) {
            if !pictures.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.miniature, maximum: Self.miniature), spacing: 6)],
                    alignment: .trailing, spacing: 6
                ) {
                    ForEach(pictures) { file in
                        Button {
                            open(file)
                        } label: {
                            RemoteImage(path: file.path, server: server)
                                .frame(width: Self.miniature, height: Self.miniature)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .banditoButton(.row(cornerRadius: 10))
                        .help(file.name)
                    }
                }
            }
            ForEach(others) { file in
                Button {
                    open(file)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.Bandito.text3)
                        Text(file.name)
                            .font(BanditoFont.font(size: 12.5, weight: 500))
                            .foregroundStyle(Color.Bandito.text2)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                            .font(BanditoFont.font(size: 11.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                }
                .banditoButton(.row(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.Bandito.line, lineWidth: 0.5))
                .help(file.name)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func open(_ file: AgentAttachment) {
        router?.showInWorkbench(.file(path: file.path), agentID: agentID)
    }
}
