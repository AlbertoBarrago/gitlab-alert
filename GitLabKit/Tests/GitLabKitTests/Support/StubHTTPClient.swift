import Foundation
@testable import GitLabKit

// MARK: - Recorded requests

/// A JSON value, kept `Sendable` so a recorded request body can cross the
/// actor boundary and still be asserted on field by field.
enum StubJSON: Sendable, Equatable, Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([StubJSON])
    case object([String: StubJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([StubJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: StubJSON].self))
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }
}

/// The GraphQL body of a recorded request.
struct RecordedGraphQL: Sendable, Decodable {
    var query: String
    var variables: [String: StubJSON]?

    /// Aliases present in the document, in `r<n>` form.
    var repositoryAliases: [String] {
        query
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains(": repository(") else { return nil }
                return trimmed.split(separator: ":").first.map { String($0).trimmingCharacters(in: .whitespaces) }
            }
    }
}

struct RecordedRequest: Sendable {
    var url: URL?
    var method: String?
    var headers: [String: String]
    var body: Data?

    func header(_ name: String) -> String? {
        if let exact = headers[name] { return exact }
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }

    var graphQL: RecordedGraphQL? {
        guard let body else { return nil }
        return try? JSONDecoder().decode(RecordedGraphQL.self, from: body)
    }

    /// The raw body as text, for asserting that the token never leaks into it.
    var bodyText: String? {
        body.flatMap { String(data: $0, encoding: .utf8) }
    }
}

// MARK: - Stub client

/// Replays canned responses and records what it was asked for.
///
/// An actor rather than a lock: `HTTPClient.send` is already `async`, so
/// isolation costs nothing and the recording is race-free by construction.
actor StubHTTPClient: HTTPClient {
    enum Outcome: Sendable {
        case response(HTTPResponse)
        case failure(GitLabError)
    }

    private var script: [Outcome]
    private let byURL: [String: Outcome]
    private var log: [RecordedRequest] = []

    /// Responses handed out in order.
    init(script: [Outcome]) {
        self.script = script
        self.byURL = [:]
    }

    init(responses: [HTTPResponse]) {
        self.init(script: responses.map(Outcome.response))
    }

    /// Responses keyed by absolute URL; every request to the same URL replays
    /// the same answer.
    init(byURL: [URL: HTTPResponse]) {
        self.script = []
        self.byURL = Dictionary(uniqueKeysWithValues: byURL.map { ($0.key.absoluteString, Outcome.response($0.value)) })
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        log.append(
            RecordedRequest(
                url: request.url,
                method: request.httpMethod,
                headers: request.allHTTPHeaderFields ?? [:],
                body: request.httpBody
            )
        )

        if let url = request.url?.absoluteString, let mapped = byURL[url] {
            return try unwrap(mapped)
        }
        guard !script.isEmpty else {
            // Loudly, not with an empty 200: a test that sends one request more
            // than it scripted has found a real bug.
            throw GitLabError.transport("StubHTTPClient exhausted after \(log.count) request(s)")
        }
        return try unwrap(script.removeFirst())
    }

    private func unwrap(_ outcome: Outcome) throws -> HTTPResponse {
        switch outcome {
        case .response(let response): return response
        case .failure(let error): throw error
        }
    }

    func requests() -> [RecordedRequest] { log }
    var requestCount: Int { log.count }
}

// MARK: - Token store

struct StubTokenStore: TokenStore {
    enum Behaviour: Sendable {
        case token(String)
        case empty
        case failure(String)
    }

    let behaviour: Behaviour

    init(_ behaviour: Behaviour = .token("ghp_stub_token_value")) {
        self.behaviour = behaviour
    }

    struct StoreFailure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    func readToken() throws -> String? {
        switch behaviour {
        case .token(let value): return value
        case .empty: return nil
        case .failure(let message): throw StoreFailure(message: message)
        }
    }

    func writeToken(_ token: String) throws {}
    func deleteToken() throws {}
}
