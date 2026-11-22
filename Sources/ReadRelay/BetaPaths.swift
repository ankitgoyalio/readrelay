import Darwin
import Foundation

struct BetaPaths {
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ReadRelay", isDirectory: true)

    var config: URL { directory.appendingPathComponent("config.json") }
    var oauthClient: URL { directory.appendingPathComponent("oauth-client.json") }
    func state(for configuration: Configuration) -> URL {
        scopeFile("state", extension: "sqlite", for: configuration)
    }

    func scopeFile(_ name: String, extension ext: String, for configuration: Configuration) -> URL {
        let suffix = configuration.scopeID.map { "-\($0.uuidString)" } ?? ""
        return directory.appendingPathComponent("\(name)\(suffix).\(ext)")
    }

    func withLock<Value>(run: () async throws -> Value) async throws -> Value {
        try prepare()
        return try await RolloutState.withLock(at: directory.appendingPathComponent("beta.lock").path, run: run)
    }

    func requireManualPaths(_ paths: String...) throws {
        let root = directory.resolvingSymlinksInPath().path
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let resolved = url.resolvingSymlinksInPath().path
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
            let resolvedParentPath = parent.appendingPathComponent(url.lastPathComponent).path
            if [url.standardizedFileURL.path, resolved, resolvedParentPath].contains(where: {
                $0 == root || $0.hasPrefix(root + "/")
            }) {
                throw RelayError("Use readrelay preview, approve, and revoke for the Homebrew setup.")
            }
        }
    }
    var logs: URL { directory.appendingPathComponent("logs", isDirectory: true) }
    func previewReport(for configuration: Configuration) -> URL {
        scopeFile("preview", extension: "json", for: configuration)
    }
    var serviceLog: URL { logs.appendingPathComponent("service.log") }
    func serviceFailure(for configuration: Configuration?) -> URL {
        let suffix = configuration?.scopeID.map { "-\($0.uuidString)" } ?? ""
        return logs.appendingPathComponent("latest-failure\(suffix).json")
    }

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

    func connect(configuration: Configuration, unattended: Bool) async throws -> RelayMailboxes {
        try await RelayMailboxes(configuration: configuration, configPath: config.path,
                                 unattended: unattended, homebrew: true)
    }

    func saveConfiguration(_ configuration: Configuration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: config, options: .atomic)
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
