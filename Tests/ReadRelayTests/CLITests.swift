import Foundation
import SQLite3
import XCTest

final class CLITests: XCTestCase {
    func testLaunchAgentSchedulesOnlyUnattendedPreviewsByDefault() throws {
        let executable = "/Users/owner/Library/Application Support/ReadRelay & Dot/readrelay"
        let config = "/Users/owner/Library/Application Support/ReadRelay & Dot/config.json"
        let state = "/Users/owner/Library/Application Support/ReadRelay & Dot/probe.sqlite"
        let logs = "/Users/owner/Library/Application Support/ReadRelay & Dot/logs"
        let result = try runCLI([
            "launch-agent", "--executable", executable, "--config", config,
            "--state", state, "--log-directory", logs
        ])
        XCTAssertEqual(result.status, 0, result.error)
        let decoded = try PropertyListSerialization.propertyList(from: result.output, format: nil)
        let job = try XCTUnwrap(decoded as? [String: Any])
        XCTAssertEqual(job["Label"] as? String, "io.ankitgoyal.readrelay")
        XCTAssertEqual(job["LimitLoadToSessionType"] as? String, "Aqua")
        XCTAssertEqual(job["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(job["StartInterval"] as? Int, 300)
        XCTAssertEqual(job["ProgramArguments"] as? [String],
                       [executable, "dry-run", "--unattended", "--config", config, "--state", state])
        XCTAssertEqual(job["StandardOutPath"] as? String, logs + "/stdout.log")
        XCTAssertEqual(job["StandardErrorPath"] as? String, logs + "/stderr.log")
    }

    func testLaunchAgentWriteModeStillRequiresWriteEnabledConfiguration() throws {
        let directory = try temporaryDirectory()
        let config = directory.appendingPathComponent("config.json")
        let state = directory.appendingPathComponent("state.sqlite")
        try Data("""
            {"primaryEmail":"primary@example.com","secondaryEmail":"secondary@example.com",
             "primaryOAuthClientFile":"unused.json","secondaryOAuthClientFile":"unused.json",
             "enableWrites":false}
            """.utf8).write(to: config)
        let result = try runCLI([
            "launch-agent", "--executable", "/opt/readrelay", "--config", config.path,
            "--state", state.path, "--log-directory", directory.path, "--enable-scheduled-writes"
        ])
        XCTAssertEqual(result.status, 0, result.error)
        let decoded = try PropertyListSerialization.propertyList(from: result.output, format: nil)
        let job = try XCTUnwrap(decoded as? [String: Any])
        let arguments = try XCTUnwrap(job["ProgramArguments"] as? [String])
        XCTAssertEqual(arguments, [
            "/opt/readrelay", "sync", "--apply", "--unattended", "--config", config.path, "--state", state.path
        ])
        let blocked = try runCLI(Array(arguments.dropFirst()))
        XCTAssertNotEqual(blocked.status, 0)
        XCTAssertTrue(blocked.error.contains("enableWrites"), blocked.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }

    func testSyncRequiresExplicitWriteConfigurationAndASuccessfulPreview() throws {
        let directory = try temporaryDirectory()
        let config = directory.appendingPathComponent("config.json")
        let state = directory.appendingPathComponent("state.sqlite")
        let arguments = ["sync", "--config", config.path, "--state", state.path]

        let disabled = """
            {"primaryEmail":"primary@example.com","secondaryEmail":"secondary@example.com",
             "primaryOAuthClientFile":"unused.json","secondaryOAuthClientFile":"unused.json"}
            """
        try Data(disabled.utf8).write(to: config)
        let unconfirmed = try runCLI(arguments)
        XCTAssertNotEqual(unconfirmed.status, 0)
        XCTAssertTrue(unconfirmed.error.contains("--apply"), unconfirmed.error)

        let notEnabled = try runCLI(arguments + ["--apply"])
        XCTAssertNotEqual(notEnabled.status, 0)
        XCTAssertTrue(notEnabled.error.contains("enableWrites"), notEnabled.error)

        let enabled = disabled.replacingOccurrences(of: "{", with: "{\"enableWrites\":true,")
        try Data(enabled.utf8).write(to: config)
        let unpreviewed = try runCLI(arguments + ["--apply"])
        XCTAssertNotEqual(unpreviewed.status, 0)
        XCTAssertTrue(unpreviewed.error.contains("successful dry run"), unpreviewed.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))

        // A state file from the original CLI has a cutoff but no saved preview.
        var legacy: OpaquePointer?
        XCTAssertEqual(sqlite3_open(state.path, &legacy), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(legacy, """
            CREATE TABLE rollout (singleton INTEGER PRIMARY KEY, primary_email TEXT,
                                  secondary_email TEXT, cutoff_ms INTEGER);
            INSERT INTO rollout VALUES (1, 'primary@example.com', 'secondary@example.com', 1700000000000);
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(legacy), SQLITE_OK)
        let cutoffOnly = try runCLI(arguments + ["--apply"])
        XCTAssertNotEqual(cutoffOnly.status, 0)
        XCTAssertTrue(cutoffOnly.error.contains("successful dry run"), cutoffOnly.error)
    }

    func testDryRunRejectsTheSameMailboxInBothRoles() throws {
        let directory = try temporaryDirectory()
        let config = directory.appendingPathComponent("config.json")
        let state = directory.appendingPathComponent("state.sqlite")
        try Data("""
            {"primaryEmail":"same@example.com","secondaryEmail":"SAME@example.com",
             "primaryOAuthClientFile":"unused.json","secondaryOAuthClientFile":"unused.json"}
            """.utf8).write(to: config)

        let result = try runCLI(["dry-run", "--config", config.path, "--state", state.path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.error.contains("distinct Gmail mailboxes"), result.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }

    func testAuthorizeRejectsAnImportForTheOtherMailbox() throws {
        let directory = try temporaryDirectory()
        let config = directory.appendingPathComponent("config.json")
        let client = directory.appendingPathComponent("client.json")
        try Data("""
            {"primaryEmail":"primary@example.com","secondaryEmail":"secondary@example.com",
             "primaryOAuthClientFile":"client.json","secondaryOAuthClientFile":"client.json"}
            """.utf8).write(to: config)
        try Data("""
            {"installed":{"client_id":"local-client","client_secret":"unused"}}
            """.utf8).write(to: client)

        let result = try runCLI(["authorize", "primary", "--config", config.path, "--import-token"],
                                input: Data("""
            {"email":"secondary@example.com","clientID":"local-client","refreshToken":"unused"}
            """.utf8))
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.error.contains("does not match the configured primary mailbox"), result.error)
    }

    func testDryRunReportsSeededMatchesAndPreservesTheirGmailLabels() throws {
        let environment = ProcessInfo.processInfo.environment
        let configPath = environment["READRELAY_SEEDED_TEST_CONFIG"]
        let expectationsPath = environment["READRELAY_SEEDED_EXPECTATIONS"]
        if configPath == nil, expectationsPath == nil {
            throw XCTSkip("Set READRELAY_SEEDED_TEST_CONFIG and READRELAY_SEEDED_EXPECTATIONS to run against seeded Gmail.")
        }
        let config = try XCTUnwrap(configPath, "Set READRELAY_SEEDED_TEST_CONFIG.")
        let expectationPath = try XCTUnwrap(expectationsPath, "Set READRELAY_SEEDED_EXPECTATIONS.")

        let expectations = try JSONDecoder().decode(
            [SeedExpectation].self, from: Data(contentsOf: URL(fileURLWithPath: expectationPath))
        )
        XCTAssertTrue(expectations.contains { $0.outcome == "wouldMarkRead" && $0.forwardedCopyID != nil })
        XCTAssertTrue(expectations.contains { $0.outcome == "originalUnread" && $0.forwardedCopyID != nil })

        let state = try temporaryDirectory().appendingPathComponent("state.sqlite")
        let arguments = ["dry-run", "--config", config, "--state", state.path]
        let first = try runCLI(arguments)
        XCTAssertEqual(first.status, 0, first.error)
        let preview = try JSONDecoder().decode(Preview.self, from: first.output)
        let fiveDaysAgo = Date().timeIntervalSince1970 - 5 * 24 * 60 * 60
        XCTAssertEqual(Double(preview.cutoffEpochMilliseconds) / 1_000, fiveDaysAgo, accuracy: 300)
        for expected in expectations {
            let item = try XCTUnwrap(preview.entries.first { $0.originalID == expected.originalID })
            XCTAssertEqual(item.outcome, expected.outcome)
            XCTAssertEqual(item.forwardedCopyID, expected.forwardedCopyID)
            if expected.outcome == "wouldMarkRead" {
                XCTAssertFalse(item.originalLabelIDs.contains("UNREAD"))
                XCTAssertTrue(item.forwardedCopyLabelIDs?.contains("UNREAD") == true)
            }
            if expected.outcome == "originalUnread" {
                XCTAssertTrue(item.originalLabelIDs.contains("UNREAD"))
                XCTAssertTrue(item.forwardedCopyLabelIDs?.contains("UNREAD") == true)
            }
        }

        let second = try runCLI(arguments)
        XCTAssertEqual(second.status, 0, second.error)
        let repeated = try JSONDecoder().decode(Preview.self, from: second.output)
        XCTAssertEqual(preview.cutoffEpochMilliseconds, repeated.cutoffEpochMilliseconds)
        for expected in expectations {
            let before = try XCTUnwrap(preview.entries.first { $0.originalID == expected.originalID })
            let after = try XCTUnwrap(repeated.entries.first { $0.originalID == expected.originalID })
            XCTAssertEqual(before, after)
        }
    }

    func testSyncMarksOnlyTheSelectedSeededCopyAndCanBeRerun() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["READRELAY_SEEDED_APPLY"] == "1" else {
            throw XCTSkip("Set READRELAY_SEEDED_APPLY=1 to deliberately change a seeded forwarded copy.")
        }
        let config = try XCTUnwrap(environment["READRELAY_SEEDED_TEST_CONFIG"])
        let path = try XCTUnwrap(environment["READRELAY_SEEDED_WRITE_EXPECTATIONS"])
        let expectations = try JSONDecoder().decode(
            [SeedExpectation].self, from: Data(contentsOf: URL(fileURLWithPath: path))
        )
        let targets = expectations.filter { $0.outcome == "wouldMarkRead" }
        XCTAssertEqual(targets.count, 1)
        let target = try XCTUnwrap(targets.count == 1 ? targets.first : nil)
        let copyID = try XCTUnwrap(target.forwardedCopyID)
        let control = try XCTUnwrap(expectations.first { $0.outcome == "originalUnread" && $0.forwardedCopyID != nil })
        XCTAssertNotEqual(target.originalID, control.originalID)
        XCTAssertNotEqual(copyID, control.forwardedCopyID)

        let directory = try temporaryDirectory()
        let state = directory.appendingPathComponent("state.sqlite")
        let pendingState = directory.appendingPathComponent("pending.sqlite")
        var reviewedCutoff: Int64?
        if let reviewedPath = environment["READRELAY_SEEDED_REVIEWED_STATE"] {
            guard !reviewedPath.isEmpty else {
                XCTFail("Provide the path to a closed, reviewed SQLite state.")
                return
            }
            let reviewedState = URL(fileURLWithPath: reviewedPath).resolvingSymlinksInPath()
            try FileManager.default.copyItem(at: reviewedState, to: state)
            reviewedCutoff = try XCTUnwrap(savedReviewCutoff(at: state), "The supplied state must contain a saved review.")
            try FileManager.default.copyItem(at: state, to: pendingState)
        }
        let options = ["--config", config, "--state", state.path]
        let before = try successfulReport(["dry-run"] + options)
        for expected in expectations {
            let entry = try XCTUnwrap(before.entries.first { $0.originalID == expected.originalID })
            guard entry.outcome == expected.outcome, entry.forwardedCopyID == expected.forwardedCopyID else {
                XCTFail("Seeded Gmail labels or pair identifiers differ from the write expectations.")
                return
            }
        }
        let comparison = try XCTUnwrap(before.entries.first { $0.originalID == control.originalID })
        guard comparison.forwardedCopyLabelIDs?.contains("UNREAD") == true else {
            XCTFail("The comparison copy must start unread.")
            return
        }

        // The second state stays pending independently of the first write,
        // reproducing the local state left by an interrupted save.
        let pendingOptions = ["--config", config, "--state", pendingState.path]
        let pending = try successfulReport(["dry-run"] + pendingOptions)
        if let reviewedCutoff, before.cutoffEpochMilliseconds != reviewedCutoff
            || pending.cutoffEpochMilliseconds != reviewedCutoff {
            XCTFail("Both previews must preserve the supplied review's cutoff.")
            return
        }
        guard pending.entries.first(where: { $0.originalID == target.originalID })?.outcome == "wouldMarkRead",
              pending.entries.first(where: { $0.originalID == target.originalID })?.forwardedCopyID == copyID else {
            XCTFail("The second preview must capture the same pending write.")
            return
        }

        let sync = ["sync", "--apply", "--original-id", target.originalID, "--copy-id", copyID]
        let applied = try successfulReport(sync + options)
        XCTAssertEqual(applied.cutoffEpochMilliseconds, before.cutoffEpochMilliseconds)
        XCTAssertEqual(applied.entries.count, 1)
        XCTAssertEqual(applied.entries.first?.forwardedCopyID, copyID)
        XCTAssertEqual(applied.entries.first?.outcome, "markedRead")

        let after = try successfulReport(["dry-run"] + options)
        XCTAssertEqual(after.cutoffEpochMilliseconds, before.cutoffEpochMilliseconds)
        XCTAssertEqual(after.entries.map(\.originalID), before.entries.map(\.originalID))
        for previous in before.entries {
            let current = try XCTUnwrap(after.entries.first { $0.originalID == previous.originalID })
            if previous.originalID == target.originalID {
                XCTAssertEqual(current.originalLabelIDs, previous.originalLabelIDs)
                XCTAssertEqual(current.forwardedCopyID, copyID)
                XCTAssertEqual(current.forwardedCopyLabelIDs, previous.forwardedCopyLabelIDs?.filter { $0 != "UNREAD" })
                XCTAssertEqual(current.outcome, "copyAlreadyRead")
            } else {
                XCTAssertEqual(current, previous)
            }
        }

        let recovered = try successfulReport(sync + pendingOptions)
        XCTAssertEqual(recovered.cutoffEpochMilliseconds, pending.cutoffEpochMilliseconds)
        XCTAssertEqual(recovered.entries.count, 1)
        XCTAssertEqual(recovered.entries.first?.forwardedCopyID, copyID)
        XCTAssertEqual(recovered.entries.first?.outcome, "copyAlreadyRead")

        let repeated = try successfulReport(sync + options)
        XCTAssertEqual(repeated.cutoffEpochMilliseconds, before.cutoffEpochMilliseconds)
        XCTAssertEqual(repeated.entries.count, 1)
        XCTAssertEqual(repeated.entries.first?.outcome, "completed")
        XCTAssertEqual(try successfulReport(["dry-run"] + options).entries, after.entries)
    }

    private func savedReviewCutoff(at state: URL) -> Int64? {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(state.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT cutoff_ms FROM rollout WHERE singleton = 1 AND EXISTS (SELECT 1 FROM previewed_backlog)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    func testSyncDiscoversNewSeededOriginalsAfterApplyingTheReviewedBacklog() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["READRELAY_SEEDED_INCREMENTAL_APPLY"] == "1" else {
            throw XCTSkip("Set READRELAY_SEEDED_INCREMENTAL_APPLY=1 to run a full sync against staged Gmail seeds.")
        }
        let config = try XCTUnwrap(environment["READRELAY_SEEDED_TEST_CONFIG"])
        let reviewedState = try XCTUnwrap(environment["READRELAY_SEEDED_REVIEWED_STATE"])
        let path = try XCTUnwrap(environment["READRELAY_SEEDED_INCREMENTAL_EXPECTATIONS"])
        let seeds = try JSONDecoder().decode(
            IncrementalSeeds.self, from: Data(contentsOf: URL(fileURLWithPath: path))
        )
        let state = try temporaryDirectory().appendingPathComponent("state.sqlite")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: reviewedState), to: state)
        let options = ["--config", config, "--state", state.path]
        let preview = try successfulReport(["dry-run"] + options)
        guard let pending = preview.entries.first(where: { $0.originalID == seeds.reviewedUnreadOriginalID }),
              pending.outcome == "originalUnread", pending.forwardedCopyLabelIDs?.contains("UNREAD") == true,
              !preview.entries.contains(where: { $0.originalID == seeds.newUnreadOriginalID }) else {
            XCTFail("The saved preview must contain the reviewed unread pair and exclude the new original.")
            return
        }
        if let late = seeds.lateUnreadCopy {
            let entry = try XCTUnwrap(preview.entries.first { $0.originalID == late.originalID })
            guard entry.outcome == "matchChanged", entry.forwardedCopyID == nil else {
                XCTFail("The late pair must be absent from the saved matches and present in Gmail now.")
                return
            }
        }

        let arguments = ["sync", "--apply"] + options
        let first = try successfulReport(arguments)
        XCTAssertEqual(first.cutoffEpochMilliseconds, preview.cutoffEpochMilliseconds)
        XCTAssertEqual(first.entries.map(\.originalID), preview.entries.map(\.originalID))
        XCTAssertEqual(first.entries.first { $0.originalID == pending.originalID }, pending)

        let second = try successfulReport(arguments)
        XCTAssertEqual(second.cutoffEpochMilliseconds, preview.cutoffEpochMilliseconds)
        XCTAssertEqual(second.entries.first { $0.originalID == pending.originalID }, pending)
        let discovered = try XCTUnwrap(second.entries.first { $0.originalID == seeds.newUnreadOriginalID })
        XCTAssertEqual(discovered.forwardedCopyID, seeds.newUnreadCopyID)
        XCTAssertEqual(discovered.outcome, "originalUnread")
        XCTAssertTrue(discovered.originalLabelIDs.contains("UNREAD"))
        XCTAssertTrue(discovered.forwardedCopyLabelIDs?.contains("UNREAD") == true)
        if let late = seeds.lateUnreadCopy {
            XCTAssertEqual(first.entries.first { $0.originalID == late.originalID }?.outcome, "matchChanged")
            let matched = try XCTUnwrap(second.entries.first { $0.originalID == late.originalID })
            XCTAssertEqual(matched.forwardedCopyID, late.copyID)
            XCTAssertEqual(matched.outcome, "originalUnread")
            XCTAssertTrue(matched.forwardedCopyLabelIDs?.contains("UNREAD") == true)
        }

        let restarted = try successfulReport(arguments)
        XCTAssertEqual(restarted.cutoffEpochMilliseconds, preview.cutoffEpochMilliseconds)
        XCTAssertEqual(restarted.entries.first { $0.originalID == pending.originalID }, pending)
        XCTAssertEqual(restarted.entries.first { $0.originalID == discovered.originalID }, discovered)
    }

    private struct IncrementalSeeds: Decodable {
        struct Pair: Decodable {
            let originalID: String
            let copyID: String
        }

        let reviewedUnreadOriginalID: String
        let newUnreadOriginalID: String
        let newUnreadCopyID: String
        let lateUnreadCopy: Pair?
    }

    private func successfulReport(_ arguments: [String]) throws -> Preview {
        let result = try runCLI(arguments)
        XCTAssertEqual(result.status, 0, result.error)
        return try JSONDecoder().decode(Preview.self, from: result.output)
    }

    private struct SeedExpectation: Decodable {
        let originalID: String
        let forwardedCopyID: String?
        let outcome: String
    }

    private struct Preview: Decodable {
        let cutoffEpochMilliseconds: Int64
        let entries: [Entry]

        struct Entry: Decodable, Equatable {
            let originalID: String
            let originalLabelIDs: [String]
            let forwardedCopyID: String?
            let forwardedCopyLabelIDs: [String]?
            let outcome: String
        }
    }

    func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func runCLI(_ arguments: [String], input: Data = Data()) throws -> (status: Int32, output: Data, error: String) {
        let directory = try temporaryDirectory()
        let errorFile = directory.appendingPathComponent("stderr")
        try Data().write(to: errorFile)
        let errorHandle = try FileHandle(forWritingTo: errorFile)
        defer { try? errorHandle.close() }

        let process = Process()
        process.executableURL = Bundle(for: CLITests.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("readrelay")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = errorHandle
        let inputFile = directory.appendingPathComponent("stdin")
        try input.write(to: inputFile)
        let inputHandle = try FileHandle(forReadingFrom: inputFile)
        defer { try? inputHandle.close() }
        process.standardInput = inputHandle
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data, try String(contentsOf: errorFile, encoding: .utf8))
    }
}
