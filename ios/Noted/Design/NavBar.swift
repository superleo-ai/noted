import SwiftUI

// Navigation-bar pieces shared by the tab roots:
//
//   .toolbar {
//       ToolbarItem(placement: .topBarTrailing) { SpaceFilterMenu() }.plainBar()
//       ToolbarItem(placement: .topBarTrailing) { SettingsAvatarButton() }.plainBar()
//   }
//   .navigationTitle("今天").largeSubtitle("10月10日 周六")

/// 全部 / 个人 / 工作, bound to Session.mode. Shows a filter icon for 全部 and "● 个人" when filtered.
struct SpaceFilterMenu: View {
    @Environment(Session.self) private var session

    var body: some View {
        Menu {
            Picker("空间", selection: Binding(get: { session.mode }, set: { session.setMode($0) })) {
                Text("全部").tag(Mode.all)
                Section {
                    Label { Text("个人") } icon: { Image(uiImage: .dot(Noted_V1_Space.life.tint)) }.tag(Mode.life)
                    Label { Text("工作") } icon: { Image(uiImage: .dot(Noted_V1_Space.work.tint)) }.tag(Mode.work)
                }
            }
            .pickerStyle(.inline)
        } label: {
            switch session.mode {
            case .all:
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .accessibilityLabel("空间")
            case .life, .work:
                HStack(spacing: 5) {
                    SpaceDot(space: session.mode.space)
                    Text(session.mode.label).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("空间 \(session.mode.label)")
            }
        }
        .accessibilityIdentifier("space-filter")
    }
}

/// The initials avatar that opens 设置.
struct SettingsAvatarButton: View {
    @Environment(Router.self) private var router
    @Environment(AppData.self) private var data

    var body: some View {
        Button { router.push(.settings) } label: {
            Avatar(name: data.account?.userName ?? "")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("设置")
        .accessibilityIdentifier("settings")
    }
}

extension View {
    /// The gray line under a large title ("10月10日 周六"). iOS 26 shows it in the bar; earlier
    /// systems ignore it (put the text in the first section instead if it matters there).
    @ViewBuilder
    func largeSubtitle(_ text: String) -> some View {
        if #available(iOS 26.0, *) {
            // The design's 15 pt gray line, not the bar's small default subtitle.
            toolbar {
                ToolbarItem(placement: .largeSubtitle) {
                    Text(text).font(.subheadline).foregroundStyle(.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            self
        }
    }
}

// MARK: - the design's plain bar (no Liquid Glass capsules)

extension ToolbarContent {
    /// A bar item drawn plain, as in the design: the icon or text in the accent with no glass
    /// capsule behind it (iOS 26 groups bar items on a shared glass background).
    @ToolbarContentBuilder
    func plainBar() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// "‹ 笔记": the design's back button, the chevron and the previous page's title in the accent.
/// It replaces the system's round glass back button on every pushed page.
struct ClassicBackButton: ViewModifier {
    @Environment(Router.self) private var router
    @Environment(AppData.self) private var data
    let route: Route

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .background { PopGestureEnabler().frame(width: 0, height: 0).accessibilityHidden(true) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { router.pop() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left").font(.system(size: 19, weight: .semibold))
                            Text(title).font(.body).lineLimit(1)
                        }
                        .padding(.leading, -8)
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("BackButton")
                }
                .plainBar()
            }
    }

    /// The page under this one: its short title, the tab's name at the root, 返回 when too long.
    private var title: String {
        let path = router.path
        guard let i = path.lastIndex(of: route), i > 0 else { return router.tab.title }
        let t = Self.title(of: path[i - 1], data: data)
        return t.count <= 6 ? t : "返回"
    }

    static func title(of r: Route, data: AppData) -> String {
        switch r {
        case .todo: "待办"
        case .event: "日程"
        case .project(let id), .projectEdit(let id): data.projectTitle(id) ?? "项目"
        case .projects: "项目"
        case .linkExisting: "关联已有"
        case .goal(let id), .goalEdit(let id): data.goals.first { $0.id == id }?.title ?? "目标"
        case .goals: "目标"
        case .objective(let id): data.objectives.first { $0.id == id }?.title ?? "目标"
        case .note: "笔记"
        case .create: "新建"
        case .settings: "设置"
        case .aiConnect: "AI 助手"
        case .pair: "配对"
        case .theme: "主题"
        case .export: "导出数据"
        case .pro: "Noted Pro"
        case .changes: "改动记录"
        case .aiConsent: "AI 数据使用"
        case .ownModel: "自带模型"
        case .deleteAccount: "删除账号"
        case .modules: "页面模块"
        case .themeEditor: "自定义主题"
        case .suggestions: "建议"
        case .ask: "提问"
        case .review: "每周回顾"
        case .schedule: "排进空档"
        }
    }
}

extension View {
    func classicBackButton(_ route: Route) -> some View { modifier(ClassicBackButton(route: route)) }
}

/// With the system back button hidden, UIKit turns off the edge swipe back; this turns it on
/// again for the stack the page is on.
private struct PopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ vc: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let nav = navigationController, let g = nav.interactivePopGestureRecognizer else { return }
            Delegate.shared.navs.add(nav)
            g.delegate = Delegate.shared
            g.isEnabled = true
        }
    }

    /// Lives as long as the app, so the gesture never has a dangling delegate (one root page
    /// swiped with no delegate freezes the stack).
    @MainActor final class Delegate: NSObject, UIGestureRecognizerDelegate {
        static let shared = Delegate()
        let navs = NSHashTable<UINavigationController>.weakObjects()

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let nav = navs.allObjects.first(where: { $0.interactivePopGestureRecognizer === g }) else { return false }
            return nav.viewControllers.count > 1 && nav.transitionCoordinator == nil
        }
    }
}
