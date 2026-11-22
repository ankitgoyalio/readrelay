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
