import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Files mode: the folder browser, or the file viewer when files are open. Waits for the server's info, and
/// says so when the server is too old to have files.
struct FilesMode: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let server = app.currentServer {
            FilesContent(server: server)
        } else {
            ModePlaceholder(mode: .files)
        }
    }
}

private struct FilesContent: View {
    let server: ServerModel
    @Environment(Router.self) private var router

    var body: some View {
        Group {
            if server.info == nil {
                FilesNote(text: L10n.Files.connecting)
            } else if !server.supports("files") {
                FilesNote(text: L10n.Files.unsupported)
            } else if router.files.showsViewer {
                FileViewer(server: server)
            } else {
                FileBrowser(server: server)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg)
        .id(server.id)
        .task(id: server.id) {
            router.files.bind(to: server.id)
        }
    }
}

private struct FilesNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(BanditoFont.text(size: 13, weight: 400))
            .foregroundStyle(Color.Bandito.text2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }
}
