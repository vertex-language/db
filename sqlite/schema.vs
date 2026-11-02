package sqlite

import "db/sql"

public enum DataType: Equatable, CustomStringConvertible {
    case integer
    case real
    case text
    case blob
    case boolean

    public var description: string {
        switch self {
        case .integer: return "INTEGER"
        case .real: return "REAL"
        case .text: return "TEXT"
        case .blob: return "BLOB"
        case .boolean: return "BOOLEAN"
        }
    }

    public static func parse(s: string) -> DataType {
        let upper = s.uppercased()
        if upper.contains("INT") { return .integer }
        if upper.contains("CHAR") || upper.contains("TEXT") || upper.contains("CLOB") || upper.contains("VARCHAR") {
            return .text
        }
        if upper.contains("BLOB") { return .blob }
        if upper.contains("REAL") || upper.contains("FLOA") || upper.contains("DOUB") { return .real }
        if upper.contains("BOOL") { return .boolean }
        return .text
    }
}

public struct Column {
    public var name: string
    public var type: DataType
    public var isPrimaryKey: bool
    public var notNull: bool
    public var defaultValue: sql.Value?

    public init(
        name: string,
        type: DataType,
        isPrimaryKey: bool = false,
        notNull: bool = false,
        defaultValue: sql.Value? = nil
    ) {
        self.name = name
        self.type = type
        self.isPrimaryKey = isPrimaryKey
        self.notNull = notNull
        self.defaultValue = defaultValue
    }
}

public class Table {
    public var name: string
    public var columns: [Column]
    public var rows: [[sql.Value]]
    public var autoIncCounter: int64
    public var primaryKeyColIndex: int?

    public init(name: string, columns: [Column]) {
        self.name = name
        self.columns = columns
        self.rows = []
        self.autoIncCounter = 0
        self.primaryKeyColIndex = nil

        var i = 0
        while i < columns.count {
            if columns[i].isPrimaryKey {
                self.primaryKeyColIndex = i
                break
            }
            i += 1
        }
    }

    public func columnIndex(colName: string) -> int? {
        let lower = colName.lowercased()
        var i = 0
        while i < self.columns.count {
            if self.columns[i].name.lowercased() == lower {
                return i
            }
            i += 1
        }
        return nil
    }

    public func clone() -> Table {
        let t = Table(name: self.name, columns: self.columns)
        t.autoIncCounter = self.autoIncCounter
        t.primaryKeyColIndex = self.primaryKeyColIndex
        for r in self.rows {
            var rowCopy: [sql.Value] = []
            for v in r {
                rowCopy.append(v)
            }
            t.rows.append(rowCopy)
        }
        return t
    }
}
