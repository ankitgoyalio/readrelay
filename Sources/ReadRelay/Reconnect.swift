import ArgumentParser

struct Reconnect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restore access to a configured Gmail mailbox.")

    @Argument(help: "Mailbox role to reconnect.")
    var role: MailboxRole

    func run() async throws {
        let paths = BetaPaths()
        try await paths.withLock {
            let configuration = try paths.loadConfiguration()
            let oauth = try OAuth(role: role, configuration: configuration, configPath: paths.config.path)
            let mailbox = oauth.account.description
            print("In your browser, authorize the \(mailbox).")
            try await oauth.authorize(importToken: false)
            print("Reconnected the \(mailbox). The next service run will use your saved sync settings and pending work.")
        }
    }
}
