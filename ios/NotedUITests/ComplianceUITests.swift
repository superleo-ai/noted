import XCTest

/// App Store compliance: the policy links (设置 → 关于, the sign-in page) and the AI consent asked
/// before the first AI request, kept in 设置 → 智能 → AI 数据使用.
final class ComplianceUITests: NotedUITestCase {
    func testPolicyLinksInSettings() throws {
        try launch()
        openSettings()
        for id in ["settings-privacy", "settings-terms", "settings-support"] {
            exists(reveal(app.descendants(matching: .any)[id].firstMatch))
        }
        XCTAssertTrue(app.descendants(matching: .any)["settings-privacy"].firstMatch.label.contains("隐私政策"))
        XCTAssertTrue(app.descendants(matching: .any)["settings-terms"].firstMatch.label.contains("用户协议"))
    }

    func testSignInNamesTheTermsAndPrivacyPolicy() throws {
        try launch(connected: false, reset: true)
        exists(app.buttons["apple-sign-in"], 10)
        let line = byID("legal-agreement")
        exists(line)
        XCTAssertTrue(line.label.contains("用户协议") && line.label.contains("隐私政策"), line.label)
        app.buttons["email-sign-in"].tap()
        exists(app.textFields["email"])
        exists(reveal(byID("legal-agreement")))
    }

    /// The first request asks; 不用 AI sends nothing, 同意并继续 sends it; then withdrawn in 设置.
    func testAIConsentIsAskedBeforeTheFirstRequestAndCanBeWithdrawn() throws {
        try launch()
        tab("new")
        let input = app.textFields["capture-input"]
        type(unique("UIT 明天要做什么"), into: input)
        app.buttons["capture-send"].tap()

        let agree = app.buttons["ai-consent-agree"]
        exists(agree, 10)
        exists(any("只为这次请求"))
        exists(any("OpenAI"))
        app.buttons["ai-consent-decline"].tap()
        gone(agree)
        let retry = app.buttons["ask-retry"]
        exists(retry, 10)

        retry.tap()
        exists(agree, 10)
        agree.tap()
        gone(agree)
        gone(retry, 20)

        openSettingsFromAnywhere()
        reveal(app.buttons["settings-ai-consent"]).tap()
        exists(app.navigationBars["AI 数据使用"])
        let status = byID("ai-consent-status")
        eventually(5, "the agreement is shown") { status.label.contains("已同意") }
        reveal(app.buttons["ai-consent-withdraw"]).tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == '撤回同意' AND identifier != 'ai-consent-withdraw'")).firstMatch
        exists(confirm)
        confirm.tap()
        eventually(5, "the agreement is withdrawn") { status.label.contains("未同意") }
        exists(reveal(app.buttons["ai-consent-agree"]))
    }

    /// 设置 is pushed from the avatar on 今天; 提问 is a pushed page without the tab bar.
    private func openSettingsFromAnywhere() {
        dismissKeyboard()
        for _ in 0..<3 where !app.buttons["tab-today"].exists { back() }
        tab("today")
        openSettings()
    }
}
