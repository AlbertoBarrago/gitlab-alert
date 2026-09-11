import Foundation
import Security

/// Every way the keychain can refuse us, carried as a typed value with the raw
/// `OSStatus` so the UI can explain itself and tests can assert on the cause.
///
/// The token value is never part of a case payload, a message, or a
/// description: an error that escapes into a log must not leak the secret.
public enum KeychainError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `SecItemAdd` failed for a reason other than a duplicate item.
    case addFailed(status: OSStatus, message: String)
    /// The item existed, and `SecItemUpdate` on it failed too.
    case updateFailed(status: OSStatus, message: String)
    case readFailed(status: OSStatus, message: String)
    case deleteFailed(status: OSStatus, message: String)
    /// The item exists but its data is not a non-empty UTF-8 string, so it was
    /// not written by us — surfacing it beats handing the caller garbage.
    case malformedItem
    /// Refusing to store an empty token: it is indistinguishable from
    /// "no token yet" on the way back out.
    case emptyToken

    public var status: OSStatus? {
        switch self {
        case .addFailed(let status, _), .updateFailed(let status, _),
             .readFailed(let status, _), .deleteFailed(let status, _):
            return status
        case .malformedItem, .emptyToken:
            return nil
        }
    }

    public var message: String {
        switch self {
        case .addFailed(_, let message), .updateFailed(_, let message),
             .readFailed(_, let message), .deleteFailed(_, let message):
            return message
        case .malformedItem:
            return "The stored keychain item is not a valid token."
        case .emptyToken:
            return "An empty token cannot be stored."
        }
    }

    public var description: String {
        guard let status else { return message }
        return "\(message) (OSStatus \(status))"
    }

    static func message(for status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
    }
}

/// The GitLab token in the login keychain, hand-rolled over the `SecItem` API.
///
/// Stored as a `kSecClassGenericPassword` in the user's file-based login
/// keychain. The data protection keychain requires access-group entitlements
/// authorized by an Apple provisioning profile; source builds signed with this
/// project's stable local certificate do not have one and fail with
/// `errSecMissingEntitlement`. The file-based keychain instead grants access to
/// the app's designated requirement, which remains stable across rebuilds.
///
/// Accessibility is `WhenUnlockedThisDeviceOnly` and `synchronizable` is false:
/// a personal access token has no business in an iCloud keychain backup.
public struct KeychainTokenStore: TokenStore {
    /// Keychain service. Injectable so tests never touch the app's real item.
    public let service: String
    /// Keychain account: the label under which the token is filed.
    public let account: String

    public init(service: String = "com.alBz.GitLabAlert", account: String = "gitlab-token") {
        self.service = service
        self.account = account
    }

    /// The attributes that identify our single item. Used verbatim as the
    /// lookup query and as the base of the add attributes, so an add and a
    /// later read can never disagree about which item they mean.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func readToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard
                let data = item as? Data,
                let token = String(data: data, encoding: .utf8),
                !token.isEmpty
            else { throw KeychainError.malformedItem }
            return token
        case errSecItemNotFound:
            // Not an error: onboarding has simply not happened yet.
            return nil
        default:
            throw KeychainError.readFailed(status: status, message: KeychainError.message(for: status))
        }
    }

    public func writeToken(_ token: String) throws {
        guard !token.isEmpty else { throw KeychainError.emptyToken }
        let data = Data(token.utf8)

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else {
            throw KeychainError.addFailed(status: addStatus, message: KeychainError.message(for: addStatus))
        }

        // Replacing a token is the common case (rotation, fixing a typo), so a
        // duplicate is expected rather than exceptional.
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw KeychainError.updateFailed(status: updateStatus, message: KeychainError.message(for: updateStatus))
        }
    }

    public func deleteToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        // Deleting what is not there is a success: sign-out must be idempotent.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status, message: KeychainError.message(for: status))
        }
    }
}
