import StoreKit
import SwiftUI

/// Noted Pro: what it adds, one price bought once, buy and restore. Shows 已开通 when the
/// App Store or the server (`noted user pro`) has granted it.
struct ProScreen: View {
    @Environment(Session.self) private var session
    @Environment(Toaster.self) private var toaster
    @State private var loaded = false

    /// 功能 · 免费 · Pro. The free rows are not gated anywhere in the app.
    static let features: [(String, Bool)] = [
        ("内置主题（日光、纸本、苔绿）", true),
        ("多设备同步", true),
        ("接入 AI 助手（MCP）", true),
        ("无限项目与目标", true),
        ("导出全部数据", true),
        ("AI 提问与一句话拆成项目", false),
        ("AI 今日简报、笔记摘要与标签、提取待办", false),
        ("自定义主题与配色", false),
        ("自定义概览页模块与顺序", false),
        ("桌面与锁屏小组件", false),
    ]

    var body: some View {
        let pro = session.pro
        List { Group {
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
                    Text(pro.isPro ? "已开通，感谢支持" : "一次买断，永久使用")
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
                Text("一次购买，同一 Apple ID 的所有设备都能用，没有月费或年费。AI 功能每天有使用次数上限。")
            }
            if pro.isPro {
                Section {
                    LabeledContent("状态") {
                        Text(pro.grantedByServer && !pro.owned ? "已开通 · 服务器授予" : "已开通 · 永久").foregroundStyle(.success)
                    }
                    .accessibilityIdentifier("pro-status")
                }
            } else {
                Section {
                    price(pro)
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
                            if pro.busy {
                                ProgressView().tint(.white)
                            } else {
                                Text(pro.product.map { "\($0.displayPrice) 买断" } ?? "购买")
                            }
                        }
                        .buttonStyle(.wide)
                        .disabled(pro.busy || pro.product == nil)
                        .accessibilityIdentifier("pro-buy")
                        Button("恢复购买") { Task { await restore(pro) } }
                            .font(.subheadline)
                            .disabled(pro.busy)
                            .accessibilityIdentifier("restore")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
        }.classicRowInsets() }
        .navigationTitle("Noted Pro")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            pro.message = nil
            await pro.load()
            loaded = true
        }
    }

    /// The one price: a white card in the existing plan style.
    @ViewBuilder
    private func price(_ pro: Pro) -> some View {
        if let p = pro.product {
            VStack(alignment: .leading, spacing: 4) {
                Text("永久版").font(.footnote).foregroundStyle(.secondaryText)
                Text(p.displayPrice).font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(.primary)
                Text("一次买断，永久使用").font(.footnote).foregroundStyle(.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.tint, lineWidth: 2) }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pro-price")
        } else {
            Group {
                if loaded { Text("暂时读不到价格").foregroundStyle(.secondaryText) } else { ProgressView() }
            }
            .frame(maxWidth: .infinity, minHeight: 90)
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

    private func buy(_ pro: Pro) {
        Task {
            await pro.buy()
            if pro.isPro { toaster.show("已开通 Pro", systemImage: "star.fill") }
        }
    }

    private func restore(_ pro: Pro) async {
        await pro.restore()
        if pro.isPro { toaster.show("已恢复购买", systemImage: "star.fill") }
    }
}
