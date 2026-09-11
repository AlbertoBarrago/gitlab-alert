import Foundation
import Security
import Testing

@testable import GitLabKit

/// Whether this process can use the current user's login keychain.
///
/// Headless CI can run without an unlocked login keychain. Probing once and
/// skipping is honest; leaving the suite red in that environment is not.
private let keychainIsUsable: Bool = {
    let probe = KeychainTokenStore(
        service: "com.alBz.GitLabAlert.tests.probe.\(UUID().uuidString)",
        account: "probe"
    )
    do {
        try probe.writeToken("probe")
        let readBack = try probe.readToken()
        try probe.deleteToken()
        return readBack == "probe"
    } catch {
        // Leave nothing behind if the write succeeded and a later step failed.
        try? probe.deleteToken()
        return false
    }
}()

/// A store on a service name no other test — and certainly not the shipping
/// app — uses, so a failed run can never clobber the real token.
private func makeTestStore() -> KeychainTokenStore {
    KeychainTokenStore(
        service: "com.alBz.GitLabAlert.tests.\(UUID().uuidString)",
        account: "gitlab-token"
    )
}

@Suite("KeychainTokenStore", .enabled(if: keychainIsUsable, "Login keychain is unavailable to this test process"))
struct KeychainTokenStoreTests {

    @Test("write then read returns the token")
    func writeThenRead() throws {
        let store = makeTestStore()
        defer { try? store.deleteToken() }

        try store.writeToken("ghp_first_token_value")
        #expect(try store.readToken() == "ghp_first_token_value")
    }

    @Test("writing again overwrites instead of failing on a duplicate item")
    func overwrite() throws {
        let store = makeTestStore()
        defer { try? store.deleteToken() }

        try store.writeToken("ghp_first_token_value")
        try store.writeToken("ghp_second_token_value")
        #expect(try store.readToken() == "ghp_second_token_value")
    }

    @Test("reading when nothing was ever written returns nil")
    func readWhenAbsent() throws {
        let store = makeTestStore()
        defer { try? store.deleteToken() }

        #expect(try store.readToken() == nil)
    }

    @Test("delete removes the item and a later read returns nil")
    func deleteThenRead() throws {
        let store = makeTestStore()
        defer { try? store.deleteToken() }

        try store.writeToken("ghp_first_token_value")
        try store.deleteToken()
        #expect(try store.readToken() == nil)
    }

    @Test("deleting a token that is not there is a no-op, not an error")
    func deleteIsIdempotent() throws {
        let store = makeTestStore()
        try store.deleteToken()
        try store.deleteToken()
    }

    @Test("two service names are two independent items")
    func servicesAreIsolated() throws {
        let first = makeTestStore()
        let second = makeTestStore()
        defer {
            try? first.deleteToken()
            try? second.deleteToken()
        }

        try first.writeToken("ghp_first_token_value")
        #expect(try second.readToken() == nil)
        #expect(try first.readToken() == "ghp_first_token_value")
    }

    @Test("a token with non-ASCII bytes survives the round-trip")
    func unicodeToken() throws {
        let store = makeTestStore()
        defer { try? store.deleteToken() }

        let token = "ghp_ünïcødé_✓_token"
        try store.writeToken(token)
        #expect(try store.readToken() == token)
    }
}

/// Behaviour that needs no keychain access, so it must never be skipped.
@Suite("KeychainTokenStore contract")
struct KeychainTokenStoreContractTests {

    @Test("an empty token is rejected before it reaches the keychain")
    func emptyTokenIsRejected() {
        let store = makeTestStore()
        #expect(throws: KeychainError.emptyToken) { try store.writeToken("") }
    }

    @Test("errors carry the status code and never the token")
    func errorsDoNotLeakSecrets() {
        let error = KeychainError.addFailed(
            status: errSecMissingEntitlement,
            message: KeychainError.message(for: errSecMissingEntitlement)
        )
        #expect(error.status == errSecMissingEntitlement)
        #expect(error.description.contains("\(errSecMissingEntitlement)"))
        #expect(error.description.contains("ghp_") == false)

        #expect(KeychainError.malformedItem.status == nil)
        #expect(KeychainError.emptyToken.description.isEmpty == false)
    }

    @Test("the default service is the app's bundle identifier")
    func defaultService() {
        let store = KeychainTokenStore()
        #expect(store.service == "com.alBz.GitLabAlert")
        #expect(store.account == "gitlab-token")
    }
}
