import SwiftUI

/// The hosted service's policy pages (internal/portal/legal).
@MainActor
enum PolicyLinks {
    static let base = "https://\(Session.hostedHost)"
    static let privacy = URL(string: "\(base)/privacy")!
    static let terms = URL(string: "\(base)/terms")!
    static let support = URL(string: "\(base)/support")!
}

/// 设置 → 关于: 隐私政策, 用户协议, 支持, opened in Safari.
struct AboutSection: View {
    var body: some View {
        Section {
            row("隐私政策", icon: "hand.raised.fill", tile: .blue, PolicyLinks.privacy, id: "settings-privacy")
            row("用户协议", icon: "doc.text.fill", tile: .graphite, PolicyLinks.terms, id: "settings-terms")
            row("支持", icon: "questionmark.circle.fill", tile: .green, PolicyLinks.support, id: "settings-support")
        } header: { SectionLabel("关于") }
    }

    private func row(_ title: String, icon: String, tile: TileColor, _ url: URL, id: String) -> some View {
        Link(destination: url) {
            HStack {
                FieldLabel(title, icon: icon, tile: tile)
                Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiaryText)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier(id)
    }
}

/// "注册即表示同意《用户协议》和《隐私政策》", both titles linked.
struct LegalAgreementLine: View {
    var lead = "注册"

    var body: some View {
        let md = "\(lead)即表示同意[《用户协议》](\(PolicyLinks.terms.absoluteString))和[《隐私政策》](\(PolicyLinks.privacy.absoluteString))"
        Text((try? AttributedString(markdown: md)) ?? AttributedString("\(lead)即表示同意《用户协议》和《隐私政策》"))
            .font(.footnote)
            .foregroundStyle(.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("legal-agreement")
    }
}
