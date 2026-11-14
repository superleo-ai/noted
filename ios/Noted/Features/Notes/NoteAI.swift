import SwiftUI

/// What the assistant says about one saved version of a note: a one-paragraph 摘要 and the
/// tags it would add. Asked for once per note text and kept for the rest of the session.
struct NoteAssist: Equatable, Sendable {
    let key: Int
    let summary: String?
    let tags: [String]

    /// The version a result belongs to: the title and the text, not the tags or the pin.
    static func key(_ n: Noted_V1_Note) -> Int {
        var h = Hasher()
        h.combine(n.id)
        h.combine(n.title)
        h.combine(n.content)
        return h.finalize()
    }

    /// A few lines are needed before a summary says anything.
    static func worthAsking(_ n: Noted_V1_Note) -> Bool {
        let text = n.content.filter { !$0.isWhitespace && !"#*-[]>`_".contains($0) }
        return text.count >= 40
    }

    /// The suggestions the note does not have yet.
    func newTags(for note: Noted_V1_Note) -> [String] {
        let have = Set(note.tags.map { $0.lowercased() })
        var seen = Set<String>()
        return tags.compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#＃"))
            let k = t.lowercased()
            guard !t.isEmpty, !have.contains(k), seen.insert(k).inserted else { return nil }
            return t
        }
    }
}

@MainActor
private enum NoteAssistCache {
    static var entries: [String: NoteAssist] = [:]
    static var access: (value: Noted_V1_AIAccess, at: Date)?
}

extension AppData {
    /// 摘要 and 建议标签 for the note as saved on the server. nil when the assistant may not read
    /// the note's space or has nothing to say. Cached per note id and text.
    func noteAssist(_ note: Noted_V1_Note) async -> NoteAssist? {
        let key = NoteAssist.key(note)
        if let hit = NoteAssistCache.entries[note.id], hit.key == key { return hit }
        guard await AIConsent.shared.isGranted(session.api) else { return nil }
        guard await aiMayRead(note.space == .work ? .work : .life), !Task.isCancelled else { return nil }
        async let s = summarizeNote(note.id)
        async let t = suggestTags(note.id)
        let result = NoteAssist(key: key, summary: await s, tags: await t)
        guard !Task.isCancelled else { return nil }
        NoteAssistCache.entries[note.id] = result
        return result
    }

    /// Whether this account lets the assistant read a space (设置 → 智能). Read again after a minute.
    func aiMayRead(_ space: Noted_V1_Space) async -> Bool {
        let access: Noted_V1_AIAccess
        if let a = NoteAssistCache.access, Date.now.timeIntervalSince(a.at) < 60 {
            access = a.value
        } else {
            guard let api = session.api,
                  let a = try? await api.ai.getAIAccess(Noted_V1_GetAIAccessRequest()) else { return false }
            NoteAssistCache.access = (a, .now)
            access = a
        }
        return space == .work ? access.allowWork : access.allowLife
    }
}

/// 摘要 · 自动生成, then 建议标签 as dashed chips that add the tag when tapped.
struct NoteAssistCard: View {
    let summary: String?
    let tags: [String]
    let add: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("摘要").font(.footnote.weight(.semibold)).foregroundStyle(.secondaryText)
                        Spacer()
                        Text("自动生成").font(.caption2).foregroundStyle(.tertiaryText)
                    }
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("note-summary")
            }
            if !tags.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("建议标签").font(.footnote.weight(.semibold)).foregroundStyle(.secondaryText)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(tags, id: \.self) { t in
                                Button { add(t) } label: {
                                    Text("+ #\(t)")
                                        .font(.subheadline)
                                        .lineLimit(1)
                                        .padding(.horizontal, 10)
                                        .frame(height: 28)
                                        .foregroundStyle(.tint)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 8)
                                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                                .foregroundStyle(.tint.opacity(0.6))
                                        }
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("添加标签 \(t)")
                                .accessibilityIdentifier("note-suggested-tag-\(t)")
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fillQuiet, in: RoundedRectangle(cornerRadius: 12))
    }
}
