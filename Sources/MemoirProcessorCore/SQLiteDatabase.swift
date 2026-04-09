import Foundation
import SQLite3

public final class SQLiteDatabase: @unchecked Sendable {
    private let dbPointer: OpaquePointer
    private let queue = DispatchQueue(label: "MemoirProcessor.SQLiteDatabase")

    public init(path: String) throws {
        var pointer: OpaquePointer?
        if sqlite3_open(path, &pointer) != SQLITE_OK {
            throw ProcessorError(code: "internal_error", message: "Unable to open SQLite database.", retryable: false)
        }

        guard let pointer else {
            throw ProcessorError(code: "internal_error", message: "SQLite pointer was nil after open.", retryable: false)
        }

        dbPointer = pointer
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
    }

    deinit {
        sqlite3_close(dbPointer)
    }

    public func execute(_ sql: String, bindings: [SQLiteValue] = [], allowFailure: Bool = false) throws {
        try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(dbPointer, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError()
            }
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE || allowFailure else {
                throw sqliteError()
            }
        }
    }

    public func fetchAll(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(dbPointer, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError()
            }
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)

            var rows: [[String: SQLiteValue]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                var row: [String: SQLiteValue] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    row[name] = SQLiteValue(statement: statement, index: index)
                }
                rows.append(row)
            }
            return rows
        }
    }

    public func fetchOne(_ sql: String, bindings: [SQLiteValue] = []) throws -> [String: SQLiteValue]? {
        try fetchAll(sql, bindings: bindings).first
    }

    private func bind(_ bindings: [SQLiteValue], to statement: OpaquePointer?) throws {
        for (index, value) in bindings.enumerated() {
            let parameter = Int32(index + 1)
            switch value {
            case .null:
                sqlite3_bind_null(statement, parameter)
            case .integer(let integer):
                sqlite3_bind_int64(statement, parameter, sqlite3_int64(integer))
            case .double(let double):
                sqlite3_bind_double(statement, parameter, double)
            case .text(let string):
                sqlite3_bind_text(statement, parameter, string, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                data.withUnsafeBytes { bytes in
                    _ = sqlite3_bind_blob(statement, parameter, bytes.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            }
        }
    }

    private func sqliteError() -> ProcessorError {
        let message = String(cString: sqlite3_errmsg(dbPointer))
        return ProcessorError(code: "internal_error", message: message, retryable: false)
    }
}

public enum SQLiteValue: Sendable {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    init(statement: OpaquePointer?, index: Int32) {
        let type = sqlite3_column_type(statement, index)
        switch type {
        case SQLITE_INTEGER:
            self = .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            self = .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            self = .text(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_BLOB:
            let bytes = sqlite3_column_blob(statement, index)
            let length = Int(sqlite3_column_bytes(statement, index))
            self = .blob(Data(bytes: bytes!, count: length))
        default:
            self = .null
        }
    }

    public var stringValue: String? {
        if case .text(let value) = self { return value }
        if case .integer(let value) = self { return String(value) }
        if case .double(let value) = self { return String(value) }
        return nil
    }

    public var intValue: Int? {
        if case .integer(let value) = self { return Int(value) }
        if case .text(let value) = self { return Int(value) }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let value) = self { return value }
        if case .integer(let value) = self { return Double(value) }
        if case .text(let value) = self { return Double(value) }
        return nil
    }

    public var boolValue: Bool {
        (intValue ?? 0) != 0
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
