import XCTest

/// 设置: an AI assistant token (made, shown with the Claude Code command, revoked), 导出数据, 退出登录.
final class SettingsUITests: NotedUITestCase {
    func testAIAssistantTokenCanBeMadeAndRevoked() throws {
        try launch()
        openSettings()
        app.buttons["settings-ai-connect"].tap()
        exists(app.navigationBars["接入 AI 助手"])
        reveal(app.buttons["token-generate"].firstMatch).tap()
        let alert = app.alerts["生成令牌"]
        exists(alert)
        let label = unique("UIT 令牌")
        let name = alert.textFields.firstMatch
        name.clearText()
        name.typeText(label)
        alert.buttons["生成"].firstMatch.tap()
        let secret = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'noted_'")).firstMatch
        exists(secret, 10)
        // The pairing command (no token) comes first; this is the one with the token.
        let command = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'claude mcp add --scope user' AND label CONTAINS 'Bearer'")).firstMatch
        exists(command)
        XCTAssertTrue(command.label.contains(secret.label), command.label)
        let revoke = app.buttons["吊销 \(label)"]
        reveal(revoke).tap()
        let confirm = app.alerts.buttons["吊销"].firstMatch
        exists(confirm)
        confirm.tap()
        sawToast("已吊销")
        gone(app.buttons["吊销 \(label)"])
        gone(secret)
    }

    func testExportMakesAFile() throws {
        try? FileManager.default.removeItem(atPath: Self.exportCopy)
        try launch()
        openSettings()
        reveal(app.buttons["settings-export"]).tap()
        exists(app.navigationBars["导出数据"])
        app.buttons["export"].tap()
        exists(app.buttons["export-share"], 20)
        exists(any(".zip"))
        eventually(5, "the zip was copied out for verify.py") { FileManager.default.fileExists(atPath: Self.exportCopy) }
    }

    func testSignOutReturnsToSignIn() throws {
        try launch()
        openSettings()
        let out = app.buttons["sign-out"]
        reveal(out).tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == '退出登录' AND identifier != 'sign-out'")).firstMatch
        exists(confirm)
        confirm.tap()
        exists(app.buttons["apple-sign-in"], 10)
        exists(app.buttons["own-server"])
    }

    /// 删除账号 on a throwaway user (the script makes it and checks afterwards that it is gone),
    /// so the seeded user the other tests share is untouched.
    func testDeleteAccountReturnsToSignIn() throws {
        let doomed = env["NOTED_DELETE_TOKEN"] ?? ""
        try XCTSkipIf(doomed.isEmpty, "NOTED_DELETE_TOKEN is not set: run ios/Tests/run-ui-tests.sh")
        try launch(extra: ["NOTED_TOKEN": doomed])
        openSettings()
        reveal(app.buttons["settings-delete-account"]).tap()
        exists(app.navigationBars["删除账号"])
        exists(any("删除后无法恢复"))
        let submit = app.buttons["delete-account-submit"]
        let field = app.textFields["delete-account-confirm"]
        reveal(field).tap()
        field.typeText("删")
        XCTAssertFalse(reveal(submit).isEnabled, "one character must not be enough")
        reveal(field).tap() // reaching the button put the keyboard away
        field.typeText("除")
        eventually(3, "the button turns on once 删除 is typed") { submit.isEnabled }
        submit.tap()
        exists(app.buttons["apple-sign-in"], 15)
        exists(app.buttons["own-server"])
    }
    /// 自带模型 Key (the tester is Pro): the row opens the form, and 保存 waits for address, model and key.
    /// Nothing is saved: the server would make a real test call.
    func testOwnModelKeyFormNeedsAllThreeFields() throws {
        try launch()
        openSettings()
        reveal(app.buttons["settings-own-model"]).tap()
        exists(app.navigationBars["自带模型 Key"])
        exists(any("不受每天 60 次的限制"))
        let save = app.buttons["own-model-save"]
        exists(save)
        XCTAssertFalse(save.isEnabled)
        let url = app.textFields["own-model-url"]
        reveal(url).tap()
        url.typeText("https://api.deepseek.com/v1")
        let model = app.textFields["own-model-name"]
        reveal(model).tap()
        model.typeText("deepseek-chat")
        XCTAssertFalse(reveal(save).isEnabled, "no key yet")
        let key = app.secureTextFields["own-model-key"]
        reveal(key).tap()
        key.typeText("sk-uit-fake")
        eventually(3, "保存 turns on with all three") { save.isEnabled }
    }
}
