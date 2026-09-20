import Foundation
import GitLabKit
import SwiftUI
import os

/// Loads avatar images on behalf of the views.
///
/// The views used to read the token out of the Keychain themselves and attach
/// it to whatever URL the API had handed them. That is the one place where a
/// credential could leave the configured instance, so the decision now lives
/// here, next to the origin, and is made by ``AvatarRequest`` — which the tests
/// cover without a UI. Views receive a loader and never see the token.
@MainActor
final class AvatarLoader {

    /// The loader used when nothing injected one: no origin, no credential, so
    /// a forgotten injection degrades to anonymous fetches instead of leaking.
    static let anonymous = AvatarLoader(preferences: nil, tokenStore: nil)

    private let preferences: Preferences?
    private let tokenStore: (any TokenStore)?
    private let session: URLSession
    private let log = Logger(subsystem: "com.alBz.GitLabAlert", category: "avatar")

    init(preferences: Preferences?, tokenStore: (any TokenStore)?) {
        self.preferences = preferences
        self.tokenStore = tokenStore

        // Not `URLSession.shared`: its `URLCache` is on disk, and avatars
        // fetched with a credential from a private instance have no business
        // being written there. Ephemeral keeps the cache in memory, which is
        // ample for images this small.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1_024 * 1_024, diskCapacity: 0)
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    /// The image bytes, or `nil` for anything that could not or must not be
    /// loaded. Never throws: a missing avatar is a monogram, not an error.
    func imageData(for url: URL?) async -> Data? {
        guard let url else { return nil }

        let origin = preferences?.gitLabBaseURL ?? GitLabClient.defaultBaseURL
        let token = credential()
        guard let request = AvatarRequest.make(for: url, origin: origin, token: token) else {
            log.debug("avatar refused scheme=\(url.scheme ?? "none", privacy: .public)")
            return nil
        }

        do {
            let (data, response) = try await session.data(
                for: request,
                delegate: AvatarRedirectGuard(origin: origin, token: token)
            )
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                log.error("avatar request failed status=\(status, privacy: .public)")
                return nil
            }
            return data
        } catch {
            log.error("avatar request error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func credential() -> String? {
        guard let tokenStore else { return nil }
        do {
            return try tokenStore.readToken()
        } catch {
            log.error("avatar credential unavailable error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Rebuilds the request at every hop of a redirect.
///
/// `URLSession` replays the original headers — the credential included — at
/// whatever host a redirect names. A GitLab instance that bounces avatar
/// requests to Gravatar would therefore hand the token to Gravatar despite the
/// same-origin check on the first request, so each hop is re-derived through
/// ``AvatarRequest`` and loses the credential the moment it leaves the origin.
///
/// `@unchecked Sendable`: an `NSObject` subclass cannot get the checked
/// conformance, and both stored properties are immutable values.
private final class AvatarRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    private let origin: URL
    private let token: String?

    init(origin: URL, token: String?) {
        self.origin = origin
        self.token = token
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            completionHandler(nil)
            return
        }
        completionHandler(AvatarRequest.make(for: url, origin: origin, token: token))
    }
}

// MARK: - Environment

private struct AvatarLoaderKey: EnvironmentKey {
    /// `nil` rather than ``AvatarLoader/anonymous``: the default value is read
    /// outside the main actor, and a view resolves the fallback itself.
    static let defaultValue: AvatarLoader? = nil
}

extension EnvironmentValues {
    var avatarLoader: AvatarLoader? {
        get { self[AvatarLoaderKey.self] }
        set { self[AvatarLoaderKey.self] = newValue }
    }
}
