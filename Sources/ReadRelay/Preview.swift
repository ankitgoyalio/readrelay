import ArgumentParser
import Foundation

struct Preview: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Preview read-status changes for the initial backlog.")

    @Flag(help: "Print the JSON report instead of the summary.")
    var json = false

    @Flag(help: "Fail if Keychain access requires user interaction.")
    var unattended = false

    func run() async throws {
        let startedAt = Date()
        let paths = BetaPaths()
        _ = try paths.loadConfiguration()
        try paths.prepare()
        try await RolloutState.withSyncLock(path: paths.state.path) {
            let configuration = try paths.loadConfiguration()
            let mailboxes = try await RelayMailboxes(
                configuration: configuration, configPath: paths.config.path, unattended: unattended
            )
            let rollout = try RolloutState(
                path: paths.state.path, configuration: configuration, previewStartedAt: startedAt
            )
            let report = try await BacklogReport.preview(mailboxes: mailboxes, rollout: rollout)
            let output = try report.json() + "\n"
            try Data(output.utf8).write(to: paths.previewReport, options: .atomic)
            if json {
                print(output, terminator: "")
            } else {
                print(report.summary(label: configuration.primaryLabel))
                print("JSON report saved to \(paths.previewReport.path)")
            }
        }
    }
}

extension BacklogReport {
    func summary(label: String) -> String {
        guard !entries.isEmpty else {
            return "No labeled originals in the initial 120-hour window. There is nothing to review."
        }
        let outcomes = Dictionary(grouping: entries, by: \.outcome).mapValues(\.count)
        let proposed = outcomes[.wouldMarkRead, default: 0]
        var lines = [
            "Preview for “\(label)”",
            "Originals reviewed: \(entries.count)",
            "Forwarded copies that would be marked read: \(proposed)",
            "Originals skipped: \(entries.count - proposed)"
        ]
        let reasons: [(Outcome, String)] = [
            (.originalUnread, "Original still unread"),
            (.copyAlreadyRead, "Forwarded copy already read"),
            (.missingMessageID, "Missing or invalid Message-ID"),
            (.missingCopy, "Forwarded copy missing"),
            (.ambiguousOriginal, "Ambiguous original"),
            (.ambiguousCopy, "Ambiguous forwarded copy"),
            (.matchChanged, "Forwarded copy match changed"),
            (.originalUnavailable, "Original unavailable")
        ]
        for (outcome, reason) in reasons {
            if let count = outcomes[outcome] { lines.append("  \(reason): \(count)") }
        }
        return lines.joined(separator: "\n")
    }
}
