#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#endif
import Foundation

/// Erreur SQLite. Le message ne contient jamais de données utilisateur (pas de valeurs liées).
public struct DatabaseError: Error, Sendable, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public let context: String

    public var description: String { "\(context): SQLite \(code) — \(message)" }
}

/// Valeur liée à une requête préparée.
enum SQLValue: Sendable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null

    static func int(_ value: Int) -> SQLValue { .integer(Int64(value)) }

    static func bool(_ value: Bool) -> SQLValue { .integer(value ? 1 : 0) }

    static func date(_ value: Date?) -> SQLValue {
        value.map { .real($0.timeIntervalSince1970) } ?? .null
    }

    static func optionalText(_ value: String?) -> SQLValue {
        value.map(SQLValue.text) ?? .null
    }

    static func optionalInt(_ value: Int?) -> SQLValue {
        value.map { .integer(Int64($0)) } ?? .null
    }
}

/// Indique à SQLite de copier immédiatement les chaînes liées.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Connexion SQLite minimale. Non thread-safe : elle est confinée à l'acteur `PhotoSwipeStore`.
final class SQLiteConnection {
    enum Location {
        case file(URL)
        case inMemory
    }

    private let handle: OpaquePointer

    init(location: Location) throws {
        let path: String
        switch location {
        case .file(let url): path = url.path
        case .inMemory: path = ":memory:"
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close_v2(db) }
            throw DatabaseError(code: code, message: message, context: "open")
        }
        handle = db
        sqlite3_busy_timeout(db, 2_000)
        // WAL : chaque transaction validée survit à une fermeture forcée de l'app.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard code == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorPointer)
            throw DatabaseError(code: code, message: message, context: "exec")
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw DatabaseError(code: code, message: lastErrorMessage, context: "prepare")
        }
        return SQLiteStatement(handle: statement, connection: self)
    }

    /// Exécute une requête sans résultat.
    func run(_ sql: String, _ arguments: [SQLValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(arguments)
        while try statement.step() {}
    }

    func query<T>(_ sql: String, _ arguments: [SQLValue] = [], map: (SQLiteRow) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(arguments)
        var results: [T] = []
        while try statement.step() {
            results.append(try map(SQLiteRow(handle: statement.handle)))
        }
        return results
    }

    func scalarInt(_ sql: String, _ arguments: [SQLValue] = []) throws -> Int64? {
        try query(sql, arguments) { row in row.isNull(0) ? nil : row.int64(0) }.first ?? nil
    }

    /// Transaction `IMMEDIATE` : verrou d'écriture pris dès le début, annulation en cas d'erreur.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let result = try body()
            try execute("COMMIT TRANSACTION;")
            return result
        } catch {
            try? execute("ROLLBACK TRANSACTION;")
            throw error
        }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }
}

final class SQLiteStatement {
    let handle: OpaquePointer
    private let connection: SQLiteConnection

    fileprivate init(handle: OpaquePointer, connection: SQLiteConnection) {
        self.handle = handle
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(handle)
    }

    /// Réinitialise la requête puis lie les arguments (index à partir de 1).
    func bind(_ arguments: [SQLValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (offset, value) in arguments.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .integer(let number): code = sqlite3_bind_int64(handle, index, number)
            case .real(let number): code = sqlite3_bind_double(handle, index, number)
            case .text(let string): code = sqlite3_bind_text(handle, index, string, -1, sqliteTransient)
            case .null: code = sqlite3_bind_null(handle, index)
            }
            guard code == SQLITE_OK else {
                throw DatabaseError(code: code, message: connection.lastErrorMessage, context: "bind")
            }
        }
    }

    /// Avance d'une ligne. Renvoie `false` quand la requête est terminée.
    func step() throws -> Bool {
        let code = sqlite3_step(handle)
        switch code {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw DatabaseError(code: code, message: connection.lastErrorMessage, context: "step")
        }
    }

    var row: SQLiteRow { SQLiteRow(handle: handle) }
}

struct SQLiteRow {
    let handle: OpaquePointer

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(handle, column) == SQLITE_NULL
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(handle, column))
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(handle, column)
    }

    func text(_ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(handle, column) else { return "" }
        return String(cString: pointer)
    }

    func optionalText(_ column: Int32) -> String? {
        isNull(column) ? nil : text(column)
    }

    func optionalInt(_ column: Int32) -> Int? {
        isNull(column) ? nil : int(column)
    }

    func optionalDouble(_ column: Int32) -> Double? {
        isNull(column) ? nil : double(column)
    }

    func optionalInt64(_ column: Int32) -> Int64? {
        isNull(column) ? nil : int64(column)
    }

    func optionalDate(_ column: Int32) -> Date? {
        isNull(column) ? nil : Date(timeIntervalSince1970: double(column))
    }

    func date(_ column: Int32) -> Date {
        Date(timeIntervalSince1970: double(column))
    }
}
