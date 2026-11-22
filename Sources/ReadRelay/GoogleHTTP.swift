import Foundation

enum GoogleHTTP {
    struct Failure: LocalizedError {
        enum Cause {
            case network(Int)
            case http(Int, String?)
            case invalidResponse
            case invalidJSON
        }

        let operation: String
        let cause: Cause

        var errorDescription: String? {
            switch cause {
            case .network(let code): "\(operation) failed (network error \(code))."
            case .http(let status, let reason):
                "\(operation) failed (HTTP \(status)\(reason.map { ", \($0)" } ?? ""))."
            case .invalidResponse: "\(operation) returned an invalid HTTP response."
            case .invalidJSON: "\(operation) returned unexpected JSON."
            }
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }()

    static func send<Value: Decodable>(_ request: URLRequest, operation: String) async throws -> Value {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Failure(operation: operation, cause: .network(error.errorCode))
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure(operation: operation, cause: .invalidResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure(operation: operation, cause: .http(http.statusCode, errorReason(from: data)))
        }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw Failure(operation: operation, cause: .invalidJSON)
        }
    }

    private static func errorReason(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let error = json["error"] as? [String: Any]
        let details = error?["details"] as? [[String: Any]]
        let errors = error?["errors"] as? [[String: Any]]
        let reason = json["error"] as? String ?? details?.first?["reason"] as? String
            ?? errors?.first?["reason"] as? String
            ?? error?["status"] as? String
        guard let reason, !reason.isEmpty, reason.utf8.count <= 64, reason.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
        }) else { return nil }
        return reason
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
