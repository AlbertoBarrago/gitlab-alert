import Foundation
import Testing

@testable import GitLabKit

@Suite("AvatarRequest")
struct AvatarRequestTests {

    private let origin = URL(string: "https://gitlab.example.com")!
    private let token = "glpat-secret"

    private func header(_ request: URLRequest?) -> String? {
        request?.value(forHTTPHeaderField: "PRIVATE-TOKEN")
    }

    @Test("an avatar on the configured origin carries the token")
    func sameOriginIsAuthenticated() {
        let url = URL(string: "https://gitlab.example.com/uploads/-/system/user/avatar/1/avatar.png")!
        #expect(header(AvatarRequest.make(for: url, origin: origin, token: token)) == token)
    }

    @Test("the host comparison ignores case")
    func hostComparisonIsCaseInsensitive() {
        let url = URL(string: "https://GitLab.Example.COM/uploads/avatar.png")!
        #expect(header(AvatarRequest.make(for: url, origin: origin, token: token)) == token)
    }

    @Test("Gravatar never receives the token")
    func gravatarIsAnonymous() {
        let url = URL(string: "https://www.gravatar.com/avatar/205e460b479e2e5b48aec07710c08d50")!
        let request = AvatarRequest.make(for: url, origin: origin, token: token)
        #expect(request != nil)
        #expect(header(request) == nil)
    }

    @Test("GitLab.com's avatar CDN is not the configured origin either")
    func avatarCDNIsAnonymous() {
        let url = URL(string: "https://avatars.gitlabusercontent.com/u/583231")!
        let request = AvatarRequest.make(for: url, origin: URL(string: "https://gitlab.com")!, token: token)
        #expect(request != nil)
        #expect(header(request) == nil)
    }

    @Test("a sibling host under the same domain is not the origin")
    func siblingHostIsAnonymous() {
        let url = URL(string: "https://evil.gitlab.example.com/avatar.png")!
        #expect(header(AvatarRequest.make(for: url, origin: origin, token: token)) == nil)
    }

    @Test("a different port on the same host is a different service")
    func differentPortIsAnonymous() {
        let url = URL(string: "https://gitlab.example.com:8443/avatar.png")!
        #expect(header(AvatarRequest.make(for: url, origin: origin, token: token)) == nil)
    }

    @Test("an explicit :443 still matches the default port")
    func explicitDefaultPortMatches() {
        let url = URL(string: "https://gitlab.example.com:443/avatar.png")!
        #expect(header(AvatarRequest.make(for: url, origin: origin, token: token)) == token)
    }

    @Test("without a token nothing is attached")
    func noTokenAttachesNothing() {
        let url = URL(string: "https://gitlab.example.com/avatar.png")!
        #expect(header(AvatarRequest.make(for: url, origin: origin, token: nil)) == nil)
        #expect(header(AvatarRequest.make(for: url, origin: origin, token: "")) == nil)
    }

    @Test("non-https URLs are refused outright", arguments: [
        "http://gitlab.example.com/avatar.png",
        "file:///etc/passwd",
        "data:image/png;base64,iVBORw0KGgo="
    ])
    func nonHTTPSIsRefused(raw: String) {
        let url = URL(string: raw)!
        #expect(AvatarRequest.make(for: url, origin: origin, token: token) == nil)
    }

    @Test("a non-https origin never authenticates anything")
    func insecureOriginIsRefused() {
        let url = URL(string: "https://gitlab.example.com/avatar.png")!
        let insecure = URL(string: "http://gitlab.example.com")!
        #expect(header(AvatarRequest.make(for: url, origin: insecure, token: token)) == nil)
    }
}
