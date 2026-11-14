import StoreKit
import StoreKitTest
import XCTest
@testable import Noted

/// Buys, refunds and restores Noted Pro (one non-consumable), against StoreKit's local test store.
@MainActor
final class PurchaseTests: XCTestCase {
    private var store: SKTestSession!

    /// StoreKit reports a refund a moment after it happens.
    private func settle(_ pro: Pro, isPro expected: Bool) async {
        for _ in 0..<30 {
            await pro.refresh()
            if pro.isPro == expected { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    override func setUp() async throws {
        store = try SKTestSession(configurationFileNamed: "Noted")
        store.resetToDefaultState()
        store.disableDialogs = true
        store.askToBuyEnabled = false
        store.clearTransactions()
    }

    override func tearDown() async throws {
        store.clearTransactions()
    }

    func testOneLifetimePurchaseIsOffered() async throws {
        let pro = Pro()
        await pro.load()
        let p = try XCTUnwrap(pro.product)
        XCTAssertEqual(p.id, Pro.lifetimeID)
        XCTAssertEqual(p.type, .nonConsumable)
        XCTAssertEqual(p.price, Decimal(string: "19.99"))
        XCTAssertFalse(pro.isPro)
    }

    func testBuyingTurnsProOnAndTellsTheServer() async throws {
        let pro = Pro()
        var sent: [String] = []
        pro.verifyOnServer = { jws in sent.append(jws); return true }
        await pro.load()
        await pro.buy()
        XCTAssertTrue(pro.isPro)
        XCTAssertTrue(pro.owned)
        XCTAssertNil(pro.message)
        XCTAssertEqual(sent.count, 1, "the signed transaction goes to VerifyPurchase")
        XCTAssertEqual(sent.first?.split(separator: ".").count, 3, "a compact JWS")
        XCTAssertTrue(pro.grantedByServer)
    }

    func testAServerThatRefusesKeepsTheLocalPurchase() async throws {
        let pro = Pro()
        pro.verifyOnServer = { _ in throw CancellationError() }
        await pro.load()
        await pro.buy()
        XCTAssertTrue(pro.isPro, "customizing still unlocks on the device")
        XCTAssertFalse(pro.grantedByServer, "AI waits for the server")
        XCTAssertNotNil(pro.message)
    }

    func testARefundTurnsProOff() async throws {
        let pro = Pro()
        await pro.load()
        await pro.buy()
        XCTAssertTrue(pro.isPro)
        let t = try XCTUnwrap(store.allTransactions().first)
        try store.refundTransaction(identifier: t.identifier)
        await settle(pro, isPro: false)
        XCTAssertFalse(pro.isPro, "a refunded purchase no longer unlocks anything")
        let jws = await pro.entitlement()
        XCTAssertNil(jws)
    }

    func testRestoringFindsAnEarlierPurchaseAndSendsIt() async throws {
        let first = Pro()
        await first.load()
        await first.buy()
        let second = Pro()      // a fresh install on the same Apple ID
        var sent = 0
        second.verifyOnServer = { _ in sent += 1; return true }
        await second.refresh()
        XCTAssertTrue(second.isPro)
        await second.restore()
        XCTAssertTrue(second.isPro)
        XCTAssertEqual(sent, 1)
    }

    func testLaunchSyncSendsThePurchaseOnceWhenTheServerDoesNotKnow() async throws {
        let first = Pro()
        await first.load()
        await first.buy()
        let pro = Pro()
        var sent = 0
        pro.verifyOnServer = { _ in sent += 1; return true }
        await pro.syncIfNeeded(serverPro: true)
        XCTAssertEqual(sent, 0, "the server already knows")
        await pro.syncIfNeeded(serverPro: false)
        XCTAssertTrue(pro.grantedByServer, "the server accepted it")
        await pro.syncIfNeeded(serverPro: false)
        XCTAssertEqual(sent, 1, "once per launch")
        XCTAssertTrue(pro.isPro, "the device entitlement still unlocks Pro")
    }

    func testRestoringWithNothingBoughtSaysSo() async {
        let pro = Pro()
        await pro.restore()
        XCTAssertFalse(pro.isPro)
        XCTAssertEqual(pro.message, "没有找到可恢复的购买")
    }

    func testAFailedPurchaseLeavesThingsAlone() async throws {
        try await store.setSimulatedError(.generic(.unknown), forAPI: .purchase)
        let pro = Pro()
        await pro.load()
        await pro.buy()
        XCTAssertFalse(pro.isPro)
        XCTAssertNotNil(pro.message, "the failure is shown")
    }
}
