import ArgumentParser
import Foundation

struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Connect two Gmail mailboxes.")

    @Option(help: "Path to one Google Desktop OAuth client JSON file.")
    var oauthClientFile: String

    @Option(help: "Gmail address receiving original messages.")
    var primaryEmail: String

    @Option(help: "Gmail address dedicated to receiving forwarded copies.")
    var secondaryEmail: String

    @Option(help: "Label applied to originals by the primary Gmail forwarding filter.")
    var primaryLabel = Configuration.defaultPrimaryLabel

    @Flag(help: "Replace the configured mailbox pair and start a fresh review.")
    var replace = false

    func run() async throws {
        let paths = BetaPaths()
        let scopeID = UUID()
        let configuration = Configuration(
            primaryEmail: primaryEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            secondaryEmail: secondaryEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            oauthClientFile: replace ? "oauth-client-\(scopeID.uuidString).json" : paths.oauthClient.lastPathComponent,
            primaryLabel: primaryLabel, scopeID: scopeID
        )
        try configuration.validate()

        let source = URL(fileURLWithPath: (oauthClientFile as NSString).expandingTildeInPath)
        guard !oauthClientFile.isEmpty, let clientData = try? Data(contentsOf: source) else {
            throw RelayError("Could not read the Google Desktop OAuth client JSON.")
        }
        let oauth = try MailboxRole.allCases.map { role in
            let email = configuration.email(for: role)
            let client = try ClientCredentials.decode(clientData, expectedEmail: email)
            return OAuth(role: role, email: email, client: client)
        }

        try await paths.withLock {
            let configured = FileManager.default.fileExists(atPath: paths.config.path)
            if configured, !replace {
                throw RelayError("A mailbox pair is already configured for this macOS login. Use readrelay setup --replace to change it, or readrelay set-label to change only the label.")
            }
            if !configured, replace {
                throw RelayError("No mailbox pair is configured. Run readrelay setup first.")
            }
            var tokens: [(OAuth, String)] = []
            for account in oauth {
                print("In your browser, authorize the \(account.role.rawValue) Gmail mailbox (\(account.email)).")
                do {
                    tokens.append((account, try await account.requestVerifiedRefreshToken()))
                } catch {
                    throw RelayError("Could not connect the \(account.role.rawValue) mailbox. \(error.localizedDescription)")
                }
            }

            try clientData.write(
                to: configuration.clientFile(for: .primary, relativeTo: paths.config.path), options: .atomic
            )
            for (account, token) in tokens {
                try account.storeRefreshToken(token)
            }
            try paths.saveConfiguration(configuration)
        }
        print("Connected both Gmail mailboxes. Run readrelay preview to review the recent backlog.")
        if replace { print("Verify forwarding again and wait for a successful Homebrew preview before approving writes.") }
    }
}

struct SetLabel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Select a primary Gmail label and start a fresh review."
    )

    @Argument(help: "Label applied to originals by the primary Gmail forwarding filter.")
    var label: String

    func run() async throws {
        let paths = BetaPaths()
        _ = try paths.loadConfiguration()
        try await paths.withLock {
            let current = try paths.loadConfiguration()
            let next = current.withFreshScope(primaryLabel: label)
            try next.validate()
            try paths.saveConfiguration(next)
        }
        print("Selected “\(label)” and returned to preview mode.")
        print("Update the Gmail forwarding filter and verify forwarding before approving writes.")
    }
}
