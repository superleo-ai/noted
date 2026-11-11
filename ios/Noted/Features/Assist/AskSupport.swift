import SwiftUI
import SwiftProtobuf

// Pieces of 提问 / 记一笔 / 拆成项目 (AskView): the conversation turn, reading what was typed,
// the rows for references, the parsed fields of a single proposed item, and finding what an
// accepted proposal created.

// MARK: - turn

/// One message and what came back for it.
struct AskTurn: Identifiable {
    enum Phase { case asking, answered(Noted_V1_AskResponse), failed }
    enum PlanState { case none, loading, ready(Noted_V1_Proposal), empty }

    let id = UUID()
    var text: String
    var phase: Phase = .asking
    var plan: PlanState = .none
    /// The reply's proposal was accepted or dismissed.
    var proposalDone = false
    /// The plan was accepted or dismissed.
    var planDone = false
    /// What was there before anything was accepted, to find what the accept created.
    var before = AskSnapshot()
    var created: AskCreated?

    var reply: Noted_V1_AskResponse? {
        if case .answered(let r) = phase { return r }
        return nil
    }

    /// The reply's proposal, when it has steps.
    var proposal: Noted_V1_Proposal? {
        guard let r = reply, r.hasProposal, !r.proposal.operations.isEmpty else { return nil }
        return r.proposal
    }

    var isPlanning: Bool { if case .loading = plan { true } else { false } }
    var hasPlan: Bool { if case .none = plan { false } else { true } }
}

// MARK: - reading the text

enum AskText {
    /// "这周工作还有什么没做完?" reads as a question; "明天三点开会" does not.
    static func isQuestion(_ s: String) -> Bool {
        let t = s.trimmedText
        if t.contains("?") || t.contains("？") { return true }
        if ["吗", "呢", "么"].contains(where: { t.hasSuffix($0) }) { return true }
        let starts = ["什么", "哪", "怎么", "为什么", "有没有", "是不是", "多少", "几", "谁", "how", "what", "when", "why"]
        if starts.contains(where: { t.lowercased().hasPrefix($0) }) { return true }
        let inside = ["有什么", "还有什么", "是什么", "怎么样", "多少", "几点", "几号", "哪些", "哪天", "哪里", "有哪", "多久"]
        return inside.contains { t.contains($0) }
    }

    /// "下个月去菲律宾，要办签证、订机票和酒店": several things to do in one go.
    static func listsSeveral(_ s: String) -> Bool {
        let t = s.trimmedText
        guard !isQuestion(t) else { return false }
        let parts = t.split(whereSeparator: { "、；;\n".contains($0) })
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return parts.count >= 2
    }
}

// MARK: - labels

enum AskLabels {
    static func kind(_ k: String) -> String {
        ["event": "日程", "task": "待办", "note": "笔记", "project": "项目", "goal": "目标", "objective": "目标"][k] ?? k
    }

    /// What a tool name read: list_events → 日程, search_notes → 笔记.
    static func tool(_ name: String) -> String? {
        let n = name.lowercased()
        let map: [(String, String)] = [
            ("event", "日程"), ("alarm", "日程"), ("task", "待办"), ("note", "笔记"), ("project", "项目"),
            ("objective", "目标"), ("goal", "目标"), ("check_in", "打卡"), ("time", "时间记录"),
            ("timer", "时间记录"), ("compass", "方向"), ("overview", "概览"), ("holiday", "节假日"),
        ]
        return map.first { n.contains($0.0) }?.1
    }

    /// 依据: what was read (tools and reference kinds), the space, and the days the references span.
    static func basis(_ r: Noted_V1_AskResponse, mode: Mode) -> String? {
        var parts: [String] = []
        for k in r.toolsUsed.compactMap(tool) + r.references.map({ kind($0.kind) }) where !parts.contains(k) {
            parts.append(k)
        }
        guard !parts.isEmpty else { return nil }
        if mode != .all { parts.append(mode.label) }
        let times = r.references.filter(\.hasTime).map(\.time.date).sorted()
        if let a = times.first, let b = times.last {
            if a.isSameDay(as: b) { parts.append(Fmt.md(a)) }
            else if Fmt.month(a) == Fmt.month(b) { parts.append("\(Fmt.md(a))–\(Calendar.current.component(.day, from: b))日") }
            else { parts.append("\(Fmt.md(a))–\(Fmt.md(b))") }
        }
        return parts.joined(separator: " · ")
    }

    /// "1 个项目 · 3 项待办".
    static func summary(_ p: Noted_V1_Proposal) -> String {
        var counts: [(String, Int)] = []
        func add(_ unit: String) {
            if let i = counts.firstIndex(where: { $0.0 == unit }) { counts[i].1 += 1 } else { counts.append((unit, 1)) }
        }
        for op in p.operations {
            switch op.type {
            case "create_project": add("个项目")
            case "create_task": add("项待办")
            case "create_event": add("个日程")
            case "create_note": add("条笔记")
            default: add("项改动")
            }
        }
        return counts.map { "\($0.1) \($0.0)" }.joined(separator: " · ")
    }

    /// The accept button: 添加到日历 for one event, 创建项目和 3 项待办 for a whole plan.
    static func accept(_ p: Noted_V1_Proposal) -> (Int) -> String {
        let types = p.operations.map(\.type)
        let total = types.count
        if total == 1 {
            switch types[0] {
            case "create_event": return { _ in "添加到日历" }
            case "create_task": return { _ in "添加待办" }
            case "create_note": return { _ in "保存笔记" }
            case "create_project": return { _ in "创建项目" }
            default: break
            }
        }
        let tasks = types.filter { $0 == "create_task" }.count
        if types.contains("create_project"), tasks == total - 1 {
            return { n in n == total ? "创建项目和 \(tasks) 项待办" : "创建所选 \(n) 项" }
        }
        return { n in "采纳 \(n) 项" }
    }

    static func toast(_ p: Noted_V1_Proposal, count: Int) -> String {
        let types = p.operations.map(\.type)
        if types.contains("create_project") { return "已创建项目" }
        if types == ["create_event"] { return "已添加到日历" }
        if types == ["create_task"] { return "已添加待办" }
        return "已写入 \(count) 项"
    }
}

// MARK: - references

extension Noted_V1_Reference {
    /// The page this reference opens, nil for a kind the app has no page for.
    @MainActor func route(_ data: AppData) -> Route? {
        switch kind {
        case "event": .event(id, occurrence: hasTime ? time.date : nil)
        case "task": .todo(id)
        case "note": .note(id)
        case "project": .project(id)
        case "goal", "objective": data.objective(id) != nil ? .objective(id) : .goal(id)
        default: nil
        }
    }
}

/// A row for something the answer talks about: the real to-do row for a to-do the app has,
/// else title with kind and time, opening its page.
struct AskReferenceRow: View {
    @Environment(AppData.self) private var data
    @Environment(Router.self) private var router
    let ref: Noted_V1_Reference

    var body: some View {
        if ref.kind == "task", let t = data.task(ref.id) {
            TodoTimelineRow(task: t, showsDate: true, showsTime: false)
        } else {
            let route = ref.route(data)
            Button { if let route { router.push(route) } } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ref.title).lineLimit(1)
                        Text(subtitle).font(.footnote).foregroundStyle(.secondaryText).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if route != nil {
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiaryText)
                    }
                }
                .padding(.vertical, 6)
                .frame(minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(route == nil)
            .accessibilityLabel("\(AskLabels.kind(ref.kind)) \(ref.title)")
            .accessibilityIdentifier("ask-ref-\(ref.id)")
        }
    }

    private var subtitle: String {
        let k = AskLabels.kind(ref.kind)
        guard ref.hasTime else { return k }
        let d = ref.time.date
        return "\(k) · \(Fmt.dayTime(d, hasTime: d.minuteOfDay != 0))"
    }
}

// MARK: - parsed fields of one proposed item

/// 识别结果 for a proposal of one event or to-do: 标题, 时间, 地点, 提醒, 空间, 项目.
enum AskFields {
    @MainActor static func rows(_ p: Noted_V1_Proposal, data: AppData) -> [(String, String)] {
        guard p.operations.count == 1, let op = p.operations.first,
              op.type == "create_event" || op.type == "create_task" else { return [] }
        let f = op.args.fields
        func str(_ k: String) -> String { f[k]?.stringValue.trimmedText ?? "" }
        var rows: [(String, String)] = []
        if !str("title").isEmpty { rows.append(("标题", str("title"))) }
        if op.type == "create_event" {
            if let s = date(str("start")) {
                if f["all_day"]?.boolValue == true { rows.append(("时间", "\(Fmt.mdw(s)) 全天")) }
                else if let e = date(str("end")), e > s {
                    rows.append(("时间", e.isSameDay(as: s) ? "\(Fmt.mdw(s)) \(Fmt.hm(s))–\(Fmt.hm(e))" : "\(Fmt.mdw(s)) \(Fmt.hm(s)) – \(Fmt.mdw(e)) \(Fmt.hm(e))"))
                } else { rows.append(("时间", "\(Fmt.mdw(s)) \(Fmt.hm(s))")) }
            }
            if !str("location").isEmpty { rows.append(("地点", str("location"))) }
            if case .numberValue(let m)? = f["remind_before_minutes"]?.kind {
                rows.append(("提醒", m == 0 ? "开始时" : "提前 \(Fmt.duration(minutes: Int(m)))"))
            }
        } else {
            if let d = date(str("due")) { rows.append(("时间", d.minuteOfDay == 0 ? Fmt.mdw(d) : "\(Fmt.mdw(d)) \(Fmt.hm(d))")) }
            if let r = date(str("remind_at")) { rows.append(("提醒", Fmt.dayTime(r))) }
        }
        switch str("space").lowercased() {
        case "work": rows.append(("空间", "工作"))
        case "life", "personal": rows.append(("空间", "个人"))
        default: break
        }
        let pid = str("project_id")
        rows.append(("项目", data.projectTitle(pid) ?? "无"))
        return rows
    }

    /// RFC 3339, zone-less local time, or a bare day.
    static func date(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

// MARK: - what an accept created

struct AskSnapshot {
    var projects: Set<String> = []
    var tasks: Set<String> = []
    var events: Set<String> = []

    @MainActor init(_ data: AppData) {
        projects = Set(data.projects.map(\.id))
        tasks = Set(data.tasks.map(\.id))
        events = Set(data.occurrences.map(\.event.id)).union(data.looseEvents.keys)
    }

    init() {}
}

/// The thing to open after an accept: the new project, else the new event, else the new to-do.
struct AskCreated {
    var text: String
    var route: Route?
    var openLabel = "打开"

    @MainActor static func find(since s: AskSnapshot, data: AppData, toast: String) -> AskCreated {
        if let p = data.projects.first(where: { !s.projects.contains($0.id) }) {
            return AskCreated(text: "已创建 \(p.title)", route: .project(p.id), openLabel: "打开项目")
        }
        if let o = data.occurrences.first(where: { !s.events.contains($0.event.id) }) {
            return AskCreated(text: "已添加 \(o.event.title)", route: .event(o.event.id, occurrence: o.start), openLabel: "打开日程")
        }
        let tasks = data.tasks.filter { !s.tasks.contains($0.id) }
        if tasks.count == 1, let t = tasks.first {
            return AskCreated(text: "已添加 \(t.title)", route: .todo(t.id), openLabel: "打开待办")
        }
        return AskCreated(text: toast, route: nil)
    }
}
