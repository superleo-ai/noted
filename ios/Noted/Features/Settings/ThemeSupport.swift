import SwiftUI

// Views shared by 主题 and 自定义主题. They draw from a Palette passed in, not from the
// live tokens, so they can show a theme before it is chosen.

/// A small picture of a theme: its page color, a card in its radius, its accent and space colors.
struct ThemeTile: View {
    let palette: Palette
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        let p = palette
        let r = max(3, p.radius * 0.5)
        Button(action: action) {
            VStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Aa 今天")
                        .font(.system(size: 13, weight: .bold, design: p.serif ? .serif : .default))
                        .foregroundStyle(p.ink)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 4) {
                            Circle().fill(p.life).frame(width: 6, height: 6)
                            Capsule().fill(p.line).frame(height: 4)
                        }
                        HStack(spacing: 4) {
                            Circle().fill(p.work).frame(width: 6, height: 6)
                            Capsule().fill(p.line).frame(width: 30, height: 4)
                        }
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: r))
                    .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(p.line, lineWidth: 0.5))
                    RoundedRectangle(cornerRadius: max(2, r * 0.7)).fill(p.accentDef).frame(height: 14)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(p.bg, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.hairline), lineWidth: isOn ? 2 : 1)
                }
                HStack(spacing: 4) {
                    if isOn { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                    Text(title).font(.footnote.weight(isOn ? .semibold : .regular)).foregroundStyle(.primary)
                }
                .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// A sample page in a theme: a 个人 project card, the two buttons and two schedule rows.
struct ThemePreviewCard: View {
    let palette: Palette
    var title = "预览"

    var body: some View {
        let p = palette
        let small = p.radiusSm
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(p.ink3)
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HStack(spacing: 5) {
                            Circle().fill(p.life).frame(width: 7, height: 7)
                            Text("个人").font(.caption2.weight(.semibold))
                        }
                        .padding(.horizontal, 8).frame(height: 22)
                        .foregroundStyle(p.life)
                        .background(p.lifeBg, in: RoundedRectangle(cornerRadius: 6))
                        Spacer()
                        Text("43 天").font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(p.ink)
                    }
                    Text("菲律宾旅行")
                        .font(.system(size: 17, weight: .semibold, design: p.serif ? .serif : .default))
                        .foregroundStyle(p.ink)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(p.surface2)
                            Capsule().fill(p.life).frame(width: g.size.width * 0.33)
                        }
                    }
                    .frame(height: 4)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(p.surface, in: RoundedRectangle(cornerRadius: p.radius))
                .overlay(RoundedRectangle(cornerRadius: p.radius).strokeBorder(p.line, lineWidth: 0.5))
                VStack(spacing: 8) {
                    Text("主按钮").font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 76, height: 34)
                        .background(p.accentDef, in: RoundedRectangle(cornerRadius: small))
                    Text("次按钮").font(.footnote.weight(.semibold)).foregroundStyle(p.ink)
                        .frame(width: 76, height: 34)
                        .background(p.surface2, in: RoundedRectangle(cornerRadius: small))
                }
            }
            VStack(spacing: 0) {
                row("14:00", "牙医复诊", p.life, strong: true)
                Rectangle().fill(p.line).frame(height: 0.5).padding(.leading, 14)
                row("16:00", "季度报告评审", p.work, strong: false)
            }
            .background(p.surface, in: RoundedRectangle(cornerRadius: p.radius))
            .overlay(RoundedRectangle(cornerRadius: p.radius).strokeBorder(p.line, lineWidth: 0.5))
        }
        .padding(14)
        .background(p.bg, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("主题预览")
    }

    private func row(_ time: String, _ text: String, _ dot: Color, strong: Bool) -> some View {
        let p = palette
        return HStack(spacing: 12) {
            Text(time).font(.caption.weight(strong ? .semibold : .medium)).monospacedDigit()
                .foregroundStyle(strong ? p.accentDef : p.ink2)
                .frame(width: 42, alignment: .leading)
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(text).font(.subheadline.weight(strong ? .semibold : .regular)).foregroundStyle(p.ink)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: max(40, p.rowHeight - 8))
    }
}

/// The small "PRO" mark next to a Pro feature, as on 设置.
struct ProMark: View {
    var body: some View {
        Text("PRO").font(.caption2.weight(.bold))
            .padding(.horizontal, 6).frame(height: 18)
            .foregroundStyle(TileColor.rust.color)
            .background(TileColor.rust.color.wash(0.12), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel("Pro")
    }
}
