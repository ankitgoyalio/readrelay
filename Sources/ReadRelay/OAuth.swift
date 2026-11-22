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
        guard let data = try? Data(contentsOf: url) else {
            throw RelayError("Could not read the Google Desktop OAuth client JSON.")
        }
        return try decode(data, expectedEmail: expectedEmail)
    }

    static func decode(_ data: Data, expectedEmail: String) throws -> Self {
        struct DesktopClient: Decodable {
            let email: String?
            let installed: ClientCredentials
        }

        guard let client = try? JSONDecoder().decode(DesktopClient.self, from: data),
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
    let account: MailboxAccount
    let client: ClientCredentials

    var role: MailboxRole { account.role }
    var email: String { account.email }

    init(role: MailboxRole, configuration: Configuration, configPath: String, reconnectCommand: String? = nil) throws {
        let email = configuration.email(for: role)
        account = MailboxAccount(role: role, email: email, reconnectCommand: reconnectCommand)
        do {
            client = try ClientCredentials.load(
                configuration.clientFile(for: role, relativeTo: configPath), expectedEmail: email
            )
        } catch {
            throw account.failure(error.localizedDescription, nextStep: "Restore the saved Desktop OAuth client JSON.")
        }
    }

    init(role: MailboxRole, email: String, client: ClientCredentials) {
        account = MailboxAccount(role: role, email: email, reconnectCommand: nil)
        self.client = client
    }

    func authorize(importToken: Bool) async throws {
        let refreshToken: String
        if importToken {
            refreshToken = try RefreshTokenImport.read(role: role, email: email, client: client)
            _ = try await verifiedMailbox(refreshToken: refreshToken)
        } else {
            refreshToken = try await requestVerifiedRefreshToken()
        }
        try storeRefreshToken(refreshToken)
    }

    func requestVerifiedRefreshToken() async throws -> String {
        let grant = try await BrowserAuthorization.requestCode(
            clientID: client.clientID, loginHint: email, scope: role.scope
        )
        let response = try await exchange([
            "grant_type": "authorization_code",
            "code": grant.code,
            "code_verifier": grant.verifier,
            "redirect_uri": grant.redirectURI
        ])
        guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else {
            throw RelayError("Google did not return an offline refresh token.")
        }
        _ = try await verifiedMailbox(refreshToken: refreshToken)
        return refreshToken
    }

    func storeRefreshToken(_ refreshToken: String) throws {
        do {
            try RefreshTokenKeychain().save(refreshToken, account: keychainAccount)
        } catch {
            throw account.failure(error.localizedDescription, nextStep: "Unlock your login Keychain and retry.")
        }
    }

    func mailbox() async throws -> GmailMailbox {
        let refreshToken = try RefreshTokenKeychain().load(account: keychainAccount, mailbox: account)
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
        let mailbox = GmailMailbox(account: account, accessToken: token.accessToken)
        try await mailbox.verifyAccount()
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

        let response: TokenResponse
        do {
            response = try await GoogleHTTP.send(request, operation: "Google OAuth token exchange")
        } catch let error as GoogleHTTP.Failure {
            if case .http(400, "invalid_grant") = error.cause, parameters["grant_type"] == "refresh_token" {
                throw account.grantFailure("Google rejected the refresh token (invalid_grant).")
            }
            throw account.googleFailure(error)
        }
        guard let scope = response.scope, Set(scope.split(separator: " ").map(String.init)) == [role.scope] else {
            throw account.grantFailure("The Gmail grant must contain exactly \(role.scope).")
        }
        guard response.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame, !response.accessToken.isEmpty else {
            throw account.failure("Google returned an invalid access token.", nextStep: "Retry and check the status if the failure persists.")
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

    func load(account: String, mailbox: MailboxAccount) throws -> String {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw mailbox.grantFailure("The refresh token is missing from Keychain.")
        }
        if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status) {
            throw mailbox.failure("Keychain access requires interaction (status \(status)).",
                                  nextStep: "Unlock your login Keychain and run an interactive preview to allow this ReadRelay executable to access the refresh token.")
        }
        guard status == errSecSuccess else {
            throw mailbox.failure("Could not read the refresh token from Keychain (status \(status)).",
                                  nextStep: "Check access to your login Keychain and retry.")
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw mailbox.grantFailure("The refresh token in Keychain is unreadable.")
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
