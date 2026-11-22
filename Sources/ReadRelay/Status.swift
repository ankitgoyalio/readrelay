import ArgumentParser
import Foundation

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the background service's sync health.")

    func run() throws {
        let paths = BetaPaths()
        let files = FileManager.default
        var lastSuccess: Date?
        print("Mode: Preview")
        if !files.fileExists(atPath: paths.config.path) {
            print("Setup: Run readrelay setup first.")
        } else if files.fileExists(atPath: paths.state.path) {
            do {
                let configuration = try paths.loadConfiguration()
                let rollout = try RolloutState(path: paths.state.path, configuration: configuration)
                lastSuccess = try rollout.lastHomebrewPreview()
            } catch {
                print("SQLite state: \(error.localizedDescription)")
            }
        }
        print("Last successful run: \(lastSuccess?.ISO8601Format() ?? "None")")
        if files.fileExists(atPath: paths.serviceFailure.path) {
            let data = try Data(contentsOf: paths.serviceFailure)
            let failure = try JSONDecoder().decode(ServiceFailure.self, from: data)
            print("Latest failure: \(failure.date.ISO8601Format()) — \(failure.message)")
        } else {
            print("Latest failure: None")
        }
    }
}

struct ServiceFailure: Codable {
    let date: Date
    let message: String
}
