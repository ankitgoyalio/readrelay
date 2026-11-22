import ArgumentParser
import CryptoKit
import Foundation

struct Approve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Approve a reviewed backlog and future eligible messages for the same mailbox pair and label."
    )

    @Argument(help: "Review code shown by readrelay preview.")
    var reviewCode: String

    func run() async throws {
        let paths = BetaPaths()
        try await paths.withConfiguredLock { configuration in
            let state = paths.state(for: configuration)
            let reviewRequired = RelayError("Run readrelay preview and use its current review code.")
            guard FileManager.default.fileExists(atPath: state.path) else { throw reviewRequired }
            let rollout = try RolloutState(path: state.path, configuration: configuration)
            guard let scope = try rollout.betaScope(), scope.reviewCode == reviewCode,
                  let digest = scope.reportDigest else { throw reviewRequired }
            try paths.requireFreshHomebrewPreview(rollout: rollout, configuration: configuration)
            // Check the local evidence first. Preview then verifies the saved scope against Gmail's current label ID.
            try paths.requireForwardingProof(for: configuration, labelID: scope.labelID)

            let changed = RelayError("The saved backlog’s preview has changed. Run readrelay preview and review it again.")
            guard let savedReport = try? Data(contentsOf: paths.previewReport(for: configuration)),
                  reviewDigest(savedReport) == digest else { throw changed }
            let mailboxes = try await paths.connect(configuration: configuration, unattended: false)
            let report = try await BacklogReport.betaPreview(mailboxes: mailboxes, rollout: rollout, configuration: configuration)
            guard Data((try report.json() + "\n").utf8) == savedReport else { throw changed }
            try rollout.approveReview()
        }
        print("Live sync approved. Run readrelay status to check the background service.")
    }
}

struct Revoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Withdraw approval and return to preview mode.")

    func run() async throws {
        let paths = BetaPaths()
        try await paths.withConfiguredLock { configuration in
            let state = paths.state(for: configuration)
            guard FileManager.default.fileExists(atPath: state.path) else { return }
            let rollout = try RolloutState(path: state.path, configuration: configuration)
            if try rollout.betaScope() != nil { try rollout.revokeReview() }
        }
        print("Write approval revoked. The background service is in preview mode.")
    }
}

func reviewDigest(_ report: Data) -> String {
    Data(SHA256.hash(data: report)).base64EncodedString()
}
