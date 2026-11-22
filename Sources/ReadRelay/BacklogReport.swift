import Foundation

struct BacklogReport: Encodable {
    let cutoffEpochMilliseconds: Int64
    let entries: [Entry]

    struct Entry: Encodable {
        let originalID: String
        let originalLabelIDs: [String]
        let forwardedCopyID: String?
        let forwardedCopyLabelIDs: [String]?
        let outcome: Outcome
        let messageID: String?

        private enum CodingKeys: String, CodingKey {
            case originalID, originalLabelIDs, forwardedCopyID, forwardedCopyLabelIDs, outcome
        }

        init(original: GmailMessage, copy: GmailMessage? = nil, messageID: String? = nil, outcome: Outcome) {
            originalID = original.id
            originalLabelIDs = (original.labelIds ?? []).sorted()
            forwardedCopyID = copy?.id
            forwardedCopyLabelIDs = copy.map { ($0.labelIds ?? []).sorted() }
            self.messageID = messageID
            self.outcome = outcome
        }

        init(saved: RolloutState.Message, outcome: Outcome) {
            originalID = saved.originalID
            originalLabelIDs = []
            forwardedCopyID = saved.copyID
            forwardedCopyLabelIDs = nil
            messageID = nil
            self.outcome = outcome
        }

        func matches(_ saved: RolloutState.Message) -> Bool {
            forwardedCopyID != nil && forwardedCopyID == saved.copyID && messageID == saved.messageID
        }

        func canClaimMatch(for saved: RolloutState.Message, claimedCopies: Set<String>) -> Bool {
            guard let forwardedCopyID, let messageID else { return false }
            return saved.copyID == nil && (saved.messageID == nil || saved.messageID == messageID)
                && !claimedCopies.contains(forwardedCopyID)
        }

        var discoveredWork: RolloutState.Message {
            RolloutState.Message(originalID: originalID, copyID: nil, messageID: messageID, completed: false)
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
        case markedRead
        case completed
        case matchChanged
        case originalUnavailable
    }

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    func rechecking(_ backlog: [RolloutState.Message]) -> Self {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.originalID, $0) })
        let checked = backlog.map { saved -> Entry in
            guard let current = byID[saved.originalID] else {
                return Entry(saved: saved, outcome: .originalUnavailable)
            }
            if current.forwardedCopyID != nil, !current.matches(saved) {
                return Entry(saved: saved, outcome: .matchChanged)
            }
            return current
        }
        return Self(cutoffEpochMilliseconds: cutoffEpochMilliseconds, entries: checked)
    }

    static func preview(mailboxes: RelayMailboxes, rollout: RolloutState) async throws -> Self {
        let backlog = try rollout.messages(in: .reviewed)
        let report = try await scan(
            primary: mailboxes.primary, secondary: mailboxes.secondary,
            labelID: mailboxes.primaryLabelID, cutoff: rollout.cutoff,
            originalIDs: backlog.map { Set($0.map(\.originalID)) }
        )
        if let backlog { return report.rechecking(backlog) }
        try rollout.savePreview(report)
        return report
    }

    static func betaPreview(
        mailboxes: RelayMailboxes, rollout: RolloutState, configuration: Configuration
    ) async throws -> Self {
        let labelID = mailboxes.primaryLabelID
        if let work = try rollout.currentWork() {
            try rollout.requireBetaLabel(labelID)
            let discover = work.batch == .ongoing
            let report = try await scan(mailboxes: mailboxes, cutoff: rollout.cutoff, work: work.messages, discover: discover)
            return report.recheckingRunnable(work.messages, discover: discover)
        }

        let report = try await scan(
            primary: mailboxes.primary, secondary: mailboxes.secondary, labelID: labelID, cutoff: rollout.cutoff
        )
        try rollout.savePreview(report, beta: (configuration, labelID))
        return report
    }

    private func recheckingRunnable(_ work: [RolloutState.Message], discover: Bool) -> Self {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.originalID, $0) })
        let knownOriginals = Set(work.map(\.originalID))
        let discovered = entries.filter { !knownOriginals.contains($0.originalID) }.map(\.discoveredWork)
        let pending = (work + discovered).filter { !$0.completed }
        let claimedCopies = Set(work.compactMap(\.copyID))
        let rechecked = pending.map { saved -> Entry in
            guard let current = byID[saved.originalID] else {
                return Entry(saved: saved, outcome: .originalUnavailable)
            }
            if current.forwardedCopyID != nil, !current.matches(saved),
               !(discover && current.canClaimMatch(for: saved, claimedCopies: claimedCopies)) {
                return Entry(saved: saved, outcome: .matchChanged)
            }
            return current
        }
        return Self(cutoffEpochMilliseconds: cutoffEpochMilliseconds,
                    entries: rechecked.sorted { $0.originalID < $1.originalID })
    }

    static func scan(
        mailboxes: RelayMailboxes, cutoff: Int64, work: [RolloutState.Message], discover: Bool
    ) async throws -> Self {
        let originalIDs = discover ? nil : Set(work.filter { !$0.completed }.map(\.originalID))
        let completedIDs = Set(work.filter(\.completed).map(\.originalID))
        return try await scan(
            primary: mailboxes.primary, secondary: mailboxes.secondary, labelID: mailboxes.primaryLabelID,
            cutoff: cutoff, originalIDs: originalIDs, excludingOriginalIDs: completedIDs
        )
    }

    private static func scan(
        primary: GmailMailbox, secondary: GmailMailbox, labelID: String, cutoff: Int64,
        originalIDs: Set<String>? = nil, excludingOriginalIDs: Set<String> = []
    ) async throws -> Self {
        if originalIDs?.isEmpty == true { return Self(cutoffEpochMilliseconds: cutoff, entries: []) }
        let originals = try await primary.messages(labelID: labelID)
            .filter { $0.labelIds?.contains(labelID) == true }
            .map(IndexedMessage.init)
        let originalIndex = index(originals)
        let eligibleOriginals = try originals.filter { original in
            if excludingOriginalIDs.contains(original.message.id) { return false }
            if let originalIDs, !originalIDs.contains(original.message.id) { return false }
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
            let copy: GmailMessage
            switch IndexedMessage.match(id, among: copyIndex[id, default: []]) {
            case .missing:
                return Entry(original: original.message, messageID: id, outcome: .missingCopy)
            case .ambiguous:
                return Entry(original: original.message, messageID: id, outcome: .ambiguousCopy)
            case .unique(let matched):
                copy = matched
            }

            let outcome: Outcome
            if original.message.isUnread {
                outcome = .originalUnread
            } else if copy.isUnread {
                outcome = .wouldMarkRead
            } else {
                outcome = .copyAlreadyRead
            }
            return Entry(original: original.message, copy: copy, messageID: id, outcome: outcome)
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

struct IndexedMessage {
    // Match modern RFC 5322 Message-IDs exactly. A malformed field can still
    // introduce a candidate and block a match, but cannot establish a match.
    private static let pattern = try! NSRegularExpression(
        pattern: #"<[A-Za-z0-9!#$%&'*+/=?^_`{|}~\x2d]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~\x2d]+)*@(?:[A-Za-z0-9!#$%&'*+/=?^_`{|}~\x2d]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~\x2d]+)*|\[[\x21-\x5a\x5e-\x7e]*\])>"#
    )

    let message: GmailMessage
    let candidates: [String]
    let messageID: String?
    let hasMultipleIDs: Bool

    enum Match {
        case missing
        case ambiguous
        case unique(GmailMessage)
    }

    static func knownID(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = trimmed.hasPrefix("<") ? trimmed : "<\(trimmed)>"
        let range = NSRange(id.startIndex..., in: id)
        return pattern.firstMatch(in: id, options: .anchored, range: range)?.range == range ? id : nil
    }

    // Candidates include malformed headers so an uncertain duplicate blocks a match.
    static func match(_ id: String, among candidates: [Self]) -> Match {
        guard let candidate = candidates.first else { return .missing }
        guard candidates.count == 1, candidate.messageID == id else { return .ambiguous }
        return .unique(candidate.message)
    }

    init(_ message: GmailMessage) {
        let headers = message.messageIDHeaders.map(Self.parse)
        let candidates = headers.flatMap(\.candidates)
        self.message = message
        self.candidates = candidates
        messageID = headers.count == 1 && candidates.count == 1 && headers.first?.wellFormed == true
            ? candidates.first
            : nil
        hasMultipleIDs = headers.count > 1 || candidates.count > 1
    }

    private static func parse(_ header: String) -> (candidates: [String], wellFormed: Bool) {
        let units = Array(header.utf16)
        let source = header as NSString
        var candidates: [String] = []
        var wellFormed = true
        var malformedComment = false
        var cursor = 0
        while cursor < units.count {
            if units[cursor] == 60, let match = pattern.firstMatch(
                in: header, options: .anchored, range: NSRange(location: cursor, length: units.count - cursor)
            ) {
                candidates.append(source.substring(with: match.range))
                cursor = NSMaxRange(match.range)
                continue
            }
            if let end = whitespaceEnd(units, at: cursor) {
                cursor = end
                continue
            }
            if units[cursor] == 40, !malformedComment {
                if let end = commentEnd(units, at: cursor) {
                    cursor = end
                    continue
                }
                // An invalid comment cannot hide a potential duplicate in the rest of the field.
                malformedComment = true
            }
            wellFormed = false
            cursor += 1
        }
        return (candidates, wellFormed)
    }

    private static func whitespaceEnd(_ units: [UInt16], at cursor: Int) -> Int? {
        func isWSP(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 }
        if isWSP(units[cursor]) { return cursor + 1 }
        if units[cursor] == 13, cursor + 2 < units.count, units[cursor + 1] == 10, isWSP(units[cursor + 2]) {
            return cursor + 3
        }
        return nil
    }

    private static func commentEnd(_ units: [UInt16], at opening: Int) -> Int? {
        var depth = 1
        var cursor = opening + 1
        while cursor < units.count {
            switch units[cursor] {
            case 40:
                depth += 1
            case 41:
                depth -= 1
                if depth == 0 { return cursor + 1 }
            case 92:
                // RFC 5322 quoted-pair, including obsolete US-ASCII pairs.
                cursor += 1
                guard cursor < units.count, units[cursor] <= 127 else { return nil }
            case 33...39, 42...91, 93...126, 1...8, 11...12, 14...31, 127:
                break
            default:
                guard let end = whitespaceEnd(units, at: cursor) else { return nil }
                cursor = end
                continue
            }
            cursor += 1
        }
        return nil
    }
}
