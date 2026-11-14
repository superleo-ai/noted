import SwiftUI

/// An AI entry point for an account that is not Noted Pro: what it would do, a lock, and a tap
/// that opens the Pro screen.
struct ProLockedRow: View {
    @Environment(Router.self) private var router
    var title = "AI 是 Noted Pro 的功能"
    var detail: String? = "一次买断，解锁提问、拆成项目、简报和笔记摘要"
    var id = "ai-locked"

    var body: some View {
        Button { router.push(.pro) } label: {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill").foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondaryText)
                    }
                }
                Spacer(minLength: 8)
                Text("Pro").font(.footnote.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(TileColor.rust.color, in: Capsule())
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，Noted Pro")
        .accessibilityHint("打开 Noted Pro")
        .accessibilityIdentifier(id)
    }
}
