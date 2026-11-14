import Foundation
import Observation
import StoreKit

/// Noted Pro: one non-consumable App Store purchase, bought once and kept forever. Customizing
/// the app is decided here; AI is decided by the server, which unlocks it once it has seen the
/// signed purchase (VerifyPurchase) or when it granted Pro itself (`noted user pro`).
@MainActor @Observable
final class Pro {
    static let lifetimeID = "cn.superleo.noted.pro.lifetime"

    var isPro = false
    /// This Apple ID owns the purchase (StoreKit's current entitlements).
    private(set) var owned = false
    /// The server's account is Pro: the purchase was verified there, or the server granted it.
    private(set) var grantedByServer = false
    /// The server's answer has arrived at least once (until then AI is not shown locked).
    private(set) var serverKnown = false
    var product: Product?
    var busy = false
    var message: String?
    /// Sends a signed transaction to the server and returns whether the account is now Pro there.
    /// Set by the session; nil before there is a server.
    var verifyOnServer: (@MainActor (String) async throws -> Bool)?
    private var updates: Task<Void, Never>?
    private var triedSync = false

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["NOTED_PRO"] == "1" { isPro = true }
        #endif
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let t) = result else { continue }
                await t.finish()
                await self?.refresh()
                if t.productID == Self.lifetimeID, t.revocationDate == nil { await self?.sendToServer(result.jwsRepresentation) }
            }
        }
    }

    func load() async {
        product = (try? await Product.products(for: [Self.lifetimeID]))?.first
        await refresh()
    }

    /// The device's verified, unrevoked purchase of Pro, as the signed transaction the server checks.
    func entitlement() async -> String? {
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.lifetimeID, t.revocationDate == nil {
                return result.jwsRepresentation
            }
        }
        return nil
    }

    /// Pro is on while this Apple ID owns the purchase (a refund revokes it) or the server says so.
    func refresh() async {
        owned = await entitlement() != nil
        var on = owned || grantedByServer
        #if DEBUG
        if ProcessInfo.processInfo.environment["NOTED_PRO"] == "1" { on = true }
        #endif
        isPro = on
    }

    func setServerGrant(_ on: Bool) {
        grantedByServer = on
        serverKnown = true
        if on { isPro = true } else { Task { await refresh() } }
    }

    /// Tells the server about the purchase so AI unlocks for this account. A failure leaves the
    /// purchase on the device; the next launch tries again.
    @discardableResult
    func sendToServer(_ jws: String) async -> Bool {
        guard let verifyOnServer else { return false }
        do {
            let on = try await verifyOnServer(jws)
            if on { setServerGrant(true) }
            return on
        } catch {
            message = describe(error)
            return false
        }
    }

    /// Records what the server says and, once per launch, sends the purchase along when the
    /// device owns Pro but the server's account does not know yet (bought offline, a new server).
    func syncIfNeeded(serverPro: Bool) async {
        setServerGrant(serverPro)
        guard !serverPro, !triedSync else { return }
        triedSync = true
        guard let jws = await entitlement() else { return }
        await sendToServer(jws)
    }

    func buy() async {
        guard let product else { return }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                if case .verified(let t) = result {
                    await t.finish()
                    await refresh()
                    message = nil
                    await sendToServer(result.jwsRepresentation)
                } else {
                    await refresh()
                    message = "购买没有通过验证"
                }
            case .pending: message = "等待批准中"
            case .userCancelled: message = nil
            @unknown default: message = nil
            }
        } catch { message = error.localizedDescription }
    }

    func restore() async {
        busy = true
        defer { busy = false }
        message = nil
        do { try await AppStore.sync() } catch { message = error.localizedDescription }
        await refresh()
        if let jws = await entitlement() {
            await sendToServer(jws)
        } else if !isPro {
            message = "没有找到可恢复的购买"
        }
    }
}
