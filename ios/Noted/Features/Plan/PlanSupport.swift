import SwiftUI

// Pieces shared by the 计划 pages (root, project, goal, objective).

// MARK: - formatting

enum PlanFmt {
    private static let ymdParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "2026-10-08" → that day at midnight.
    static func day(_ s: String) -> Date? { ymdParser.date(from: s) }

    /// A price with two decimals: "27.50".
    static func price(_ v: Double) -> String { String(format: "%.2f", v) }

    /// A number typed by the person ("78,6", "1 200.5").
    static func parse(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespaces))
    }

    /// Up to one decimal, no trailing ".0": 78.6, 80.
    static func value(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return Fmt.number(r)
    }

    /// Markdown reduced to a one-line preview.
    static func preview(_ md: String) -> String {
        var s = md.replacingOccurrences(of: "\n", with: " ")
        for token in ["# ", "## ", "### ", "- [ ] ", "- [x] ", "**", "__", "`", "> ", "* "] {
            s = s.replacingOccurrences(of: token, with: "")
        }
        s = s.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}

extension Noted_V1_GoalPeriod {
    /// 每天 / 每周 / 每月 choices for pickers.
    static let planChoices: [Noted_V1_GoalPeriod] = [.day, .week, .month]
    /// .unspecified counts as weekly.
    var planNormalized: Noted_V1_GoalPeriod { self == .unspecified ? .week : self }
}

extension Noted_V1_Goal {
    /// "每周 3 次", "每天 30 分钟".
    var planRule: String { "\(period.every) \(Fmt.number(target)) \(isMinutes ? "分钟" : unitLabel)" }
    /// The running total's name ("课时"), or 累计.
    var planCounterName: String { counterUnit.isEmpty ? "累计" : counterUnit }
}

// MARK: - detail page pieces

/// The top of a detail page: tags, a large title and a gray line, on the page background.
struct PlanDetailHeader<Tags: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder var tags: Tags

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) { tags }
            Text(title).font(.largeTitle.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            if !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
    }
}

/// A small project chip that opens the project.
struct PlanProjectChip: View {
    @Environment(AppData.self) private var data
    @Environment(Router.self) private var router
    let projectID: String

    var body: some View {
        if let p = data.project(projectID) {
            Button { router.push(.project(p.id)) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder").font(.system(size: 11, weight: .semibold))
                    Text(p.title).font(.footnote.weight(.semibold)).lineLimit(1)
                }
                .padding(.horizontal, 9).frame(height: 24)
                .foregroundStyle(.primary)
                .background(.fillTrack, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("项目 \(p.title)")
        }
    }
}

/// A white tile with a gray caption and a big value (连续达成, 本月).
struct PlanStatTile<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote).foregroundStyle(.secondaryText)
            value
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// One day of the last-7-days strip.
struct PlanDayDot: Identifiable {
    let date: Date
    let on: Bool
    var id: Date { date }
}

/// 日 一 二 … 今: a check in a green dot for days with a check-in.
struct PlanSevenDayDots: View {
    let days: [PlanDayDot]
    var now: Date = .now

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days) { d in
                let today = d.date.isSameDay(as: now)
                VStack(spacing: 6) {
                    ZStack {
                        Circle().fill(d.on ? Color.success : Color.fillTrack)
                        if d.on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                    }
                    .frame(width: 22, height: 22)
                    .overlay {
                        if today { Circle().strokeBorder(.tint, lineWidth: 1.6).frame(width: 28, height: 28) }
                    }
                    .frame(width: 28, height: 28)
                    Text(today ? "今" : Fmt.weekdayShort(d.date)).font(.caption).foregroundStyle(.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Fmt.mdw(d.date)) \(d.on ? "已打卡" : "未打卡")")
            }
        }
    }

    /// The last 7 days ending today, from the progress's recent totals.
    static func days(from recent: [[Noted_V1_DayTotal]], now: Date = .now) -> [PlanDayDot] {
        var amounts: [String: Double] = [:]
        for list in recent { for d in list { amounts[d.date, default: 0] += d.amount } }
        return (0..<7).reversed().map { i in
            let day = now.startOfDay.adding(days: -i)
            return PlanDayDot(date: day, on: (amounts[Fmt.ymd(day)] ?? 0) > 0)
        }
    }
}

/// The big ring card: ring with "c/t" and the period, the main button, the 7-day strip.
struct PlanRingCard: View {
    let fraction: Double
    let done: Bool
    let value: String
    let total: String
    let caption: String
    let buttonTitle: String
    let buttonIcon: String
    let days: [PlanDayDot]
    let action: () -> Void
    @State private var bump = 0

    var body: some View {
        VStack(spacing: 0) {
            ProgressRing(value: fraction, lineWidth: 14, tint: done ? .success : nil, animateOnAppear: true) {
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(value).font(.system(size: 30, weight: .bold, design: .monospaced))
                            .contentTransition(.numericText())
                        Text("/\(total)").font(.system(size: 20, weight: .medium, design: .monospaced)).foregroundStyle(.secondaryText)
                    }
                    Text(caption).font(.footnote).foregroundStyle(.secondaryText)
                }
            }
            .frame(width: 168, height: 168)
            .padding(.top, 6)
            Button {
                bump += 1
                action()
            } label: {
                Label(buttonTitle, systemImage: buttonIcon)
            }
            .buttonStyle(.wide(done ? .success : .filled))
            .sensoryFeedback(.increase, trigger: bump)
            .padding(.top, 18)
            .accessibilityIdentifier("goal-checkin")
            PlanSevenDayDots(days: days).padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .animation(.snappy, value: value)
    }
}

/// A one-field number sheet (记一次体重): big centered field, a caption, 取消 / done.
struct PlanNumberSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var caption: String = ""
    var doneTitle = "保存"
    var initial: Double?
    var allowsZero = false
    let onSave: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List { Group {
                Section {
                    TextField("0", text: $text)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .focused($focused)
                        .accessibilityLabel(title)
                } footer: {
                    if !caption.isEmpty {
                        Text(caption).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                    }
                }
            }.classicRowInsets() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }.plainBar()
                ToolbarItem(placement: .confirmationAction) {
                    Button(doneTitle) {
                        guard let v = value else { return }
                        onSave(v)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(value == nil)
                    .accessibilityIdentifier("number-sheet-save")
                }.plainBar()
            }
        }
        .presentationDetents([.height(230)])
        .onAppear {
            if let initial, text.isEmpty { text = initial == initial.rounded() ? Fmt.number(initial) : String(format: "%g", initial) }
            focused = true
        }
    }

    private var value: Double? {
        guard let v = PlanFmt.parse(text), v.isFinite else { return nil }
        return allowsZero ? (v >= 0 ? v : nil) : (v > 0 ? v : nil)
    }
}

/// "+ 添加维度"-style centered accent row.
struct PlanAddRow: View {
    let title: String
    var systemImage = "plus"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
                .foregroundStyle(.tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}
