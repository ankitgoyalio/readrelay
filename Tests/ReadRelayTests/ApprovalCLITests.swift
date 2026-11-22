import Darwin
import Foundation
import SQLite3
import XCTest

extension CLITests {
    func testApprovalRequiresTheCodeFromTheCurrentPreviewBeforeConnecting() throws {
        let home = try temporaryDirectory()
        try approvalFixture(home: home, evidence: true)

        let result = try runCLI(["approve", "earlier-review"], home: home)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.error.contains("Run readrelay preview and use its current review code"), result.error)
        let status = try runCLI(["status"], home: home)
        XCTAssertTrue(String(decoding: status.output, as: UTF8.self).contains("Mode: Preview"))
    }

    func testApprovalRequiresTheHomebrewJobToPreviewTheSavedBacklog() throws {
        let home = try temporaryDirectory()
        try approvalFixture(home: home, evidence: false)

        let result = try runCLI(["approve", "current-review"], home: home)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.error.contains("wait for a successful unattended preview"), result.error)
    }

    func testApprovalRequiresAnUnattendedPreviewNewerThanTheLatestServiceFailure() throws {
        let home = try temporaryDirectory()
        let directory = try approvalFixture(home: home, evidence: true, approved: true)
        let logs = directory.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let failureFile = logs.appendingPathComponent("latest-failure.json")
        let oldSuccess = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in [1.0, -1.0] {
            let failure = try JSONSerialization.data(withJSONObject: [
                "date": oldSuccess.addingTimeInterval(offset).timeIntervalSinceReferenceDate,
                "message": "Mailbox access failed."
            ])
            try failure.write(to: failureFile)

            let result = try runCLI(["approve", "current-review"], home: home)
            XCTAssertNotEqual(result.status, 0)
            let expected = offset > 0 ? "wait for a successful unattended preview" : "Run readrelay verify-forwarding"
            XCTAssertTrue(result.error.contains(expected), result.error)
            XCTAssertTrue(try statusOutput(home: home).contains("Mode: Live"))
        }
    }

    func testApprovalRequiresAnUnattendedPreviewNewerThanAGrantReplacement() throws {
        let home = try temporaryDirectory()
        let directory = try approvalFixture(home: home, evidence: true, approved: true)
        let marker = directory.appendingPathComponent("grant-replacement.json")
        let oldSuccess = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in [1.0, -1.0] {
            try JSONEncoder().encode(oldSuccess.addingTimeInterval(offset)).write(to: marker)

            let result = try runCLI(["approve", "current-review"], home: home)
            XCTAssertNotEqual(result.status, 0)
            let expected = offset > 0 ? "wait for a successful unattended preview" : "Run readrelay verify-forwarding"
            XCTAssertTrue(result.error.contains(expected), result.error)
            XCTAssertTrue(try statusOutput(home: home).contains("Mode: Live"))
        }
    }

    func testApprovalRequiresForwardingProofForTheSavedLabelID() throws {
        let home = try temporaryDirectory()
        let directory = try approvalFixture(home: home, evidence: true)
        try Data("""
            {"primaryEmail":"primary@example.com","secondaryEmail":"secondary@example.com",
             "primaryLabel":"ReadRelay","primaryLabelID":"Recreated_Label"}
            """.utf8).write(to: directory.appendingPathComponent("forwarding-proof.json"))

        let result = try runCLI(["approve", "current-review"], home: home)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.error.contains("Run readrelay verify-forwarding"), result.error)
    }

    func testApprovalRejectsAReportThatChangedAfterItsCodeWasIssued() throws {
        let home = try temporaryDirectory()
        let directory = try approvalFixture(home: home, evidence: true)
        try Data("""
            {"primaryEmail":"primary@example.com","secondaryEmail":"secondary@example.com",
             "primaryLabel":"ReadRelay","primaryLabelID":"Label_123"}
            """.utf8).write(to: directory.appendingPathComponent("forwarding-proof.json"))
        try Data("""
            {"cutoffEpochMilliseconds":1700000000000,"entries":[]}
            """.utf8).write(to: directory.appendingPathComponent("preview.json"))

        let result = try runCLI(["approve", "current-review"], home: home)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.error.contains("preview has changed"), result.error)
    }

    func testRevokeSucceedsOnlyAfterTheRunningJobReleasesTheLock() throws {
        let home = try temporaryDirectory()
        let directory = try approvalFixture(home: home, evidence: true, approved: true)
        let lock = open(directory.appendingPathComponent("beta.lock").path, O_CREAT | O_RDWR, 0o600)
        defer { close(lock) }
        XCTAssertGreaterThanOrEqual(lock, 0)
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)

        let blocked = try runCLI(["revoke"], home: home)
        XCTAssertNotEqual(blocked.status, 0)
        XCTAssertTrue(blocked.error.contains("Wait for the current ReadRelay command"), blocked.error)
        XCTAssertTrue(try statusOutput(home: home).contains("Mode: Live"))

        XCTAssertEqual(flock(lock, LOCK_UN), 0)
        let revoked = try runCLI(["revoke"], home: home)
        XCTAssertEqual(revoked.status, 0, revoked.error)
        XCTAssertTrue(try statusOutput(home: home).contains("Mode: Preview"))

        let replay = try runCLI(["approve", "current-review"], home: home)
        XCTAssertNotEqual(replay.status, 0)
        XCTAssertTrue(replay.error.contains("use its current review code"), replay.error)
    }

    func testReconnectRetriesAfterTheBetaLockIsReleasedAndIdentifiesTheSavedAccount() throws {
        let home = try temporaryDirectory()
        let directory = try approvalFixture(home: home, evidence: true, approved: true)
        let config = directory.appendingPathComponent("config.json")
        let savedConfig = try Data(contentsOf: config)
        let state = directory.appendingPathComponent("state.sqlite")
        let savedState = try Data(contentsOf: state)
        let lock = open(directory.appendingPathComponent("beta.lock").path, O_CREAT | O_RDWR, 0o600)
        defer { close(lock) }
        XCTAssertGreaterThanOrEqual(lock, 0)
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)

        let blocked = try runCLI(["reconnect", "secondary"], home: home)
        XCTAssertNotEqual(blocked.status, 0)
        XCTAssertTrue(blocked.error.contains("Wait for the current ReadRelay command"), blocked.error)

        XCTAssertEqual(flock(lock, LOCK_UN), 0)
        let retried = try runCLI(["reconnect", "secondary"], home: home)
        XCTAssertNotEqual(retried.status, 0)
        XCTAssertTrue(retried.error.contains("secondary mailbox (secondary@example.com)"), retried.error)
        XCTAssertTrue(retried.error.contains("Google Desktop OAuth client JSON"), retried.error)
        XCTAssertTrue(try statusOutput(home: home).contains("Mode: Live"))
        XCTAssertEqual(try Data(contentsOf: config), savedConfig)
        XCTAssertEqual(try Data(contentsOf: state), savedState)
    }

    func testPreviewNamesTheAccountWhenItsDesktopClientCannotBeRead() throws {
        let home = try temporaryDirectory()
        try approvalFixture(home: home, evidence: true, approved: true)

        let preview = try runCLI(["preview", "--unattended"], home: home)

        XCTAssertNotEqual(preview.status, 0)
        XCTAssertTrue(preview.error.contains("primary mailbox (primary@example.com)"), preview.error)
        XCTAssertTrue(preview.error.contains("Restore the saved Desktop OAuth client JSON"), preview.error)
        XCTAssertFalse(preview.error.contains("readrelay reconnect primary"), preview.error)
    }

    func testStatusMarksAnEarlierReconnectFailureAsFollowedBySuccess() throws {
        let home = try temporaryDirectory()
        let directory = try approvalFixture(home: home, evidence: true, approved: true)
        let logs = directory.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let failureFile = logs.appendingPathComponent("latest-failure.json")
        let message = "Could not access the secondary mailbox (secondary@example.com). "
            + "Google rejected the refresh token. Run readrelay reconnect secondary."
        let serviceSuccess = Date(timeIntervalSince1970: 1_700_000_001)
        for secondsAfterSuccess in [1.0, -1.0] {
            let date = serviceSuccess.addingTimeInterval(secondsAfterSuccess).timeIntervalSinceReferenceDate
            let failure = try JSONSerialization.data(withJSONObject: ["date": date, "message": message])
            try failure.write(to: failureFile)

            let status = try statusOutput(home: home)
            XCTAssertTrue(status.contains(message), status)
            XCTAssertEqual(status.contains("(followed by a successful run)"), secondsAfterSuccess < 0, status)
            XCTAssertTrue(status.contains("Mode: Live"), status)
        }
    }

    func testChangingTheLabelStartsInPreviewAndRejectsTheOldReviewCode() throws {
        let home = try temporaryDirectory()
        try approvalFixture(home: home, evidence: true, approved: true)

        let changed = try runCLI(["set-label", "New label"], home: home)
        XCTAssertEqual(changed.status, 0, changed.error)
        let status = try statusOutput(home: home)
        XCTAssertTrue(status.contains("Mode: Preview"), status)
        XCTAssertTrue(status.contains("Primary label: New label"), status)
        XCTAssertTrue(status.contains("Last successful run: None"), status)

        let replay = try runCLI(["approve", "current-review"], home: home)
        XCTAssertNotEqual(replay.status, 0)
        XCTAssertTrue(replay.error.contains("use its current review code"), replay.error)
    }

    func testManualSyncRejectsABetaStateThroughAnAlias() throws {
        let home = try temporaryDirectory()
        let directory = try approvalFixture(home: home, evidence: true)
        let config = home.appendingPathComponent("manual.json")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("config.json"), to: config)
        let alias = home.appendingPathComponent("alias.sqlite")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory.appendingPathComponent("state.sqlite"))

        let result = try runCLI(["sync", "--apply", "--config", config.path, "--state", alias.path], home: home)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.error.contains("for the Homebrew setup"), result.error)
        XCTAssertTrue(try statusOutput(home: home).contains("Mode: Preview"))
    }

    func testDocumentedManualLaunchAgentPathsWorkAlongsideBetaState() throws {
        let home = try temporaryDirectory()
        let directory = try approvalFixture(home: home, evidence: true)
        let config = directory.appendingPathComponent("readrelay.json")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("config.json"), to: config)
        let state = directory.appendingPathComponent("launchd-preview.sqlite")

        let agent = try runCLI([
            "launch-agent", "--executable", directory.appendingPathComponent("bin/readrelay").path,
            "--config", config.path, "--state", state.path,
            "--log-directory", directory.appendingPathComponent("logs/preview").path
        ], home: home)
        XCTAssertEqual(agent.status, 0, agent.error)
        let plist = try PropertyListSerialization.propertyList(from: agent.output, options: [], format: nil)
        let arguments = try XCTUnwrap((plist as? [String: Any])?["ProgramArguments"] as? [String])
        let preview = try runCLI(Array(arguments.dropFirst()), home: home)
        XCTAssertNotEqual(preview.status, 0)
        XCTAssertTrue(preview.error.contains("Could not read the Google Desktop OAuth client JSON"), preview.error)
    }

    private func statusOutput(home: URL) throws -> String {
        let result = try runCLI(["status"], home: home)
        XCTAssertEqual(result.status, 0, result.error)
        return String(decoding: result.output, as: UTF8.self)
    }

    @discardableResult
    private func approvalFixture(home: URL, evidence: Bool, approved: Bool = false) throws -> URL {
        let directory = home.appendingPathComponent("Library/Application Support/ReadRelay")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
            {"primaryEmail":"primary@example.com","secondaryEmail":"secondary@example.com",
             "primaryOAuthClientFile":"unused.json","secondaryOAuthClientFile":"unused.json",
             "enableWrites":true}
            """.utf8).write(to: directory.appendingPathComponent("config.json"))
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("state.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, """
            CREATE TABLE rollout (singleton INTEGER PRIMARY KEY, primary_email TEXT,
                                  secondary_email TEXT, cutoff_ms INTEGER, primary_label TEXT);
            INSERT INTO rollout VALUES (1, 'primary@example.com', 'secondary@example.com', 1700000000000, 'ReadRelay');
            CREATE TABLE previewed_backlog (original_id TEXT, copy_id TEXT, message_id TEXT, completed INTEGER);
            INSERT INTO previewed_backlog VALUES ('pending-original', 'pending-copy', 'pending@example.com', 0);
            CREATE TABLE beta_scope (singleton INTEGER PRIMARY KEY, label_id TEXT, review_code TEXT,
                                     report_digest TEXT, approved_review_code TEXT, live_succeeded_at REAL);
            INSERT INTO beta_scope VALUES (1, 'Label_123', 'current-review', 'digest', NULL, NULL);
            CREATE TABLE homebrew_preview (singleton INTEGER PRIMARY KEY, succeeded_at REAL);
            """, nil, nil, nil), SQLITE_OK)
        if evidence {
            XCTAssertEqual(sqlite3_exec(database, """
                INSERT INTO homebrew_preview VALUES (1, 1700000000.0);
                """, nil, nil, nil), SQLITE_OK)
        }
        if approved {
            XCTAssertEqual(sqlite3_exec(database, """
                UPDATE beta_scope SET approved_review_code = review_code, live_succeeded_at = 1700000001.0;
                """, nil, nil, nil), SQLITE_OK)
        }
        return directory
    }
}
