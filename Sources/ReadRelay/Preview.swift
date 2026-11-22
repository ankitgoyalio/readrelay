import ArgumentParser
import Foundation

struct Preview: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Preview read-status changes for the configured mailbox pair.")

    @Flag(help: "Print the JSON report instead of the summary.")
    var json = false

    @Flag(help: "Fail if Keychain access requires user interaction.")
    var unattended = false

    func run() async throws {
        let startedAt = Date()
        let paths = BetaPaths()
        try await paths.withConfiguredLock { configuration in
            let mailboxes = try await paths.connect(configuration: configuration, unattended: unattended)
            let rollout = try RolloutState(
                path: paths.state(for: configuration).path, configuration: configuration,
                preview: .beta(startedAt)
            )
            let report = try await BacklogReport.betaPreview(mailboxes: mailboxes, rollout: rollout, configuration: configuration)
            let output = try report.json() + "\n"
            let data = Data(output.utf8)
            let reportFile = paths.previewReport(for: configuration)
            try data.write(to: reportFile, options: .atomic)
            if json {
                print(output, terminator: "")
            } else {
                let code = UUID().uuidString
                try rollout.recordReview(code: code, digest: reviewDigest(data))
                print("Mailbox pair: \(configuration.primaryEmail) → \(configuration.secondaryEmail)")
                print("Primary label: \(configuration.primaryLabel)")
                print(report.summary())
                print("JSON report saved to \(reportFile.path)")
                print("To approve the reviewed work and future eligible messages in this scope, run:")
                print("  readrelay approve \(code)")
            }
        }
    }
}

extension BacklogReport {
    func summary() -> String {
        guard !entries.isEmpty else {
            return "No pending eligible originals to review."
        }
        let outcomes = Dictionary(grouping: entries, by: \.outcome).mapValues(\.count)
        let proposed = outcomes[.wouldMarkRead, default: 0]
        var lines = [
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
