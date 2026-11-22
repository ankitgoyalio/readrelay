import Foundation
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

    private struct ForwardingPreview: Decodable {
        struct Entry: Decodable { let outcome: String }
        let entries: [Entry]
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
