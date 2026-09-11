import Foundation

/// A single HTTP response, reduced to the parts this app cares about.
///
/// Using a value type instead of `HTTPURLResponse` is what makes the whole data
/// layer testable: a fake client can replay recorded fixtures with no network.
public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    /// Header names are matched case-insensitively via ``header(_:)``.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup — HTTP/2 lowercases names, HTTP/1.1 does not.
    public func header(_ name: String) -> String? {
        if let exact = headers[name] { return exact }
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }

    public var isNotModified: Bool { status == 304 }
    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// The seam between the client and the network. Production uses
/// ``URLSessionHTTPClient``; tests inject a replaying fake.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}
