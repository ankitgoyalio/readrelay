extension Sync {
    func applyBacklog(
        _ backlog: [RolloutState.Message], rollout: RolloutState, configuration: Configuration
    ) async throws -> BacklogReport {
        let pending = backlog.filter { !$0.completed }
        let cutoff = rollout.cutoff
        if pending.isEmpty {
            let entries = backlog.map { BacklogReport.Entry(saved: $0, outcome: .completed) }
            return BacklogReport(cutoffEpochMilliseconds: cutoff, entries: entries)
        }

        let primary = try await OAuth(role: .primary, configuration: configuration, configPath: config).mailbox()
        let labelID = try await primary.readRelayLabelID()
        let secondary = try await OAuth(role: .secondary, configuration: configuration, configPath: config).mailbox()
        let report = try await BacklogReport.scan(
            primary: primary, secondary: secondary, labelID: labelID, cutoff: cutoff,
            originalIDs: Set(pending.map(\.originalID))
        ).rechecking(pending)
        let byID = Dictionary(uniqueKeysWithValues: report.entries.map { ($0.originalID, $0) })
        var entries: [BacklogReport.Entry] = []
        for saved in backlog {
            if saved.completed {
                entries.append(.init(saved: saved, outcome: .completed))
                continue
            }
            guard let current = byID[saved.originalID] else {
                throw RelayError("Could not recheck the previewed original message.")
            }
            guard current.matches(saved), let copyID = saved.copyID, let messageID = saved.messageID else {
                entries.append(current)
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
            try rollout.markCompleted(originalID: saved.originalID)
            entries.append(entry)
        }
        return BacklogReport(cutoffEpochMilliseconds: cutoff, entries: entries)
    }
}
