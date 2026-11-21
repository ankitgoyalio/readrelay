import Foundation
import SQLite3

struct RolloutState {
    let path: String

    /// Keep the reviewed starting point stable across previews and the first live sync.
    func cutoff(for configuration: Configuration, startedAt: Date) throws -> Int64 {
        guard !path.isEmpty else { throw RelayError("Provide a path for the SQLite rollout state.") }
        let filePath = URL(fileURLWithPath: path).path
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let status = sqlite3_open_v2(filePath, &database, flags, nil)
        defer { sqlite3_close(database) }
        guard status == SQLITE_OK, let database else {
            throw RelayError("Could not open the SQLite rollout state (status \(status)).")
        }

        let primary = configuration.primaryEmail.lowercased()
        let secondary = configuration.secondaryEmail.lowercased()
        let fiveDays: TimeInterval = 5 * 24 * 60 * 60
        let initialCutoff = Int64(startedAt.addingTimeInterval(-fiveDays).timeIntervalSince1970 * 1_000)

        sqlite3_busy_timeout(database, 5_000)
        try execute("""
            CREATE TABLE IF NOT EXISTS rollout (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                primary_email TEXT NOT NULL,
                secondary_email TEXT NOT NULL,
                cutoff_ms INTEGER NOT NULL
            )
            """, in: database)
        try execute("BEGIN IMMEDIATE", in: database)
        do {
            try prepare("""
                INSERT INTO rollout (singleton, primary_email, secondary_email, cutoff_ms)
                VALUES (1, ?, ?, ?) ON CONFLICT(singleton) DO NOTHING
                """, in: database) { statement in
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                guard sqlite3_bind_text(statement, 1, primary, -1, transient) == SQLITE_OK,
                      sqlite3_bind_text(statement, 2, secondary, -1, transient) == SQLITE_OK,
                      sqlite3_bind_int64(statement, 3, initialCutoff) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else {
                    throw RelayError("Could not save the initial cutoff.")
                }
            }
            let saved = try prepare(
                "SELECT primary_email, secondary_email, cutoff_ms FROM rollout WHERE singleton = 1",
                in: database
            ) { statement in
                guard sqlite3_step(statement) == SQLITE_ROW,
                      let savedPrimary = sqlite3_column_text(statement, 0),
                      let savedSecondary = sqlite3_column_text(statement, 1),
                      sqlite3_column_type(statement, 2) == SQLITE_INTEGER else {
                    throw RelayError("Could not load the initial cutoff.")
                }
                guard String(cString: savedPrimary) == primary, String(cString: savedSecondary) == secondary else {
                    throw RelayError("The SQLite rollout state belongs to a different mailbox pair.")
                }
                return sqlite3_column_int64(statement, 2)
            }
            try execute("COMMIT", in: database)
            return saved
        } catch {
            try? execute("ROLLBACK", in: database)
            throw error
        }
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        let status = sqlite3_exec(database, sql, nil, nil, nil)
        guard status == SQLITE_OK else {
            throw RelayError("Could not update the SQLite rollout state (status \(status)).")
        }
    }

    private func prepare<Value>(
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
