import ArgumentParser
import Darwin
import Foundation

struct ServiceRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service-run", abstract: "Run the Homebrew background service once.", shouldDisplay: false
    )

    func run() async throws {
        let startedAt = Date()
        try HomebrewJob.verifyCurrentProcess()

        let paths = BetaPaths()
        try await paths.withLock {
            var activeConfiguration: Configuration?
            do {
                let configuration = try paths.loadConfiguration()
                activeConfiguration = configuration
                let mailboxes = try await paths.connect(configuration: configuration, unattended: true)
                let rollout = try RolloutState(
                    path: paths.state(for: configuration).path, configuration: configuration,
                    preview: .beta(startedAt)
                )

                if try rollout.betaScope()?.approvedReviewCode != nil {
                    try rollout.requireBetaLabel(mailboxes.primaryLabelID)
                    guard try rollout.lastHomebrewPreview() != nil else {
                        throw RelayError("The saved scope needs a successful Homebrew preview. Run readrelay revoke and review a new preview.")
                    }
                    try paths.requireForwardingProof(for: configuration, labelID: mailboxes.primaryLabelID)
                    _ = try await SyncEngine.run(rollout: rollout) { mailboxes }
                    let date = Date()
                    try rollout.recordLiveRun(at: date)
                    try Self.log("Live sync succeeded", at: date, to: paths.serviceLog)
                } else {
                    _ = try await BacklogReport.betaPreview(mailboxes: mailboxes, rollout: rollout, configuration: configuration)
                    let date = Date()
                    try rollout.recordHomebrewPreview(at: date)
                    try Self.log("Preview succeeded", at: date, to: paths.serviceLog)
                }
            } catch {
                let failure = ServiceFailure(date: Date(), message: error.localizedDescription)
                try JSONEncoder().encode(failure)
                    .write(to: paths.serviceFailure(for: activeConfiguration), options: .atomic)
                try Self.log(failure.message, at: failure.date, to: paths.serviceLog)
                throw error
            }
        }
    }

    private static func log(_ message: String, at date: Date, to url: URL) throws {
        try Data("\(date.ISO8601Format()) \(message)\n".utf8).write(to: url, options: .atomic)
    }
}

private enum HomebrewJob {
    private static let label = "homebrew.mxcl.readrelay"

    static func verifyCurrentProcess() throws {
        let uid = getuid()
        let failure = RelayError(
            "Start ReadRelay from your macOS login with brew services start ankitgoyalio/readrelay/readrelay."
        )
        guard uid != 0, uid == geteuid(), getppid() == 1, let account = getpwuid(uid),
              let homeDirectory = account.pointee.pw_dir,
              let executable = Bundle.main.executableURL else {
            throw failure
        }

        let agent = URL(fileURLWithPath: String(cString: homeDirectory))
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(uid)/\(label)"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
        process.waitUntilExit()

        // Only match top-level launchctl fields, including the active job's actual PID.
        let programKey = "\tprogram = "
        guard process.terminationStatus == 0,
              lines.contains("\tpid = \(getpid())"),
              lines.contains("\ttype = LaunchAgent"),
              lines.contains("\tpath = \(agent.path)"),
              let programLine = lines.first(where: { $0.hasPrefix(programKey) }) else {
            throw failure
        }
        let program = URL(fileURLWithPath: String(programLine.dropFirst(programKey.count)))
        guard program.pathComponents.suffix(4).elementsEqual(["opt", "readrelay", "bin", "readrelay"]),
              program.resolvingSymlinksInPath().path == executable.resolvingSymlinksInPath().path else {
            throw failure
        }
    }
}
