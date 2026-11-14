import SwiftUI
import UIKit

// The design is drawn in the classic iOS look: plain bar buttons, a gray segmented track with a
// white thumb, 13 pt gray section labels and 44 pt rows. iOS 26 draws these controls in Liquid
// Glass with larger metrics, so the app sets them back here.

@MainActor
enum ClassicChrome {
    /// The segmented controls (`.seg`): a gray track, radius 9, with a white rounded thumb inset
    /// 2 pt and a hairline between unselected segments. 14 pt medium, the selected one semibold.
    static func install() {
        let seg = UISegmentedControl.appearance()
        // Opaque: the divider images overlap the segments, so a translucent track shows seams.
        let track = UIColor(red: 0xE3 / 255, green: 0xE3 / 255, blue: 0xE8 / 255, alpha: 1)
        let pressed = UIColor(red: 0xD8 / 255, green: 0xD8 / 255, blue: 0xDD / 255, alpha: 1)
        seg.setBackgroundImage(fill(track), for: .normal, barMetrics: .default)
        seg.setBackgroundImage(fill(pressed), for: .highlighted, barMetrics: .default)
        seg.setBackgroundImage(thumb(track), for: .selected, barMetrics: .default)
        seg.setBackgroundImage(thumb(track), for: [.selected, .highlighted], barMetrics: .default)
        seg.setDividerImage(divider(track, line: true), forLeftSegmentState: .normal, rightSegmentState: .normal, barMetrics: .default)
        for (l, r) in [(UIControl.State.selected, UIControl.State.normal), (.normal, .selected), (.highlighted, .normal),
                       (.normal, .highlighted), (.selected, .highlighted), (.highlighted, .selected)] {
            seg.setDividerImage(divider(track, line: false), forLeftSegmentState: l, rightSegmentState: r, barMetrics: .default)
        }
        seg.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: UIColor.label], for: .normal)
        seg.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: UIColor.label], for: .selected)
    }

    private static let height: CGFloat = 32

    private static func fill(_ c: UIColor) -> UIImage {
        let size = CGSize(width: 4, height: height)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            c.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }.resizableImage(withCapInsets: .zero, resizingMode: .stretch)
    }

    private static func thumb(_ track: UIColor) -> UIImage {
        let size = CGSize(width: 24, height: height)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            track.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let r = CGRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4)
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 4, color: UIColor.black.withAlphaComponent(0.12).cgColor)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: r, cornerRadius: 7).fill()
        }.resizableImage(withCapInsets: UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10), resizingMode: .stretch)
    }

    private static func divider(_ track: UIColor, line: Bool) -> UIImage {
        let size = CGSize(width: 1, height: height)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            track.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            if line {
                UIColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.25).setFill()
                ctx.fill(CGRect(x: 0.25, y: 8, width: 0.5, height: size.height - 16))
            }
        }
    }
}

extension View {
    /// A segmented picker in the design's shape (the track's corners; ClassicChrome draws the rest).
    func classicSegmented() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// The 13 pt gray label over a group (`.sh`): "记录", "待办 · 3", "过去 7 天".
struct SectionLabel: View {
    let title: String
    var systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .medium)) }
            Text(title)
        }
        .font(.footnote)
        .foregroundStyle(.secondaryText)
        .textCase(nil)
    }
}

extension View {
    /// The design's row padding above and below (`.row`: 6 pt). iOS 26 pads list rows more, which
    /// made every row 8–16 pt taller than the design. Apply to a List's content: rows that set
    /// their own insets keep them.
    @ViewBuilder
    func classicRowInsets(_ vertical: CGFloat = 6) -> some View {
        if #available(iOS 26.0, *) {
            listRowInsets(.vertical, vertical)
        } else {
            self
        }
    }
}

extension View {
    /// A section whose row runs edge to edge (chip strips, horizontal cards): no side margin, so
    /// the strip's own 16 pt padding lines it up with the groups.
    @ViewBuilder
    func edgeToEdgeSection() -> some View {
        if #available(iOS 26.0, *) {
            listSectionMargins(.horizontal, 0).listSectionSeparator(.hidden)
        } else {
            listSectionSeparator(.hidden)
        }
    }
}

