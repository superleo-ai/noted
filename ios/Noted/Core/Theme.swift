import SwiftUI
import UIKit

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// The values every screen reads. A theme is a set of these and nothing else.
struct Palette: Sendable {
    var bg, surface, surface2, ink, ink2, ink3, line: Color
    var accentDef, work, life, ok, bad, warn: Color
    var workBg, lifeBg, badBg: Color
    var radius: CGFloat
    var rowHeight: CGFloat
    /// The design's smaller radius: 10 where the main one is 14.
    var radiusSm: CGFloat { (radius * 0.7).rounded() }
    /// Whether the accent follows the work / life mode.
    var modeColors = true
    /// Titles in the serif face (纸本).
    var serif = false

    /// The app's own look (see Design/Tokens.swift); widgets and note images read it from here.
    static let daylight = Palette(
        bg: Color(hex: 0xF2F2F7), surface: Color(hex: 0xFFFFFF), surface2: Color(hex: 0xE9E9EE),
        ink: Color(hex: 0x000000), ink2: Color(hex: 0x6E6E73), ink3: Color(hex: 0xA3A3A8), line: Color(hex: 0xD8D8DC),
        accentDef: Color(hex: 0x1F5BFF), work: Color(hex: 0x1F5BFF), life: Color(hex: 0xC2410C), ok: Color(hex: 0x1B8A55),
        bad: Color(hex: 0xE5484D), warn: Color(hex: 0xE8890C),
        workBg: Color(hex: 0xE4ECFF), lifeBg: Color(hex: 0xF8E8E0), badBg: Color(hex: 0xFCE9EA),
        radius: 14, rowHeight: 52)

    static let paper: Palette = {
        var p = Palette(
        bg: Color(hex: 0xF4EEE1), surface: Color(hex: 0xFBF7EE), surface2: Color(hex: 0xECE4D2),
        ink: Color(hex: 0x2A241C), ink2: Color(hex: 0x5F5546), ink3: Color(hex: 0x8A7F6B), line: Color(hex: 0xDCD2BC),
        accentDef: Color(hex: 0xB03A24), work: Color(hex: 0x2B5A88), life: Color(hex: 0x96560F), ok: Color(hex: 0x386F43),
        bad: Color(hex: 0xB03A24), warn: Color(hex: 0x7A5200),
        workBg: Color(hex: 0xE1EAF2), lifeBg: Color(hex: 0xF3E4CC), badBg: Color(hex: 0xF4DDD6),
        radius: 6, rowHeight: 50)
        p.serif = true
        return p
    }()

    static let moss = Palette(
        bg: Color(hex: 0xF0F3EC), surface: Color(hex: 0xFFFFFF), surface2: Color(hex: 0xE3E9DD),
        ink: Color(hex: 0x17251C), ink2: Color(hex: 0x4F6054), ink3: Color(hex: 0x7B8C80), line: Color(hex: 0xD5DDCF),
        accentDef: Color(hex: 0x276B49), work: Color(hex: 0x2A5F8F), life: Color(hex: 0xA2561A), ok: Color(hex: 0x276B49),
        bad: Color(hex: 0xBE3A2E), warn: Color(hex: 0x835400),
        workBg: Color(hex: 0xE1EBF4), lifeBg: Color(hex: 0xF7E6D6), badBg: Color(hex: 0xF9E1DE),
        radius: 20, rowHeight: 54)

    static func builtin(_ id: String) -> Palette {
        switch id {
        case "paper": .paper
        case "moss": .moss
        default: .daylight
        }
    }

    init(bg: Color, surface: Color, surface2: Color, ink: Color, ink2: Color, ink3: Color, line: Color,
         accentDef: Color, work: Color, life: Color, ok: Color, bad: Color, warn: Color,
         workBg: Color, lifeBg: Color, badBg: Color, radius: CGFloat, rowHeight: CGFloat) {
        self.bg = bg; self.surface = surface; self.surface2 = surface2
        self.ink = ink; self.ink2 = ink2; self.ink3 = ink3; self.line = line
        self.accentDef = accentDef; self.work = work; self.life = life
        self.ok = ok; self.bad = bad; self.warn = warn
        self.workBg = workBg; self.lifeBg = lifeBg; self.badBg = badBg
        self.radius = radius; self.rowHeight = rowHeight
    }
}

/// The built-in themes, in the order the 主题 page shows them.
enum BuiltinTheme: String, CaseIterable, Identifiable, Sendable {
    case daylight, paper, moss
    var id: String { rawValue }
    var label: String {
        switch self {
        case .daylight: "日光"
        case .paper: "纸本"
        case .moss: "苔绿"
        }
    }
    var palette: Palette { Palette.builtin(rawValue) }
}

/// A set of changes on top of a built-in theme: what the 自定义主题 editor makes.
struct ThemeOverrides: Codable, Equatable, Sendable {
    var base = "daylight"
    var accent: UInt32?
    var work: UInt32?
    var life: UInt32?
    var bg: UInt32?
    var radius: Double?
    var density: String?   // compact | regular | roomy
    var serif: Bool?

    init(base: String = "daylight") { self.base = base }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = try c.decodeIfPresent(String.self, forKey: .base) ?? "daylight"
        accent = try c.decodeIfPresent(UInt32.self, forKey: .accent)
        work = try c.decodeIfPresent(UInt32.self, forKey: .work)
        life = try c.decodeIfPresent(UInt32.self, forKey: .life)
        bg = try c.decodeIfPresent(UInt32.self, forKey: .bg)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius)
        density = try c.decodeIfPresent(String.self, forKey: .density)
        serif = try c.decodeIfPresent(Bool.self, forKey: .serif)
    }

    var isEmpty: Bool {
        accent == nil && work == nil && life == nil && bg == nil && radius == nil && density == nil && serif == nil
    }

    func apply(to p: inout Palette) {
        if let a = accent { p.accentDef = Color(hex: a) }
        if let w = work { p.work = Color(hex: w); p.workBg = Color(hex: w).wash(0.12) }
        if let l = life { p.life = Color(hex: l); p.lifeBg = Color(hex: l).wash(0.12) }
        if let b = bg { p.bg = Color(hex: b) }
        if let r = radius { p.radius = CGFloat(r) }
        switch density {
        case "compact": p.rowHeight = 44
        case "roomy": p.rowHeight = 60
        case "regular": p.rowHeight = 52
        default: break
        }
        if let s = serif { p.serif = s }
    }

    /// The built-in theme with these changes.
    var palette: Palette {
        var p = Palette.builtin(base == ThemeSpec.custom ? "daylight" : base)
        apply(to: &p)
        return p
    }
}

/// What the person chose, as stored in the "ui.theme" preference. Only the
/// differences from the base theme are kept.
///
/// `base` is a built-in theme id, or "custom" for the saved 我的主题 (`mine`). The top-level
/// accent ... serif fields are changes on top of the base; older versions of the app wrote the
/// accent there, so they still apply.
struct ThemeSpec: Codable, Equatable, Sendable {
    static let custom = "custom"

    var base = "daylight"
    var accent: UInt32?
    var work: UInt32?
    var life: UInt32?
    var bg: UInt32?
    var radius: Double?
    var density: String?   // compact | regular | roomy
    var serif: Bool?
    var modeColors = true
    /// 我的主题, saved from the editor; shown as a fourth theme once it exists.
    var mine: ThemeOverrides?

    init(base: String = "daylight", modeColors: Bool = true) {
        self.base = base
        self.modeColors = modeColors
    }

    /// Any field may be missing: a theme saved by another version of the app still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = try c.decodeIfPresent(String.self, forKey: .base) ?? "daylight"
        accent = try c.decodeIfPresent(UInt32.self, forKey: .accent)
        work = try c.decodeIfPresent(UInt32.self, forKey: .work)
        life = try c.decodeIfPresent(UInt32.self, forKey: .life)
        bg = try c.decodeIfPresent(UInt32.self, forKey: .bg)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius)
        density = try c.decodeIfPresent(String.self, forKey: .density)
        serif = try c.decodeIfPresent(Bool.self, forKey: .serif)
        modeColors = try c.decodeIfPresent(Bool.self, forKey: .modeColors) ?? true
        mine = try? c.decodeIfPresent(ThemeOverrides.self, forKey: .mine)
        if base == Self.custom && mine == nil { base = "daylight" }
    }

    var isCustom: Bool { base == Self.custom || !overrides.isEmpty }

    /// The theme's name for a settings row: 日光 / 纸本 / 苔绿 / 我的主题.
    var label: String { base == Self.custom ? "我的主题" : (BuiltinTheme(rawValue: base) ?? .daylight).label }

    /// The top-level changes, as one value.
    var overrides: ThemeOverrides {
        get {
            var o = ThemeOverrides(base: base)
            o.accent = accent; o.work = work; o.life = life; o.bg = bg
            o.radius = radius; o.density = density; o.serif = serif
            return o
        }
        set {
            accent = newValue.accent; work = newValue.work; life = newValue.life; bg = newValue.bg
            radius = newValue.radius; density = newValue.density; serif = newValue.serif
        }
    }

    /// Switches to a built-in theme or to 我的主题, dropping changes made on top of the old one.
    mutating func select(_ id: String) {
        base = id
        overrides = ThemeOverrides(base: id)
    }

    var palette: Palette {
        var p = base == Self.custom ? (mine?.palette ?? .daylight) : Palette.builtin(base)
        overrides.apply(to: &p)
        p.modeColors = modeColors
        return p
    }
}

/// The palette the design tokens (Design/Tokens.swift) read. Session keeps it in step with the
/// chosen theme; views that read a token are redrawn when it changes.
@Observable
final class LiveTheme: @unchecked Sendable {
    static let shared = LiveTheme()
    var palette = Palette.daylight
}

/// What SwiftUI's environment cannot reach: the navigation bar's title face.
@MainActor
enum ThemeChrome {
    private static var serif: Bool?

    static func apply(_ p: Palette) {
        guard serif != p.serif else { return }
        let first = serif == nil
        serif = p.serif
        let bar = UINavigationBar.appearance()
        if p.serif {
            bar.largeTitleTextAttributes = [.font: font(.largeTitle, .bold)]
            bar.titleTextAttributes = [.font: font(.headline, .semibold)]
        } else {
            bar.largeTitleTextAttributes = nil
            bar.titleTextAttributes = nil
        }
        // Bars already on screen do not read the appearance proxy again. At launch there are none.
        guard !first else { return }
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows { update(w.rootViewController, bar) }
        }
    }

    private static func update(_ vc: UIViewController?, _ proxy: UINavigationBar) {
        guard let vc else { return }
        if let nav = vc as? UINavigationController {
            nav.navigationBar.largeTitleTextAttributes = proxy.largeTitleTextAttributes
            nav.navigationBar.titleTextAttributes = proxy.titleTextAttributes
            nav.navigationBar.setNeedsLayout()
        }
        vc.children.forEach { update($0, proxy) }
        update(vc.presentedViewController, proxy)
    }

    /// The system serif (New York). Chinese has no serif face on iOS, so it stays in PingFang.
    static func font(_ style: UIFont.TextStyle, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        let sized = UIFont.systemFont(ofSize: base.pointSize, weight: weight)
        guard let d = sized.fontDescriptor.withDesign(.serif) else { return sized }
        return UIFont(descriptor: d, size: base.pointSize)
    }
}

extension Color {
    /// The color as 0xRRGGBB, for storing in a ThemeSpec.
    var hex: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return (c(r) << 16) | (c(g) << 8) | c(b)
    }
}

extension EnvironmentValues {
    @Entry var palette: Palette = .daylight
    @Entry var mode: Mode = .all
}

/// 全部 / 个人 / 工作: the space filter in every tab's navigation bar.
enum Mode: String, CaseIterable, Identifiable, Sendable {
    case all, life, work
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "全部"
        case .life: "个人"
        case .work: "工作"
        }
    }
    var space: Noted_V1_Space {
        switch self {
        case .all: .unspecified
        case .life: .life
        case .work: .work
        }
    }
    func accent(_ p: Palette) -> Color {
        guard p.modeColors else { return p.accentDef }
        switch self {
        case .all: return p.accentDef
        case .life: return p.life
        case .work: return p.work
        }
    }
}

extension Noted_V1_Space {
    func color(_ p: Palette) -> Color { self == .work ? p.work : p.life }
    var label: String { self == .work ? "工作" : "个人" }
}
