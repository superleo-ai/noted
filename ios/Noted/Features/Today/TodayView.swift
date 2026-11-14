import SwiftUI

/// 今天 (tab root): a range switch (今天 / 接下来 / 这周 / 这个月) over the blocks of the 页面模块
/// layout: 今日简报, 日程与待办, 本周目标, 进行中, 今天打卡, 置顶项目, 最近笔记 and 近 14 天.
struct TodayView: View {
    @Environment(AppData.self) private var data
    @Environment(Session.self) private var session
    @State private var range: TodayRange = .today
    @State private var assist = TodayAssist()
    /// mode + day the briefing was fetched for, so coming back to the tab does not ask again.
    @State private var briefingKey = ""

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            TodayList(now: ctx.date, range: $range, assist: assist) { await loadAssist(force: true) }
        }
        .navigationTitle("今天")
        .largeSubtitle(range.subtitle(.now))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SpaceFilterMenu() }.plainBar()
            ToolbarItem(placement: .topBarTrailing) { SettingsAvatarButton() }.plainBar()
        }
        .task(id: range) {
            await data.loadMonth(.now)
            if range == .next { await data.loadMonth(Date.now.adding(days: 14)) }
        }
        .onAppear { Task { await loadAssist(force: false) } }
        .onChange(of: session.mode) { Task { await loadAssist(force: false) } }
    }

    /// The briefing (once per mode and day unless forced) and the suggestion count (every time).
    private func loadAssist(force: Bool) async {
        guard let s = await data.loadAISettings(), s.status.enabled else {
            assist = TodayAssist(); briefingKey = ""
            return
        }
        var a = assist
        a.review = s.features.weeklyReview
        a.briefingOn = s.status.chat && s.features.dailyBriefing && !session.aiLocked // AI is Noted Pro
        a.suggestionsOn = s.features.suggestions
        let space = session.mode.space
        let key = "\(session.mode.rawValue)-\(Fmt.ymd(.now))"
        if !a.briefingOn {
            a.briefing = nil
        } else if force || key != briefingKey {
            a.briefing = await data.dailyBriefing(space: space)
            briefingKey = key
        }
        if a.suggestionsOn { a.suggestions = await data.listSuggestions(space: space).count } else { a.suggestions = 0 }
        if space == session.mode.space { assist = a }
    }
}

private struct TodayList: View {
    @Environment(AppData.self) private var data
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(Toaster.self) private var toaster
    let now: Date
    @Binding var range: TodayRange
    let assist: TodayAssist
    let reloadAssist: @MainActor () async -> Void
    @State private var confirmDelete: Noted_V1_Task?
    @State private var showPast = false

    /// The 页面模块 layout for this mode; without Pro the default one.
    private var modules: [ModuleState] {
        (session.pro.isPro ? session.layout.modules(for: session.mode) : Layout.standard).filter(\.on)
    }

    /// Wide (an opened iPhone Duo with nothing open beside 今天): the briefing and the timeline on
    /// the left, the other modules on the right.
    @Environment(\.wideRoot) private var wide
    private static let leftModules: Set<String> = ["briefing", "items"]

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                let side = wide ? modules.filter { !Self.leftModules.contains($0.id) } : []
                if side.isEmpty {
                    column {
                        rangePicker
                        ForEach(modules, id: \.id) { m in module(m.id) }
                    }
                } else {
                    HStack(spacing: 0) {
                        column {
                            rangePicker
                            ForEach(modules.filter { Self.leftModules.contains($0.id) }, id: \.id) { m in module(m.id) }
                        }
                        column {
                            ForEach(side, id: \.id) { m in module(m.id) }
                        }
                    }
                }
            }
            .onChange(of: router.scrollToTopRequest) {
                withAnimation(.snappy) { proxy.scrollTo(TodayList.topID, anchor: .top) }
            }
            .onChange(of: range) { showPast = false }
        }
        .confirmationDialog("删除待办？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmDelete) { t in
            Button("删除待办", role: .destructive) {
                Task { if await data.deleteTask(t.id) { toaster.show("已删除", systemImage: "trash") } }
            }
            .accessibilityIdentifier("today-delete-confirm")
        } message: { t in
            Text("“\(t.title)”")
        }
        .accessibilityIdentifier("today-list")
    }

    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        List { Group { content() }.classicRowInsets() }
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 10)
            .refreshable {
                await data.refreshAll()
                await reloadAssist()
            }
    }

    @ViewBuilder
    private func module(_ id: String) -> some View {
        switch id {
        case "briefing": briefing
        case "items": items
        case "goals": weekGoals
        case "inProgress": inProgress
        case "checkIns": checkIns
        case "pinned": pinned
        case "notes": recentNotes
        case "heat": heat
        default: EmptyView()
        }
    }

    private var rangePicker: some View {
        Section {
            Picker("范围", selection: $range) {
                ForEach(TodayRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).classicSegmented()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("today-range")
            .id(Self.topID)
        }
        .listSectionSpacing(.compact)
    }

    // MARK: 今日简报

    @ViewBuilder
    private var briefing: some View {
        let text = range == .today ? assist.briefing : nil
        if text != nil || assist.suggestions > 0 {
            Section {
                BriefingRow(text: text, suggestions: assist.suggestions)
            }
        }
    }

    // MARK: 日程与待办

    @ViewBuilder
    private var items: some View {
        switch range {
        case .today: agenda
        case .next: upcoming
        case .week, .month: period
        }
    }

    static let topID = "today-top"

    // MARK: 日程与待办

    /// One line of the timeline.
    private enum Line: Identifiable {
        case event(Noted_V1_Occurrence)
        case todo(Noted_V1_Task)
        case now
        case untimedLabel

        var id: String {
            switch self {
            case .event(let o): "e-\(o.key)"
            case .todo(let t): "t-\(t.id)"
            case .now: "now"
            case .untimedLabel: "untimed"
            }
        }
    }

    /// Overdue to-dos from earlier days, then events and timed to-dos by time with the now line among
    /// them, then 全天 · 未定时: all-day events and date-only to-dos (open ones first).
    private var lines: [Line] {
        let today = now.startOfDay
        let occs = data.occurrences(on: now)
        let tasks = data.tasks(on: now)
        var out: [Line] = data.overdueTasks(now: now).map { .todo($0) }

        var timed: [(minute: Int, line: Line)] = []
        for o in occs where !o.event.allDay {
            timed.append((o.start < today ? 0 : o.start.minuteOfDay, .event(o)))
        }
        for t in tasks where t.hasClockTime {
            timed.append((t.dueTime.date.minuteOfDay, .todo(t)))
        }
        timed.sort { $0.minute < $1.minute }
        let nowMinute = now.minuteOfDay
        var placed = false
        for x in timed {
            if !placed && x.minute > nowMinute { out.append(.now); placed = true }
            out.append(x.line)
        }
        if !placed && !timed.isEmpty { out.append(.now) }

        let untimed: [Line] = occs.filter(\.event.allDay).map { .event($0) }
            + tasks.filter { !$0.hasClockTime }.sorted { !$0.completed && $1.completed }.map { .todo($0) }
        if !untimed.isEmpty {
            out.append(.untimedLabel)
            out += untimed
        }
        return out
    }

    private var agenda: some View {
        let lines = self.lines
        return Section {
            if lines.isEmpty {
                Group {
                    if data.isLoaded { EmptyState(text: "今天没有安排") }
                    else { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 22) }
                }
            }
            ForEach(lines, id: \.id) { row($0) }
        } header: {
            VStack(alignment: .leading, spacing: 0) {
                if #unavailable(iOS 26.0) {
                    Text(Fmt.mdw(now)).font(.subheadline).foregroundStyle(.secondaryText)
                        .textCase(nil).padding(.bottom, 10)
                }
                SectionHeader("日程与待办", action: "日历") { router.select(.calendar) }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 0))
        }
    }

    @ViewBuilder
    private func row(_ line: Line) -> some View {
        switch line {
        case .event(let o):
            EventTimelineRow(occurrence: o, now: now)
        case .todo(let t):
            TodoTimelineRow(task: t, now: now)
                .todaySwipes(t, onDelete: { confirmDelete = t })
        case .now:
            NowLine(now: now)
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
        case .untimedLabel:
            Text("全天 · 未定时")
                .font(.footnote).foregroundStyle(.secondaryText)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
        }
    }

    // MARK: 接下来, 这周, 这个月

    /// One day's lines for the range views: overdue to-dos (today only), then events and timed
    /// to-dos by time, then all-day events and date-only to-dos.
    private func dayLines(_ day: Date) -> [Line] {
        let start = day.startOfDay
        let occs = data.occurrences(on: day)
        let tasks = data.tasks(on: day)
        var out: [Line] = day.isSameDay(as: now) ? data.overdueTasks(now: now).map { .todo($0) } : []
        var timed: [(minute: Int, line: Line)] = []
        for o in occs where !o.event.allDay { timed.append((o.start < start ? 0 : o.start.minuteOfDay, .event(o))) }
        for t in tasks where t.hasClockTime { timed.append((t.dueTime.date.minuteOfDay, .todo(t))) }
        out += timed.sorted { $0.minute < $1.minute }.map(\.line)
        out += occs.filter(\.event.allDay).map { .event($0) }
        out += tasks.filter { !$0.hasClockTime }.sorted { !$0.completed && $1.completed }.map { .todo($0) }
        return out
    }

    private func count(_ day: Date) -> Int { data.occurrences(on: day).count + data.tasks(on: day).count }

    private func daySection(_ day: Date) -> some View {
        Section {
            ForEach(dayLines(day), id: \.id) { row($0) }
        } header: {
            Text(day.todayGroupTitle(now: now))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(day.isSameDay(as: now) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondaryText))
                .textCase(nil)
        }
    }

    @ViewBuilder
    private var upcoming: some View {
        let days = TodayRange.next.days(now).filter { count($0) > 0 }
        if days.isEmpty {
            Section {
                if data.isLoaded { EmptyState(text: "接下来 14 天没有安排") }
                else { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 22) }
            }
        }
        ForEach(days, id: \.self) { daySection($0) }
    }

    @ViewBuilder
    private var period: some View {
        let days = range.days(now)
        let counts = days.map(count)
        let today = now.startOfDay
        let past = days.filter { $0 < today }
        let rest = days.filter { $0 >= today && (count($0) > 0 || ($0 == today && !data.overdueTasks(now: now).isEmpty)) }
        Section {
            if range == .week { TodayWeekStrip(days: days, counts: counts, now: now) }
            else { TodayMonthGrid(days: days, counts: counts, now: now) }
            if !past.isEmpty {
                Button { withAnimation(.snappy) { showPast.toggle() } } label: {
                    HStack {
                        Text(pastSummary(past)).font(.subheadline).foregroundStyle(.secondaryText)
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiaryText)
                            .rotationEffect(.degrees(showPast ? 180 : 0))
                    }
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showPast ? "收起已过去的日子" : "展开已过去的日子")
                .accessibilityIdentifier("today-past-toggle")
            }
        } header: {
            VStack(alignment: .leading, spacing: 0) {
                if #unavailable(iOS 26.0) {
                    Text(range.subtitle(now)).font(.subheadline).foregroundStyle(.secondaryText)
                        .textCase(nil).padding(.bottom, 10)
                }
                SectionHeader(range == .week ? "这周" : "这个月", action: "日历") { router.select(.calendar) }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 0))
        }
        if showPast {
            ForEach(past.filter { count($0) > 0 }, id: \.self) { daySection($0) }
        }
        if rest.isEmpty {
            Section { EmptyState(text: range == .week ? "这周没有更多安排" : "这个月没有更多安排") }
        }
        ForEach(rest, id: \.self) { daySection($0) }
    }

    /// "周一 – 周三 · 已完成 5 项", "11月1日 – 10日 · 已完成 12 项".
    private func pastSummary(_ past: [Date]) -> String {
        guard let first = past.first, let last = past.last else { return "" }
        let name: (Date) -> String = { range == .week ? Fmt.weekday($0) : Fmt.md($0) }
        let span = first == last ? name(first) : "\(name(first)) – \(name(last))"
        let done = past.reduce(0) { n, d in
            n + data.tasks(on: d).filter(\.completed).count + data.occurrences(on: d).filter { $0.start >= d.startOfDay }.count
        }
        return "\(span) · 已完成 \(done) 项"
    }

    // MARK: 本周目标

    @ViewBuilder
    private var weekGoals: some View {
        let goals = data.goals.filter { !$0.archived && data.inSpace($0.space) && ($0.period == .week || $0.period == .unspecified) }
        if !goals.isEmpty {
            Section {
                WeekGoalsStrip(goals: goals)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } header: {
                SectionHeader("本周目标", action: assist.review ? "回顾" : nil) { router.push(.review) }
            }
        }
    }

    // MARK: 最近笔记

    @ViewBuilder
    private var recentNotes: some View {
        let notes = data.visibleNotes.filter { !$0.archived }.sorted { $0.updateTime.date > $1.updateTime.date }.prefix(3)
        if !notes.isEmpty {
            Section {
                ForEach(Array(notes), id: \.id) { RecentNoteRow(note: $0, now: now) }
            } header: {
                SectionHeader("最近笔记", action: "全部") { router.select(.notes) }
            }
        }
    }

    // MARK: 近 14 天

    @ViewBuilder
    private var heat: some View {
        let goals = data.goals.filter { !$0.archived && data.inSpace($0.space) && !$0.progress.recent.isEmpty }
        if !goals.isEmpty {
            Section {
                ForEach(goals, id: \.id) { HeatRow(goal: $0) }
            } header: {
                SectionHeader("近 14 天")
            }
        }
    }

    // MARK: 进行中

    @ViewBuilder
    private var inProgress: some View {
        let tasks = data.inProgressTasks
        if !tasks.isEmpty {
            Section {
                ForEach(tasks, id: \.id) { t in
                    InProgressRow(task: t, now: now)
                        .todaySwipes(t, onDelete: { confirmDelete = t })
                }
            } header: {
                SectionHeader("进行中")
            }
        }
    }

    // MARK: 今天打卡

    @ViewBuilder
    private var checkIns: some View {
        let goals = data.standaloneGoals
        let objectives = data.visibleObjectives
        if !goals.isEmpty || !objectives.isEmpty {
            Section {
                ForEach(goals, id: \.id) { GoalRow(goal: $0) }
                ForEach(objectives, id: \.id) { ObjectiveRow(objective: $0) }
            } header: {
                SectionHeader("今天打卡", action: "全部") { router.push(.goals) }
            }
        }
    }

    // MARK: 置顶项目

    @ViewBuilder
    private var pinned: some View {
        let projects = data.pinnedProjects
        if !projects.isEmpty {
            Section {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(projects, id: \.id) { ProjectCard(project: $0, width: 236, now: now) }
                    }
                    .padding(.horizontal, 16)
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                SectionHeader("置顶项目", action: "全部") { router.push(.projects) }
                    .padding(.horizontal, 16)
            }
            .edgeToEdgeSection()
        }
    }
}

/// A to-do with sittings: dot, title, "60%", a bar and "已做 3 次 · 共 2 小时 10 分 · 上次 今天".
private struct InProgressRow: View {
    @Environment(Router.self) private var router
    let task: Noted_V1_Task
    let now: Date

    var body: some View {
        Button { router.push(.todo(task.id)) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SpaceDot(space: task.space)
                    Text(task.title).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(task.progress)%").font(.system(.subheadline, design: .monospaced).weight(.bold))
                }
                ProgressBar(value: Double(task.progress) / 100)
                Text(summary).font(.footnote).foregroundStyle(.secondaryText).lineLimit(1).monospacedDigit()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inprogress-\(task.id)")
    }

    private var summary: String {
        var s = "已做 \(task.workSessions) 次 · 共 \(Fmt.duration(minutes: Int(task.workedMinutes)))"
        if task.hasLastWorkedTime { s += " · 上次 \(Fmt.day(task.lastWorkedTime.date, now: now))" }
        return s
    }
}

// MARK: - swipes

extension View {
    /// Right: 完成 (green). Left: 删除 (red, asks first) and 推迟 (to tomorrow).
    fileprivate func todaySwipes(_ task: Noted_V1_Task, onDelete: @escaping () -> Void) -> some View {
        modifier(TodaySwipes(task: task, onDelete: onDelete))
    }
}

private struct TodaySwipes: ViewModifier {
    @Environment(AppData.self) private var data
    @Environment(Toaster.self) private var toaster
    let task: Noted_V1_Task
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    let done = !task.completed
                    Task { if await data.setCompleted(task.id, done), done { toaster.show("已完成") } }
                } label: {
                    task.completed ? Label("未完成", systemImage: "arrow.uturn.backward") : Label("完成", systemImage: "checkmark")
                }
                .tint(task.completed ? .tabInactive : .success)
                .accessibilityIdentifier("swipe-complete")
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(action: onDelete) { Label("删除", systemImage: "trash") }
                    .tint(.danger)
                    .accessibilityIdentifier("swipe-delete")
                if !task.completed {
                    Button {
                        Task { if let d = await data.postpone(task.id) { toaster.show("已推迟到\(Fmt.day(d))", systemImage: "clock") } }
                    } label: { Label("推迟", systemImage: "clock") }
                    .tint(.warning)
                    .accessibilityIdentifier("swipe-postpone")
                }
            }
    }
}
