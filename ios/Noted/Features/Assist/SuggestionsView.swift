import SwiftUI

/// 建议: the pending proposals for this space, each with its space and kind, title, reason and the
/// steps to pick. Nothing runs until 采纳; 忽略 drops it.
struct SuggestionsView: View {
    @Environment(AppData.self) private var data
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(Toaster.self) private var toaster
    @State private var proposals: [Noted_V1_Proposal] = []
    @State private var state: LoadState = .loading

    private enum LoadState { case loading, off, ready }

    var body: some View {
        List { Group {
            Section {
                Text("\(proposals.count) 条 · 你不点，就不会执行")
                    .font(.subheadline).foregroundStyle(.secondaryText)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("suggestions-count")
            }
            .listSectionSpacing(.compact)

            switch state {
            case .loading:
                Section { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 22) }
            case .off:
                Section { EmptyState(text: "建议已关闭") }
            case .ready:
                if proposals.isEmpty {
                    Section { EmptyState(text: "现在没有建议") }
                }
                ForEach(proposals, id: \.id) { pr in
                    Section {
                        SuggestionHeader(proposal: pr)
                            .listRowSeparator(.hidden)
                        ProposalCard(proposal: pr, title: pr.title, idPrefix: "suggestion",
                                     acceptLabel: { n in pr.operations.count == 1 ? "采纳" : "采纳 \(n) 项" }) { n in
                            withAnimation(.snappy) { proposals.removeAll { $0.id == pr.id } }
                            if n > 0 { toaster.show(pr.operations.count == 1 ? "已采纳" : "已采纳 \(n) 项") }
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 12, trailing: 12))
                    }
                    .accessibilityIdentifier("suggestion-\(pr.id)")
                }
            }
        }.classicRowInsets() }
        .listStyle(.insetGrouped)
        .navigationTitle("建议")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("改动记录") { router.push(.changes) }
                    .accessibilityIdentifier("suggestions-changes")
            }.plainBar()
            ToolbarItem(placement: .topBarTrailing) { SpaceFilterMenu() }.plainBar()
        }
        .refreshable { await load() }
        .task(id: session.mode) { await load() }
    }

    private func load() async {
        guard let s = await data.loadAISettings(), s.status.enabled, s.features.suggestions else {
            proposals = []
            state = .off
            return
        }
        let space = session.mode.space
        let got = await data.listSuggestions(space: space)
        guard space == session.mode.space else { return }
        proposals = got
        state = .ready
    }
}

/// "● 个人  菲律宾旅行" on the left, the kind ("冲突", "逾期") on the right.
private struct SuggestionHeader: View {
    @Environment(AppData.self) private var data
    let proposal: Noted_V1_Proposal

    var body: some View {
        HStack(spacing: 8) {
            SpaceTag(space: proposal.space)
            if let c = context {
                Text(c).font(.footnote.weight(.medium)).foregroundStyle(.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 8)
            InfoTag(text: kindLabel,
                    tint: warns ? .danger : .secondaryText,
                    background: warns ? Color.danger.opacity(0.1) : .fillTrack)
        }
        .padding(.top, 4)
    }

    private var warns: Bool { proposal.kind == "conflict" || proposal.kind == "overdue" }

    private var kindLabel: String {
        switch proposal.kind {
        case "goal_slot": "目标"
        case "project_dates": "项目"
        case "conflict": "冲突"
        case "overdue": "逾期"
        case "schedule": "排进空档"
        case "weekly": "下周计划"
        case "plan": "计划"
        case "extract": "提取待办"
        case "ask": "提问"
        default: "建议"
        }
    }

    /// The project or goal the first step touches, when the step names one we have.
    private var context: String? {
        for op in proposal.operations {
            let f = op.args.fields
            for key in ["project_id", "goal_id"] {
                guard case .stringValue(let id)? = f[key]?.kind, !id.isEmpty else { continue }
                if key == "project_id", let t = data.projectTitle(id) { return t }
                if key == "goal_id", let g = data.goal(id) { return g.title }
            }
            if op.type == "update_project", case .stringValue(let id)? = f["id"]?.kind, let t = data.projectTitle(id) { return t }
        }
        return nil
    }
}
