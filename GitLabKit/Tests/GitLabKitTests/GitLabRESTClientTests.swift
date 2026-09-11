import Foundation
import Testing
@testable import GitLabKit

@Test func verifyTokenUsesTheConfiguredGitLabInstance() async throws {
    let baseURL = try #require(URL(string: "https://gitlab.example.com"))
    let userURL = try #require(URL(string: "https://gitlab.example.com/api/v4/user"))
    let response = HTTPResponse(
        status: 200,
        body: Data("""
        {"username":"alberto","name":"Alberto Barrago","avatar_url":"https://gitlab.example.com/avatar.png","web_url":"https://gitlab.example.com/alberto"}
        """.utf8)
    )
    let http = StubHTTPClient(responses: [response])
    let client = GitLabClient(httpClient: http, tokenStore: StaticTokenStore(token: "glpat-secret"), baseURL: baseURL)

    let profile = try await client.verifyToken()

    #expect(profile.login == "alberto")
    let request = try #require((await http.requests()).first)
    #expect(request.url == userURL)
    #expect(request.header("PRIVATE-TOKEN") == "glpat-secret")
}

@Test func attributionIsDisabledWithoutMakingNetworkRequests() async throws {
    let http = StubHTTPClient(responses: [])
    let client = GitLabClient(httpClient: http, tokenStore: StaticTokenStore(token: "glpat-secret"))

    let result = try await client.fetchAttribution(repositories: ["group/project"], limit: 10)

    #expect(result.isEmpty)
    #expect((await http.requests()).isEmpty)
}

private struct StaticTokenStore: TokenStore {
    let token: String
    func readToken() throws -> String? { token }
    func writeToken(_ token: String) throws {}
    func deleteToken() throws {}
}
