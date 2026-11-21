import Foundation

struct GmailMailbox: Sendable {
    let role: MailboxRole
    let accessToken: String

    func verifyAccount(expectedEmail: String) async throws {
        struct Profile: Decodable { let emailAddress: String }
        let profile: Profile = try await get("profile", query: [URLQueryItem(name: "fields", value: "emailAddress")])
        guard profile.emailAddress.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
            throw RelayError("Google authorized a different account for the \(role.rawValue) mailbox.")
        }
    }

    func readRelayLabelID() async throws -> String {
        struct Labels: Decodable {
            struct Label: Decodable {
                let name: String
                let id: String
            }
            let labels: [Label]
        }

        let result: Labels = try await get("labels", query: [URLQueryItem(name: "fields", value: "labels(id,name)")])
        guard let label = result.labels.first(where: { $0.name == "ReadRelay" }) else {
            throw RelayError("The primary mailbox does not have a ReadRelay label.")
        }
        return label.id
    }

    /// With gmail.metadata, labels are the only available primary selection.
    /// Scan the whole secondary mailbox so copies outside the initial window
    /// and duplicates hidden by normal Gmail views still participate in matching.
    func messages(labelID: String? = nil) async throws -> [GmailMessage] {
        struct Page: Decodable {
            struct Reference: Decodable { let id: String }
            let messages: [Reference]?
            let nextPageToken: String?
        }

        var messages: [GmailMessage] = []
        var seenIDs: Set<String> = []
        var seenPageTokens: Set<String> = []
        var pageToken: String?
        repeat {
            var query = [
                URLQueryItem(name: "maxResults", value: "500"),
                URLQueryItem(name: "includeSpamTrash", value: "true"),
                URLQueryItem(name: "fields", value: "messages(id),nextPageToken")
            ]
            if let labelID { query.append(URLQueryItem(name: "labelIds", value: labelID)) }
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: Page = try await get("messages", query: query)
            let ids = (page.messages ?? []).map(\.id).filter { seenIDs.insert($0).inserted }
            messages.append(contentsOf: try await metadata(for: ids))
            pageToken = page.nextPageToken
            if let pageToken, !seenPageTokens.insert(pageToken).inserted {
                throw RelayError("Gmail returned a repeated \(role.rawValue) message page.")
            }
        } while pageToken != nil
        return messages
    }

    private func metadata(for ids: [String]) async throws -> [GmailMessage] {
        try await withThrowingTaskGroup(of: GmailMessage.self) { group in
            var remaining = ids.makeIterator()
            for _ in 0..<min(ids.count, 4) {
                guard let id = remaining.next() else { break }
                group.addTask { try await message(id: id) }
            }

            var results: [GmailMessage] = []
            while let message = try await group.next() {
                results.append(message)
                if let id = remaining.next() {
                    group.addTask { try await self.message(id: id) }
                }
            }
            return results
        }
    }

    private func message(id: String) async throws -> GmailMessage {
        let message: GmailMessage = try await get("messages/\(id)", query: [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "Message-ID"),
            URLQueryItem(name: "fields", value: "id,internalDate,labelIds,payload(headers(name,value))")
        ])
        guard message.id == id else {
            throw RelayError("Gmail returned an unexpected \(role.rawValue) message identifier.")
        }
        return message
    }

    private func get<Value: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Value {
        let endpoint = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
        var url = URLComponents(url: endpoint.appending(path: path), resolvingAgainstBaseURL: false)!
        url.queryItems = query
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await GoogleHTTP.read(request, operation: "\(role.rawValue) Gmail \(path.split(separator: "/")[0]) request")
    }
}


struct GmailMessage: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        struct Header: Decodable, Sendable {
            let name: String
            let value: String
        }
        let headers: [Header]?
    }

    let id: String
    let internalDate: String?
    let labelIds: [String]?
    let payload: Payload?

    var isUnread: Bool {
        labelIds?.contains("UNREAD") == true
    }

    var messageIDHeaders: [String] {
        (payload?.headers ?? [])
            .filter { $0.name.caseInsensitiveCompare("Message-ID") == .orderedSame }
            .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
