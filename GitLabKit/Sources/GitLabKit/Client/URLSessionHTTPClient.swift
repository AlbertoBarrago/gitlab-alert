import Foundation

/// `URLSession`-backed ``HTTPClient``.
///
/// Note the cache policy: GitLab sends `Cache-Control: max-age=300` on the repo
/// events endpoint, and letting `URLSession` serve that from its own cache would
/// silently hide fresh events. We manage freshness ourselves with ETags instead.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 20
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GitLabError.transport("Non-HTTP response")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key] = value
                }
            }
            return HTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch let error as GitLabError {
            throw error
        } catch {
            throw GitLabError.transport(error.localizedDescription)
        }
    }
}
