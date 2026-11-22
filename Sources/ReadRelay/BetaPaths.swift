import Darwin
import Foundation

struct BetaPaths {
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ReadRelay", isDirectory: true)

    var config: URL { directory.appendingPathComponent("config.json") }
    var oauthClient: URL { directory.appendingPathComponent("oauth-client.json") }
    var state: URL { directory.appendingPathComponent("state.sqlite") }
    var logs: URL { directory.appendingPathComponent("logs", isDirectory: true) }
    var previewReport: URL { directory.appendingPathComponent("preview.json") }

    func prepare() throws {
        umask(0o077)
        try createPrivateDirectory(directory)
        try createPrivateDirectory(logs)
    }

    func loadConfiguration() throws -> Configuration {
        guard FileManager.default.fileExists(atPath: config.path) else {
            throw RelayError("No mailbox pair is configured. Run readrelay setup first.")
        }
        return try Configuration.load(path: config.path)
    }

    private func createPrivateDirectory(_ url: URL) throws {
        let files = FileManager.default
        let permissions: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: permissions)
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else {
            throw RelayError("ReadRelay requires a private directory owned by the current user at \(url.path).")
        }
        if (attributes[.posixPermissions] as? NSNumber)?.intValue != 0o700 {
            try files.setAttributes(permissions, ofItemAtPath: url.path)
        }
    }
}
