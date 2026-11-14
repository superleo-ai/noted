import Foundation
import SwiftProtobuf

// The assistant's calls: 提问 / 记一笔, 一句话拆成项目, 简报, 建议, 排进空档, 每周回顾, 改动记录,
// 笔记摘要 and 建议标签. Proposals are accepted or dismissed with acceptProposal / dismissProposal
// (AppData+Notes). Nothing here writes data except undoChange and suggestTags(apply: true).

extension AppData {
    /// AI is Noted Pro (bought, or granted by the server). Without it nothing reaches the model; a
    /// call the person started says why, automatic ones (简报, 摘要) stay quiet.
    func aiIsPro(announce: Bool = false) -> Bool {
        if !session.aiLocked { return true }
        if announce { toaster.show("AI 是 Noted Pro 的功能", systemImage: "lock.fill") }
        return false
    }

    /// One turn with the assistant. The reply may carry a proposal (nothing done yet) and the rows
    /// it read (references). Pass the returned session id back to continue the conversation.
    func ask(_ message: String, sessionID: String = "", space: Noted_V1_Space) async -> Noted_V1_AskResponse? {
        var r = Noted_V1_AskRequest()
        r.message = message; r.sessionID = sessionID; r.space = space
        guard aiIsPro(announce: true) else { return nil }
        guard await AIConsent.shared.request(session.api) else { return nil }
        return await perform { try await $0.ai.ask(r) }
    }

    /// "下个月去菲律宾，要办签证、订机票和酒店" → a pending project-with-tasks proposal.
    func planFromText(_ text: String, space: Noted_V1_Space) async -> Noted_V1_Proposal? {
        var r = Noted_V1_PlanFromTextRequest()
        r.text = text; r.space = space
        guard aiIsPro(announce: true) else { return nil }
        guard await AIConsent.shared.request(session.api) else { return nil }
        return await perform { try await $0.ai.planFromText(r) }
    }

    /// Today's one-paragraph briefing. nil when AI is off or the feature is turned off (no toast:
    /// the overview just hides the line).
    func dailyBriefing(space: Noted_V1_Space, day: Date = .now) async -> String? {
        guard aiIsPro() else { return nil }
        guard let api = session.api, await AIConsent.shared.isGranted(api) else { return nil }
        var r = Noted_V1_DailyBriefingRequest()
        r.day = Google_Protobuf_Timestamp(date: day); r.timeZone = TimeZone.current.identifier; r.space = space
        let s = try? await api.ai.dailyBriefing(r).briefing
        return (s?.isEmpty ?? true) ? nil : s
    }

    /// Pending suggestions (recomputed by the server before listing). Silent on failure.
    func listSuggestions(space: Noted_V1_Space) async -> [Noted_V1_Proposal] {
        guard let api = session.api else { return [] }
        var r = Noted_V1_ListProposalsRequest(); r.space = space
        return (try? await api.suggest.listProposals(r).proposals) ?? []
    }

    /// Free stretches for these tasks over the next `days` days, as a pending proposal.
    func proposeSchedule(taskIDs: [String], minutes: Int32 = 60, days: Int32 = 5) async -> Noted_V1_Proposal? {
        var r = Noted_V1_ProposeScheduleRequest()
        r.taskIds = taskIDs; r.durationMinutes = minutes; r.days = days; r.timeZone = TimeZone.current.identifier
        return await perform { try await $0.suggest.proposeSchedule(r) }
    }

    /// The review of the week containing `weekOf`.
    func weeklyReview(weekOf: Date = .now, space: Noted_V1_Space) async -> Noted_V1_WeeklyReview? {
        var r = Noted_V1_GetWeeklyReviewRequest()
        r.weekOf = Google_Protobuf_Timestamp(date: weekOf); r.space = space; r.timeZone = TimeZone.current.identifier
        return await perform { try await $0.suggest.getWeeklyReview(r) }
    }

    /// What accepted proposals wrote, newest first.
    func listChanges(limit: Int32 = 100) async -> [Noted_V1_Change]? {
        var r = Noted_V1_ListChangesRequest(); r.limit = limit
        return await perform { try await $0.suggest.listChanges(r).changes }
    }

    /// Reverts everything one change wrote, then reloads.
    func undoChange(_ id: String) async -> Noted_V1_Change? {
        var r = Noted_V1_UndoChangeRequest(); r.id = id
        guard let c = await perform({ try await $0.suggest.undoChange(r) }) else { return nil }
        await refreshTasks()
        await refreshProjects()
        await refreshNotes()
        await reloadEvents()
        didWrite()
        return c
    }

    /// A one-paragraph summary of a note. nil when unavailable (silent).
    func summarizeNote(_ noteID: String) async -> String? {
        guard aiIsPro() else { return nil }
        guard let api = session.api, await AIConsent.shared.isGranted(api) else { return nil }
        var r = Noted_V1_SummarizeNoteRequest(); r.noteID = noteID
        let s = try? await api.ai.summarizeNote(r).summary
        return (s?.isEmpty ?? true) ? nil : s
    }

    /// Tags the assistant would add to a note. `apply` also merges them into the note.
    func suggestTags(_ noteID: String, apply: Bool = false) async -> [String] {
        guard aiIsPro() else { return [] }
        guard let api = session.api, await AIConsent.shared.isGranted(api) else { return [] }
        var r = Noted_V1_SuggestTagsRequest(); r.noteID = noteID; r.apply = apply
        return (try? await api.ai.suggestTags(r).tags) ?? []
    }
}
