import ArgumentParser
import Foundation

@main
struct ReadRelay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "readrelay",
        abstract: "Preview read-status changes for forwarded Gmail messages.",
        subcommands: [Authorize.self, DryRun.self]
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

struct Configuration: Decodable {
    let primaryEmail: String
    let secondaryEmail: String
    let primaryOAuthClientFile: String
    let secondaryOAuthClientFile: String

    static func load(path: String) throws -> Self {
        let config: Self
        do {
            config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw RelayError("Could not read the ReadRelay configuration JSON.")
        }
        guard !config.primaryEmail.isEmpty, !config.secondaryEmail.isEmpty,
              config.primaryEmail.caseInsensitiveCompare(config.secondaryEmail) != .orderedSame else {
            throw RelayError("Configure two distinct Gmail mailboxes.")
        }
        return config
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
    static let configuration = CommandConfiguration(abstract: "Store a Gmail refresh token in Keychain.")

    @Argument(help: "Mailbox role.")
    var role: MailboxRole

    @Option(help: "Path to the ReadRelay configuration JSON.")
    var config: String

    @Flag(help: "Import an existing refresh token JSON from standard input.")
    var importToken = false

    func run() async throws {
        let configuration = try Configuration.load(path: config)
        let oauth = try OAuth(role: role, configuration: configuration, configPath: config)
        try await oauth.authorize(importToken: importToken)
        print("Authorized the \(role.rawValue) Gmail mailbox.")
    }
}

struct DryRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Report proposed read-status changes as JSON.")

    @Option(help: "Path to the ReadRelay configuration JSON.")
    var config: String

    @Option(help: "Path to the SQLite rollout state.")
    var state: String

    func run() async throws {
        let startedAt = Date()
        let configuration = try Configuration.load(path: config)
        let primaryOAuth = try OAuth(role: .primary, configuration: configuration, configPath: config)
        let secondaryOAuth = try OAuth(role: .secondary, configuration: configuration, configPath: config)
        let primary = try await primaryOAuth.mailbox()
        let labelID = try await primary.readRelayLabelID()
        let secondary = try await secondaryOAuth.mailbox()
        let cutoff = try RolloutState(path: state).cutoff(for: configuration, startedAt: startedAt)
        let report = try await DryRunReport.preview(primary: primary, secondary: secondary, labelID: labelID, cutoff: cutoff)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = try encoder.encode(report)
        print(String(decoding: output, as: UTF8.self))
    }
}
