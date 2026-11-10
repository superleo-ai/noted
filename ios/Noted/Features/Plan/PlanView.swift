import SwiftUI

/// 计划 (tab root): 项目 cards, 目标 rows, each with "全部 ›".
struct PlanView: View {
    @Environment(AppData.self) private var data
    @Environment(Router.self) private var router

    var body: some View {
        let projects = data.activeProjects
        let goals = data.standaloneGoals
        let objectives = data.visibleObjectives
        ScrollViewReader { proxy in
            List {
                Section {
                    if projects.isEmpty {
                        EmptyState(text: "没有进行中的项目")
                            .background(.white, in: RoundedRectangle(cornerRadius: 14))
                            .planCardRow()
                    }
                    ForEach(projects, id: \.id) { p in
                        ProjectCard(project: p).planCardRow()
                    }
                } header: {
                    SectionHeader("项目", action: "全部") { router.push(.projects) }
                        .id("top")
                        .accessibilityIdentifier("plan-projects-all")
                }

                Section {
                    ForEach(goals, id: \.id) { GoalRow(goal: $0) }
                    ForEach(objectives, id: \.id) { ObjectiveRow(objective: $0) }
                    if goals.isEmpty && objectives.isEmpty { EmptyState(text: "没有目标") }
                } header: {
                    SectionHeader("目标", action: "全部") { router.push(.goals) }
                        .accessibilityIdentifier("plan-goals-all")
                }
            }
            .listStyle(.insetGrouped)
            .onChange(of: router.scrollToTopRequest) { _, _ in
                withAnimation { proxy.scrollTo("top", anchor: .top) }
            }
        }
        .refreshable { await data.refreshAll() }
        .navigationTitle("计划")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { SpaceFilterMenu() } }
    }
}

extension View {
    /// A card that sits on the page background inside a List (no cell background, no insets).
    func planCardRow(bottom: CGFloat = 12) -> some View {
        self.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: bottom, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
