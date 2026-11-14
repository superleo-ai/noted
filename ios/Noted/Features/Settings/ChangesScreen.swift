import SwiftUI

/// AI 的改动记录 (route .changes): what accepted proposals wrote, newest first. Each change can be
/// undone once (swipe, or the context menu), after a confirmation.
struct ChangesScreen: View {
    @Environment(AppData.self) private var data
    @Environment(Toaster.self) private var toaster

    @State private var changes: [Noted_V1_Change] = []
    @State private var loaded = false
    @State private var undoing: Noted_V1_Change?

    var body: some View {
        List { Group {
            if !loaded {
                Section { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 22) }
            } else if changes.isEmpty {
                Section { EmptyState(text: "还没有改动") }
            } else {
                Section {
                    ForEach(changes, id: \.id) { c in
                        row(c)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !c.undone {
                                    Button { undoing = c } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
                                        .tint(.danger)
                                }
                            }
                            .contextMenu {
                                if !c.undone {
                                    Button(role: .destructive) { undoing = c } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
                                }
                            }
                    }
                }
            }
        }.classicRowInsets() }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 0, for: .scrollContent)
        .navigationTitle("AI 的改动记录")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("撤销这次改动？", isPresented: Binding(get: { undoing != nil }, set: { if !$0 { undoing = nil } }),
                            titleVisibility: .visible, presenting: undoing) { c in
            Button("撤销 \(c.entries) 项", role: .destructive) { undo(c) }
                .accessibilityIdentifier("changes-undo-confirm")
            Button("取消", role: .cancel) {}
        } message: { c in
            Text("“\(c.summary)”写入的内容会被删除或改回")
        }
    }

    private func row(_ c: Noted_V1_Change) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(c.summary.isEmpty ? "改动" : c.summary)
                    .foregroundStyle(c.undone ? .secondaryText : .primary)
                    .strikethrough(c.undone, color: .tertiaryText)
                    .lineLimit(3)
                Text(detail(c)).font(.footnote).foregroundStyle(.secondaryText)
            }
            Spacer(minLength: 8)
            if c.undone {
                InfoTag(text: "已撤销")
            } else {
                Button { undoing = c } label: { Text("撤销").font(.subheadline) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("撤销 \(c.summary)")
                    .accessibilityIdentifier("changes-undo")
            }
        }
        .padding(.vertical, 2)
    }

    private func detail(_ c: Noted_V1_Change) -> String {
        var s = "\(Fmt.stamp(c.createTime.date)) · \(c.entries) 项"
        if c.undone, c.hasUndoTime { s += " · \(Fmt.stamp(c.undoTime.date)) 撤销" }
        return s
    }

    private func load() async {
        if let got = await data.listChanges() { changes = got }
        loaded = true
    }

    private func undo(_ c: Noted_V1_Change) {
        Task {
            guard let got = await data.undoChange(c.id) else { return }
            if let i = changes.firstIndex(where: { $0.id == got.id }) { changes[i] = got }
            toaster.show("已撤销", systemImage: "arrow.uturn.backward")
        }
    }
}
