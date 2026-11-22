import Foundation
import SQLite3
import XCTest

extension CLITests {
    func testVerifyForwardingWithNoMailboxPairGivesSetupInstructions() throws {
        let home = try temporaryDirectory()

        let result = try runCLI(["verify-forwarding", "<test@example.com>"], home: home)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.error.contains("Run readrelay setup first."), result.error)
        XCTAssertTrue(result.output.isEmpty)
    }

    func testVerifyForwardingRejectsAnInvalidMessageIDBeforeConnecting() throws {
        let home = try temporaryDirectory()

        let result = try runCLI(["verify-forwarding", "<first@example.com> <second@example.com>"], home: home)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.error.contains("Copy one Message-ID from Show original"), result.error)
        XCTAssertTrue(result.output.isEmpty)
    }

    func testVerifyForwardingAcceptsAnAlreadyReadPairAndPreservesItsLabels() throws {
        let (home, messageID) = try forwardingFixture("READRELAY_FORWARDING_TEST_RECENT_MESSAGE_ID")
        let before = try forwardingPreview(home: home)
        let preview = try JSONDecoder().decode(ForwardingPreview.self, from: before)
        XCTAssertEqual(preview.entries.map(\.outcome), ["copyAlreadyRead"], "Use a label with one recent, already-read test pair.")

        let verification = try runCLI(["verify-forwarding", messageID], home: home)
        XCTAssertEqual(verification.status, 0, verification.error)
        XCTAssertTrue(String(decoding: verification.output, as: UTF8.self).contains("Forwarding verified"))
        XCTAssertEqual(try forwardingPreview(home: home), before)
    }

    func testVerifyForwardingFindsAPairOutsideAnEmptyPreview() throws {
        let (home, messageID) = try forwardingFixture("READRELAY_FORWARDING_TEST_OLDER_MESSAGE_ID")
        let before = try forwardingPreview(home: home)
        let preview = try JSONDecoder().decode(ForwardingPreview.self, from: before)
        XCTAssertTrue(preview.entries.isEmpty, "Use a label with no originals in the five-day window.")

        let verification = try runCLI(["verify-forwarding", messageID], home: home)
        XCTAssertEqual(verification.status, 0, verification.error)
        XCTAssertTrue(String(decoding: verification.output, as: UTF8.self).contains("Forwarding verified"))
        XCTAssertEqual(try forwardingPreview(home: home), before)
    }

    func testBetaPreviewUsesARecentCutoffAfterAnEarlierFailedScan() throws {
        let (home, _) = try forwardingFixture("READRELAY_FORWARDING_TEST_RECENT_MESSAGE_ID")
        _ = try forwardingPreview(home: home)
        try stageBetaState(home: home, sql: """
            DROP TABLE beta_scope;
            DROP TABLE previewed_backlog;
            UPDATE rollout SET cutoff_ms = 1700000000000;
            """)

        let fiveDaysAgo = Date().addingTimeInterval(-120 * 60 * 60)
        let first = try JSONDecoder().decode(ForwardingPreview.self, from: forwardingPreview(home: home))
        XCTAssertGreaterThanOrEqual(first.cutoffEpochMilliseconds, Int64(fiveDaysAgo.timeIntervalSince1970 * 1_000))
        let repeated = try JSONDecoder().decode(ForwardingPreview.self, from: forwardingPreview(home: home))
        XCTAssertEqual(repeated.cutoffEpochMilliseconds, first.cutoffEpochMilliseconds)
    }

    func testBetaPreviewReportsSavedPendingWorkAndOmitsCompletedOriginals() throws {
        let (home, _) = try forwardingFixture("READRELAY_FORWARDING_TEST_RECENT_MESSAGE_ID")
        let first = try JSONDecoder().decode(ForwardingPreview.self, from: forwardingPreview(home: home))
        XCTAssertEqual(first.entries.count, 1, "Use a label with one recent test pair.")
        try stageBetaState(home: home, sql: """
            CREATE TABLE sync_work AS SELECT * FROM previewed_backlog;
            UPDATE sync_work SET completed = 1;
            INSERT INTO sync_work VALUES ('pending-unavailable', NULL, NULL, 0);
            """)

        let recurring = try JSONDecoder().decode(ForwardingPreview.self, from: forwardingPreview(home: home))
        XCTAssertEqual(recurring.cutoffEpochMilliseconds, first.cutoffEpochMilliseconds)
        XCTAssertEqual(recurring.entries.map(\.originalID), ["pending-unavailable"])
        XCTAssertEqual(recurring.entries.map(\.outcome), ["originalUnavailable"])
    }

    private struct ForwardingPreview: Decodable {
        struct Entry: Decodable {
            let originalID: String
            let outcome: String
        }
        let cutoffEpochMilliseconds: Int64
        let entries: [Entry]
    }

    private func stageBetaState(home: URL, sql: String) throws {
        let directory = home.appendingPathComponent("Library/Application Support/ReadRelay")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let state = try XCTUnwrap(files.first { $0.pathExtension == "sqlite" })
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_open_v2(state.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }

    private func forwardingFixture(_ messageVariable: String) throws -> (home: URL, messageID: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let setup = environment["READRELAY_FORWARDING_TEST_SETUP"],
              let messageID = environment[messageVariable] else {
            throw XCTSkip("Set READRELAY_FORWARDING_TEST_SETUP and \(messageVariable) to opt in.")
        }
        let home = try temporaryDirectory()
        let destination = home.appendingPathComponent("Library/Application Support/ReadRelay")
        let source = URL(fileURLWithPath: setup)
        let files = FileManager.default
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["config.json", "oauth-client.json"] {
            try files.copyItem(at: source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
        }
        return (home, messageID)
    }

    private func forwardingPreview(home: URL) throws -> Data {
        let result = try runCLI(["preview", "--json"], home: home)
        XCTAssertEqual(result.status, 0, result.error)
        return result.output
    }
}
