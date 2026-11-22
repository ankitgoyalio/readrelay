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

    func withConfiguredLock<Value>(run: (Configuration) async throws -> Value) async throws -> Value {
        _ = try loadConfiguration()
        return try await withLock {
            try await run(loadConfiguration())
        }
    }

    func requireManualPaths(_ paths: String...) throws {
        let roots = [directory.standardizedFileURL, directory.resolvingSymlinksInPath()].map {
            $0.path.lowercased()
        }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let resolved = url.resolvingSymlinksInPath().path
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
            let resolvedParentPath = parent.appendingPathComponent(url.lastPathComponent).path
            let candidates = [url.standardizedFileURL.path, resolved, resolvedParentPath].map { $0.lowercased() }
            if candidates.contains(where: { path in
                roots.contains { root in
                    if path == root { return true }
                    guard path.hasPrefix(root + "/") else { return false }
                    return Self.isBetaArtifact(String(path.dropFirst(root.count + 1)))
                }
            }) {
                throw RelayError("Use readrelay preview, approve, and revoke for the Homebrew setup.")
            }
        }
    }

    private static func isBetaArtifact(_ path: String) -> Bool {
        if ["config.json", "beta.lock", "logs/service.log"].contains(path) { return true }
        let files = [
            ("state", ".sqlite"), ("state", ".sqlite-journal"), ("state", ".sqlite-shm"), ("state", ".sqlite-wal"),
            ("oauth-client", ".json"), ("preview", ".json"), ("forwarding-proof", ".json"), ("grant-replacement", ".json"),
            ("logs/latest-failure", ".json")
        ]
        return files.contains { name, extensionSuffix in
            if path == name + extensionSuffix { return true }
            let prefix = name + "-"
            guard path.hasPrefix(prefix), path.hasSuffix(extensionSuffix) else { return false }
            let scope = path.dropFirst(prefix.count).dropLast(extensionSuffix.count)
            return UUID(uuidString: String(scope)) != nil
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

    func latestServiceFailure(for configuration: Configuration?) throws -> ServiceFailure? {
        let files = configuration?.scopeID == nil
            ? [serviceFailure(for: nil)]
            : [serviceFailure(for: configuration), serviceFailure(for: nil)]
        return try files.compactMap { try readEvidence(ServiceFailure.self, at: $0) }
            .max { $0.date < $1.date }
    }

    func requireFreshHomebrewPreview(rollout: RolloutState, configuration: Configuration) throws {
        let replacement = try readEvidence(Date.self, at: grantReplacement(for: configuration))
        let failure = try latestServiceFailure(for: configuration)?.date
        guard let preview = try rollout.lastHomebrewPreview(),
              [replacement, failure].compactMap({ $0 }).allSatisfy({ preview > $0 }) else {
            throw RelayError("Start ReadRelay with brew services and wait for a successful unattended preview in readrelay status. If the service is in Live mode, run readrelay revoke before seeking a new approval.")
        }
    }

    // Record the change before saving into Keychain so an interrupted replacement cannot leave stale proof.
    func recordGrantReplacement(for configuration: Configuration) throws {
        try JSONEncoder().encode(Date()).write(to: grantReplacement(for: configuration), options: .atomic)
    }

    func recordGrantReplacementIfShared(with accounts: [OAuth]) throws {
        guard let configuration = try? loadConfiguration() else { return }
        let sharesGrant = accounts.contains { account in
            let saved = try? OAuth(role: account.role, configuration: configuration, configPath: config.path)
            return saved?.keychainAccount == account.keychainAccount
        }
        if sharesGrant { try recordGrantReplacement(for: configuration) }
    }

    private func grantReplacement(for configuration: Configuration) -> URL {
        scopeFile("grant-replacement", extension: "json", for: configuration)
    }

    private func readEvidence<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
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
