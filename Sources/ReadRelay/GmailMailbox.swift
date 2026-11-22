import Foundation

struct RelayMailboxes {
    let primary: GmailMailbox
    let secondary: GmailMailbox
    let readRelayLabelID: String

    init(configuration: Configuration, configPath: String, unattended: Bool, homebrew: Bool = false) async throws {
        let primaryOAuth = try OAuth(role: .primary, configuration: configuration, configPath: configPath)
        let secondaryOAuth = try OAuth(role: .secondary, configuration: configuration, configPath: configPath)
        if unattended { try OAuth.preventKeychainPrompts() }
        func connect(_ oauth: OAuth) async throws -> GmailMailbox {
            do {
                return try await oauth.mailbox()
            } catch {
                let command = homebrew ? "readrelay authorize \(oauth.role.rawValue)"
                    : "readrelay authorize \(oauth.role.rawValue) --config <path>"
                throw RelayError("\(error.localizedDescription) To reconnect this mailbox, run \(command).")
            }
        }
        primary = try await connect(primaryOAuth)
        readRelayLabelID = try await primary.labelID(named: configuration.primaryLabel)
        secondary = try await connect(secondaryOAuth)
    }
}

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

    func labelID(named name: String) async throws -> String {
        struct Labels: Decodable {
            struct Label: Decodable {
                let name: String
                let id: String
            }
            let labels: [Label]
        }

        let result: Labels = try await get("labels", query: [URLQueryItem(name: "fields", value: "labels(id,name)")])
        guard let label = result.labels.first(where: { $0.name == name }) else {
            throw RelayError("The primary mailbox does not have the label “\(name)”. Create it in Gmail, add it to the forwarding filter, and try again.")
        }
        return label.id
    }

    func historyCursor() async throws -> UInt64 {
        struct Profile: Decodable { let historyId: String }
        let profile: Profile = try await get("profile", query: [URLQueryItem(name: "fields", value: "historyId")])
        guard let cursor = UInt64(profile.historyId), cursor > 0 else {
            throw RelayError("Gmail returned an invalid \(role.rawValue) history cursor.")
        }
        return cursor
    }

    struct HistoryChanges: Sendable {
        var cursor: UInt64
        var matchingSetChanged = false
        var selectedMessageChanged = false
    }

    /// Check the whole change stream. A label filter could hide an original that
    /// lost ReadRelay, or a new message that gained it after delivery.
    func changes(after cursor: UInt64, selectedID: String, matchLabelID: String? = nil) async throws -> HistoryChanges {
        struct Page: Decodable {
            struct Record: Decodable {
                struct Reference: Decodable { let id: String }
                struct MessageChange: Decodable { let message: Reference }
                struct LabelChange: Decodable {
                    let message: Reference
                    let labelIds: [String]
                }
                let id: String
                let messages: [Reference]?
                let messagesAdded: [MessageChange]?
                let messagesDeleted: [MessageChange]?
                let labelsAdded: [LabelChange]?
                let labelsRemoved: [LabelChange]?
            }
            let historyId: String
            let history: [Record]?
            let nextPageToken: String?
        }

        var changes = HistoryChanges(cursor: cursor)
        var lastRecordID = cursor
        var seenPageTokens: Set<String> = []
        var pageToken: String?
        repeat {
            var query = [
                URLQueryItem(name: "startHistoryId", value: String(cursor)),
                URLQueryItem(name: "maxResults", value: "500"),
                URLQueryItem(name: "fields", value: "historyId,nextPageToken,history(id,messages(id),"
                             + "messagesAdded(message(id)),messagesDeleted(message(id)),"
                             + "labelsAdded(message(id),labelIds),labelsRemoved(message(id),labelIds))")
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: Page = try await get("history", query: query)
            for record in page.history ?? [] {
                guard let recordID = UInt64(record.id), recordID > lastRecordID else {
                    throw RelayError("Gmail returned out-of-order \(role.rawValue) history.")
                }
                lastRecordID = recordID
                let membership = (record.messagesAdded ?? []) + (record.messagesDeleted ?? [])
                let labels = (record.labelsAdded ?? []) + (record.labelsRemoved ?? [])
                let typedIDs = Set(membership.map(\.message.id) + labels.map(\.message.id))
                let otherChange = typedIDs.isEmpty || (record.messages ?? []).contains { !typedIDs.contains($0.id) }
                if otherChange || !membership.isEmpty || labels.contains(where: { change in
                    matchLabelID.map { change.labelIds.contains($0) } ?? false
                }) {
                    changes.matchingSetChanged = true
                }
                if typedIDs.contains(selectedID) {
                    changes.selectedMessageChanged = true
                }
            }
            guard let pageCursor = UInt64(page.historyId), pageCursor >= lastRecordID else {
                throw RelayError("Gmail returned an invalid \(role.rawValue) history cursor.")
            }
            changes.cursor = pageCursor
            pageToken = page.nextPageToken
            if let pageToken, pageToken.isEmpty || !seenPageTokens.insert(pageToken).inserted {
                throw RelayError("Gmail returned an invalid \(role.rawValue) history page token.")
            }
        } while pageToken != nil
        return changes
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
            if let pageToken, pageToken.isEmpty || !seenPageTokens.insert(pageToken).inserted {
                throw RelayError("Gmail returned an invalid \(role.rawValue) message page token.")
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

    func message(id: String) async throws -> GmailMessage {
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

    func markRead(id: String) async throws -> GmailMessage {
        guard role == .secondary else {
            throw RelayError("Only the secondary mailbox can be modified.")
        }
        let fields = [URLQueryItem(name: "fields", value: "id,labelIds")]
        var request = requestFor("messages/\(id)/modify", query: fields)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"removeLabelIds":["UNREAD"]}"#.utf8)
        let updated: GmailMessage = try await GoogleHTTP.send(request, operation: "secondary Gmail message modification")
        guard updated.id == id, !updated.isUnread else {
            throw RelayError("Gmail did not confirm removal of UNREAD from the forwarded copy.")
        }
        return updated
    }

    private func get<Value: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Value {
        try await GoogleHTTP.send(requestFor(path, query: query),
                                  operation: "\(role.rawValue) Gmail \(path.split(separator: "/")[0]) request")
    }

    private func requestFor(_ path: String, query: [URLQueryItem]) -> URLRequest {
        let endpoint = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
        var url = URLComponents(url: endpoint.appending(path: path), resolvingAgainstBaseURL: false)!
        url.queryItems = query
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
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
            .map(\.value)
    }
}
