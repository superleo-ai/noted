import SwiftUI
import WidgetKit

struct NotedWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        let s = entry.snapshot
        Group {
            if !s.pro {
                LockedView(c: s.colors)
            } else {
                switch family {
                case .systemSmall: SmallSnapshotView(s: s, now: entry.date)
                case .systemMedium: MediumSnapshotView(s: s)
                #if os(iOS)
                case .accessoryRectangular: RectangularSnapshotView(s: s, now: entry.date)
                case .accessoryCircular: CircularSnapshotView(s: s)
                case .accessoryInline: InlineSnapshotView(s: s, now: entry.date)
                #else
                case .accessoryRectangular: RectangularSnapshotView(s: s, now: entry.date)
                case .accessoryCircular: CircularSnapshotView(s: s)
                case .accessoryInline: InlineSnapshotView(s: s, now: entry.date)
                case .accessoryCorner: InlineSnapshotView(s: s, now: entry.date)
                #endif
                default: SmallSnapshotView(s: s, now: entry.date)
                }
            }
        }
        .containerBackground(for: .widget) { Color(rgb: s.colors.bg) }
    }
}

struct NotedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NotedToday", provider: Provider()) { NotedWidgetView(entry: $0) }
            .configurationDisplayName("今天")
            .description("今天的日程、待办和目标。")
            #if os(iOS)
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
            #else
            .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline, .accessoryCorner])
            #endif
    }
}

struct NotedPlansView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        let s = entry.snapshot
        Group {
            if !s.pro {
                LockedView(c: s.colors)
            } else {
                switch family {
                case .systemMedium: PlanMediumView(s: s)
                case .accessoryRectangular: PlanRectangularView(s: s)
                case .accessoryCircular: PlanCircularView(s: s)
                default: PlanSmallView(s: s)
                }
            }
        }
        .containerBackground(for: .widget) { Color(rgb: s.colors.bg) }
    }
}

struct NotedPlansWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NotedPlans", provider: Provider()) { NotedPlansView(entry: $0) }
            .configurationDisplayName("目标计划")
            .description("减肥这样的大目标:结果和每个维度的进度。")
            #if os(iOS)
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
            #else
            .supportedFamilies([.accessoryRectangular, .accessoryCircular])
            #endif
    }
}

@main
struct NotedWidgetBundle: WidgetBundle {
    var body: some Widget {
        NotedWidget()
        NotedPlansWidget()
    }
}
