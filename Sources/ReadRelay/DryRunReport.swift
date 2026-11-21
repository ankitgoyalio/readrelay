import Foundation

struct DryRunReport: Encodable {
    let cutoffEpochMilliseconds: Int64
    let entries: [Entry]

    struct Entry: Encodable {
        let originalID: String
        let originalLabelIDs: [String]
        let forwardedCopyID: String?
        let forwardedCopyLabelIDs: [String]?
        let outcome: Outcome

        init(original: GmailMessage, copy: GmailMessage? = nil, outcome: Outcome) {
            originalID = original.id
            originalLabelIDs = (original.labelIds ?? []).sorted()
            forwardedCopyID = copy?.id
            forwardedCopyLabelIDs = copy.map { ($0.labelIds ?? []).sorted() }
            self.outcome = outcome
        }
    }

    enum Outcome: String, Encodable {
        case wouldMarkRead
        case originalUnread
        case missingMessageID
        case missingCopy
        case ambiguousOriginal
        case ambiguousCopy
        case copyAlreadyRead
    }

    static func preview(
        primary: GmailMailbox, secondary: GmailMailbox, labelID: String, cutoff: Int64
    ) async throws -> Self {
        let originals = try await primary.messages(labelID: labelID)
            .filter { $0.labelIds?.contains(labelID) == true }
            .map(IndexedMessage.init)
        let originalIndex = index(originals)
        let eligibleOriginals = try originals.filter { original in
            guard let rawDate = original.message.internalDate, let date = Int64(rawDate) else {
                throw RelayError("Gmail returned an original without a valid internal date.")
            }
            return date >= cutoff
        }
        let needsCopies = eligibleOriginals.contains { original in
            guard let id = original.messageID else { return false }
            return originalIndex[id]?.count == 1
        }
        let copyIndex = needsCopies ? try await index(secondary.messages().map(IndexedMessage.init)) : [:]

        let entries = eligibleOriginals.map { original -> Entry in
            if original.hasMultipleIDs {
                return Entry(original: original.message, outcome: .ambiguousOriginal)
            }
            guard let id = original.messageID else {
                return Entry(original: original.message, outcome: .missingMessageID)
            }
            guard originalIndex[id]?.count == 1 else {
                return Entry(original: original.message, outcome: .ambiguousOriginal)
            }
            guard let candidates = copyIndex[id], let copy = candidates.first else {
                return Entry(original: original.message, outcome: .missingCopy)
            }
            guard candidates.count == 1, copy.messageID == id else {
                return Entry(original: original.message, outcome: .ambiguousCopy)
            }

            let outcome: Outcome
            if original.message.isUnread {
                outcome = .originalUnread
            } else if copy.message.isUnread {
                outcome = .wouldMarkRead
            } else {
                outcome = .copyAlreadyRead
            }
            return Entry(original: original.message, copy: copy.message, outcome: outcome)
        }

        return Self(cutoffEpochMilliseconds: cutoff, entries: entries.sorted { $0.originalID < $1.originalID })
    }

    private static func index(_ messages: [IndexedMessage]) -> [String: [IndexedMessage]] {
        var messagesByID: [String: [IndexedMessage]] = [:]
        for message in messages {
            for id in Set(message.candidates) {
                messagesByID[id, default: []].append(message)
            }
        }
        return messagesByID
    }
}

private struct IndexedMessage {
    // Match modern RFC 5322 Message-IDs exactly. A malformed field can still
    // introduce a candidate and block a match, but cannot establish a match.
    private static let pattern = try! NSRegularExpression(
        pattern: #"<[A-Za-z0-9!#$%&'*+/=?^_`{|}~\x2d]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~\x2d]+)*@(?:[A-Za-z0-9!#$%&'*+/=?^_`{|}~\x2d]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~\x2d]+)*|\[[\x21-\x5a\x5e-\x7e]*\])>"#
    )

    let message: GmailMessage
    let candidates: [String]
    let messageID: String?
    let hasMultipleIDs: Bool

    init(_ message: GmailMessage) {
        let headers = message.messageIDHeaders
        let candidates = headers.flatMap { header in
            Self.pattern.matches(in: header, range: NSRange(header.startIndex..., in: header)).compactMap { match in
                Range(match.range, in: header).map { String(header[$0]) }
            }
        }
        self.message = message
        self.candidates = candidates
        messageID = headers.count == 1 && candidates.count == 1 && headers.first == candidates.first
            ? candidates.first
            : nil
        hasMultipleIDs = headers.count > 1 || candidates.count > 1
    }
}
