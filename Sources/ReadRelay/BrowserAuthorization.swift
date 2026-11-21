import AppKit
import CryptoKit
import Darwin
import Foundation

enum BrowserAuthorization {
    struct Grant {
        let code: String
        let verifier: String
        let redirectURI: String
    }

    @MainActor
    static func requestCode(clientID: String, loginHint: String, scope: String) throws -> Grant {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw RelayError("Could not open the local OAuth listener.") }
        defer { close(listener) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var addressLength = socklen_t(address.sin_len)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, addressLength) }
        }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &addressLength) }
        }
        guard bound == 0, named == 0, listen(listener, 8) == 0 else {
            throw RelayError("Could not bind the local OAuth listener.")
        }

        let redirectURI = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/oauth/callback"
        let state = randomString()
        let verifier = randomString()
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var authorization = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        authorization.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "login_hint", value: loginHint)
        ]
        guard let url = authorization.url, NSWorkspace.shared.open(url) else {
            throw RelayError("Could not open the browser for Gmail authorization.")
        }
        return try receive(
            listener: listener, state: state, verifier: verifier, redirectURI: redirectURI
        )
    }

    private static func receive(listener: Int32, state: String, verifier: String, redirectURI: String) throws -> Grant {
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while ContinuousClock.now < deadline {
            var events = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&events, 1, 1_000)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0, events.revents & Int16(POLLIN) != 0 else {
                throw RelayError("The local OAuth listener stopped.")
            }
            let connection = accept(listener, nil, nil)
            if connection < 0 { continue }
            defer { close(connection) }

            var suppressSignal: Int32 = 1
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            guard setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &suppressSignal,
                             socklen_t(MemoryLayout<Int32>.size)) == 0,
                  setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                             socklen_t(MemoryLayout<timeval>.size)) == 0 else { continue }
            guard let query = callbackQuery(connection), query.filter({ $0.name == "state" }).map(\.value) == [state] else {
                respond(connection, status: "400 Bad Request", body: "Invalid authorization callback.")
                continue
            }
            let codes = query.filter { $0.name == "code" }
            guard codes.count == 1, let code = codes.first?.value, !code.isEmpty,
                  !query.contains(where: { $0.name == "error" }) else {
                respond(connection, status: "400 Bad Request", body: "Gmail authorization was not completed.")
                throw RelayError("Google did not grant Gmail authorization.")
            }

            respond(connection, status: "200 OK", body: "Authorization response received. Return to ReadRelay in Terminal.")
            return Grant(code: code, verifier: verifier, redirectURI: redirectURI)
        }
        throw RelayError("Timed out waiting for Google authorization.")
    }

    private static func callbackQuery(_ connection: Int32) -> [URLQueryItem]? {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        let newline = Data("\r\n".utf8)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while request.count < 8_192, ContinuousClock.now < deadline {
            let count = recv(connection, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            request.append(contentsOf: buffer.prefix(count))
            if let end = request.range(of: newline)?.lowerBound {
                guard let line = String(data: request.prefix(upTo: end), encoding: .utf8) else { return nil }
                let pieces = line.split(separator: " ")
                guard pieces.count == 3, pieces[0] == "GET",
                      let callback = URLComponents(string: String(pieces[1])),
                      callback.scheme == nil, callback.host == nil, callback.path == "/oauth/callback" else { return nil }
                return callback.queryItems
            }
        }
        return nil
    }

    private static func respond(_ connection: Int32, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
            + body
        let data = Data(response.utf8)
        _ = data.withUnsafeBytes { send(connection, $0.baseAddress, $0.count, 0) }
    }

    private static func randomString() -> String {
        var random = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
