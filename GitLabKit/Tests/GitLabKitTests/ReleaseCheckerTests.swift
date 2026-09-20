import Foundation
import Testing

@testable import GitLabKit

@Suite("ReleaseVersion")
struct ReleaseVersionTests {

    @Test("dotted versions compare by number, not by string")
    func numericOrdering() throws {
        let nine = try #require(ReleaseVersion("0.1.9"))
        let ten = try #require(ReleaseVersion("0.1.10"))
        // The bug this exists to prevent: "0.1.10" < "0.1.9" as strings.
        #expect(nine < ten)
        #expect(try #require(ReleaseVersion("0.2.0")) > ten)
        #expect(try #require(ReleaseVersion("1.0.0")) > #require(ReleaseVersion("0.99.99")))
    }

    @Test("a leading v is accepted, since tags carry one")
    func tagPrefix() throws {
        #expect(try #require(ReleaseVersion("v0.1.6")) == #require(ReleaseVersion("0.1.6")))
    }

    @Test("missing components read as zero")
    func shorterVersionsAreEqual() throws {
        #expect(try #require(ReleaseVersion("1.2")) == #require(ReleaseVersion("1.2.0")))
        #expect(try #require(ReleaseVersion("1.2.1")) > #require(ReleaseVersion("1.2")))
    }

    @Test("anything that is not dotted integers is refused", arguments: [
        "", "1.2.beta", "nightly", "1..2", "-1.0", "v", "1.2.3-rc1"
    ])
    func malformedIsRefused(raw: String) {
        #expect(ReleaseVersion(raw) == nil)
    }
}

@Suite("GitHubReleaseChecker")
struct GitHubReleaseCheckerTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func payload(tag: String, url: String = "https://github.com/AlbertoBarrago/gitlab-alert/releases/tag/v0.1.6") -> HTTPResponse {
        let json = """
        {"tag_name":"\(tag)","html_url":"\(url)","published_at":"2026-09-20T10:00:00Z"}
        """
        return HTTPResponse(status: 200, body: Data(json.utf8))
    }

    @Test("a newer tag is an available update")
    func newerTagIsAnUpdate() async throws {
        let http = StubHTTPClient(responses: [payload(tag: "v0.1.6")])
        let check = try await GitHubReleaseChecker(httpClient: http).check(currentVersion: "0.1.5", now: now)

        #expect(check.isUpdateAvailable)
        #expect(check.latest.description == "0.1.6")
        #expect(check.checkedAt == now)
        #expect(check.publishedAt != nil)

        let request = try #require((await http.requests()).first)
        #expect(request.url?.absoluteString == "https://api.github.com/repos/AlbertoBarrago/gitlab-alert/releases/latest")
        // No credential of any kind leaves with this request.
        #expect(request.header("Authorization") == nil)
        #expect(request.header("PRIVATE-TOKEN") == nil)
    }

    @Test("the same version is not an update")
    func sameVersionIsNotAnUpdate() async throws {
        let http = StubHTTPClient(responses: [payload(tag: "v0.1.5")])
        let check = try await GitHubReleaseChecker(httpClient: http).check(currentVersion: "0.1.5", now: now)
        #expect(!check.isUpdateAvailable)
    }

    /// A build ahead of the published release — the maintainer's own — must not
    /// be told to downgrade.
    @Test("a newer local build is not an update")
    func localBuildAheadIsNotAnUpdate() async throws {
        let http = StubHTTPClient(responses: [payload(tag: "v0.1.5")])
        let check = try await GitHubReleaseChecker(httpClient: http).check(currentVersion: "0.1.6", now: now)
        #expect(!check.isUpdateAvailable)
    }

    @Test("a tag that is not a version is refused rather than announced")
    func unparsableTagIsRefused() async throws {
        let http = StubHTTPClient(responses: [payload(tag: "nightly")])
        await #expect(throws: ReleaseCheckError.self) {
            try await GitHubReleaseChecker(httpClient: http).check(currentVersion: "0.1.5", now: now)
        }
    }

    @Test("a non-https release URL is refused")
    func insecureReleaseURLIsRefused() async throws {
        let http = StubHTTPClient(responses: [payload(tag: "v0.2.0", url: "http://example.com/release")])
        await #expect(throws: ReleaseCheckError.self) {
            try await GitHubReleaseChecker(httpClient: http).check(currentVersion: "0.1.5", now: now)
        }
    }

    @Test("being rate limited is its own outcome")
    func rateLimitIsDistinct() async throws {
        let http = StubHTTPClient(responses: [HTTPResponse(status: 403)])
        await #expect(throws: ReleaseCheckError.rateLimited) {
            try await GitHubReleaseChecker(httpClient: http).check(currentVersion: "0.1.5", now: now)
        }
    }

    @Test("a broken payload does not crash the check")
    func brokenPayload() async throws {
        let http = StubHTTPClient(responses: [HTTPResponse(status: 200, body: Data("not json".utf8))])
        await #expect(throws: ReleaseCheckError.self) {
            try await GitHubReleaseChecker(httpClient: http).check(currentVersion: "0.1.5", now: now)
        }
    }
}
