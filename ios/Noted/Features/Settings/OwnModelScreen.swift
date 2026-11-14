import SwiftUI
import GRPCCore

/// What 自带模型 Key's form will send, and whether it can. The server checks again (and makes one
/// test call); this only keeps 保存 off until the fields could work.
struct OwnModelForm: Equatable {
    var baseURL = ""
    var model = ""
    var key = ""
    /// A key is already stored: leaving the field empty keeps it.
    var hasKey = false

    var trimmedBaseURL: String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
    var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The endpoint's host when the address is a usable https URL.
    var host: String? { Self.host(of: trimmedBaseURL) }

    static func host(of url: String) -> String? {
        guard let c = URLComponents(string: url), c.scheme?.lowercased() == "https",
              let h = c.host, !h.isEmpty, c.user == nil, c.query == nil, c.fragment == nil else { return nil }
        return h
    }

    /// Why 保存 is off, for the footer; nil when it can be saved.
    var problem: String? {
        if trimmedBaseURL.isEmpty { return "填写接口地址" }
        if host == nil { return "接口地址要是 https:// 开头的完整地址" }
        if trimmedModel.isEmpty { return "填写模型名" }
        if trimmedKey.isEmpty && !hasKey { return "填写 API Key" }
        if trimmedKey.contains(where: \.isWhitespace) { return "API Key 里不能有空格" }
        return nil
    }

    var canSave: Bool { problem == nil }

    init(baseURL: String = "", model: String = "", key: String = "", hasKey: Bool = false) {
        self.baseURL = baseURL; self.model = model; self.key = key; self.hasKey = hasKey
    }

    /// The form for what the server has (never the key itself: it is not sent back).
    init(_ s: Noted_V1_ModelSettings) {
        self.init(baseURL: s.baseURL, model: s.model, hasKey: s.keySet)
    }
}

/// The row in 设置 → 智能: locked for an account without Pro (opens the Pro screen).
struct OwnModelRow: View {
    @Environment(Session.self) private var session
    @State private var consent = AIConsent.shared

    var body: some View {
        if session.pro.isPro {
            NavigationLink(value: Route.ownModel) {
                FieldLabel("自带模型 Key", icon: "key.fill", tile: .graphite, value: consent.ownHost ?? "未设置")
            }
            .accessibilityIdentifier("settings-own-model")
            .task { await consent.refreshOwnModel(session.api) }
        } else {
            ProLockedRow(title: "自带模型 Key", detail: "用你自己的模型服务，不受每天的次数限制", id: "settings-own-model-locked")
        }
    }
}

/// 自带模型 Key: the endpoint, model and key a Pro user's AI requests go to instead of the server's.
struct OwnModelScreen: View {
    @Environment(Session.self) private var session
    @Environment(Toaster.self) private var toaster
    @State private var consent = AIConsent.shared
    @State private var saved: Noted_V1_ModelSettings?
    @State private var form = OwnModelForm()
    @State private var loaded = false
    @State private var saving = false
    @State private var confirmClear = false

    var body: some View {
        List { Group {
            Section {
                TextField("https://api.openai.com/v1", text: $form.baseURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("接口地址")
                    .accessibilityIdentifier("own-model-url")
                TextField("模型，例如 gpt-4o-mini", text: $form.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("模型")
                    .accessibilityIdentifier("own-model-name")
                SecureField(form.hasKey ? "API Key（留空不改）" : "API Key", text: $form.key)
                    .textContentType(.password)
                    .accessibilityLabel("API Key")
                    .accessibilityIdentifier("own-model-key")
            } header: {
                SectionLabel("接口地址 · 模型 · API Key")
            } footer: {
                Text("用你自己的 key：费用由你的服务商结算，不受每天 60 次的限制。")
                    .accessibilityIdentifier("own-model-explainer")
            }

            if let saved, saved.keySet {
                Section {
                    FieldLabel("已保存的 Key", icon: "key.fill", tile: .graphite, value: saved.keyHint)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("own-model-hint")
                    FieldLabel("状态", icon: saved.active ? "checkmark.seal.fill" : "pause.circle", tile: saved.active ? .green : .gray,
                               value: saved.active ? "使用中" : "未启用")
                        .accessibilityElement(children: .combine)
                } footer: {
                    Text(saved.active
                         ? "AI 请求的内容会发送到 \(saved.host)。"
                         : "需要 Noted Pro 才会使用这个 key，在那之前仍用服务器的模型。")
                }
            }

            Section {
                Button {
                    save()
                } label: {
                    HStack {
                        Text(saving ? "正在试用这个 key…" : "保存")
                        if saving { Spacer(); ProgressView() }
                    }
                }
                .disabled(!form.canSave || saving)
                .accessibilityIdentifier("own-model-save")
                if saved?.keySet == true {
                    Button("清除", role: .destructive) { confirmClear = true }
                        .disabled(saving)
                        .accessibilityIdentifier("own-model-clear")
                }
            } footer: {
                if loaded, let p = form.problem { Text(p) } else { Text("保存前会用这个 key 试一次调用。清除后回到服务器的模型。") }
            }
        }.classicRowInsets() }
        .navigationTitle("自带模型 Key")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog("清除自带模型 Key？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) { clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("之后 AI 请求回到服务器的模型，并受每天的次数限制。")
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            let s = try await api.ai.getModelSettings(Noted_V1_GetModelSettingsRequest())
            apply(s)
        } catch {
            toaster.error(error)
        }
        loaded = true
    }

    private func apply(_ s: Noted_V1_ModelSettings) {
        saved = s
        form = OwnModelForm(s)
        consent.setOwnModel(s, api: session.api)
    }

    private func save() {
        guard let api = session.api, form.canSave else { return }
        var req = Noted_V1_SetModelSettingsRequest()
        req.baseURL = form.trimmedBaseURL
        req.model = form.trimmedModel
        req.apiKey = form.trimmedKey
        saving = true
        Task {
            defer { saving = false }
            do {
                apply(try await api.ai.setModelSettings(req))
                toaster.show("已保存", systemImage: "key.fill")
            } catch {
                toaster.error(Self.message(error))
            }
        }
    }

    private func clear() {
        guard let api = session.api else { return }
        Task {
            do {
                apply(try await api.ai.clearModelSettings(Noted_V1_ClearModelSettingsRequest()))
                toaster.show("已清除", systemImage: "key")
            } catch {
                toaster.error(error)
            }
        }
    }

    /// The server words these refusals for the person (which part of the key or address is wrong).
    static func message(_ error: Error) -> String {
        if let e = error as? RPCError, e.code == .invalidArgument || e.code == .failedPrecondition,
           e.message.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
            return e.message
        }
        return describe(error)
    }
}
