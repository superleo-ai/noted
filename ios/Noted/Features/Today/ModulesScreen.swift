import SwiftUI

/// 页面模块 (Pro): which blocks 今天 shows and in what order, for one layout or one per mode.
/// Changes are saved as they are made. Without Pro the default layout is shown read-only.
struct ModulesScreen: View {
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @State private var layout = Layout()
    @State private var editing: Mode = .all
    @State private var loaded = false

    private var isPro: Bool { session.pro.isPro }
    private var mode: Mode { layout.perMode ? editing : .all }
    private var modules: [ModuleState] { isPro ? layout.modules(for: mode) : Layout.standard }

    var body: some View {
        List { Group {
            if !isPro { proSection }
            modeSection
            moduleSection
            if isPro { resetSection }
        }.classicRowInsets() }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 0, for: .scrollContent)
        .environment(\.editMode, editMode)
        .navigationTitle("页面模块")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            layout = session.layout
            editing = session.mode
            loaded = true
        }
    }

    private var editMode: Binding<EditMode> {
        let m: EditMode = isPro ? .active : .inactive
        return Binding(get: { m }, set: { _ in })
    }

    private var proSection: some View {
        Section {
            Button { router.push(.pro) } label: {
                HStack {
                    Text("开通 Pro 后可以调整")
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityIdentifier("modules-pro")
        }
    }

    private var perModeBinding: Binding<Bool> {
        Binding(get: { isPro && layout.perMode }, set: { setPerMode($0) })
    }

    private var modeSection: some View {
        Section {
            Toggle("三种模式各用各的布局", isOn: perModeBinding)
                .tint(.switchOn)
                .disabled(!isPro)
                .accessibilityIdentifier("modules-per-mode")
            if isPro && layout.perMode {
                Picker("正在编辑", selection: $editing) {
                    ForEach(Mode.allCases) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented).classicSegmented()
                .accessibilityIdentifier("modules-mode")
            }
        } header: {
            SectionLabel("正在编辑 · 今天")
        }
    }

    private var moduleSection: some View {
        Section {
            ForEach(modules) { m in moduleRow(m) }
                .onMove(perform: isPro ? { from, to in move(from, to) } : nil)
        } header: {
            SectionLabel(isPro ? "拖动排序 · 关掉的不显示" : "默认布局")
        }
    }

    private func moduleRow(_ m: ModuleState) -> some View {
        let info = Layout.info(m.id)
        let on = Binding<Bool>(get: { m.on }, set: { v in setOn(m.id, v) })
        return Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                Text(info.detail).font(.footnote).foregroundStyle(.secondaryText)
            }
        }
        .tint(.switchOn)
        .disabled(!isPro)
        .accessibilityIdentifier("module-\(m.id)")
    }

    private var resetSection: some View {
        Section {
            Button("还原默认") { update { $0 = Layout.standard } }
                .disabled(modules == Layout.standard)
                .accessibilityIdentifier("modules-reset")
        }
    }

    private func update(_ change: (inout [ModuleState]) -> Void) {
        var next = layout.modules(for: mode)
        change(&next)
        layout.set(next, for: mode)
        session.saveLayout(layout)
    }

    private func setOn(_ id: String, _ on: Bool) {
        update { mods in
            if let i = mods.firstIndex(where: { $0.id == id }) { mods[i].on = on }
        }
    }

    private func move(_ from: IndexSet, _ to: Int) {
        update { $0.move(fromOffsets: from, toOffset: to) }
    }

    /// Turning it on starts 个人 and 工作 from the shared layout.
    private func setPerMode(_ on: Bool) {
        guard isPro else { return }
        if on && !layout.perMode {
            if layout.life == Layout.standard { layout.life = layout.all }
            if layout.work == Layout.standard { layout.work = layout.all }
        }
        layout.perMode = on
        session.saveLayout(layout)
    }
}
