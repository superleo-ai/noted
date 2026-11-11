import SwiftUI

/// 主题: the built-in themes (and 我的主题 once saved), whether work and personal each get their
/// color, and a preview. Saved to the "ui.theme" preference so every device shows it.
struct ThemeScreen: View {
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @State private var confirmDelete = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        let theme = session.theme
        List {
            Section("主题") {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(BuiltinTheme.allCases) { t in
                        ThemeTile(palette: t.palette, title: t.label, isOn: theme.base == t.rawValue) { pick(t.rawValue) }
                            .accessibilityIdentifier("theme-\(t.rawValue)")
                    }
                    if let mine = theme.mine {
                        ThemeTile(palette: mine.palette, title: "我的主题", isOn: theme.base == ThemeSpec.custom) { pick(ThemeSpec.custom) }
                            .contextMenu {
                                Button { router.push(.themeEditor) } label: { Label("编辑", systemImage: "slider.horizontal.3") }
                                Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
                            }
                            .accessibilityIdentifier("theme-custom")
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                Toggle("工作 / 个人各用一种颜色", isOn: Binding(get: { theme.modeColors }, set: setModeColors))
                    .tint(.switchOn)
                    .accessibilityIdentifier("theme-mode-colors")
                NavigationLink(value: Route.themeEditor) {
                    HStack {
                        Text("自定义主题")
                        if !session.pro.isPro {
                            Spacer(minLength: 8)
                            ProMark()
                        }
                    }
                }
                .accessibilityLabel(session.pro.isPro ? "自定义主题" : "自定义主题，Pro")
                .accessibilityIdentifier("theme-editor")
            }
            Section {
                ThemePreviewCard(palette: session.palette)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listSectionSeparator(.hidden)
        }
        .navigationTitle("主题")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("删除我的主题？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { deleteMine() }
            Button("取消", role: .cancel) {}
        }
    }

    private func pick(_ id: String) {
        var t = session.theme
        guard t.base != id || !t.overrides.isEmpty else { return }
        t.select(id)
        withAnimation(.snappy) { session.saveTheme(t) }
    }

    private func setModeColors(_ on: Bool) {
        var t = session.theme
        t.modeColors = on
        withAnimation(.snappy) { session.saveTheme(t) }
    }

    private func deleteMine() {
        var t = session.theme
        if t.base == ThemeSpec.custom { t.select(t.mine?.base ?? "daylight") }
        t.mine = nil
        withAnimation(.snappy) { session.saveTheme(t) }
    }
}
