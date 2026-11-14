import StoreKit
import SwiftUI
import WidgetKit

/// 删除账号 (pushed from 设置 → 账号): says what goes and that it cannot be undone, asks for 删除
/// to be typed, then deletes the account on the server and signs this device out.
struct DeleteAccountScreen: View {
    @Environment(AppData.self) private var data
    @Environment(Session.self) private var session
    @Environment(Toaster.self) private var toaster

    @State private var typed = ""
    @State private var deleting = false
    @FocusState private var focused: Bool

    private static let word = "删除"
    private var ready: Bool { typed.trimmingCharacters(in: .whitespaces) == Self.word && !deleting }

    var body: some View {
        List { Group {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.danger)
                    Text("删除后无法恢复")
                        .font(.title3.weight(.semibold))
                    Text("账号\(accountName)和它在服务器上的全部内容会被立即永久删除，没有回收站，也没有人能帮你找回。")
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }

            Section {
                item("笔记", icon: "note.text", tile: .orange)
                item("待办、日程、闹钟和提醒", icon: "calendar", tile: .red)
                item("项目、目标、指南针和进度记录", icon: "target", tile: .rust)
                item("时间记录", icon: "timer", tile: .teal)
                item("AI 的建议、改动记录和搜索索引", icon: "sparkles", tile: .blue)
                item("主题、页面模块等设置", icon: "paintpalette", tile: .gray)
                item("邮箱和密码、Apple ID 绑定", icon: "person.crop.circle", tile: .graphite)
                item("所有令牌：接入的 AI 助手和其他设备会立即断开", icon: "key.fill", tile: .green)
            } header: {
                SectionLabel("会被删除")
            }

            Section {
                NavigationLink(value: Route.export) {
                    FieldLabel("先导出数据", icon: "square.and.arrow.up", tile: .green)
                }
                .accessibilityIdentifier("delete-account-export")
            } footer: {
                Text("想留一份的话，先导出：笔记、日历和全部数据会打包成一个文件。")
            }

            if session.pro.isPro {
                Section {
                } footer: {
                    Text("Noted Pro 是一次买断，购买记录留在你的 Apple ID 里。删除账号后再注册，用“恢复购买”就能找回 Pro。")
                }
            }

            Section {
                TextField("输入“\(Self.word)”确认", text: $typed)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.done)
                    .disabled(deleting)
                    .accessibilityIdentifier("delete-account-confirm")
            } header: {
                SectionLabel("确认")
            } footer: {
                Text("在上面输入“\(Self.word)”两个字，再点下面的按钮。")
            }

            Section {
                Button(action: delete) {
                    if deleting {
                        ProgressView().tint(.white)
                    } else {
                        Text("永久删除账号")
                    }
                }
                .buttonStyle(WideButtonStyle(kind: .danger))
                .disabled(!ready)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("delete-account-submit")
            }
        }.classicRowInsets() }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("删除账号")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(deleting)
    }

    private func item(_ title: String, icon: String, tile: TileColor) -> some View {
        FieldLabel(title, icon: icon, tile: tile)
    }

    private var accountName: String {
        guard let n = data.account?.userName, !n.isEmpty else { return "" }
        return "「\(n)」"
    }

    private func delete() {
        guard ready else { return }
        focused = false
        deleting = true
        Task {
            let ok = await data.deleteAccount()
            deleting = false
            if ok { toaster.show("账号已删除", systemImage: "trash") }
        }
    }
}

extension AppData {
    /// Deletes the account on the server (everything it owns, every token), then forgets it here:
    /// pending reminders, the widgets' and the watch's copy, the token and everything loaded.
    /// On failure the error is toasted and nothing local changes.
    func deleteAccount() async -> Bool {
        var r = Noted_V1_DeleteAccountRequest(); r.confirm = "DELETE"
        guard await perform({ _ = try await $0.account.deleteAccount(r) }) != nil else { return false }
        await session.reminders.schedule([])
        let empty = Snapshot()
        SnapshotStore.save(empty)
        WidgetCenter.shared.reloadAllTimelines()
        WatchBridge.shared.push(empty)
        signOut()
        return true
    }
}
