import BanditoDesign
import BanditoL10n
import SwiftUI

/// A small sheet asking for the name of a new folder or file.
struct FileNameSheet: View {
    let sheet: NameSheet
    let existing: Set<String>
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    /// Names with a slash or the dot names would point elsewhere; a taken name would fail on the server.
    private var isValid: Bool {
        !trimmed.isEmpty && !trimmed.contains("/") && trimmed != "." && trimmed != ".." && !existing.contains(trimmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(sheet == .folder ? L10n.Files.Dialog.newFolder : L10n.Files.Dialog.newFile)
                .font(BanditoFont.display(size: 15.5, weight: 600))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.Bandito.text)
            TextField(L10n.Files.Dialog.name, text: $name)
                .banditoField()
                .font(BanditoFont.text(size: 14, weight: 400))
                .onSubmit(submit)
            if existing.contains(trimmed) {
                Text(L10n.Files.Error.exists)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
            }
            HStack {
                Spacer()
                Button(L10n.Files.cancel) { dismiss() }
                    .banditoButton(.quiet())
                Button(L10n.Files.Dialog.create, action: submit)
                    .banditoButton(.signal())
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(Color.Bandito.surface2)
    }

    private func submit() {
        guard isValid else { return }
        onSubmit(trimmed)
        dismiss()
    }
}
