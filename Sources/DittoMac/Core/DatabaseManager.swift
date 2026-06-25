import Foundation
import GRDB

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private var dbPool: DatabasePool?
    private let historyLimitKey = "historyLimit"

    var historyLimit: Int {
        get { UserDefaults.standard.integer(forKey: historyLimitKey).clamped(to: 50...10_000, default: 500) }
        set { UserDefaults.standard.set(newValue, forKey: historyLimitKey) }
    }

    var databaseURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("DittoMac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clips.db")
    }

    var databaseSize: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: databaseURL.path),
              let size = attrs[.size] as? Int else { return "–" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    func setup() throws {
        var config = Configuration()
        config.prepareDatabase { db in
            // These PRAGMAs must run outside any transaction
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
            try db.execute(sql: "PRAGMA auto_vacuum=INCREMENTAL")
            try db.execute(sql: "PRAGMA busy_timeout=5000")
            try db.execute(sql: "PRAGMA cache_size=-16000")
        }
        let pool = try DatabasePool(path: databaseURL.path, configuration: config)
        self.dbPool = pool

        var migrator = DatabaseMigrator()
        migrator.eraseDatabaseOnSchemaChange = false

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS clips (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    contentType     TEXT NOT NULL,
                    content         TEXT NOT NULL,
                    contentRTF      BLOB,
                    contentImage    BLOB,
                    contentFiles    TEXT,
                    sourceApp       TEXT,
                    sourceAppName   TEXT,
                    createdAt       DATETIME NOT NULL,
                    lastPastedAt    DATETIME,
                    pasteCount      INTEGER NOT NULL DEFAULT 0,
                    isPinned        INTEGER NOT NULL DEFAULT 0,
                    pinOrder        INTEGER,
                    title           TEXT,
                    crc32           INTEGER NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_clips_createdAt ON clips(createdAt DESC);
                CREATE INDEX IF NOT EXISTS idx_clips_isPinned  ON clips(isPinned, pinOrder);
                CREATE INDEX IF NOT EXISTS idx_clips_crc32     ON clips(crc32);

                CREATE VIRTUAL TABLE IF NOT EXISTS clips_fts USING fts5(
                    content,
                    title,
                    content='clips',
                    content_rowid='id'
                );

                CREATE TRIGGER IF NOT EXISTS clips_ai AFTER INSERT ON clips BEGIN
                    INSERT INTO clips_fts(rowid, content, title) VALUES (new.id, new.content, new.title);
                END;

                CREATE TRIGGER IF NOT EXISTS clips_ad AFTER DELETE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, content, title)
                    VALUES ('delete', old.id, old.content, old.title);
                END;

                CREATE TRIGGER IF NOT EXISTS clips_au AFTER UPDATE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, content, title)
                    VALUES ('delete', old.id, old.content, old.title);
                    INSERT INTO clips_fts(rowid, content, title) VALUES (new.id, new.content, new.title);
                END;
            """)
        }

        try migrator.migrate(pool)
    }

    func insert(_ entry: ClipboardEntry) async throws {
        guard let pool = dbPool else { return }
        try await pool.write { db in
            var e = entry
            try e.insert(db)
        }
        try await enforceHistoryLimit()
    }

    func fetchRecent(limit: Int = 200) async throws -> [ClipboardEntry] {
        guard let pool = dbPool else { return [] }
        return try await pool.read { db in
            try ClipboardEntry.fetchAll(db, sql: """
                SELECT * FROM clips
                ORDER BY isPinned DESC,
                         CASE WHEN isPinned = 1 THEN pinOrder ELSE NULL END ASC,
                         createdAt DESC
                LIMIT ?
            """, arguments: [limit])
        }
    }

    func search(_ query: String, limit: Int = 200) async throws -> [ClipboardEntry] {
        guard let pool = dbPool else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return try await fetchRecent(limit: limit) }

        let ftsQuery = trimmed
            .split(separator: " ")
            .map { token -> String in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " ")

        return try await pool.read { db in
            try ClipboardEntry.fetchAll(db, sql: """
                SELECT clips.*
                FROM clips
                JOIN clips_fts ON clips.id = clips_fts.rowid
                WHERE clips_fts MATCH ?
                ORDER BY clips.isPinned DESC, bm25(clips_fts), clips.createdAt DESC
                LIMIT ?
            """, arguments: [ftsQuery, limit])
        }
    }

    func isDuplicate(crc32: UInt32) async throws -> Bool {
        guard let pool = dbPool else { return false }
        return try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips WHERE crc32 = ? ORDER BY createdAt DESC LIMIT 1", arguments: [crc32]) ?? 0 > 0
        }
    }

    func pin(_ entry: ClipboardEntry) async throws {
        guard let pool = dbPool, let id = entry.id else { return }
        let maxOrder = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(pinOrder), 0) FROM clips WHERE isPinned = 1") ?? 0
        }
        try await pool.write { db in
            try db.execute(sql: "UPDATE clips SET isPinned = 1, pinOrder = ? WHERE id = ?", arguments: [maxOrder + 1, id])
        }
    }

    func unpin(_ entry: ClipboardEntry) async throws {
        guard let pool = dbPool, let id = entry.id else { return }
        try await pool.write { db in
            try db.execute(sql: "UPDATE clips SET isPinned = 0, pinOrder = NULL WHERE id = ?", arguments: [id])
        }
    }

    func delete(_ entry: ClipboardEntry) async throws {
        guard let pool = dbPool, let id = entry.id else { return }
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM clips WHERE id = ?", arguments: [id])
        }
    }

    func clearHistory() async throws {
        guard let pool = dbPool else { return }
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM clips WHERE isPinned = 0")
        }
    }

    func recordPaste(id: Int64) async throws {
        guard let pool = dbPool else { return }
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE clips SET lastPastedAt = ?, pasteCount = pasteCount + 1 WHERE id = ?
            """, arguments: [Date(), id])
        }
    }

    func vacuum() async throws {
        guard let pool = dbPool else { return }
        try await pool.write { db in
            try db.execute(sql: "VACUUM")
        }
    }

    private func enforceHistoryLimit() async throws {
        guard let pool = dbPool else { return }
        let limit = historyLimit
        try await pool.write { db in
            try db.execute(sql: """
                DELETE FROM clips
                WHERE isPinned = 0 AND id NOT IN (
                    SELECT id FROM clips
                    WHERE isPinned = 0
                    ORDER BY createdAt DESC
                    LIMIT ?
                )
            """, arguments: [limit])
        }
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>, default defaultValue: Int) -> Int {
        guard self > 0 else { return defaultValue }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
