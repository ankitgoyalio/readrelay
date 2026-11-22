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

    func run() async throws {
        let paths = BetaPaths()
        let configuration = Configuration(
            primaryEmail: primaryEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            secondaryEmail: secondaryEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            oauthClientFile: paths.oauthClient.lastPathComponent, primaryLabel: primaryLabel
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

        try paths.prepare()
        try await RolloutState.withSyncLock(path: paths.state.path) {
            guard !FileManager.default.fileExists(atPath: paths.config.path) else {
                throw RelayError("A mailbox pair is already configured for this macOS login.")
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

            try clientData.write(to: paths.oauthClient, options: .atomic)
            for (account, token) in tokens {
                try account.storeRefreshToken(token)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: paths.config, options: .atomic)
        }
        print("Connected both Gmail mailboxes. Run readrelay preview to review the recent backlog.")
    }
}
