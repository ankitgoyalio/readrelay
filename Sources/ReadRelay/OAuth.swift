import Foundation
import Security

struct ClientCredentials: Decodable {
    let clientID: String
    let clientSecret: String

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }

    static func load(_ url: URL, expectedEmail: String) throws -> Self {
        struct DesktopClient: Decodable {
            let email: String?
            let installed: ClientCredentials
        }

        guard let data = try? Data(contentsOf: url),
              let client = try? JSONDecoder().decode(DesktopClient.self, from: data),
              !client.installed.clientID.isEmpty, !client.installed.clientSecret.isEmpty else {
            throw RelayError("Could not read the Google Desktop OAuth client JSON.")
        }
        if let email = client.email, email.caseInsensitiveCompare(expectedEmail) != .orderedSame {
            throw RelayError("The OAuth client file is assigned to a different mailbox.")
        }
        return client.installed
    }
}

struct RefreshTokenImport: Decodable {
    let email: String
    let clientID: String
    let refreshToken: String

    static func read(role: MailboxRole, email: String, client: ClientCredentials) throws -> String {
        let input = try FileHandle.standardInput.readToEnd()
        guard let input, let imported = try? JSONDecoder().decode(Self.self, from: input),
              !imported.refreshToken.isEmpty else {
            throw RelayError("Provide a refresh token JSON on standard input.")
        }
        guard imported.email.caseInsensitiveCompare(email) == .orderedSame,
              imported.clientID == client.clientID else {
            throw RelayError("The token import does not match the configured \(role.rawValue) mailbox or client.")
        }
        return imported.refreshToken
    }
}

struct OAuth {
    let role: MailboxRole
    let email: String
    let client: ClientCredentials

    init(role: MailboxRole, configuration: Configuration, configPath: String) throws {
        self.role = role
        email = configuration.email(for: role)
        client = try ClientCredentials.load(
            configuration.clientFile(for: role, relativeTo: configPath), expectedEmail: email
        )
    }

    func authorize(importToken: Bool) async throws {
        let refreshToken: String
        if importToken {
            refreshToken = try RefreshTokenImport.read(role: role, email: email, client: client)
        } else {
            let grant = try await BrowserAuthorization.requestCode(
                clientID: client.clientID, loginHint: email, scope: role.scope
            )
            let response = try await exchange([
                "grant_type": "authorization_code",
                "code": grant.code,
                "code_verifier": grant.verifier,
                "redirect_uri": grant.redirectURI
            ])
            guard let token = response.refreshToken, !token.isEmpty else {
                throw RelayError("Google did not return an offline refresh token.")
            }
            refreshToken = token
        }

        _ = try await verifiedMailbox(refreshToken: refreshToken)
        try RefreshTokenKeychain().save(refreshToken, account: keychainAccount)
    }

    func mailbox() async throws -> GmailMailbox {
        let refreshToken = try RefreshTokenKeychain().load(account: keychainAccount)
        return try await verifiedMailbox(refreshToken: refreshToken)
    }

    static func preventKeychainPrompts() throws {
        // The existing refresh tokens use the macOS file-based Keychain.
        let status = SecKeychainSetUserInteractionAllowed(false)
        guard status == errSecSuccess else {
            throw RelayError("Could not disable Keychain interaction for this run (status \(status)).")
        }
    }

    private var keychainAccount: String {
        "\(role.rawValue):\(email.lowercased()):\(client.clientID)"
    }

    private func verifiedMailbox(refreshToken: String) async throws -> GmailMailbox {
        let token = try await exchange(["grant_type": "refresh_token", "refresh_token": refreshToken])
        let mailbox = GmailMailbox(role: role, accessToken: token.accessToken)
        try await mailbox.verifyAccount(expectedEmail: email)
        return mailbox
    }

    private func exchange(_ parameters: [String: String]) async throws -> TokenResponse {
        var form = parameters
        form["client_id"] = client.clientID
        form["client_secret"] = client.clientSecret
        // Form encoding must escape literal +, & and =, including in imported tokens.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = form.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let response: TokenResponse = try await GoogleHTTP.send(request, operation: "\(role.rawValue) OAuth token exchange")
        guard let scope = response.scope, Set(scope.split(separator: " ").map(String.init)) == [role.scope] else {
            throw RelayError("The \(role.rawValue) Gmail grant must contain exactly \(role.scope).")
        }
        guard response.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame, !response.accessToken.isEmpty else {
            throw RelayError("Google returned an invalid \(role.rawValue) access token.")
        }
        return response
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let scope: String?
        let refreshToken: String?
        let tokenType: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case scope
            case refreshToken = "refresh_token"
            case tokenType = "token_type"
        }
    }
}

private struct RefreshTokenKeychain {
    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.ankitgoyal.readrelay.oauth",
            kSecAttrAccount as String: account
        ]
    }

    func load(account: String) throws -> String {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw RelayError("A refresh token is missing from Keychain. Run readrelay authorize for that mailbox.")
        }
        if status == errSecInteractionNotAllowed {
            throw RelayError("Keychain access requires interaction. Unlock the login Keychain and allow this ReadRelay executable to access the refresh token.")
        }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw RelayError("Could not read the refresh token from Keychain (status \(status)).")
        }
        return value
    }

    func save(_ token: String, account: String) throws {
        let match = query(account: account)
        let values = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemAdd(match.merging(values) { _, updated in updated } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(match as CFDictionary, values as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw RelayError("Could not store the refresh token in Keychain (status \(status)).")
        }
    }
}
