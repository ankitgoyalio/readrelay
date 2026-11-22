enum SyncEngine {
    static func run(
        rollout: RolloutState, originalID: String? = nil, copyID: String? = nil,
        connect: () async throws -> RelayMailboxes
    ) async throws -> BacklogReport {
        guard let current = try rollout.currentWork() else {
            throw RelayError("Run a successful dry run with this SQLite state before syncing.")
        }
        let batch = current.batch
        var work = current.messages
        if let originalID, let copyID {
            let backlog = batch == .reviewed ? work : try rollout.messages(in: .reviewed) ?? []
            guard backlog.contains(where: { $0.originalID == originalID && $0.copyID == copyID }),
                  let pair = work.first(where: { $0.originalID == originalID && $0.copyID == copyID }) else {
                throw RelayError("The requested message pair is absent from the previewed backlog.")
            }
            work = [pair]
        }
        let report = try await applyWork(
            work, in: batch, discover: batch == .ongoing && originalID == nil, rollout: rollout, connect: connect
        )
        if batch == .reviewed, originalID == nil {
            try rollout.startIncrementalSync()
        }
        return report
    }

    private static func applyWork(
        _ savedWork: [RolloutState.Message], in batch: RolloutState.Batch, discover: Bool,
        rollout: RolloutState, connect: () async throws -> RelayMailboxes
    ) async throws -> BacklogReport {
        let pending = savedWork.filter { !$0.completed }
        let cutoff = try rollout.cutoff
        if pending.isEmpty, !discover {
            let entries = savedWork.map { BacklogReport.Entry(saved: $0, outcome: .completed) }
            return BacklogReport(cutoffEpochMilliseconds: cutoff, entries: entries)
        }

        let mailboxes = try await connect()
        let primary = mailboxes.primary
        let secondary = mailboxes.secondary
        let labelID = mailboxes.readRelayLabelID
        func scan() async throws -> BacklogReport {
            try await BacklogReport.scan(mailboxes: mailboxes, cutoff: cutoff, work: savedWork, discover: discover)
        }

        // Start the change streams before listing either mailbox so changes
        // during the scan, including between list pages, can invalidate it.
        async let initialPrimaryCursor = primary.historyCursor()
        async let initialSecondaryCursor = secondary.historyCursor()
        var (primaryCursor, secondaryCursor) = try await (initialPrimaryCursor, initialSecondaryCursor)
        let report = try await scan()
        let knownOriginals = Set(savedWork.map(\.originalID))
        let discovered = report.entries.filter { !knownOriginals.contains($0.originalID) }.map(\.discoveredWork)
        try rollout.saveDiscovered(discovered)
        var claimedCopies = Set(savedWork.compactMap(\.copyID))
        var byID = Dictionary(uniqueKeysWithValues: report.entries.map { ($0.originalID, $0) })

        func recheck(
            _ saved: RolloutState.Message, copyID: String, messageID: String, canSaveMatch: Bool
        ) async throws -> CheckedPair {
            for _ in 0..<3 {
                async let fetchedCopy = secondary.message(id: copyID)
                async let fetchedOriginal = primary.message(id: saved.originalID)
                let (copy, original) = try await (fetchedCopy, fetchedOriginal)
                guard original.labelIds?.contains(labelID) == true,
                      let originalDate = original.internalDate.flatMap(Int64.init), originalDate >= cutoff else {
                    return .skipped(.init(saved: saved, outcome: .originalUnavailable))
                }
                guard IndexedMessage(original).messageID == messageID, IndexedMessage(copy).messageID == messageID else {
                    return .skipped(.init(saved: saved, outcome: .matchChanged))
                }
                if original.isUnread, copy.isUnread, !canSaveMatch {
                    return .matched(original, copy)
                }

                // A clean history read in both mailboxes validates the scan and
                // the selected messages. Gmail offers no cross-mailbox transaction,
                // so a concurrent change after these reads can still race the write.
                let originalCheckpoint = primaryCursor
                let copyCheckpoint = secondaryCursor
                async let primaryChanges = primary.changes(
                    after: originalCheckpoint, selectedID: saved.originalID, matchLabelID: labelID
                )
                async let secondaryChanges = secondary.changes(after: copyCheckpoint, selectedID: copyID)
                let (originalChanges, copyChanges) = try await (primaryChanges, secondaryChanges)
                primaryCursor = originalChanges.cursor
                secondaryCursor = copyChanges.cursor
                if originalChanges.matchingSetChanged || copyChanges.matchingSetChanged {
                    let refreshed = try await scan()
                    byID = Dictionary(uniqueKeysWithValues: refreshed.entries.map { ($0.originalID, $0) })
                    guard let current = byID[saved.originalID] else {
                        return .skipped(.init(saved: saved, outcome: .originalUnavailable))
                    }
                    guard current.forwardedCopyID != nil else { return .skipped(current) }
                    guard current.forwardedCopyID == copyID, current.messageID == messageID else {
                        return .skipped(.init(saved: saved, outcome: .matchChanged))
                    }
                    continue
                }
                if !originalChanges.selectedMessageChanged, !copyChanges.selectedMessageChanged {
                    return .matched(original, copy)
                }
            }
            throw RelayError("Gmail kept changing during match validation. Retry sync to recheck the pending pair.")
        }

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
            let canSaveMatch = discover && current.canClaimMatch(for: saved, claimedCopies: claimedCopies)
            guard canSaveMatch || current.matches(saved) else {
                entries.append(.init(saved: saved, outcome: .matchChanged))
                continue
            }

            let checked = try await recheck(saved, copyID: copyID, messageID: messageID, canSaveMatch: canSaveMatch)
            let original: GmailMessage
            let copy: GmailMessage
            switch checked {
            case .skipped(let entry):
                entries.append(entry)
                continue
            case .matched(let checkedOriginal, let checkedCopy):
                (original, copy) = (checkedOriginal, checkedCopy)
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

private enum CheckedPair {
    case matched(GmailMessage, GmailMessage)
    case skipped(BacklogReport.Entry)
}
