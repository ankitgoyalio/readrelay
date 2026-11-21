import Darwin
import Foundation
import SQLite3

final class RolloutState {
    struct Message {
        let originalID: String
        let copyID: String?
        let messageID: String?
        let completed: Bool
    }

    enum Batch: String {
        case reviewed = "previewed_backlog"
        case ongoing = "sync_work"
    }

    private let database: OpaquePointer
    let cutoff: Int64

    init(path: String, configuration: Configuration, previewStartedAt: Date? = nil) throws {
        guard !path.isEmpty else { throw RelayError("Provide a path for the SQLite rollout state.") }
        let filePath = URL(fileURLWithPath: path).path
        let create = previewStartedAt != nil
        if !create, !FileManager.default.fileExists(atPath: filePath) {
            throw RelayError("Run a successful dry run with this SQLite state before syncing.")
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        let status = sqlite3_open_v2(filePath, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw RelayError("Could not open the SQLite rollout state (status \(status)).")
        }

        let primary = configuration.primaryEmail.lowercased()
        let secondary = configuration.secondaryEmail.lowercased()
        sqlite3_busy_timeout(handle, 5_000)
        do {
            if let previewStartedAt {
                let fiveDays: TimeInterval = 5 * 24 * 60 * 60
                let initialCutoff = Int64(previewStartedAt.addingTimeInterval(-fiveDays).timeIntervalSince1970 * 1_000)
                try Self.execute("""
                    CREATE TABLE IF NOT EXISTS rollout (
                        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                        primary_email TEXT NOT NULL,
                        secondary_email TEXT NOT NULL,
                        cutoff_ms INTEGER NOT NULL
                    )
                    """, in: handle)
                try Self.prepare("""
                    INSERT INTO rollout (singleton, primary_email, secondary_email, cutoff_ms)
                    VALUES (1, ?, ?, ?) ON CONFLICT(singleton) DO NOTHING
                    """, in: handle) { statement in
                    try Self.bind(primary, to: statement, at: 1)
                    try Self.bind(secondary, to: statement, at: 2)
                    guard sqlite3_bind_int64(statement, 3, initialCutoff) == SQLITE_OK else {
                        throw RelayError("Could not bind the initial cutoff.")
                    }
                    try Self.finish(statement)
                }
            } else if try !Self.hasTable("rollout", in: handle) {
                throw RelayError("Run a successful dry run with this SQLite state before syncing.")
            }

            cutoff = try Self.prepare(
                "SELECT primary_email, secondary_email, cutoff_ms FROM rollout WHERE singleton = 1",
                in: handle
            ) { statement in
                guard sqlite3_step(statement) == SQLITE_ROW,
                      sqlite3_column_type(statement, 2) == SQLITE_INTEGER else {
                    throw RelayError("Could not load the initial cutoff. Run a successful dry run before syncing.")
                }
                guard Self.columnText(statement, 0) == primary, Self.columnText(statement, 1) == secondary else {
                    throw RelayError("The SQLite rollout state belongs to a different mailbox pair.")
                }
                return sqlite3_column_int64(statement, 2)
            }
        } catch {
            sqlite3_close(handle)
            throw error
        }
        database = handle
    }

    deinit { sqlite3_close(database) }

    static func withSyncLock<Value>(path: String, run: () async throws -> Value) async throws -> Value {
        let databasePath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let descriptor = open(databasePath + ".sync.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RelayError("Could not open the rollout sync lock.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw RelayError("Could not acquire the rollout sync lock. Another sync may be running.")
        }
        return try await run()
    }

    // The table is published with the entire first successful report, including an empty backlog.
    func savePreview(_ report: BacklogReport) throws {
        try transaction {
            guard try !Self.hasTable(Batch.reviewed.rawValue, in: database) else {
                throw RelayError("Another dry run saved the backlog. Run dry-run again to review it.")
            }
            try createBatch(.reviewed)
            try insert(report.entries.map { entry in
                Message(originalID: entry.originalID, copyID: entry.forwardedCopyID,
                        messageID: entry.messageID, completed: false)
            }, into: .reviewed)
        }
    }

    // Publishing the new batch also records that the full reviewed sync succeeded.
    func startIncrementalSync() throws {
        try transaction {
            try createBatch(.ongoing)
            try Self.execute("""
                INSERT INTO sync_work (original_id, copy_id, message_id, completed)
                SELECT original_id, copy_id, message_id, completed FROM previewed_backlog
                """, in: database)
        }
    }

    func saveDiscovered(_ messages: [Message]) throws {
        guard !messages.isEmpty else { return }
        try transaction {
            try insert(messages, into: .ongoing)
        }
    }

    private func transaction(_ update: () throws -> Void) throws {
        try Self.execute("BEGIN IMMEDIATE", in: database)
        do {
            try update()
            try Self.execute("COMMIT", in: database)
        } catch {
            try? Self.execute("ROLLBACK", in: database)
            throw error
        }
    }

    private func createBatch(_ batch: Batch) throws {
        try Self.execute("""
            CREATE TABLE \(batch.rawValue) (
                original_id TEXT PRIMARY KEY NOT NULL,
                copy_id TEXT,
                message_id TEXT,
                completed INTEGER NOT NULL DEFAULT 0 CHECK (completed IN (0, 1))
            )
            """, in: database)
    }

    private func insert(_ messages: [Message], into batch: Batch) throws {
        try Self.prepare("""
            INSERT INTO \(batch.rawValue) (original_id, copy_id, message_id) VALUES (?, ?, ?)
            """, in: database) { statement in
            for message in messages {
                try Self.bind(message.originalID, to: statement, at: 1)
                try Self.bind(message.copyID, to: statement, at: 2)
                try Self.bind(message.messageID, to: statement, at: 3)
                try Self.finish(statement)
                sqlite3_reset(statement)
            }
        }
    }

    func messages(in batch: Batch) throws -> [Message]? {
        guard try Self.hasTable(batch.rawValue, in: database) else { return nil }
        return try Self.prepare("""
            SELECT original_id, copy_id, message_id, completed FROM \(batch.rawValue) ORDER BY original_id
            """, in: database) { statement in
            var messages: [Message] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return messages }
                guard status == SQLITE_ROW, let originalID = Self.columnText(statement, 0) else {
                    throw RelayError("Could not load the saved sync work.")
                }
                messages.append(Message(
                    originalID: originalID,
                    copyID: Self.columnText(statement, 1),
                    messageID: Self.columnText(statement, 2),
                    completed: sqlite3_column_int(statement, 3) == 1
                ))
            }
        }
    }

    func saveMatch(originalID: String, copyID: String, messageID: String) throws {
        try Self.prepare("""
            UPDATE sync_work SET copy_id = ?, message_id = ? WHERE original_id = ? AND copy_id IS NULL
            """, in: database) { statement in
            try Self.bind(copyID, to: statement, at: 1)
            try Self.bind(messageID, to: statement, at: 2)
            try Self.bind(originalID, to: statement, at: 3)
            try Self.finish(statement)
            guard sqlite3_changes(database) == 1 else {
                throw RelayError("Could not save the match for the original message.")
            }
        }
    }

    func markCompleted(originalID: String, in batch: Batch) throws {
        try Self.prepare("UPDATE \(batch.rawValue) SET completed = 1 WHERE original_id = ?", in: database) { statement in
            try Self.bind(originalID, to: statement, at: 1)
            try Self.finish(statement)
            guard sqlite3_changes(database) == 1 else {
                throw RelayError("Could not save progress for the original message.")
            }
        }
    }

    private static func hasTable(_ table: String, in database: OpaquePointer) throws -> Bool {
        try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", in: database) { statement in
            try bind(table, to: statement, at: 1)
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW || status == SQLITE_DONE else {
                throw RelayError("Could not inspect the SQLite rollout state (status \(status)).")
            }
            return status == SQLITE_ROW
        }
    }

    private static func bind(_ text: String?, to statement: OpaquePointer, at index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status = text.map { sqlite3_bind_text(statement, index, $0, -1, transient) }
            ?? sqlite3_bind_null(statement, index)
        guard status == SQLITE_OK else {
            throw RelayError("Could not bind a SQLite rollout value (status \(status)).")
        }
    }

    private static func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    private static func finish(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            throw RelayError("Could not save the SQLite rollout state (status \(status)).")
        }
    }

    private static func execute(_ sql: String, in database: OpaquePointer) throws {
        let status = sqlite3_exec(database, sql, nil, nil, nil)
        guard status == SQLITE_OK else {
            throw RelayError("Could not update the SQLite rollout state (status \(status)).")
        }
    }

    private static func prepare<Value>(
        _ sql: String, in database: OpaquePointer, read: (OpaquePointer) throws -> Value
    ) throws -> Value {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard status == SQLITE_OK, let statement else {
            throw RelayError("Could not read the SQLite rollout state (status \(status)).")
        }
        return try read(statement)
    }
}
