import SwiftUI
import GRPCCore

/// Whether this account has agreed to send item text to the model provider (App Store 5.1.2(i)).
/// Kept in the "ai.consent" preference so it follows the account to every device.
///
/// Calls the person starts (提问, 拆成项目) go through `request`, which shows the consent sheet
/// until they agree; calls that run by themselves (今日简报, 笔记摘要与标签) go through
/// `isGranted`, which never asks and is false until they agree.
@MainActor @Observable
final class AIConsent {
    static let shared = AIConsent()

    /// Who the server sends AI requests to. The policy page names it in internal/portal/legal.go;
    /// change both together and bump `version`.
    static let providerName = "OpenAI（GPT）"
    /// Bump when the provider or what is sent changes: an agreement to an older version no longer counts.
    static let version = 1
    static let key = "ai.consent"

    struct Record: Codable, Equatable, Sendable {
        var granted: Bool
        var version: Int
        var at: Date
    }

    private(set) var record: Record?
    /// The connection `record` was read on; another one (a new sign-in) reads it again.
    private var loadedFor: ObjectIdentifier?
    /// The consent sheet is up (AppShell's `aiConsentPrompt`).
    var isAsking = false
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    var granted: Bool { record.map { $0.granted && $0.version >= Self.version } ?? false }

    /// The host of the Pro user's own model (自带模型 Key) while it is in use: AI requests go there
    /// instead of `providerName`. Nil: the server's provider.
    private(set) var ownHost: String?
    private var ownLoadedFor: ObjectIdentifier?

    /// Who receives the content: the user's own endpoint, or the server's provider.
    var provider: String { ownHost ?? Self.providerName }

    /// Reads 自带模型 Key once per connection. Offline or an older server: the server's provider.
    func refreshOwnModel(_ api: API?) async {
        guard let api else { ownHost = nil; ownLoadedFor = nil; return }
        let id = ObjectIdentifier(api)
        if ownLoadedFor == id { return }
        guard let s = try? await api.ai.getModelSettings(Noted_V1_GetModelSettingsRequest()) else { return }
        setOwnModel(s, api: api)
    }

    /// What 自带模型 Key's screen read or saved.
    func setOwnModel(_ s: Noted_V1_ModelSettings, api: API?) {
        ownHost = Self.ownHost(s)
        ownLoadedFor = api.map(ObjectIdentifier.init)
    }

    nonisolated static func ownHost(_ s: Noted_V1_ModelSettings) -> String? {
        s.keySet && s.active && !s.host.isEmpty ? s.host : nil
    }

    /// For automatic calls: true only when this account has agreed. Never shows anything.
    func isGranted(_ api: API?) async -> Bool {
        await refresh(api)
    }

    /// For calls the person started: true at once when agreed, otherwise the consent sheet and their answer.
    func request(_ api: API?) async -> Bool {
        if await refresh(api) { return true }
        guard api != nil else { return false }
        return await withCheckedContinuation { c in
            waiting.append(c)
            isAsking = true
        }
    }

    /// The sheet's answer. A swipe down counts as 不用 AI.
    func answer(_ yes: Bool, api: API?) {
        isAsking = false
        if yes { set(true, api: api) }
        let w = waiting
        waiting = []
        for c in w { c.resume(returning: yes) }
    }

    /// Agree or withdraw (设置 → 智能 → AI 数据使用). Withdrawn: AI entry points ask again.
    func set(_ granted: Bool, api: API?) {
        let r = Record(granted: granted, version: Self.version, at: .now)
        record = r
        guard let api else { return }
        loadedFor = ObjectIdentifier(api)
        guard let raw = try? Self.encoder.encode(r) else { return }
        Task {
            var req = Noted_V1_SetPreferenceRequest()
            req.key = Self.key; req.value = String(decoding: raw, as: UTF8.self)
            _ = try? await api.prefs.setPreference(req)
        }
    }

    /// Reads the preference once per connection. Offline: not agreed for now, read again next time.
    @discardableResult
    func refresh(_ api: API?) async -> Bool {
        guard let api else { record = nil; loadedFor = nil; return false }
        #if DEBUG
        if ProcessInfo.processInfo.environment["NOTED_AI_CONSENT"] == "1" {
            record = Record(granted: true, version: Self.version, at: .now)
            await refreshOwnModel(api)
            return true
        }
        #endif
        await refreshOwnModel(api)
        let id = ObjectIdentifier(api)
        if loadedFor == id { return granted }
        var req = Noted_V1_GetPreferenceRequest(); req.key = Self.key
        do {
            let p = try await api.prefs.getPreference(req)
            record = try? Self.decoder.decode(Record.self, from: Data(p.value.utf8))
            loadedFor = id
        } catch let e as RPCError where e.code == .notFound {
            record = nil
            loadedFor = id
        } catch {
            record = nil
        }
        return granted
    }

    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

// MARK: - the sheet

extension View {
    /// The consent sheet, shown when an AI call the person started needs an answer. Attached once,
    /// at the root: every AI entry point is a pushed page, so this is the only sheet up.
    func aiConsentPrompt() -> some View { modifier(AIConsentPrompt()) }
}

private struct AIConsentPrompt: ViewModifier {
    @Environment(Session.self) private var session
    @State private var consent = AIConsent.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { consent.isAsking }, set: { up in
            if !up, consent.isAsking { consent.answer(false, api: session.api) }
        })) {
            AIConsentSheet { yes in consent.answer(yes, api: session.api) }
        }
    }
}

/// 使用 AI 前: what is sent, to whom, what we do and don't do with it; 同意并继续 / 不用 AI.
struct AIConsentSheet: View {
    let answer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.tint, in: RoundedRectangle(cornerRadius: 13))
                        Text("使用 AI 功能前").font(.title2.weight(.bold)).padding(.top, 6)
                        Text("AI 功能需要把你的部分内容交给第三方模型服务处理。请先看一下会发生什么。")
                            .font(.subheadline).foregroundStyle(.secondaryText)
                    }
                    AIConsentExplainer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 12)
            }
            VStack(spacing: 10) {
                Button("同意并继续") { answer(true) }
                    .buttonStyle(.wide)
                    .accessibilityIdentifier("ai-consent-agree")
                Button("不用 AI") { answer(false) }
                    .buttonStyle(.wide(.gray))
                    .accessibilityIdentifier("ai-consent-decline")
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .background(Color.groupedBackground.ignoresSafeArea())
        .presentationDragIndicator(.visible)
    }
}

/// The points the person agrees to, shared by the sheet and 设置 → AI 数据使用.
struct AIConsentExplainer: View {
    @State private var consent = AIConsent.shared
    private var provider: String { consent.provider }
    private var own: Bool { consent.ownHost != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            point("doc.text", "发送什么",
                  "完成这次请求所需的条目文字，比如相关的笔记、待办和日程，只限你在“设置 → 智能”里允许 AI 读取的空间（工作 / 个人）。")
            point("arrow.up.forward.circle", "发给谁",
                  own ? "经由我们的服务器 \(Session.hostedHost) 发送到你在“自带模型 Key”里填的 \(provider) 处理。"
                      : "经由我们的服务器 \(Session.hostedHost) 发送给 \(provider) 处理。")
            point("lock.shield", "只为这次请求",
                  "我们只把内容发去完成你发起的这次请求，不拿它做广告、不卖给别人。\(provider) 怎样处理收到的数据，以它自己的条款为准。")
            point("wand.and.stars", "哪些功能会用到",
                  "提问、记一笔、拆成项目、今日简报、笔记摘要与标签。同意后，你开启的今日简报和笔记摘要会自动生成。")
            point("hand.raised", "随时撤回",
                  "可以在“设置 → 智能 → AI 数据使用”撤回。不同意也能正常使用 Noted 的其他功能。")
            Link("阅读隐私政策", destination: PolicyLinks.privacy)
                .font(.subheadline.weight(.medium))
                .accessibilityIdentifier("ai-consent-privacy")
        }
    }

    private func point(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.subheadline).foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 设置 → 智能 → AI 数据使用

/// The row in 设置 → 智能.
struct AIConsentRow: View {
    @State private var consent = AIConsent.shared

    var body: some View {
        NavigationLink(value: Route.aiConsent) {
            FieldLabel("AI 数据使用", icon: "hand.raised.fill", tile: .graphite, value: consent.granted ? "已同意" : "未同意")
        }
        .accessibilityIdentifier("settings-ai-consent")
    }
}

/// What was agreed to, with 同意 or 撤回同意.
struct AIConsentScreen: View {
    @Environment(Session.self) private var session
    @Environment(Toaster.self) private var toaster
    @State private var consent = AIConsent.shared
    @State private var confirmWithdraw = false

    var body: some View {
        List { Group {
            Section {
                FieldLabel("状态", icon: consent.granted ? "checkmark.seal.fill" : "xmark.seal", tile: consent.granted ? .green : .gray,
                           value: statusText)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("ai-consent-status")
            }
            Section {
                AIConsentExplainer().padding(.vertical, 8)
            }
            Section {
                if consent.granted {
                    Button("撤回同意", role: .destructive) { confirmWithdraw = true }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("ai-consent-withdraw")
                } else {
                    Button("同意并开启 AI 功能") {
                        consent.set(true, api: session.api)
                        toaster.show("已同意", systemImage: "checkmark.seal")
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("ai-consent-agree")
                }
            } footer: {
                Text(consent.granted ? "撤回后，用到 AI 的功能会先再问你一次；今日简报和笔记摘要不再生成。" : "不同意也能正常使用 Noted 的其他功能。")
            }
        }.classicRowInsets() }
        .navigationTitle("AI 数据使用")
        .navigationBarTitleDisplayMode(.inline)
        .task { await consent.refresh(session.api) }
        .confirmationDialog("撤回同意？", isPresented: $confirmWithdraw, titleVisibility: .visible) {
            Button("撤回同意", role: .destructive) {
                consent.set(false, api: session.api)
                toaster.show("已撤回", systemImage: "hand.raised")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("之后不会再把内容发给 \(consent.provider)，除非你再次同意。")
        }
    }

    private var statusText: String {
        guard let r = consent.record, consent.granted else { return "未同意" }
        return "已同意 · \(Fmt.ymd(r.at))"
    }
}
