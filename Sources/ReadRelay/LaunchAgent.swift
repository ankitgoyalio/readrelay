import ArgumentParser
import Foundation

struct LaunchAgent: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print a user launchd plist. The default job runs unattended previews."
    )

    @Option(help: "Absolute path to the installed ReadRelay executable.")
    var executable: String

    @Option(help: "Absolute path to the ReadRelay configuration JSON.")
    var config: String

    @Option(help: "Absolute path to the SQLite state.")
    var state: String

    @Option(help: "Absolute path to an existing private log directory.")
    var logDirectory: String

    @Flag(help: "Schedule sync --apply after the owner approves recurring writes.")
    var enableScheduledWrites = false

    func run() throws {
        guard [executable, config, state, logDirectory].allSatisfy({ $0.hasPrefix("/") }) else {
            throw RelayError("The executable, config, state, and log directory must use absolute paths.")
        }
        let command = enableScheduledWrites ? ["sync", "--apply"] : ["dry-run"]
        let arguments = [executable] + command + ["--unattended", "--config", config, "--state", state]
        let logs = URL(fileURLWithPath: logDirectory, isDirectory: true)
        let plist: [String: Any] = [
            "Label": "io.ankitgoyal.readrelay",
            "LimitLoadToSessionType": "Aqua",
            "ProgramArguments": arguments,
            "RunAtLoad": true,
            "StartInterval": 300,
            "Umask": "077",
            "StandardOutPath": logs.appendingPathComponent("stdout.log").path,
            "StandardErrorPath": logs.appendingPathComponent("stderr.log").path
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
