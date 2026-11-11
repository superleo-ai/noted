import SwiftUI

/// 每周回顾 (route .review): the week's numbers, goals, compass, words against deeds, time,
/// what slipped, and next week's proposal (nothing written before 采纳). Previous/next week in
/// the toolbar. Shows only an empty state when the weekly_review feature is off.
struct ReviewView: View {
    @Environment(AppData.self) private var data
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(Toaster.self) private var toaster

    @State private var weekOf = Date.now
    @State private var review: Noted_V1_WeeklyReview?
    @State private var state: LoadState = .loading
    @State private var handled: Set<String> = []

    private enum LoadState { case loading, ready, off, failed }

    var body: some View {
        Group {
            switch state {
            case .loading where review == nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(.groupedBackground)
            case .off:
                List { Section { EmptyState(text: "每周回顾未开启") } }
            case .failed where review == nil:
                List { Section { EmptyState(text: "没有读到回顾") } }
            default:
                if let review { content(review) }
            }
        }
        .navigationTitle(ReviewWeek.isCurrent(weekOf) ? "本周回顾" : "每周回顾")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if state != .off {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("上一周")
                        .accessibilityIdentifier("review-prev")
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(ReviewWeek.isCurrent(weekOf))
                        .accessibilityLabel("下一周")
                        .accessibilityIdentifier("review-next")
                }
            }
        }
        .task(id: "\(Int(weekOf.timeIntervalSince1970))-\(session.mode.rawValue)") { await load() }
        .refreshable { await load() }
    }

    // MARK: page

    private func content(_ r: Noted_V1_WeeklyReview) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(ReviewWeek.label(from: r.from.date, to: r.to.date))
                        .font(.subheadline).foregroundStyle(.secondaryText)
                    HStack(spacing: 8) {
                        ReviewStat(label: "完成", value: "\(r.tasksDone)", of: "\(r.tasksTotal)")
                        ReviewStat(label: "目标", value: "\(r.goals.filter(\.isAchieved).count)", of: "\(r.goals.count)")
                        ReviewStat(label: "顺延", value: "\(r.carriedTasks.count)")
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 0, trailing: 0))
            }
            compass(r)
            goals(r)
            behavior(r)
            time(r)
            carried(r)
            nextWeek(r)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(20)
    }

    @ViewBuilder
    private func compass(_ r: Noted_V1_WeeklyReview) -> some View {
        let c = r.compass
        if r.hasCompass, c.version > 0, !(c.vision.isEmpty && c.antiVision.isEmpty) {
            Section("方向") {
                if !c.vision.isEmpty { compassRow("想要的", c.vision, tint: .success) }
                if !c.antiVision.isEmpty { compassRow("拒绝的", c.antiVision, tint: .danger) }
            }
        }
    }

    private func compassRow(_ label: String, _ text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.footnote.weight(.semibold)).foregroundStyle(tint)
            Text(text).font(.subheadline).lineLimit(3)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func goals(_ r: Noted_V1_WeeklyReview) -> some View {
        if !r.goals.isEmpty {
            Section("目标") {
                ForEach(r.goals, id: \.id) { g in
                    Button { router.push(.goal(g.id)) } label: {
                        HStack(spacing: 10) {
                            SpaceDot(space: g.space)
                            Text(g.title).foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(Fmt.number(g.done))/\(Fmt.number(g.goalTarget))")
                                .font(.system(.subheadline, design: .monospaced)).foregroundStyle(.secondaryText)
                            GoalResultTag(goal: g)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private func behavior(_ r: Noted_V1_WeeklyReview) -> some View {
        let b = r.behavior
        if r.hasBehavior, !b.mismatches.isEmpty || b.unlinkedMinutes > 0 {
            Section {
                ForEach(Array(b.mismatches.enumerated()), id: \.offset) { _, m in
                    Label { Text(m).font(.subheadline) } icon: {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.warning)
                    }
                }
                if b.unlinkedMinutes > 0 {
                    HStack {
                        Text("没有对应目标的时间").font(.subheadline)
                        Spacer()
                        Text(Fmt.duration(minutes: Int(b.unlinkedMinutes))).font(.subheadline).foregroundStyle(.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("言行")
            } footer: {
                if !b.unlinked.isEmpty {
                    Text(b.unlinked.prefix(3).map { "\($0.title) \(Fmt.duration(minutes: Int($0.minutes)))" }.joined(separator: " · "))
                }
            }
        }
    }

    @ViewBuilder
    private func time(_ r: Noted_V1_WeeklyReview) -> some View {
        if r.timeMinutes > 0 {
            Section {
                ForEach(r.topActivities, id: \.key) { row in
                    HStack {
                        Text(row.label).font(.subheadline).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Fmt.duration(minutes: Int(row.minutes))).font(.subheadline).foregroundStyle(.secondaryText).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                HStack {
                    Text("时间")
                    Spacer()
                    Text("共 \(Fmt.duration(minutes: Int(r.timeMinutes)))")
                }
            }
        }
    }

    @ViewBuilder
    private func carried(_ r: Noted_V1_WeeklyReview) -> some View {
        if !r.carriedTasks.isEmpty {
            Section("没做完的") {
                ForEach(r.carriedTasks, id: \.id) { t in
                    Button { router.push(.todo(t.id)) } label: {
                        HStack(spacing: 12) {
                            CheckMark(isOn: false, size: 22)
                            Text(t.title).foregroundStyle(.primary).lineLimit(2)
                            Spacer(minLength: 8)
                            if let p = data.project(t.projectID) {
                                Text(p.title).font(.footnote.weight(.semibold)).lineLimit(1)
                                    .padding(.horizontal, 9).frame(height: 24)
                                    .foregroundStyle(p.space.tint)
                                    .background(p.space.tint.wash(0.12), in: Capsule())
                            } else {
                                SpaceTag(space: t.space)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private func nextWeek(_ r: Noted_V1_WeeklyReview) -> some View {
        let p = r.nextWeek
        if r.hasNextWeek, p.status == "pending", !p.operations.isEmpty, !handled.contains(p.id) {
            Section {
                ProposalCard(proposal: p, title: "下周建议", idPrefix: "review-next",
                             acceptLabel: { "采纳所选 \($0) 条" }) { n in
                    handled.insert(p.id)
                    if n > 0 { toaster.show("已采纳 \(n) 条") }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.white)
            }
        }
    }

    // MARK: loading

    private func shift(_ weeks: Int) {
        weekOf = Fmt.calendar.date(byAdding: .weekOfYear, value: weeks, to: weekOf) ?? weekOf
        if ReviewWeek.isCurrent(weekOf) { weekOf = .now }
    }

    private func load() async {
        if review == nil { state = .loading }
        switch await data.loadWeeklyReview(weekOf: weekOf, space: session.mode.space) {
        case .review(let r):
            review = r
            state = .ready
        case .off:
            review = nil
            state = .off
        case .failed:
            state = .failed
        }
    }
}
