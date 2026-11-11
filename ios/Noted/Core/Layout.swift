import Foundation

struct ModuleState: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var on: Bool
}

/// Which blocks the 今天 page shows and in what order, as stored in "ui.layout".
struct Layout: Codable, Equatable, Sendable {
    /// Every block the 今天 page can show, in the default order, and whether it is on by default.
    static let catalog: [(id: String, title: String, detail: String, on: Bool)] = [
        ("briefing", "今日简报", "一段自动生成的文字", true),
        ("items", "日程与待办", "按时间排列", true),
        ("goals", "本周目标", "进度条 · 紧凑", true),
        ("inProgress", "进行中", "做过几次的待办", true),
        ("checkIns", "今天打卡", "目标和打卡按钮", true),
        ("pinned", "置顶项目", "横向卡片", true),
        ("notes", "最近笔记", "最近编辑的 3 条", false),
        ("heat", "近 14 天热力", "每个目标一行", false),
    ]
    static let standard: [ModuleState] = catalog.map { ModuleState(id: $0.id, on: $0.on) }

    static func info(_ id: String) -> (title: String, detail: String) {
        let c = catalog.first { $0.id == id }
        return (c?.title ?? id, c?.detail ?? "")
    }

    var perMode = false
    var all = Layout.standard
    var life = Layout.standard
    var work = Layout.standard

    init() {}

    /// Any field may be missing, and modules added since it was saved are appended in their default state.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        perMode = try c.decodeIfPresent(Bool.self, forKey: .perMode) ?? false
        all = Layout.reconcile(try c.decodeIfPresent([ModuleState].self, forKey: .all))
        life = Layout.reconcile(try c.decodeIfPresent([ModuleState].self, forKey: .life))
        work = Layout.reconcile(try c.decodeIfPresent([ModuleState].self, forKey: .work))
    }

    static func reconcile(_ saved: [ModuleState]?) -> [ModuleState] {
        guard let saved, !saved.isEmpty else { return standard }
        let known = Set(catalog.map(\.id))
        var out = saved.filter { known.contains($0.id) }
        for m in standard where !out.contains(where: { $0.id == m.id }) { out.append(m) }
        return out
    }

    func modules(for mode: Mode) -> [ModuleState] {
        guard perMode else { return all }
        switch mode {
        case .all: return all
        case .life: return life
        case .work: return work
        }
    }

    mutating func set(_ modules: [ModuleState], for mode: Mode) {
        guard perMode else { all = modules; return }
        switch mode {
        case .all: all = modules
        case .life: life = modules
        case .work: work = modules
        }
    }
}
