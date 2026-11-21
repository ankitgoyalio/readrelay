extension Sync {
    func applyWork(
        _ savedWork: [RolloutState.Message], in batch: RolloutState.Batch, discover: Bool,
        rollout: RolloutState, configuration: Configuration
    ) async throws -> BacklogReport {
        let pending = savedWork.filter { !$0.completed }
        let cutoff = rollout.cutoff
        if pending.isEmpty, !discover {
            let entries = savedWork.map { BacklogReport.Entry(saved: $0, outcome: .completed) }
            return BacklogReport(cutoffEpochMilliseconds: cutoff, entries: entries)
        }

        if unattended { try OAuth.preventKeychainPrompts() }
        let primary = try await OAuth(role: .primary, configuration: configuration, configPath: config).mailbox()
        let labelID = try await primary.readRelayLabelID()
        let secondary = try await OAuth(role: .secondary, configuration: configuration, configPath: config).mailbox()
        let report = try await BacklogReport.scan(
            primary: primary, secondary: secondary, labelID: labelID, cutoff: cutoff,
            originalIDs: discover ? nil : Set(pending.map(\.originalID)),
            excludingOriginalIDs: Set(savedWork.filter(\.completed).map(\.originalID))
        )
        let knownOriginals = Set(savedWork.map(\.originalID))
        let discovered = report.entries.filter { !knownOriginals.contains($0.originalID) }.map {
            RolloutState.Message(originalID: $0.originalID, copyID: nil, messageID: $0.messageID, completed: false)
        }
        try rollout.saveDiscovered(discovered)
        var claimedCopies = Set(savedWork.compactMap(\.copyID))
        let byID = Dictionary(uniqueKeysWithValues: report.entries.map { ($0.originalID, $0) })
        var entries: [BacklogReport.Entry] = []
        for saved in (savedWork + discovered).sorted(by: { $0.originalID < $1.originalID }) {
            if saved.completed {
                entries.append(.init(saved: saved, outcome: .completed))
                continue
            }
            guard let current = byID[saved.originalID] else {
                entries.append(.init(saved: saved, outcome: .originalUnavailable))
                continue
            }
            guard let copyID = current.forwardedCopyID, let messageID = current.messageID else {
                entries.append(current)
                continue
            }
            let canSaveMatch = discover && saved.copyID == nil
                && (saved.messageID == nil || saved.messageID == messageID)
                && !claimedCopies.contains(copyID)
            guard canSaveMatch || current.matches(saved) else {
                entries.append(.init(saved: saved, outcome: .matchChanged))
                continue
            }

            // Refresh both members of the uniquely matched pair. Read the original
            // last so its current unread status is checked immediately before a write.
            let copy = try await secondary.message(id: copyID)
            let original = try await primary.message(id: saved.originalID)
            guard original.labelIds?.contains(labelID) == true,
                  let originalDate = original.internalDate.flatMap(Int64.init), originalDate >= cutoff else {
                entries.append(.init(saved: saved, outcome: .originalUnavailable))
                continue
            }
            guard IndexedMessage(original).messageID == messageID, IndexedMessage(copy).messageID == messageID else {
                entries.append(.init(saved: saved, outcome: .matchChanged))
                continue
            }
            if canSaveMatch {
                try rollout.saveMatch(originalID: saved.originalID, copyID: copyID, messageID: messageID)
                claimedCopies.insert(copyID)
            }

            let entry: BacklogReport.Entry
            if !copy.isUnread {
                entry = .init(original: original, copy: copy, outcome: .copyAlreadyRead)
            } else if original.isUnread {
                entries.append(.init(original: original, copy: copy, outcome: .originalUnread))
                continue
            } else {
                let updated = try await secondary.markRead(id: copyID)
                entry = .init(original: original, copy: updated, outcome: .markedRead)
            }
            // On an uncertain write or interrupted save, the next run reads Gmail
            // before attempting another modification.
            try rollout.markCompleted(originalID: saved.originalID, in: batch)
            entries.append(entry)
        }
        return BacklogReport(cutoffEpochMilliseconds: cutoff, entries: entries)
    }
}
