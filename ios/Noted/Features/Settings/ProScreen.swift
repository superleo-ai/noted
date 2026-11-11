import StoreKit
import SwiftUI

/// Noted Pro: what it adds, the two subscriptions, buy and restore. Shows 已开通 when the
/// App Store or the server (`noted user pro`) has granted it.
struct ProScreen: View {
    @Environment(Session.self) private var session
    @Environment(Toaster.self) private var toaster
    @State private var yearly = true
    @State private var loaded = false
    @State private var manage = false

    /// 功能 · 免费 · Pro. The first rows are not gated anywhere in the app, so they are marked free.
    private static let features: [(String, Bool)] = [
        ("内置主题（日光、纸本、苔绿）", true),
        ("多设备同步", true),
        ("接入 AI 助手（MCP）", true),
        ("无限项目与目标", true),
        ("导出全部数据", true),
        ("自定义主题与配色", false),
        ("自定义概览页模块与顺序", false),
        ("桌面与锁屏小组件", false),
    ]

    var body: some View {
        let pro = session.pro
        List {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(TileColor.rust.color, in: RoundedRectangle(cornerRadius: 17))
                        .padding(.bottom, 8)
                        .accessibilityHidden(true)
                    Text("Noted Pro").font(.largeTitle.weight(.bold))
                    Text(pro.isPro ? "已开通，感谢支持" : "一次订阅，所有设备")
                        .foregroundStyle(.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
            }
            Section {
                HStack(spacing: 0) {
                    Text("功能")
                    Spacer(minLength: 8)
                    Text("免费").frame(width: 48)
                    Text("PRO").frame(width: 48)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondaryText)
                .accessibilityHidden(true)
                ForEach(Self.features, id: \.0) { f in
                    HStack(spacing: 0) {
                        Text(f.0)
                        Spacer(minLength: 8)
                        mark(f.1).frame(width: 48)
                        mark(true).frame(width: 48)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(f.1 ? "\(f.0)，免费" : "\(f.0)，Pro")
                }
            } footer: {
                Text("订阅由 App Store 管理，可随时取消。取消后已有的主题和布局继续生效，只是不能再修改。")
            }
            if pro.isPro {
                Section {
                    LabeledContent("状态") {
                        Text(pro.grantedByServer ? "已开通 · 服务器授予" : "已开通").foregroundStyle(.success)
                    }
                    if !pro.grantedByServer {
                        Button("管理订阅") { manage = true }
                            .accessibilityIdentifier("pro-manage")
                    }
                }
            } else {
                Section {
                    plans(pro)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    if let m = pro.message {
                        Text(m).foregroundStyle(.danger).frame(maxWidth: .infinity).padding(.top, 8)
                    }
                }
                Section {
                    VStack(spacing: 12) {
                        Button { buy(pro) } label: {
                            if pro.busy { ProgressView().tint(.white) } else { Text("订阅") }
                        }
                        .buttonStyle(.wide)
                        .disabled(pro.busy || chosen(pro) == nil)
                        .accessibilityIdentifier("subscribe")
                        Button("恢复购买") { Task { await restore(pro) } }
                            .font(.subheadline)
                            .disabled(pro.busy)
                            .accessibilityIdentifier("restore")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
        }
        .navigationTitle("Noted Pro")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            pro.message = nil
            await pro.load()
            loaded = true
        }
        .manageSubscriptionsSheet(isPresented: $manage)
    }

    @ViewBuilder
    private func plans(_ pro: Pro) -> some View {
        if pro.products.isEmpty {
            Group {
                if loaded { Text("暂时读不到价格").foregroundStyle(.secondaryText) } else { ProgressView() }
            }
            .frame(maxWidth: .infinity, minHeight: 90)
        } else {
            HStack(spacing: 10) {
                if let m = pro.monthly {
                    PlanCard(title: "月付", price: m.displayPrice, period: "每月", isOn: !yearly) { yearly = false }
                }
                if let y = pro.yearly {
                    PlanCard(title: pro.yearlySaving.map { "年付 · 省 \($0)%" } ?? "年付",
                             price: y.displayPrice, period: "每年", isOn: yearly) { yearly = true }
                }
            }
        }
    }

    @ViewBuilder
    private func mark(_ on: Bool) -> some View {
        if on {
            Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(.success)
        } else {
            Text("—").foregroundStyle(.tertiaryText)
        }
    }

    private func chosen(_ pro: Pro) -> Product? {
        yearly ? (pro.yearly ?? pro.monthly) : (pro.monthly ?? pro.yearly)
    }

    private func buy(_ pro: Pro) {
        guard let p = chosen(pro) else { return }
        Task {
            await pro.buy(p)
            if pro.isPro { toaster.show("已开通 Pro", systemImage: "star.fill") }
        }
    }

    private func restore(_ pro: Pro) async {
        await pro.restore()
        if pro.isPro { toaster.show("已恢复购买", systemImage: "star.fill") }
    }
}

/// One subscription choice: a white card, outlined in the accent when chosen.
private struct PlanCard: View {
    let title: String
    let price: String
    let period: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.footnote).foregroundStyle(.secondaryText)
                Text(price).font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(.primary)
                Text(period).font(.footnote).foregroundStyle(.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.hairline), lineWidth: isOn ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(price) \(period)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
