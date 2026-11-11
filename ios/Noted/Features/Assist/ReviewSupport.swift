import SwiftUI
import SwiftProtobuf
import GRPCCore

// Pieces of 每周回顾: the stat tiles, the goal tag, week labels and a quiet review call.

/// One of the three tiles at the top: "完成 11/14".
struct ReviewStat: View {
    let label: String
    let value: String
    var of: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.footnote).foregroundStyle(.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .monospaced))
                if let of {
                    Text("/\(of)").font(.system(size: 17, weight: .medium, design: .monospaced)).foregroundStyle(.secondaryText)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(of.map { "\(label) \(value)/\($0)" } ?? "\(label) \(value)")
    }
}

/// 达标 (green), 未做 / 差 n (red).
struct GoalResultTag: View {
    let goal: Noted_V1_Goal

    var body: some View {
        if goal.isAchieved {
            InfoTag(text: "达标", tint: .success, background: Color.success.wash(0.13))
        } else if goal.done == 0 {
            InfoTag(text: "未做", tint: .danger, background: Color.danger.wash(0.12))
        } else {
            InfoTag(text: "差 \(Fmt.number(max(goal.goalTarget - goal.done, 0)))", tint: .danger, background: Color.danger.wash(0.12))
        }
    }
}

enum ReviewWeek {
    private static let iso = Calendar(identifier: .iso8601)

    /// "10月5日 – 11日 · 第 41 周" (the end is the last day, not the exclusive bound).
    static func label(from: Date, to: Date) -> String {
        let last = to.addingTimeInterval(-1)
        let c = Fmt.calendar
        let range = c.component(.month, from: from) == c.component(.month, from: last)
            ? "\(Fmt.md(from)) – \(c.component(.day, from: last))日"
            : "\(Fmt.md(from)) – \(Fmt.md(last))"
        return "\(range) · 第 \(iso.component(.weekOfYear, from: from)) 周"
    }

    /// Whether `d` falls in the current week.
    static func isCurrent(_ d: Date) -> Bool {
        Fmt.calendar.isDate(d, equalTo: .now, toGranularity: .weekOfYear)
    }
}

extension AppData {
    /// The weekly review without a toast when the feature is off (FailedPrecondition): `.off`.
    enum ReviewResult { case review(Noted_V1_WeeklyReview), off, failed }

    func loadWeeklyReview(weekOf: Date, space: Noted_V1_Space) async -> ReviewResult {
        guard let api = session.api else { return .failed }
        var r = Noted_V1_GetWeeklyReviewRequest()
        r.weekOf = Google_Protobuf_Timestamp(date: weekOf); r.space = space; r.timeZone = TimeZone.current.identifier
        do {
            return .review(try await api.suggest.getWeeklyReview(r))
        } catch let e as RPCError where e.code == .failedPrecondition {
            return .off
        } catch {
            toaster.error(error)
            return .failed
        }
    }
}
