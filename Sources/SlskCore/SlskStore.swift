import Foundation
import SQLite3

// The client's own small database: the transfer queue, the history, blocked users and notes. It never touches the music library.

public final class SlskStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL?) {
        let path = url?.path ?? ":memory:"
        if let url { try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        if sqlite3_open(path, &db) != SQLITE_OK { db = nil; return }
        exec("PRAGMA journal_mode=WAL")
        exec("""
        CREATE TABLE IF NOT EXISTS transfers(id INTEGER PRIMARY KEY, kind TEXT, user TEXT, path TEXT, size INTEGER, done INTEGER, state TEXT, reason TEXT, dest TEXT, created REAL);
        CREATE TABLE IF NOT EXISTS history(id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, user TEXT, path TEXT, size INTEGER, finished REAL);
        CREATE TABLE IF NOT EXISTS bans(user TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS notes(user TEXT PRIMARY KEY, text TEXT);
        CREATE TABLE IF NOT EXISTS friends(user TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS wishlist(query TEXT PRIMARY KEY);
        """)
    }
    deinit { sqlite3_close(db) }

    @discardableResult private func exec(_ sql: String) -> Bool { lock.lock(); defer { lock.unlock() }; return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    private func run(_ sql: String, _ args: [Any?] = [], row: ((OpaquePointer) -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
        defer { sqlite3_finalize(st) }
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case let v as Int: sqlite3_bind_int64(st, n, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, n, v)
            case let v as UInt64: sqlite3_bind_int64(st, n, Int64(bitPattern: v))
            case let v as Double: sqlite3_bind_double(st, n, v)
            case let v as String: sqlite3_bind_text(st, n, v, -1, T)
            default: sqlite3_bind_null(st, n)
            }
        }
        while sqlite3_step(st) == SQLITE_ROW { row?(st) }
    }
    private static func text(_ st: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }

    // transfers
    public struct Saved: Equatable {
        public var id: Int, kind: String, user: String, path: String, size: UInt64, done: UInt64, state: String, reason: String, dest: String
        public init(id: Int, kind: String, user: String, path: String, size: UInt64, done: UInt64, state: String, reason: String, dest: String) {
            self.id = id; self.kind = kind; self.user = user; self.path = path; self.size = size; self.done = done; self.state = state; self.reason = reason; self.dest = dest
        }
    }
    public func save(_ s: Saved) {
        run("INSERT OR REPLACE INTO transfers(id,kind,user,path,size,done,state,reason,dest,created) VALUES(?,?,?,?,?,?,?,?,?,?)", [s.id, s.kind, s.user, s.path, s.size, s.done, s.state, s.reason, s.dest, Date().timeIntervalSince1970])
    }
    public func remove(id: Int) { run("DELETE FROM transfers WHERE id=?", [id]) }
    public func load() -> [Saved] {
        var out: [Saved] = []
        run("SELECT id,kind,user,path,size,done,state,reason,dest FROM transfers ORDER BY id") { st in
            out.append(Saved(id: Int(sqlite3_column_int64(st, 0)), kind: Self.text(st, 1), user: Self.text(st, 2), path: Self.text(st, 3), size: UInt64(bitPattern: sqlite3_column_int64(st, 4)), done: UInt64(bitPattern: sqlite3_column_int64(st, 5)), state: Self.text(st, 6), reason: Self.text(st, 7), dest: Self.text(st, 8)))
        }
        return out
    }
    public func addHistory(kind: String, user: String, path: String, size: UInt64) { run("INSERT INTO history(kind,user,path,size,finished) VALUES(?,?,?,?,?)", [kind, user, path, size, Date().timeIntervalSince1970]) }
    public func historyCount() -> Int { var n = 0; run("SELECT COUNT(*) FROM history") { n = Int(sqlite3_column_int64($0, 0)) }; return n }

    // bans, notes, friends, wishlist
    public func ban(_ u: String, _ on: Bool) { run(on ? "INSERT OR IGNORE INTO bans(user) VALUES(?)" : "DELETE FROM bans WHERE user=?", [u]) }
    public func isBanned(_ u: String) -> Bool { var b = false; run("SELECT 1 FROM bans WHERE user=?", [u]) { _ in b = true }; return b }
    public func bans() -> [String] { var o: [String] = []; run("SELECT user FROM bans ORDER BY user") { o.append(Self.text($0, 0)) }; return o }
    public func setNote(_ u: String, _ t: String) { t.isEmpty ? run("DELETE FROM notes WHERE user=?", [u]) : run("INSERT OR REPLACE INTO notes(user,text) VALUES(?,?)", [u, t]) }
    public func note(_ u: String) -> String { var s = ""; run("SELECT text FROM notes WHERE user=?", [u]) { s = Self.text($0, 0) }; return s }
    public func friend(_ u: String, _ on: Bool) { run(on ? "INSERT OR IGNORE INTO friends(user) VALUES(?)" : "DELETE FROM friends WHERE user=?", [u]) }
    public func friends() -> [String] { var o: [String] = []; run("SELECT user FROM friends ORDER BY user") { o.append(Self.text($0, 0)) }; return o }
    public func wish(_ q: String, _ on: Bool) { run(on ? "INSERT OR IGNORE INTO wishlist(query) VALUES(?)" : "DELETE FROM wishlist WHERE query=?", [q]) }
    public func wishes() -> [String] { var o: [String] = []; run("SELECT query FROM wishlist ORDER BY query") { o.append(Self.text($0, 0)) }; return o }
}
