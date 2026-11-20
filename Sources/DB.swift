// mFONTS — petit enveloppe SQLite (catalogue et lecture de la base de Right Fonts).
import Foundation
import SQLite3

final class DB {
    private var h: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct Row {
        let s: OpaquePointer
        func text(_ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(s, i)) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(s, i) }
    }

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK else { throw DBError(msg: "open \(path)") }
        sqlite3_busy_timeout(h, 3000)
    }
    deinit { sqlite3_close(h) }

    struct DBError: LocalizedError { let msg: String; var errorDescription: String? { msg } }

    private func bind(_ st: OpaquePointer, _ args: [Any?]) {
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case let v as String: sqlite3_bind_text(st, n, v, -1, DB.transient)
            case let v as Int: sqlite3_bind_int64(st, n, Int64(v))
            case let v as Bool: sqlite3_bind_int64(st, n, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(st, n, v)
            default: sqlite3_bind_null(st, n)
            }
        }
    }

    func exec(_ sql: String, _ args: [Any?] = []) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK, let st else { throw DBError(msg: String(cString: sqlite3_errmsg(h))) }
        defer { sqlite3_finalize(st) }
        bind(st, args)
        let r = sqlite3_step(st)
        guard r == SQLITE_DONE || r == SQLITE_ROW else { throw DBError(msg: String(cString: sqlite3_errmsg(h))) }
    }

    func query(_ sql: String, _ args: [Any?] = [], _ each: (Row) -> Void) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK, let st else { throw DBError(msg: String(cString: sqlite3_errmsg(h))) }
        defer { sqlite3_finalize(st) }
        bind(st, args)
        while sqlite3_step(st) == SQLITE_ROW { each(Row(s: st)) }
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }
}
