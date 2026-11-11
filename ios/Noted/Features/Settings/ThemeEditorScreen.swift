import SwiftUI

/// 自定义主题 (Pro): colors, corner radius, density and title face on top of a built-in theme,
/// with a live preview. Saving makes it 我的主题, a fourth theme on 主题. Without Pro it can be
/// tried out, and saving opens Noted Pro.
struct ThemeEditorScreen: View {
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(Toaster.self) private var toaster

    @State private var draft = ThemeOverrides()
    @State private var started = false

    private static let accents: [UInt32] = [0x1F5BFF, 0x276B49, 0xB03A24, 0x6B4E16, 0x0E7C86]
    private static let works: [UInt32] = [0x1F5BFF, 0x2A5F8F, 0x0E7C86]
    private static let lives: [UInt32] = [0xC2410C, 0x96560F, 0xB03A24]
    private static let bgs: [UInt32] = [0xF2F2F7, 0xF4EEE1, 0xF0F3EC, 0xFFFFFF]

    /// The theme the changes start from, without them.
    private var basePalette: Palette { Palette.builtin(draft.base) }

    var body: some View {
        let p = draft.palette
        List {
            Section {
                ThemePreviewCard(palette: p, title: "预览 · 我的主题")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                Picker("基于", selection: Binding(get: { draft.base }, set: { rebase($0) })) {
                    ForEach(BuiltinTheme.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .accessibilityIdentifier("theme-editor-base")
                colorRow("主色", Self.accents, \.accent, basePalette.accentDef, id: "accent")
                colorRow("工作色", Self.works, \.work, basePalette.work, id: "work")
                colorRow("个人色", Self.lives, \.life, basePalette.life, id: "life")
                colorRow("底色", Self.bgs, \.bg, basePalette.bg, id: "bg")
            }
            Section {
                HStack(spacing: 12) {
                    Text("圆角")
                    Slider(value: Binding(get: { draft.radius ?? Double(basePalette.radius) }, set: { draft.radius = $0.rounded() }),
                           in: 2...24, step: 1)
                        .accessibilityLabel("圆角")
                        .accessibilityValue("\(Int(p.radius))")
                        .accessibilityIdentifier("theme-editor-radius")
                    Text("\(Int(p.radius))").monospacedDigit().foregroundStyle(.secondaryText).frame(width: 26, alignment: .trailing)
                }
                LabeledContent("密度") {
                    Picker("密度", selection: Binding(get: { draft.density ?? "regular" }, set: { draft.density = $0 == "regular" ? nil : $0 })) {
                        Text("紧凑").tag("compact")
                        Text("标准").tag("regular")
                        Text("宽松").tag("roomy")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                    .accessibilityIdentifier("theme-editor-density")
                }
                LabeledContent("标题") {
                    Picker("标题", selection: Binding(get: { p.serif }, set: { draft.serif = $0 == basePalette.serif ? nil : $0 })) {
                        Text("无衬线").tag(false)
                        Text("衬线").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .accessibilityIdentifier("theme-editor-serif")
                }
            }
            Section {
                Button("保存为「我的主题」") { save() }
                    .buttonStyle(.wide)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("theme-editor-save")
            } footer: {
                if !draft.isEmpty {
                    Button("还原") { draft = ThemeOverrides(base: draft.base) }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .accessibilityIdentifier("theme-editor-reset")
                }
            }
        }
        .navigationTitle("自定义主题")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !session.pro.isPro {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text("自定义主题").font(.headline)
                        ProMark()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("theme-editor-save-top")
            }
        }
        .onAppear(perform: start)
    }

    // MARK: rows

    private func colorRow(_ title: String, _ swatches: [UInt32], _ key: WritableKeyPath<ThemeOverrides, UInt32?>,
                          _ fallback: Color, id: String) -> some View {
        let current = draft[keyPath: key] ?? fallback.hex
        return HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 8)
            ForEach(swatches, id: \.self) { c in
                Button { set(key, c, fallback) } label: {
                    Circle().fill(Color(hex: c)).frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
                        .padding(3)
                        .overlay(Circle().strokeBorder(current == c ? Color.primary : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title) \(String(format: "#%06X", c))")
                .accessibilityAddTraits(current == c ? .isSelected : [])
            }
            ColorPicker(title, selection: Binding(get: { Color(hex: current) }, set: { set(key, $0.hex, fallback) }),
                        supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel("\(title)，其他颜色")
                .accessibilityIdentifier("theme-editor-\(id)")
        }
    }

    private func set(_ key: WritableKeyPath<ThemeOverrides, UInt32?>, _ value: UInt32, _ fallback: Color) {
        // The base theme's own color is no change at all.
        draft[keyPath: key] = value == fallback.hex ? nil : value
    }

    // MARK: actions

    private func start() {
        guard !started else { return }
        started = true
        let t = session.theme
        if let mine = t.mine {
            draft = mine
        } else {
            // The current theme, with any changes already made on top of it.
            var o = t.overrides
            o.base = t.base == ThemeSpec.custom ? "daylight" : t.base
            draft = o
        }
        if BuiltinTheme(rawValue: draft.base) == nil { draft.base = "daylight" }
    }

    /// A new starting theme keeps the changes made so far.
    private func rebase(_ base: String) {
        draft.base = base
        let b = Palette.builtin(base)
        if draft.accent == b.accentDef.hex { draft.accent = nil }
        if draft.work == b.work.hex { draft.work = nil }
        if draft.life == b.life.hex { draft.life = nil }
        if draft.bg == b.bg.hex { draft.bg = nil }
        if draft.radius == Double(b.radius) { draft.radius = nil }
        if draft.serif == b.serif { draft.serif = nil }
    }

    private func save() {
        guard session.pro.isPro else {
            router.push(.pro)
            return
        }
        var t = session.theme
        t.mine = draft
        t.select(ThemeSpec.custom)
        withAnimation(.snappy) { session.saveTheme(t) }
        toaster.show("已保存为我的主题")
        router.pop()
    }
}
