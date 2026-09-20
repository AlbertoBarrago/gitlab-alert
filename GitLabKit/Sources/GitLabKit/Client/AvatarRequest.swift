import Foundation

/// Builds the request for one remote avatar and decides whether the GitLab
/// credential is allowed to travel with it.
///
/// Avatar URLs arrive inside API payloads, and they are not guaranteed to point
/// at the configured instance: GitLab.com serves them from
/// `avatars.gitlabusercontent.com`, and a self-managed instance with Gravatar or
/// Libravatar enabled — the shipped default — hands out `gravatar.com` URLs for
/// every user who never uploaded a picture. Sending the personal access token to
/// those hosts would hand a third party a working credential for the instance,
/// so the header is attached only when the URL is on the configured origin
/// itself. Everything else is fetched anonymously, which is exactly what a
/// public avatar needs.
public enum AvatarRequest {

    /// The request to load `url`, or `nil` when it must not be loaded at all.
    ///
    /// Returns `nil` for anything that is not plain https, so a `file:` or
    /// `data:` URL in a payload can never cause a load.
    public static func make(for url: URL, origin: URL, token: String?) -> URLRequest? {
        guard url.scheme?.lowercased() == "https" else { return nil }

        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.setValue("GitLabAlert/\(GitLabKit.version)", forHTTPHeaderField: "User-Agent")

        if let token, !token.isEmpty, isSameOrigin(url, as: origin) {
            request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        }
        return request
    }

    /// Same host *and* same effective port, compared case-insensitively.
    ///
    /// The scheme is pinned to https on both sides — `Preferences` refuses any
    /// other origin and ``make(for:origin:token:)`` refuses any other URL — so
    /// the default port is 443 for both. A differing port is a different
    /// service on the same machine, which is not the instance the user
    /// authorized.
    public static func isSameOrigin(_ url: URL, as origin: URL) -> Bool {
        guard
            origin.scheme?.lowercased() == "https",
            let host = url.host?.lowercased(),
            let originHost = origin.host?.lowercased(),
            host == originHost
        else { return false }
        return (url.port ?? 443) == (origin.port ?? 443)
    }
}
