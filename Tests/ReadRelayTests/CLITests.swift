import Foundation
import XCTest

final class CLITests: XCTestCase {
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
