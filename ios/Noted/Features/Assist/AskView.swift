import SwiftUI

/// 提问 / 记一笔 / 拆成项目 (route .ask(text), from the input box on 新建): a conversation.
/// Each message goes to Ask first. Its reply shows with the rows it read (tap to open) and the
/// 依据 line; anything it prepared shows as a proposal to accept. Text that lists several things
/// to do (签证、机票和酒店) goes on to PlanFromText when Ask prepared nothing, and can be sent
/// there by hand with 拆成项目. Nothing is written before an accept.
struct AskView: View {
    @Environment(AppData.self) private var data
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(Toaster.self) private var toaster
    let text: String

    @State private var turns: [AskTurn] = []
    @State private var sessionID = ""
    @State private var draft = ""
    @State private var started = false
    @FocusState private var inputFocused: Bool

    private var busy: Bool { turns.contains { if case .asking = $0.phase { true } else { $0.isPlanning } } }

    var body: some View {
        ScrollViewReader { proxy in
            List { Group {
                if session.aiLocked {
                    Section { ProLockedRow(title: "提问与拆成项目", detail: "AI 是 Noted Pro 的功能") }
                }
                ForEach(turns) { turn in turnSections(turn) }
            }.classicRowInsets() }
            .listStyle(.insetGrouped)
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: turns.map(\.id)) { _, ids in
                guard let last = ids.last else { return }
                withAnimation(.snappy) { proxy.scrollTo(last, anchor: .top) }
            }
        }
        .navigationTitle(AskText.isQuestion(text) ? "提问" : "新内容")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            BottomBar {
                CaptureBar(text: $draft, placeholder: "继续补充，或再说一件事", busy: busy, floating: true,
                           focus: $inputFocused, idPrefix: "ask") { send($0) }
            }
        }
        .task {
            guard !started, !session.aiLocked else { return }
            started = true
            send(text)
        }
    }

    // MARK: sections

    @ViewBuilder private func turnSections(_ turn: AskTurn) -> some View {
        Section {
            Text(turn.text)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .accessibilityLabel("你说：\(turn.text)")
        }
        .id(turn.id)
        .listSectionSpacing(8)

        switch turn.phase {
        case .asking:
            Section { waiting("正在想…") }
        case .failed:
            Section {
                HStack {
                    Text("没有得到回答").foregroundStyle(.secondaryText)
                    Spacer()
                    Button("重试") { retry(turn.id) }
                        .accessibilityIdentifier("ask-retry")
                }
            }
        case .answered(let r):
            answerSections(turn, r)
        }

        planSections(turn)

        if let c = turn.created {
            Section {
                Button {
                    if let route = c.route { router.push(route) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.success)
                        Text(c.text).lineLimit(2)
                        Spacer(minLength: 8)
                        if c.route != nil {
                            Text(c.openLabel).foregroundStyle(.tint)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(c.route == nil)
                .accessibilityIdentifier("ask-open-created")
            }
        }
    }

    @ViewBuilder private func answerSections(_ turn: AskTurn, _ r: Noted_V1_AskResponse) -> some View {
        let basis = AskLabels.basis(r, mode: session.mode)
        Section {
            if !r.reply.trimmedText.isEmpty {
                Text(r.reply).textSelection(.enabled)
            }
            ForEach(Array(r.references.enumerated()), id: \.offset) { _, ref in
                AskReferenceRow(ref: ref)
            }
        } footer: {
            if let basis { Text("依据  \(basis)") }
        }

        let actions = quickActions(turn, r)
        if !actions.isEmpty {
            Section {
                ChipRow {
                    ForEach(actions, id: \.title) { a in
                        Chip(title: a.title, filled: true, action: a.run)
                            .accessibilityIdentifier(a.id)
                    }
                }
                .padding(.horizontal, -16)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .listSectionSpacing(12)
        }

        if let p = turn.proposal, !turn.proposalDone {
            proposalSections(p, turn: turn.id, plan: false)
        }
    }

    @ViewBuilder private func planSections(_ turn: AskTurn) -> some View {
        switch turn.plan {
        case .none: EmptyView()
        case .loading: Section { waiting("正在拆成项目…") }
        case .empty:
            Section { Text("没有拆出要做的事").foregroundStyle(.secondaryText) }
        case .ready(let p):
            if !turn.planDone { proposalSections(p, turn: turn.id, plan: true) }
        }
    }

    /// 识别结果 (one event or to-do) and the card to accept it.
    @ViewBuilder private func proposalSections(_ p: Noted_V1_Proposal, turn: UUID, plan: Bool) -> some View {
        let fields = AskFields.rows(p, data: data)
        if !fields.isEmpty {
            Section {
                ForEach(fields, id: \.0) { label, value in
                    LabeledContent(label, value: value)
                }
            } header: { SectionLabel("识别结果") }
        }
        Section {
            ProposalCard(proposal: p, title: title(p, single: !fields.isEmpty),
                         idPrefix: plan ? "plan" : "ask-proposal", acceptLabel: AskLabels.accept(p)) { n in
                accepted(p, turn: turn, plan: plan, count: n)
            }
            .listRowInsets(EdgeInsets())
        }
    }

    private func title(_ p: Noted_V1_Proposal, single: Bool) -> String {
        if single { return p.title.isEmpty ? "确认" : p.title }
        let s = AskLabels.summary(p)
        return p.title.isEmpty ? "拟创建 · \(s)" : p.title
    }

    private func waiting(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(label).foregroundStyle(.secondaryText)
        }
    }

    // MARK: quick actions

    private struct QuickAction {
        var title: String
        var id: String
        var run: () -> Void
    }

    /// 排进空档 for the open to-dos the reply read, 给 X 设个日期 for one without a day, and
    /// 拆成项目 when the text lists several things and no plan was made yet.
    private func quickActions(_ turn: AskTurn, _ r: Noted_V1_AskResponse) -> [QuickAction] {
        var out: [QuickAction] = []
        let open = r.references.filter { $0.kind == "task" && !(data.task($0.id)?.completed ?? false) }
        if !open.isEmpty {
            let ids = open.map(\.id)
            out.append(QuickAction(title: "排进空档", id: "ask-schedule") { router.push(.schedule(ids)) })
        }
        if let t = open.lazy.compactMap({ data.task($0.id) }).first(where: { !$0.hasDueTime }) {
            let name = t.title.count > 8 ? String(t.title.prefix(8)) + "…" : t.title
            out.append(QuickAction(title: "给\(name)设个日期", id: "ask-set-date") { router.push(.todo(t.id)) })
        }
        let planLike = turn.proposal?.operations.contains { $0.type == "create_project" } ?? false
        if AskText.listsSeveral(turn.text), !turn.hasPlan, !planLike, turn.created == nil {
            let id = turn.id
            out.append(QuickAction(title: "拆成项目", id: "ask-plan") { Task { await plan(id) } })
        }
        return out
    }

    // MARK: actions

    private func update(_ id: UUID, _ change: (inout AskTurn) -> Void) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[i])
    }

    private func send(_ message: String) {
        let t = message.trimmedText
        guard !t.isEmpty else { return }
        var turn = AskTurn(text: t)
        turn.before = AskSnapshot(data)
        turns.append(turn)
        let id = turn.id
        Task { await ask(id) }
    }

    private func retry(_ id: UUID) {
        update(id) { $0.phase = .asking }
        Task { await ask(id) }
    }

    private func ask(_ id: UUID) async {
        guard let turn = turns.first(where: { $0.id == id }) else { return }
        guard let r = await data.ask(turn.text, sessionID: sessionID, space: session.mode.space) else {
            update(id) { $0.phase = .failed }
            return
        }
        sessionID = r.sessionID
        update(id) { $0.phase = .answered(r); $0.before = AskSnapshot(data) }
        // Several things to do and nothing prepared: break it into a project.
        let prepared = r.hasProposal && !r.proposal.operations.isEmpty
        if !prepared, AskText.listsSeveral(turn.text) { await plan(id) }
    }

    private func plan(_ id: UUID) async {
        guard let turn = turns.first(where: { $0.id == id }), !turn.isPlanning else { return }
        update(id) { $0.plan = .loading }
        guard let p = await data.planFromText(turn.text, space: session.mode.space) else {
            update(id) { $0.plan = .none }
            return
        }
        update(id) { $0.plan = p.operations.isEmpty ? .empty : .ready(p); $0.before = AskSnapshot(data) }
    }

    private func accepted(_ p: Noted_V1_Proposal, turn id: UUID, plan: Bool, count: Int) {
        guard let turn = turns.first(where: { $0.id == id }) else { return }
        let snapshot = turn.before
        update(id) { t in
            if plan { t.planDone = true } else { t.proposalDone = true }
        }
        guard count > 0 else { return }
        let message = AskLabels.toast(p, count: count)
        toaster.show(message)
        let created = AskCreated.find(since: snapshot, data: data, toast: message)
        update(id) { $0.created = created; $0.before = AskSnapshot(data) }
    }
}
