import Foundation
import SQLite3

/// Local SQLite sync-state DB — an **audit log** of completed pulls.
/// iOS port of the desktop `stbox-viz-gui/src/sync_db.rs`
/// (movement_logger_desktop issues #3/#4, audit-only as of #14).
///
/// As of the v0.0.14 live-mirror model the sync *decision* is made by
/// comparing the local mirror file's size to the box's reported size
/// (see `mirrorOffset` / `runSyncDiff` in `FileSyncViewModel`), which is
/// what makes a continuously-growing log fetch only its new tail. This
/// table is no longer consulted to decide what to fetch; it's kept as a
/// per-box record of "this file reached this size at this time, saved
/// here" for history/debugging.
///
/// Policy (user decision, desktop v0.0.6, locked): sync is **purely
/// additive** — it never issues DELETE. Nothing on the box is ever removed
/// by a sync.
///
/// Uses the system `SQLite3` module — no external dependency, consistent
/// with the desktop's `rusqlite bundled` choice (self-contained, no
/// reliance on a system libsqlite the host might not have).
final class SyncDb {

    /// `<Application Support>/sqlite/sync.db`.
    ///
    /// Anchored to Application Support, *not* the app's `Documents/` folder
    /// where the downloaded CSVs land. `Documents/` is user-visible and
    /// user-deletable via the Files app (`UIFileSharingEnabled`); putting
    /// the DB there would let a user wipe sync history by tidying their
    /// files, and is the iOS analogue of the desktop's "anchored to $HOME,
    /// not the download folder" rule. The DB lives in its own `sqlite/`
    /// subdir so the data root stays tidy if other state is added next to
    /// it later (mirrors desktop issue #4's flat-file → `sqlite/` move).
    static func defaultDbPath() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("sqlite", isDirectory: true)
                   .appendingPathComponent("sync.db")
    }

    private var db: OpaquePointer?

    /// Open (creating the file + parent dir + schema if missing). Returns
    /// nil if the DB can't be opened — callers degrade to "nothing synced"
    /// rather than crashing the Sync tab.
    init?(path: URL = SyncDb.defaultDbPath()) {
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        // `size` is part of the primary key on purpose: the firmware reuses
        // session-style names, and a file that grew (new session, same
        // name) must count as a *new* file and be re-pulled rather than
        // silently skipped. Schema is byte-for-byte the desktop's.
        let schema = """
        CREATE TABLE IF NOT EXISTS synced_files (
            box_id        TEXT    NOT NULL,
            name          TEXT    NOT NULL,
            size          INTEGER NOT NULL,
            downloaded_at TEXT    NOT NULL,
            local_path    TEXT    NOT NULL,
            PRIMARY KEY (box_id, name, size)
        );
        """
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK {
            sqlite3_close(db)
            return nil
        }
    }

    deinit { sqlite3_close(db) }

    /// Record a successfully-saved file. INSERT OR REPLACE so a re-download
    /// of the same triple just refreshes the timestamp / path instead of
    /// erroring on the primary key.
    @discardableResult
    func markSynced(boxId: String, name: String, size: Int64, localPath: String) -> Bool {
        let sql = """
        INSERT OR REPLACE INTO synced_files
            (box_id, name, size, downloaded_at, local_path)
        VALUES (?1, ?2, ?3, ?4, ?5)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        let nowIso = ISO8601DateFormatter().string(from: Date())
        sqlite3_bind_text(stmt, 1, boxId, -1, SQLiteDb.transient)
        sqlite3_bind_text(stmt, 2, name, -1, SQLiteDb.transient)
        sqlite3_bind_int64(stmt, 3, size)
        sqlite3_bind_text(stmt, 4, nowIso, -1, SQLiteDb.transient)
        sqlite3_bind_text(stmt, 5, localPath, -1, SQLiteDb.transient)
        return sqlite3_step(stmt) == SQLITE_DONE
    }
}

/// SQLITE_TRANSIENT tells SQLite to copy the bound string immediately —
/// required because the Swift `String` bridge buffer doesn't outlive the
/// `sqlite3_bind_text` call. Hoisted into one place so every bind site uses
/// the same destructor constant.
private enum SQLiteDb {
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
