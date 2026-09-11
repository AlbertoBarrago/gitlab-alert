import Testing
@testable import GitLabKit

@Test func packageIsReachable() {
    #expect(GitLabKit.version == "0.1.0")
}
