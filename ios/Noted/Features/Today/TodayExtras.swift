import SwiftUI

// Pieces of the 今天 page beyond the day's timeline: the range switch, the briefing line, the week
// strip and month grid, 本周目标, 最近笔记 and the 14-day heat rows.

// MARK: - range

/// 今天 / 接下来 / 这周 / 这个月.
enum TodayRange: String, CaseIterable, Identifiable, Hashable {
    case today, next, week, month
    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: "今天"
        case .next: "接下来"
        case .week: "这周"
        case .month: "这个月"
        }
    }

    /// The days this range covers (接下来: the 14 days from tomorrow).
    func days(_ now: Date) -> [Date] {
        let today = now.startOfDay
        switch self {
        case .today: return [today]
        case .next: return (1...14).map { today.adding(days: $0) }
        case .week:
            let start = today.startOfWeek
            return (0..<7).map { start.adding(days: $0) }
        case .month:
            let start = today.startOfMonth
            let count = Fmt.calendar.range(of: .day, in: .month, for: start)?.count ?? 30
            return (0..<count).map { start.adding(days: $0) }
        }
    }

    /// The gray line under the title: "11月11日 周三", "11月9日 – 11月15日 · 第 46 周", "2026年11月".
    func subtitle(_ now: Date) -> String {
        let days = days(now)
        switch self {
        case .today: return Fmt.mdw(now)
        case .next: return "\(Fmt.md(days[0])) – \(Fmt.md(days[days.count - 1]))"
        case .week:
            let week = Calendar(identifier: .iso8601).component(.weekOfYear, from: now)
            return "\(Fmt.md(days[0])) – \(Fmt.md(days[days.count - 1])) · 第 \(week) 周"
        case .month: return Fmt.ym(now)
        }
    }
}

extension Date {
    /// A day-group header on 今天: "今天 · 周三", "明天 · 周四", "11月14日 周六".
    func todayGroupTitle(now: Date) -> String {
        switch Fmt.dayDiff(self, from: now) {
        case 0: "今天 · \(Fmt.weekday(self))"
        case 1: "明天 · \(Fmt.weekday(self))"
        default: Fmt.mdw(self)
        }
    }
}

// MARK: - assistant bits

/// What the assistant adds to 今天, each part nil/0/false when its feature is off or AI is unavailable.
struct TodayAssist: Equatable {
    var briefing: String?
    var suggestions = 0
    var review = false
    var briefingOn = false
    var suggestionsOn = false
}

/// The briefing paragraph, 自动生成 under it, and "N 条建议 ›".
struct BriefingRow: View {
    @Environment(Router.self) private var router
    let text: String?
    let suggestions: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text {
                Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("today-briefing")
            }
            HStack(alignment: .firstTextBaseline) {
                if text != nil { Text("自动生成").font(.caption2).foregroundStyle(.tertiaryText) }
                Spacer(minLength: 8)
                if suggestions > 0 {
                    Button { router.push(.suggestions) } label: {
                        HStack(spacing: 2) {
                            Text("\(suggestions) 条建议")
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        }
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(suggestions) 条建议")
                    .accessibilityIdentifier("today-suggestions")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - week strip, month grid

/// Seven columns: weekday, a bar as tall as the day is busy, the date. Today in the accent.
struct TodayWeekStrip: View {
    let days: [Date]
    let counts: [Int]
    let now: Date

    var body: some View {
        let top = max(counts.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                let today = d.isSameDay(as: now)
                let past = d < now.startOfDay
                VStack(spacing: 5) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3).fill(.fillTrack).frame(height: 44)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(today ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.tabInactive.opacity(past ? 0.35 : 0.7)))
                            .frame(height: counts[i] == 0 ? 0 : max(6, 44 * CGFloat(counts[i]) / CGFloat(top)))
                    }
                    Text(Fmt.weekdayShort(d)).font(.caption2.weight(today ? .bold : .regular))
                        .foregroundStyle(today ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondaryText))
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Fmt.weekday(d)) \(counts[i]) 项")
            }
        }
        .padding(.vertical, 6)
    }
}

/// The month as a 7-column grid of day numbers with a dot per busy day. Today circled in the accent.
struct TodayMonthGrid: View {
    let days: [Date]
    let counts: [Int]
    let now: Date

    var body: some View {
        let lead = days.first.map { (Fmt.calendar.component(.weekday, from: $0) + 5) % 7 } ?? 0
        let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) {
                    Text($0).font(.caption2).foregroundStyle(.secondaryText).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 30) }
                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    let today = d.isSameDay(as: now)
                    VStack(spacing: 2) {
                        Text("\(Fmt.calendar.component(.day, from: d))")
                            .font(.caption.weight(today ? .bold : .regular)).monospacedDigit()
                            .foregroundStyle(today ? AnyShapeStyle(.white) : AnyShapeStyle(d < now.startOfDay ? .secondaryText : .primary))
                            .frame(width: 22, height: 22)
                            .background { if today { Circle().fill(.tint) } }
                        Circle().fill(counts[i] > 0 ? AnyShapeStyle(Color.tabInactive) : AnyShapeStyle(.clear))
                            .frame(width: 4, height: 4)
                    }
                    .frame(height: 30)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Fmt.md(d)) \(counts[i]) 项")
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - 本周目标

/// Small cards in a row: title, "2/3", a bar. Tapping one opens the goal.
struct WeekGoalsStrip: View {
    @Environment(Router.self) private var router
    let goals: [Noted_V1_Goal]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(goals, id: \.id) { g in
                    Button { router.push(.goal(g.id)) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text(g.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(Fmt.number(g.done))/\(Fmt.number(g.goalTarget))")
                                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(g.isAchieved ? AnyShapeStyle(Color.success) : AnyShapeStyle(.secondaryText))
                            }
                            ProgressBar(value: g.fraction, tint: g.isAchieved ? .success : g.space.tint)
                        }
                        .padding(12)
                        .frame(width: 150, alignment: .leading)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14))
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(CardPressStyle())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(g.title) \(Fmt.number(g.done))/\(Fmt.number(g.goalTarget))")
                    .accessibilityIdentifier("weekgoal-\(g.id)")
                }
            }
            .padding(.horizontal, 16)
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
    }
}

// MARK: - 最近笔记, 近 14 天

struct RecentNoteRow: View {
    @Environment(Router.self) private var router
    let note: Noted_V1_Note
    let now: Date

    var body: some View {
        Button { router.push(.note(note.id)) } label: {
            HStack(spacing: 10) {
                SpaceDot(space: note.space)
                Text(note.title.isEmpty ? "无标题" : note.title).lineLimit(1)
                Spacer(minLength: 8)
                Text(Fmt.stamp(note.updateTime.date, now: now)).font(.footnote).foregroundStyle(.secondaryText)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("recent-note-\(note.id)")
    }
}

/// A goal's last 14 days as squares, filled on days with a check-in.
struct HeatRow: View {
    @Environment(Router.self) private var router
    let goal: Noted_V1_Goal

    var body: some View {
        let recent = goal.progress.recent
        Button { router.push(.goal(goal.id)) } label: {
            HStack(spacing: 3) {
                Text(goal.title).font(.footnote.weight(.semibold)).lineLimit(1)
                    .frame(width: 64, alignment: .leading).padding(.trailing, 4)
                ForEach(Array(recent.enumerated()), id: \.offset) { _, d in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(d.amount > 0 ? AnyShapeStyle(goal.space.tint) : AnyShapeStyle(.fillTrack))
                        .frame(maxWidth: .infinity).frame(height: 14)
                }
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(goal.title) 近 14 天打卡 \(recent.filter { $0.amount > 0 }.count) 天")
    }
}
