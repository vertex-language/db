package sql

/// Row represents a single record of column values.
public struct Row {
    public var columns: [string]
    public var values: [Value]

    public init(columns: [string] = [], values: [Value] = []) {
        self.columns = columns
        self.values = values
    }

    public func get(_ colName: string) -> Value? {
        var i = 0
        while i < self.columns.count {
            if self.columns[i] == colName {
                if i < self.values.count {
                    return self.values[i]
                }
            }
            i += 1
        }
        return nil
    }

    public func string(_ colName: string) -> string? {
        return self.get(colName)?.asString()
    }

    public func int(_ colName: string) -> int64? {
        return self.get(colName)?.asInt()
    }

    public func float(_ colName: string) -> float64? {
        return self.get(colName)?.asFloat()
    }

    public func bool(_ colName: string) -> bool? {
        return self.get(colName)?.asBool()
    }

    public func blob(_ colName: string) -> [uint8]? {
        return self.get(colName)?.asBlob()
    }

    public func at(_ index: int) -> Value? {
        if index >= 0 && index < self.values.count {
            return self.values[index]
        }
        return nil
    }
}

/// Rows provides cursor iteration over query results.
public class Rows {
    public var columns: [string]
    public var records: [Row]
    public var cursor: int

    public init(columns: [string] = [], records: [Row] = []) {
        self.columns = columns
        self.records = records
        self.cursor = -1
    }

    public func next() -> bool {
        self.cursor += 1
        return self.cursor < self.records.count
    }

    public func current() -> Row? {
        if self.cursor >= 0 && self.cursor < self.records.count {
            return self.records[self.cursor]
        }
        return nil
    }

    public func count() -> int {
        return self.records.count
    }

    public func all() -> [Row] {
        return self.records
    }
}

/// Result contains execution metadata (rows affected, last insert ID).
public struct Result {
    public var rowsAffected: int64
    public var lastInsertId: int64

    public init(rowsAffected: int64 = 0, lastInsertId: int64 = 0) {
        self.rowsAffected = rowsAffected
        self.lastInsertId = lastInsertId
    }
}

/// DbError represents errors encountered during database operations.
public enum DbError: Error, Equatable, CustomStringConvertible {
    case connectionFailed(string)
    case queryFailed(string)
    case syntaxError(string)
    case tableNotFound(string)
    case columnNotFound(string)
    case constraintViolation(string)
    case protocolError(string)
    case authFailed(string)

    public var description: string {
        switch self {
        case .connectionFailed(let msg): return "database connection failed: \(msg)"
        case .queryFailed(let msg): return "database query failed: \(msg)"
        case .syntaxError(let msg): return "SQL syntax error: \(msg)"
        case .tableNotFound(let msg): return "table not found: \(msg)"
        case .columnNotFound(let msg): return "column not found: \(msg)"
        case .constraintViolation(let msg): return "constraint violation: \(msg)"
        case .protocolError(let msg): return "protocol error: \(msg)"
        case .authFailed(let msg): return "authentication failed: \(msg)"
        }
    }
}
