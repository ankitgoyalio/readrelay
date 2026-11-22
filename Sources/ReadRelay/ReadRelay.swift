import ArgumentParser
import Foundation

@main
struct ReadRelay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "readrelay",
        abstract: "Preview and sync read status for forwarded Gmail messages.",
        version: "0.1.0",
        subcommands: [
            Setup.self, Reconnect.self, SetLabel.self, VerifyForwarding.self, Preview.self, Approve.self, Revoke.self, Status.self,
            Authorize.self, DryRun.self, Sync.self, LaunchAgent.self, ServiceRun.self
        ]
    )
}

enum MailboxRole: String, CaseIterable, ExpressibleByArgument {
    case primary, secondary

    var scope: String {
        "https://www.googleapis.com/auth/gmail." + (self == .primary ? "metadata" : "modify")
    }
}

struct RelayError: LocalizedError {
    let description: String

    init(_ description: String) {
        self.description = description
    }

    var errorDescription: String? { description }
}

struct Configuration: Codable {
    static let defaultPrimaryLabel = "ReadRelay"

    let primaryEmail: String
    let secondaryEmail: String
    let primaryOAuthClientFile: String
    let secondaryOAuthClientFile: String
    let enableWrites: Bool?
    let scopeID: UUID?
    private let configuredPrimaryLabel: String?

    var primaryLabel: String { configuredPrimaryLabel ?? Self.defaultPrimaryLabel }

    enum CodingKeys: String, CodingKey {
        case primaryEmail, secondaryEmail, primaryOAuthClientFile, secondaryOAuthClientFile, enableWrites, scopeID
        case configuredPrimaryLabel = "primaryLabel"
    }

    init(primaryEmail: String, secondaryEmail: String, oauthClientFile: String, primaryLabel: String,
         scopeID: UUID) {
        self.init(primaryEmail: primaryEmail, secondaryEmail: secondaryEmail,
                  primaryOAuthClientFile: oauthClientFile, secondaryOAuthClientFile: oauthClientFile,
                  primaryLabel: primaryLabel, scopeID: scopeID)
    }

    private init(primaryEmail: String, secondaryEmail: String, primaryOAuthClientFile: String,
                 secondaryOAuthClientFile: String, primaryLabel: String, scopeID: UUID) {
        self.primaryEmail = primaryEmail
        self.secondaryEmail = secondaryEmail
        self.primaryOAuthClientFile = primaryOAuthClientFile
        self.secondaryOAuthClientFile = secondaryOAuthClientFile
        enableWrites = nil
        self.scopeID = scopeID
        configuredPrimaryLabel = primaryLabel
    }

    func withFreshScope(primaryLabel: String) -> Self {
        Self(primaryEmail: primaryEmail, secondaryEmail: secondaryEmail, primaryOAuthClientFile: primaryOAuthClientFile,
             secondaryOAuthClientFile: secondaryOAuthClientFile, primaryLabel: primaryLabel, scopeID: UUID())
    }

    static func load(path: String) throws -> Self {
        let config: Self
        do {
            config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw RelayError("Could not read the ReadRelay configuration JSON.")
        }
        try config.validate()
        return config
    }

    func validate() throws {
        guard !primaryEmail.isEmpty, !secondaryEmail.isEmpty,
              primaryEmail.caseInsensitiveCompare(secondaryEmail) != .orderedSame else {
            throw RelayError("Configure two distinct Gmail mailboxes.")
        }
        guard !primaryLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              primaryLabel.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw RelayError("Provide a nonempty primary Gmail label name without control characters.")
        }
    }

    func email(for role: MailboxRole) -> String {
        role == .primary ? primaryEmail : secondaryEmail
    }

    func clientFile(for role: MailboxRole, relativeTo configPath: String) -> URL {
        let clientPath = role == .primary ? primaryOAuthClientFile : secondaryOAuthClientFile
        let expandedPath = (clientPath as NSString).expandingTildeInPath
        let folder = URL(fileURLWithPath: configPath).deletingLastPathComponent()
        return URL(fileURLWithPath: expandedPath, relativeTo: folder)
    }
}

struct Authorize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Store a Gmail refresh token for a manual configuration.")

    @Argument(help: "Mailbox role.")
    var role: MailboxRole

    @Option(help: "Path to a manual ReadRelay configuration JSON.")
    var config: String

    @Flag(help: "Import an existing refresh token JSON from standard input.")
    var importToken = false

    func run() async throws {
        let paths = BetaPaths()
        try paths.requireManualPaths(config)
        let configuration = try Configuration.load(path: config)
        let oauth = try OAuth(role: role, configuration: configuration, configPath: config)
        let token = try await oauth.verifiedRefreshToken(importToken: importToken)
        if FileManager.default.fileExists(atPath: paths.config.path) {
            try await paths.withLock {
                try paths.recordGrantReplacementIfShared(with: [oauth])
                try oauth.storeRefreshToken(token)
            }
        } else {
            try oauth.storeRefreshToken(token)
        }
        print("Authorized the \(role.rawValue) Gmail mailbox.")
    }
}

struct DryRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Report proposed read-status changes as JSON.")

    @Option(help: "Path to the ReadRelay configuration JSON.")
    var config: String

    @Option(help: "Path to the SQLite rollout state.")
    var state: String

    @Flag(help: "Fail if Keychain access requires user interaction.")
    var unattended = false

    func run() async throws {
        let startedAt = Date()
        try BetaPaths().requireManualPaths(config, state)
        let configuration = try Configuration.load(path: config)
        let mailboxes = try await RelayMailboxes(configuration: configuration, configPath: config, unattended: unattended)
        let rollout = try RolloutState(path: state, configuration: configuration, preview: .manual(startedAt))
        let report = try await BacklogReport.preview(mailboxes: mailboxes, rollout: rollout)
        print(try report.json())
    }
}

struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Apply read-status changes to reviewed and newly labeled mail.")

    @Option(help: "Path to the ReadRelay configuration JSON.")
    var config: String

    @Option(help: "Path to the SQLite state from a successful dry run.")
    var state: String

    @Flag(help: "Confirm Gmail writes for this sync.")
    var apply = false

    @Flag(help: "Fail if Keychain access requires user interaction.")
    var unattended = false

    @Option(help: "Limit the sync to this previewed primary Gmail message ID. Requires --copy-id.")
    var originalID: String?

    @Option(help: "Require this previewed secondary Gmail message ID. Requires --original-id.")
    var copyID: String?

    func run() async throws {
        guard apply else { throw RelayError("Pass --apply after reviewing the dry run.") }
        try BetaPaths().requireManualPaths(config, state)
        let configuration = try Configuration.load(path: config)
        guard configuration.enableWrites == true else {
            throw RelayError("Set enableWrites to true in the configuration after reviewing the dry run.")
        }
        let selection: (String, String)?
        switch (originalID, copyID) {
        case let (.some(original), .some(copy)):
            selection = (original, copy)
        case (.none, .none):
            selection = nil
        default:
            throw RelayError("Pass --original-id and --copy-id together to limit the sync to one reviewed pair.")
        }
        try await RolloutState.withSyncLock(path: state) {
            let rollout = try RolloutState(path: state, configuration: configuration)
            guard try rollout.betaScope() == nil else {
                throw RelayError("Use readrelay preview, approve, and revoke for the Homebrew setup.")
            }
            let report = try await SyncEngine.run(rollout: rollout, selection: selection) {
                try await RelayMailboxes(configuration: configuration, configPath: config, unattended: unattended)
            }
            print(try report.json())
        }
    }
}
