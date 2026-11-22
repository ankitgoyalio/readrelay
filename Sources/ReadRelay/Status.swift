import ArgumentParser
import Foundation

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the background service's sync health.")

    func run() throws {
        let paths = BetaPaths()
        let files = FileManager.default
        var configuration: Configuration?
        var isLive = false
        var lastSuccess: Date?
        var setupMessage: String?
        if !files.fileExists(atPath: paths.config.path) {
            setupMessage = "Setup: Run readrelay setup first."
        } else {
            do {
                let current = try paths.loadConfiguration()
                configuration = current
                let state = paths.state(for: current)
                if files.fileExists(atPath: state.path) {
                    let rollout = try RolloutState(path: state.path, configuration: current)
                    let scope = try rollout.betaScope()
                    isLive = scope?.approvedReviewCode != nil
                    let dates = [try rollout.lastHomebrewPreview(), scope?.lastLiveRun].compactMap { $0 }
                    lastSuccess = dates.max()
                }
            } catch {
                setupMessage = "Saved state: \(error.localizedDescription)"
            }
        }
        print(isLive ? "Mode: Live" : "Mode: Preview")
        if let configuration {
            print("Mailbox pair: \(configuration.primaryEmail) → \(configuration.secondaryEmail)")
            print("Primary label: \(configuration.primaryLabel)")
        }
        if let setupMessage { print(setupMessage) }
        print("Last successful run: \(lastSuccess?.ISO8601Format() ?? "None")")
        if let failure = try paths.latestServiceFailure(for: configuration) {
            let recovery = lastSuccess.map { $0 > failure.date } == true ? " (followed by a successful run)" : ""
            print("Latest failure: \(failure.date.ISO8601Format())\(recovery) — \(failure.message)")
        } else {
            print("Latest failure: None")
        }
    }
}

struct ServiceFailure: Codable {
    let date: Date
    let message: String
}
