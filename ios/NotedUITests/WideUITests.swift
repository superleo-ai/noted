import XCTest

/// Wide screens (an iPhone Duo opened): a tab's list and the page opened from it side by side.
/// The test build lets any phone turn (NOTED_ROTATE=1); sideways, even a regular iPhone or the folded
/// Duo is wider than WideLayout.minWidth, so this runs on whatever simulator the suite uses.
final class WideUITests: NotedUITestCase {
    override func tearDown() {
        super.tearDown()
        XCUIDevice.shared.orientation = .portrait
    }

    private func note(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'note-row' AND label BEGINSWITH %@", title)).firstMatch
    }

    private func wideLaunch(tab: String) throws {
        try launch(tab: tab, extra: ["NOTED_ROTATE": "1"])
        XCUIDevice.shared.orientation = .landscapeLeft
        eventually(5, "the app turned sideways") { app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }
    }

    func testSelectingANoteShowsItBesideTheList() throws {
        try wideLaunch(tab: "notes")
        exists(byID("detail-placeholder"))
        let row = note("周会纪要")
        exists(row)
        row.tap()

        let preview = byID("note-preview")
        exists(preview)
        exists(text("回归测试下周开始"))
        gone(byID("detail-placeholder"), 2)
        XCTAssertTrue(row.isHittable, "the list stays on screen beside the note")
        XCTAssertFalse(row.frame.intersects(preview.frame), "the note is beside the list, not over it")
        XCTAssertLessThan(row.frame.maxX, preview.frame.minX + 1, "the list on the left, the note on the right")
        XCTAssertTrue(app.buttons["tab-notes"].isHittable, "the tab bar stays")

        // Another note from the list takes the page's place (no stack to go back through).
        let other = note("旅行清单")
        reveal(other).tap()
        exists(text("签证打印件"))
        gone(text("回归测试下周开始"), 3)
        XCTAssertFalse(app.navigationBars.buttons["BackButton"].exists, "a note opened from the list replaces the one beside it")
    }

    func testTodayFillsTheWidthUntilSomethingIsOpened() throws {
        try wideLaunch(tab: "today")
        exists(byID("today-list"))
        XCTAssertFalse(byID("split-detail").exists, "nothing open: 今天 has the whole width")
        let settings = app.buttons["settings"]
        exists(settings)
        settings.tap()
        // 设置 is a list itself: it takes the list column, and what it opens goes beside it.
        exists(app.navigationBars["设置"])
        exists(byID("list-back"))
        let theme = button("主题")
        reveal(theme).tap()
        exists(byID("split-detail"))
        XCTAssertTrue(app.navigationBars["设置"].exists, "设置 stays beside the page it opened")
        byID("list-back").tap()
        gone(app.navigationBars["设置"])
        exists(byID("today-list"))
    }
}
