import XCTest
@testable import Noted

/// 自带模型 Key: when 保存 turns on, and which host the consent text names.
final class OwnModelTests: XCTestCase {
    func testSaveNeedsAnHTTPSAddressAModelAndAKey() {
        var f = OwnModelForm()
        XCTAssertEqual(f.problem, "填写接口地址")
        f.baseURL = "api.deepseek.com"
        XCTAssertFalse(f.canSave, "no scheme")
        f.baseURL = "http://api.deepseek.com/v1"
        XCTAssertFalse(f.canSave, "plain http")
        f.baseURL = "  https://api.deepseek.com/v1/ "
        XCTAssertEqual(f.trimmedBaseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(f.host, "api.deepseek.com")
        XCTAssertEqual(f.problem, "填写模型名")
        f.model = "deepseek-chat"
        XCTAssertEqual(f.problem, "填写 API Key")
        f.key = "sk-fake key"
        XCTAssertFalse(f.canSave, "a space in the key")
        f.key = " sk-fake-0000 "
        XCTAssertTrue(f.canSave)
        XCTAssertEqual(f.trimmedKey, "sk-fake-0000")
    }

    func testAStoredKeyMayBeKept() {
        var s = Noted_V1_ModelSettings()
        s.baseURL = "https://api.openai.com/v1"; s.model = "gpt-4o-mini"; s.keySet = true; s.keyHint = "sk-…abcd"
        let f = OwnModelForm(s)
        XCTAssertEqual(f.key, "", "the key is never filled in")
        XCTAssertTrue(f.canSave, "an empty key keeps the stored one")
    }

    func testRejectsAddressesWithCredentialsOrQuery() {
        XCTAssertNil(OwnModelForm.host(of: "https://user:pw@api.openai.com/v1"))
        XCTAssertNil(OwnModelForm.host(of: "https://api.openai.com/v1?x=1"))
        XCTAssertNil(OwnModelForm.host(of: "https://"))
        XCTAssertEqual(OwnModelForm.host(of: "HTTPS://api.openai.com"), "api.openai.com")
    }

    func testConsentNamesTheOwnHostOnlyWhileItIsUsed() {
        var s = Noted_V1_ModelSettings()
        XCTAssertNil(AIConsent.ownHost(s))
        s.keySet = true; s.host = "api.deepseek.com"
        XCTAssertNil(AIConsent.ownHost(s), "stored but not active (no Pro)")
        s.active = true
        XCTAssertEqual(AIConsent.ownHost(s), "api.deepseek.com")
    }
}
