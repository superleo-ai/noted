import SwiftUI
import GRPCCore

/// 排进空档 (route .schedule): free stretches for the given to-dos, drawn on a small day timeline
/// next to what is already there (dashed: proposed, solid: existing), then the proposal to accept.
/// 换个时间: 晚一点 asks again from after the slots just offered; a length asks again with that length.
/// Nothing is written before 采纳.
struct ScheduleView: View {
    let taskIDs: [String]

    @Environment(AppData.self) private var data
    @Environment(Router.self) private var router
    @Environment(Toaster.self) private var toaster

    @State private var proposal: Noted_V1_Proposal?
    @State private var state: LoadState = .loading
    @State private var minutes: Int32 = 60
    @State private var handled = false
    /// Look for free time from here on; nil: now.
    @State private var from: Date?

    private enum LoadState { case loading, ready, noSlot, failed }
    private static let lengths: [Int32] = [30, 60, 90, 120]

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(.groupedBackground)
            case .noSlot:
                List { Section { EmptyState(text: from == nil ? "接下来两周没有 \(Fmt.duration(minutes: Int(minutes))) 的空档" : "再往后两周也没有空档") } }
            case .failed:
                List { Section { EmptyState(text: "没有排出时间") } }
            case .ready:
                if let proposal { content(proposal) }
            }
        }
        .navigationTitle("排进空档")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { lengthMenu }
        }
        .task { await propose() }
        // Leaving without a choice drops the proposal, so it does not linger under 建议.
        .onDisappear {
            if !handled, let p = proposal { Task { await data.dismissProposal(p.id) } }
        }
    }

    private var lengthMenu: some View {
        Menu {
            Button("晚一点", systemImage: "clock.arrow.circlepath") {
                guard let p = proposal, let last = ScheduleSlot.parse(p).map(\.end).max() else { return }
                from = last
                Task { await propose(replacing: true) }
            }
            .disabled(proposal == nil)
            Picker("时长", selection: Binding(get: { minutes }, set: { m in
                minutes = m
                from = nil
                Task { await propose(replacing: true) }
            })) {
                ForEach(Self.lengths, id: \.self) { m in Text(Fmt.duration(minutes: Int(m))).tag(m) }
            }
        } label: {
            Text("换个时间")
        }
        .disabled(state == .loading)
        .accessibilityLabel("换个时间")
        .accessibilityIdentifier("schedule-retry")
    }

    // MARK: page

    private func content(_ p: Noted_V1_Proposal) -> some View {
        let slots = ScheduleSlot.parse(p)
        let days = Array(Set(slots.map { $0.start.startOfDay })).sorted()
        return List {
            ForEach(days, id: \.self) { day in
                Section {
                    DayTimeline(slots: slots.filter { $0.start.isSameDay(as: day) },
                                existing: existing(on: day))
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 16))
                } header: {
                    Text(Fmt.mdw(day))
                } footer: {
                    if day == days.first { Text("虚线是建议的时间，实线是已有安排") }
                }
            }
            Section {
                ProposalCard(proposal: p, title: p.title.isEmpty ? "排进空档" : p.title, idPrefix: "schedule") { n in
                    handled = true
                    if n > 0 { toaster.show("已排进 \(n) 项", systemImage: "calendar") }
                    router.pop()
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.white)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(20)
        .task(id: days) { for d in days { await data.loadMonth(d) } }
    }

    /// Timed events on `day` in every space (busy is busy, whatever the filter).
    private func existing(on day: Date) -> [Noted_V1_Occurrence] {
        let start = day.startOfDay, end = start.adding(days: 1)
        return data.occurrences.filter { !$0.event.allDay && $0.start < end && $0.end > start }
    }

    // MARK: loading

    private func propose(replacing: Bool = false) async {
        if replacing, let old = proposal { await data.dismissProposal(old.id) }
        state = .loading
        switch await data.scheduleProposal(taskIDs: taskIDs, minutes: minutes, from: from) {
        case .proposal(let p):
            proposal = p
            state = .ready
        case .noSlot:
            proposal = nil
            state = .noSlot
        case .failed:
            proposal = nil
            state = .failed
        }
    }
}

// MARK: - slots

/// One proposed stretch, read from a create_event operation's args.
struct ScheduleSlot: Identifiable {
    let id: Int
    let title: String
    let start: Date
    let end: Date
    let space: Noted_V1_Space

    static func parse(_ p: Noted_V1_Proposal) -> [ScheduleSlot] {
        p.operations.enumerated().compactMap { i, op in
            let f = op.args.fields
            guard let s = f["start"].flatMap({ date($0.stringValue) }),
                  let e = f["end"].flatMap({ date($0.stringValue) }) else { return nil }
            let space: Noted_V1_Space = f["space"]?.stringValue.lowercased().contains("work") == true ? .work : .life
            return ScheduleSlot(id: i, title: f["title"]?.stringValue ?? op.label, start: s, end: e, space: space)
        }
    }

    private static func date(_ s: String) -> Date? {
        let a = ISO8601DateFormatter()
        if let d = a.date(from: s) { return d }
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return a.date(from: s)
    }
}

/// Hour lines from the earliest to the latest item of the day; existing events solid, proposed
/// ones dashed in the accent.
private struct DayTimeline: View {
    let slots: [ScheduleSlot]
    let existing: [Noted_V1_Occurrence]

    private let hourHeight: CGFloat = 44
    private let gutter: CGFloat = 30

    private var range: (from: Int, to: Int) {
        let c = Fmt.calendar
        let starts = slots.map(\.start) + existing.map(\.start)
        let ends = slots.map(\.end) + existing.map(\.end)
        let day = slots.first?.start.startOfDay ?? .now.startOfDay
        let lo = starts.map { max(0, c.component(.hour, from: max($0, day))) }.min() ?? 9
        let hi = ends.map { $0 >= day.adding(days: 1) ? 24 : c.component(.hour, from: $0) + (c.component(.minute, from: $0) > 0 ? 1 : 0) }.max() ?? 17
        let from = min(lo, slots.map { c.component(.hour, from: $0.start) }.min() ?? lo)
        var to = max(hi, from + 3)
        to = min(to, 24)
        return (from, to)
    }

    var body: some View {
        let r = range
        let day = slots.first?.start.startOfDay ?? .now.startOfDay
        let top = day.at(hour: r.from)
        let height = CGFloat(r.to - r.from) * hourHeight
        GeometryReader { g in
            let width = g.size.width - gutter
            ZStack(alignment: .topLeading) {
                ForEach(r.from...r.to, id: \.self) { h in
                    HStack(spacing: 6) {
                        Text(String(format: "%02d", h % 24))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiaryText)
                            .frame(width: gutter - 6, alignment: .trailing)
                        Rectangle().fill(.hairline).frame(height: 0.5)
                    }
                    .offset(y: CGFloat(h - r.from) * hourHeight - 7)
                }
                ForEach(existing, id: \.key) { o in
                    block(top: top, start: o.start, end: o.end, total: height) { h in
                        HStack(spacing: 0) {
                            Rectangle().fill(o.event.space.tint).frame(width: 3)
                            Text(o.event.title).font(.footnote.weight(.semibold)).lineLimit(1)
                                .padding(.horizontal, 8).padding(.top, 5)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                        .frame(height: h)
                        .background(o.event.space.tint.wash(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .frame(width: width).offset(x: gutter)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("已有 \(o.event.title) \(Fmt.hm(o.start))–\(Fmt.hm(o.end))")
                }
                ForEach(slots) { s in
                    block(top: top, start: s.start, end: s.end, total: height) { h in
                        HStack(alignment: .top) {
                            Text(s.title).font(.footnote.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(Fmt.hm(s.start))–\(Fmt.hm(s.end))").font(.system(size: 11, design: .monospaced))
                        }
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 8).padding(.top, 5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .frame(height: h)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.tint, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                    }
                    .frame(width: width).offset(x: gutter)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("建议 \(s.title) \(Fmt.hm(s.start))–\(Fmt.hm(s.end))")
                }
            }
        }
        .frame(height: height + 8)
        .padding(.top, 7)
    }

    /// Positions `content` between `start` and `end`, clipped to the visible hours.
    private func block<C: View>(top: Date, start: Date, end: Date, total: CGFloat, @ViewBuilder _ content: (CGFloat) -> C) -> some View {
        let y0 = max(0, CGFloat(start.timeIntervalSince(top) / 3600) * hourHeight)
        let y1 = min(total, CGFloat(end.timeIntervalSince(top) / 3600) * hourHeight)
        let h = max(22, y1 - y0 - 2)
        return content(h).offset(y: y0 + 1)
    }
}

// MARK: - data

extension AppData {
    enum ScheduleResult { case proposal(Noted_V1_Proposal), noSlot, failed }

    /// propose_schedule over the next 14 days. No free stretch (FailedPrecondition) is `.noSlot`, no toast.
    func scheduleProposal(taskIDs: [String], minutes: Int32, from: Date? = nil) async -> ScheduleResult {
        guard let api = session.api else { return .failed }
        var r = Noted_V1_ProposeScheduleRequest()
        r.taskIds = taskIDs; r.durationMinutes = minutes; r.days = 14; r.timeZone = TimeZone.current.identifier
        if let from { r.from = .init(date: from) }
        do {
            return .proposal(try await api.suggest.proposeSchedule(r))
        } catch let e as RPCError where e.code == .failedPrecondition {
            return .noSlot
        } catch {
            toaster.error(error)
            return .failed
        }
    }
}
