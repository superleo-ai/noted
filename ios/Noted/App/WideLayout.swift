import SwiftUI
import UIKit

/// Wide screens (an iPhone Duo opened: 669 pt upright, 951 pt sideways): a tab shows its list and the
/// page opened from it side by side. Chosen by the width the app is given, never by the kind of device:
/// the Duo folded (466 pt) and every other iPhone held upright stay one column, exactly as before.
enum WideLayout {
    static let minWidth: CGFloat = 600

    static func isWide(_ width: CGFloat) -> Bool { width >= minWidth }

    /// The list column: 40% of the width, between 280 and 380 pt.
    static func listWidth(for width: CGFloat) -> CGFloat { min(380, max(280, (width * 0.4).rounded())) }

    /// Portrait only on a phone-sized screen (as before); any way up but upside down on a screen
    /// that is wide even held upright (the Duo opened). DEBUG: NOTED_ROTATE=1 lets any phone turn,
    /// for the wide UI test and screenshots on a simulator that cannot unfold.
    static func orientations(for screen: UIScreen?) -> UIInterfaceOrientationMask {
        #if DEBUG
        if ProcessInfo.processInfo.environment["NOTED_ROTATE"] == "1" { return .allButUpsideDown }
        #endif
        // 1.0: upright only, also on the Duo opened (still two columns: 669 pt). Sideways the list
        // column is too short to scroll to its last rows yet (WideUITests).
        return .portrait
    }
}

extension EnvironmentValues {
    /// The tab's root page has the whole wide width to itself (nothing open beside it): 今天 lays its
    /// modules out in two columns, 日历's month shows the grid and the day's list side by side.
    @Entry var wideRoot = false
}

extension AppTab {
    /// 笔记 and 计划 always keep a page column beside the list; 今天 and 日历 fill the width until
    /// something is opened from them.
    var keepsDetailColumn: Bool { self == .notes || self == .plan }

    var detailPlaceholder: String {
        switch self {
        case .notes: "选择一条笔记"
        case .plan: "选择一个项目或目标"
        case .today, .calendar: ""
        }
    }
}

extension Route {
    /// Pages that are lists themselves: on a wide screen they take the list column (with a way back
    /// to the tab's root) and what is opened from them goes beside them.
    var isListPage: Bool {
        switch self {
        case .settings, .projects, .goals: true
        default: false
        }
    }
}

/// Asks the system again which ways the app may turn when the screen changes (the Duo opened or closed).
final class OrientationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        WideLayout.orientations(for: window?.windowScene?.screen)
    }
}

extension View {
    /// When the window's shorter side crosses the wide width (unfolding, folding), the allowed
    /// orientations are asked for again, so folding a sideways Duo turns the app back upright.
    func refreshesOrientations() -> some View {
        onGeometryChange(for: Bool.self) { WideLayout.isWide(min($0.size.width, $0.size.height)) } action: { _ in
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for w in scene.windows { w.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            }
        }
    }
}

/// One tab on a wide screen: the list column (the tab's root, or a list page such as 设置 opened from it)
/// and, beside it, the stack of pages opened from it. The tab bar runs under both.
struct SplitTab<Root: View>: View {
    @Bindable var router: Router
    let width: CGFloat
    @ViewBuilder var root: Root
    @State private var listRouter: Router

    init(router: Router, width: CGFloat, @ViewBuilder root: () -> Root) {
        self.router = router
        self.width = width
        self.root = root()
        _listRouter = State(initialValue: Router(listFor: router))
    }

    /// A list page (设置, 项目 · 全部, 目标 · 全部) at the bottom of the stack takes the list column.
    private var lead: Route? {
        if let first = router.path.first, first.isListPage { first } else { nil }
    }

    private var detailPath: Binding<[Route]> {
        Binding(get: { Array(router.path.dropFirst(lead == nil ? 0 : 1)) },
                set: { router.path = (lead.map { [$0] } ?? []) + $0 })
    }

    /// The list column never stacks: a link followed in it (NavigationLink(value:)) opens beside it.
    private var listPath: Binding<[Route]> {
        Binding(get: { [] }, set: { new in if let r = new.last { listRouter.push(r) } })
    }

    private var showsDetail: Bool { router.tab.keepsDetailColumn || !detailPath.wrappedValue.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NavigationStack(path: listPath) {
                    Group {
                        if let lead {
                            RouteDestination(route: lead)
                                .toolbar {
                                    ToolbarItem(placement: .topBarLeading) {
                                        Button { router.popToRoot() } label: { Image(systemName: "chevron.backward") }
                                            .accessibilityLabel("返回")
                                            .accessibilityIdentifier("list-back")
                                    }.plainBar()
                                }
                        } else {
                            root.environment(\.wideRoot, !showsDetail)
                        }
                    }
                    .themedPage()
                    .navigationDestination(for: Route.self) { RouteDestination(route: $0).themedPage() }
                }
                .environment(listRouter)
                .frame(width: showsDetail ? WideLayout.listWidth(for: width) : width)
                .accessibilityIdentifier("split-list")

                if showsDetail {
                    Rectangle().fill(.hairline).frame(width: 0.5).ignoresSafeArea()
                    NavigationStack(path: detailPath) {
                        DetailPlaceholder(text: router.tab.detailPlaceholder, symbol: router.tab.symbol)
                            .themedPage()
                            .navigationDestination(for: Route.self) { RouteDestination(route: $0).themedPage() }
                    }
                    .environment(router)
                    .accessibilityIdentifier("split-detail")
                }
            }
            AppTabBar()
        }
    }
}

/// The page column before anything is opened.
private struct DetailPlaceholder: View {
    let text: String
    let symbol: String

    var body: some View {
        ContentUnavailableView(text, systemImage: symbol)
            .foregroundStyle(.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar(.hidden, for: .navigationBar)
            .accessibilityIdentifier("detail-placeholder")
    }
}
