import Foundation

/// The authenticated user's public profile, shown in the popover header.
public struct Profile: Sendable, Codable, Hashable {
    public var login: String
    public var name: String?
    public var avatarURL: URL?
    // Kept only for decoding profiles from the first prototype. GitLab's
    // `/user` payload carries no equivalent, so nothing fills these.
    public var followers: Int
    public var following: Int
    public var publicRepoCount: Int
    public var url: URL

    public init(
        login: String,
        name: String? = nil,
        avatarURL: URL? = nil,
        followers: Int = 0,
        following: Int = 0,
        publicRepoCount: Int = 0,
        url: URL
    ) {
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
        self.followers = followers
        self.following = following
        self.publicRepoCount = publicRepoCount
        self.url = url
    }

    /// What to show when the profile has a display name and when it does not.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return login
    }
}
