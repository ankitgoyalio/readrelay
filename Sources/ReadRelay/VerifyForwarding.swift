import ArgumentParser
import Foundation

struct VerifyForwarding: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Verify a known labeled original and its forwarded copy."
    )

    @Argument(help: "Message-ID from Show original in the primary Gmail mailbox.")
    var messageID: String

    func run() async throws {
        guard let id = IndexedMessage.knownID(messageID) else {
            throw ValidationError("Copy one Message-ID from Show original in the primary Gmail mailbox.")
        }
        let paths = BetaPaths()
        _ = try paths.loadConfiguration()
        try await paths.withLock {
            let configuration = try paths.loadConfiguration()
            let mailboxes = try await paths.connect(configuration: configuration, unattended: false)
            let labelID = mailboxes.readRelayLabelID
            let originals = try await mailboxes.primary.messages(labelID: labelID)
                .filter { $0.labelIds?.contains(labelID) == true }

            switch match(id, in: originals) {
            case .missing:
                throw RelayError("No original with that Message-ID has the “\(configuration.primaryLabel)” label. In the primary mailbox, check the Message-ID and make sure the filter applies that label. Send a new test message and try again.")
            case .ambiguous:
                throw RelayError("The labeled original has an ambiguous Message-ID match. Send a new test message that matches the forwarding filter and use its Message-ID.")
            case .unique:
                break
            }

            let copies = try await mailboxes.secondary.messages()
            switch match(id, in: copies) {
            case .missing:
                throw RelayError("No matching forwarded copy in \(configuration.secondaryEmail). Check that the primary filter forwards to that address, then retry after delivery or send a new test message.")
            case .ambiguous:
                throw RelayError("The forwarded copy has an ambiguous Message-ID match in \(configuration.secondaryEmail). Check for overlapping forwarding filters and send a new test message.")
            case .unique:
                break
            }

            try paths.saveForwardingProof(for: configuration, labelID: labelID)
            print("Forwarding verified for “\(configuration.primaryLabel)” from \(configuration.primaryEmail) to \(configuration.secondaryEmail).")
        }
    }

    private func match(_ id: String, in messages: [GmailMessage]) -> IndexedMessage.Match {
        let candidates = messages.map(IndexedMessage.init).filter { $0.candidates.contains(id) }
        return IndexedMessage.match(id, among: candidates)
    }
}

private struct ForwardingProof: Codable, Equatable {
    let primaryEmail: String
    let secondaryEmail: String
    let primaryLabel: String
    let primaryLabelID: String

    init(configuration: Configuration, labelID: String) {
        primaryEmail = configuration.primaryEmail.lowercased()
        secondaryEmail = configuration.secondaryEmail.lowercased()
        primaryLabel = configuration.primaryLabel
        primaryLabelID = labelID
    }
}

extension BetaPaths {
    /// Call with the current Gmail label ID while holding the beta state lock.
    func hasForwardingProof(for configuration: Configuration, labelID: String) throws -> Bool {
        let forwardingProof = scopeFile("forwarding-proof", extension: "json", for: configuration)
        let data: Data
        do {
            data = try Data(contentsOf: forwardingProof)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        } catch {
            throw RelayError("Could not read the saved forwarding verification. Run readrelay verify-forwarding again.")
        }
        guard let saved = try? JSONDecoder().decode(ForwardingProof.self, from: data) else {
            throw RelayError("Could not read the saved forwarding verification. Run readrelay verify-forwarding again.")
        }
        return saved == ForwardingProof(configuration: configuration, labelID: labelID)
    }

    fileprivate func saveForwardingProof(for configuration: Configuration, labelID: String) throws {
        let forwardingProof = scopeFile("forwarding-proof", extension: "json", for: configuration)
        let proof = ForwardingProof(configuration: configuration, labelID: labelID)
        do {
            try JSONEncoder().encode(proof).write(to: forwardingProof, options: .atomic)
        } catch {
            throw RelayError("Could not save the forwarding verification. Check access to \(directory.path) and try again.")
        }
    }
}
