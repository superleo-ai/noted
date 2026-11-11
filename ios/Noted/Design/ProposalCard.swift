import SwiftUI

/// A pending proposal shown in place: pick which steps to carry out, fill what it could not know,
/// then accept. Nothing is written before the accept button. Used by 提取待办, 提问, 记一笔, 建议,
/// 每周回顾 and 排进空档.
struct ProposalCard: View {
    @Environment(AppData.self) private var data
    let proposal: Noted_V1_Proposal
    var title: String
    var idPrefix = "proposal"
    var acceptLabel: (Int) -> String = { "采纳 \($0) 项" }
    var dismissLabel = "忽略"
    /// Called with how many steps were carried out (0: dismissed).
    var onDone: (Int) -> Void

    @State private var picked: Set<Int>
    @State private var dates: [String: Date] = [:]
    @State private var texts: [String: String] = [:]
    @State private var busy = false

    init(proposal: Noted_V1_Proposal, title: String, idPrefix: String = "proposal",
         acceptLabel: @escaping (Int) -> String = { "采纳 \($0) 项" }, dismissLabel: String = "忽略",
         onDone: @escaping (Int) -> Void) {
        self.proposal = proposal
        self.title = title
        self.idPrefix = idPrefix
        self.acceptLabel = acceptLabel
        self.dismissLabel = dismissLabel
        self.onDone = onDone
        _picked = State(initialValue: Set(proposal.operations.indices))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, proposal.reason.isEmpty ? 12 : 4)
            if !proposal.reason.isEmpty {
                Text(proposal.reason).font(.footnote).foregroundStyle(.secondaryText)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }
            ForEach(Array(proposal.operations.enumerated()), id: \.offset) { i, op in
                Divider().padding(.leading, 14)
                Button {
                    if picked.contains(i) { picked.remove(i) } else { picked.insert(i) }
                } label: {
                    HStack(spacing: 12) {
                        CheckMark(isOn: picked.contains(i), size: 22)
                        Text(op.label).font(.subheadline).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(picked.contains(i) ? .isSelected : [])
            }
            ForEach(proposal.inputs, id: \.name) { input in
                Divider().padding(.leading, 14)
                HStack {
                    Text(input.label).font(.subheadline)
                    Spacer()
                    if input.type == "date" {
                        if dates[input.name] == nil {
                            // Not guessed: the person picks it (SpecAI 不猜).
                            if input.required { Text("必填").font(.footnote.weight(.semibold)).foregroundStyle(.danger) }
                            Button("选择日期") { dates[input.name] = Date.now.startOfDay }
                                .font(.subheadline.weight(.semibold))
                                .accessibilityIdentifier("\(idPrefix)-input-\(input.name)")
                        } else {
                            DatePicker(input.label, selection: dateBinding(input.name), displayedComponents: .date)
                                .labelsHidden()
                                .environment(\.locale, Fmt.zh)
                        }
                    } else {
                        TextField(input.required ? "必填" : "选填", text: Binding(get: { texts[input.name] ?? "" }, set: { texts[input.name] = $0 }))
                            .multilineTextAlignment(.trailing)
                            .font(.subheadline)
                    }
                }
                .padding(.horizontal, 14).frame(minHeight: 44)
            }
            Divider()
            HStack(spacing: 10) {
                Button(dismissLabel) {
                    Task { await data.dismissProposal(proposal.id) }
                    onDone(0)
                }
                .buttonStyle(.wide(.gray, small: true))
                .accessibilityIdentifier("\(idPrefix)-dismiss")
                Button(busy ? "正在写入…" : acceptLabel(picked.count)) { Task { await accept() } }
                    .buttonStyle(.wide(.filled, small: true))
                    .disabled(picked.isEmpty || busy || missingRequired)
                    .accessibilityIdentifier("\(idPrefix)-accept")
            }
            .padding(12)
        }
        .background(.fillQuiet, in: RoundedRectangle(cornerRadius: 12))
    }

    private var missingRequired: Bool {
        proposal.inputs.contains { input in
            guard input.required else { return false }
            if input.type == "date" { return dates[input.name] == nil }
            return (texts[input.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func dateBinding(_ name: String) -> Binding<Date> {
        Binding(get: { dates[name] ?? Date.now.startOfDay }, set: { dates[name] = $0 })
    }

    private func accept() async {
        busy = true
        defer { busy = false }
        var inputs: [String: String] = [:]
        for input in proposal.inputs {
            if input.type == "date" { if let d = dates[input.name] { inputs[input.name] = Fmt.ymd(d) } }
            else if let t = texts[input.name], !t.isEmpty { inputs[input.name] = t }
        }
        let n = picked.count
        if await data.acceptProposal(proposal.id, indexes: picked.sorted(), inputs: inputs) != nil { onDone(n) }
    }
}

