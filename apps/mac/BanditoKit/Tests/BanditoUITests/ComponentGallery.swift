import BanditoDesign
import BanditoKit
import SwiftUI
import Testing

@testable import BanditoUI

/// Renders every component in its main states into `component-gallery.png` for visual review.
@MainActor
@Suite struct ComponentGallery {
    @Test func rendersGallery() throws {
        let url = try SnapshotSupport.render(
            GalleryPage(), "component-gallery", size: CGSize(width: 960, height: 1500))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

/// All components in one column. Bindings are `.constant`, so the page is a static picture.
struct GalleryPage: View {
    private let galleryFaces: [AvatarFace] = [.chevronDash, .dots, .carets]
    private let names = ["Forge", "Scout", "Night Owl", "Watch", "Quill"]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            GallerySection(title: "Avatars") {
                HStack(spacing: 14) {
                    ForEach(AvatarColor.allCases.indices, id: \.self) { index in
                        RaccoonAvatar(
                            name: "Gallery",
                            color: AvatarColor.allCases[index],
                            face: galleryFaces[index % galleryFaces.count],
                            size: 56)
                    }
                }
                HStack(spacing: 18) {
                    ForEach(names, id: \.self) { name in
                        VStack(spacing: 6) {
                            RaccoonAvatar(name: name, size: 40)
                            Text(name)
                                .font(.bandito(.small))
                                .foregroundStyle(Color.Bandito.text2)
                        }
                    }
                    AgentAvatar(name: "Forge", size: 36)
                        .overlay(alignment: .bottomTrailing) {
                            StatusDot(status: .needsYou, ringColor: Color.Bandito.surface1)
                        }
                    AgentAvatar(name: "Scout", size: 22)
                }
            }

            GallerySection(title: "Status") {
                HStack(spacing: 22) {
                    ForEach(AgentStatus.allCases, id: \.self) { status in
                        HStack(spacing: 8) {
                            StatusDot(status: status)
                            Text(status.rawValue)
                                .font(.bandito(.small))
                                .foregroundStyle(Color.Bandito.text2)
                        }
                    }
                }
            }

            GallerySection(title: "Chips") {
                HStack(spacing: 10) {
                    ForEach(ChipTone.allCases, id: \.self) { tone in
                        Chip(text: "\(tone)", tone: tone)
                    }
                }
            }

            GallerySection(title: "Buttons") {
                HStack(spacing: 14) {
                    Button("Разрешить") {}
                        .buttonStyle(SignalButtonStyle())
                    Button("Разрешить large") {}
                        .buttonStyle(SignalButtonStyle(size: .large))
                    Button("Отклонить") {}
                        .buttonStyle(QuietButtonStyle())
                    Button("Light") {}
                        .buttonStyle(LightPillButtonStyle())
                    Button {
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(IconButtonStyle(label: "Search"))
                }
                HStack(spacing: 10) {
                    KeyHint("⌘K")
                    KeyHint("esc")
                    KeyHint("↵")
                }
            }

            GallerySection(title: "Segmented") {
                SegmentedPicker(
                    selection: .constant(1),
                    options: [(0, "Низкое"), (1, "Среднее"), (2, "Высокое"), (3, "Максимум")]
                )
                .frame(width: 420)
            }

            GallerySection(title: "Usage and context") {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        UsageBar(fraction: 0.9)
                        UsageBar(fraction: 0.18)
                        UsageBar(fraction: 0)
                        UsageBar(fraction: 0.64, tint: Color.Bandito.ok, height: 8)
                    }
                    .frame(width: 300)
                    HStack(spacing: 18) {
                        ContextRing(fraction: 0.31)
                        ContextRing(fraction: 0.6, size: 24)
                        ContextRing(fraction: 0.85, size: 32)
                    }
                }
            }

            GallerySection(title: "Cards and radio") {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 8) {
                        RadioRow(
                            title: "Claude Code", description: "Вход выполнен · Max", badge: "рекомендуем",
                            isSelected: true
                        ) {}
                        RadioRow(title: "Codex", description: "Нужно войти", isSelected: false) {}
                    }
                    .frame(width: 340)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Обычная карточка")
                            .font(.bandito(.small))
                            .foregroundStyle(Color.Bandito.text)
                            .padding(14)
                            .frame(width: 200, alignment: .leading)
                            .banditoCard()
                        Text("Выбранная карточка")
                            .font(.bandito(.small))
                            .foregroundStyle(Color.Bandito.text)
                            .padding(14)
                            .frame(width: 200, alignment: .leading)
                            .banditoCard(selected: true)
                    }
                }
            }

            GallerySection(title: "Toggle") {
                HStack(spacing: 40) {
                    Toggle("Утренняя сводка", isOn: .constant(true))
                        .toggleStyle(BanditoToggleStyle())
                        .frame(width: 280)
                    Toggle("Уведомления", isOn: .constant(false))
                        .toggleStyle(BanditoToggleStyle())
                        .frame(width: 280)
                }
            }

            GallerySection(title: "Typography") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Title 44 / 700").font(.bandito(.title)).foregroundStyle(Color.Bandito.text)
                    Text("Heading 22 / 600").font(.bandito(.heading)).foregroundStyle(Color.Bandito.text)
                    Text("Body 15 / 400 — Добавь тесты для вебхука оплаты.").font(.bandito(.body))
                        .foregroundStyle(Color.Bandito.text)
                    Text("Small 13 / 500 — Forge ждёт задачу").font(.bandito(.small))
                        .foregroundStyle(Color.Bandito.text2)
                    Text("git push origin feat/billing-webhook-tests").font(.bandito(.mono))
                        .foregroundStyle(Color.Bandito.text2)
                    Text("Label 11 / 500").font(.bandito(.label)).foregroundStyle(Color.Bandito.text3)
                }
                SectionLabel("Ждут вас", tone: .signal)
                SectionLabel("Команда")
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.Bandito.bg)
    }
}

/// Titled block of the gallery.
private struct GallerySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title)
            content
        }
    }
}
