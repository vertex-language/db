package sqlite

import (
    "db/sql"
    "fs"
)

public class Database {
    public var path: string
    public var tables: [string: Table]
    public var inTransaction: bool
    var txSnapshot: [string: Table]?

    public static func open(path: string = ":memory:") throws -> Database {
        return try Database(path: path)
    }

    public init(path: string = ":memory:") throws {
        self.path = path
        self.tables = [:]
        self.inTransaction = false
        self.txSnapshot = nil
        try self.load()
    }

    public func getTable(name: string) -> Table? {
        return self.tables[name.lowercased()]
    }

    public func exec(sqlStr: string, params: [sql.Value] = []) throws -> sql.Result {
        let stmts = splitStatements(sqlStr)
        var lastRes = sql.Result(rowsAffected: 0)
        for s in stmts {
            let trimmed = trimString(s)
            if trimmed.isEmpty { continue }
            let parser = Parser(sql: trimmed)
            let stmt = try parser.parse()
            let (res, _) = try Engine.execute(stmt, db: self, params: params)
            if let r = res {
                lastRes = r
            }
        }
        return lastRes
    }

    public func query(sqlStr: string, params: [sql.Value] = []) throws -> sql.Rows {
        let parser = Parser(sql: sqlStr)
        let stmt = try parser.parse()
        let (_, rows) = try Engine.execute(stmt, db: self, params: params)
        return rows ?? sql.Rows(columns: [], records: [])
    }

    public func queryRow(sqlStr: string, params: [sql.Value] = []) throws -> sql.Row? {
        let rows = try self.query(sqlStr, params: params)
        if rows.next() {
            return rows.current()
        }
        return nil
    }

    public func beginTransaction() throws {
        if self.inTransaction {
            throw sql.DbError.queryFailed("transaction is already open")
        }
        self.inTransaction = true
        var snap: [string: Table] = [:]
        for (k, v) in self.tables {
            snap[k] = v.clone()
        }
        self.txSnapshot = snap
    }

    public func commitTransaction() throws {
        if !self.inTransaction {
            throw sql.DbError.queryFailed("no active transaction")
        }
        self.inTransaction = false
        self.txSnapshot = nil
        try self.save()
    }

    public func rollbackTransaction() throws {
        if !self.inTransaction {
            throw sql.DbError.queryFailed("no active transaction")
        }
        if let snap = self.txSnapshot {
            self.tables = snap
        }
        self.inTransaction = false
        self.txSnapshot = nil
    }

    public func close() {
        try? self.save()
    }

    public func save() throws {
        if self.inTransaction { return }
        if self.path == ":memory:" || self.path.isEmpty { return }
        let serialized = self.serialize()
        try fs.WriteText(fs.Path(self.path), serialized)
    }

    public func load() throws {
        if self.path == ":memory:" || self.path.isEmpty { return }
        do {
            let data = try fs.ReadText(fs.Path(self.path))
            try self.deserialize(data)
        } catch {
            // File does not exist yet or is empty
        }
    }

    func serialize() -> string {
        var out = "VTXSQL1\n"
        for (_, table) in self.tables {
            out.append("TABLE\t\(table.name)\t\(table.autoIncCounter)\n")
            for col in table.columns {
                let pkStr = col.isPrimaryKey ? "1" : "0"
                let nnStr = col.notNull ? "1" : "0"
                out.append("COL\t\(col.name)\t\(col.type.description)\t\(pkStr)\t\(nnStr)\n")
            }
            out.append("ROWS\t\(table.rows.count)\n")
            for r in table.rows {
                var rowStr = ""
                var first = true
                for val in r {
                    if !first { rowStr.append("\t") }
                    rowStr.append(serializeValue(val))
                    first = false
                }
                out.append(rowStr + "\n")
            }
            out.append("ENDTABLE\n")
        }
        return out
    }

    func deserialize(content: string) throws {
        let lines = splitLines(content)
        var i = 0
        if lines.isEmpty || lines[0] != "VTXSQL1" {
            return
        }
        i = 1

        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("TABLE\t") {
                let parts = splitByTab(line)
                if parts.count >= 3 {
                    let tableName = parts[1]
                    let counter = int64(parts[2]) ?? 0
                    i += 1

                    var cols: [Column] = []
                    while i < lines.count && lines[i].hasPrefix("COL\t") {
                        let colParts = splitByTab(lines[i])
                        if colParts.count >= 5 {
                            let cName = colParts[1]
                            let cType = DataType.parse(colParts[2])
                            let isPk = colParts[3] == "1"
                            let notNull = colParts[4] == "1"
                            cols.append(Column(name: cName, type: cType, isPrimaryKey: isPk, notNull: notNull))
                        }
                        i += 1
                    }

                    let table = Table(name: tableName, columns: cols)
                    table.autoIncCounter = counter

                    if i < lines.count && lines[i].hasPrefix("ROWS\t") {
                        let rowCountParts = splitByTab(lines[i])
                        let totalRows = int(rowCountParts[1]) ?? 0
                        i += 1

                        var rowIdx = 0
                        while rowIdx < totalRows && i < lines.count {
                            let rLine = lines[i]
                            if rLine == "ENDTABLE" { break }
                            let valStrs = splitByTab(rLine)
                            var rowVals: [sql.Value] = []
                            for vs in valStrs {
                                rowVals.append(deserializeValue(vs))
                            }
                            table.rows.append(rowVals)
                            rowIdx += 1
                            i += 1
                        }
                    }

                    while i < lines.count && lines[i] != "ENDTABLE" {
                        i += 1
                    }
                    if i < lines.count && lines[i] == "ENDTABLE" {
                        i += 1
                    }

                    self.tables[table.name.lowercased()] = table
                    continue
                }
            }
            i += 1
        }
    }
}

func serializeValue(v: sql.Value) -> string {
    switch v {
    case .null:
        return "N"
    case .integer(let n):
        return "I:\(n)"
    case .real(let r):
        return "R:\(r)"
    case .boolean(let b):
        return "B:" + (b ? "1" : "0")
    case .text(let s):
        return "T:" + toHex([uint8](s.utf8))
    case .blob(let b):
        return "X:" + toHex(b)
    }
}

func deserializeValue(s: string) -> sql.Value {
    if s == "N" { return .null }
    if s.hasPrefix("I:") {
        let numStr = string(s.dropFirst(2))
        return .integer(int64(numStr) ?? 0)
    }
    if s.hasPrefix("R:") {
        let numStr = string(s.dropFirst(2))
        return .real(float64(numStr) ?? 0.0)
    }
    if s.hasPrefix("B:") {
        let bStr = string(s.dropFirst(2))
        return .boolean(bStr == "1")
    }
    if s.hasPrefix("T:") {
        let hexStr = string(s.dropFirst(2))
        let bytes = fromHex(hexStr)
        var text = ""
        for b in bytes {
            text.append(Character(UnicodeScalar(b)))
        }
        return .text(text)
    }
    if s.hasPrefix("X:") {
        let hexStr = string(s.dropFirst(2))
        return .blob(fromHex(hexStr))
    }
    return .null
}

func splitByTab(s: string) -> [string] {
    var parts: [string] = []
    var cur = ""
    for b in s.utf8 {
        if b == 0x09 { // '\t'
            parts.append(cur)
            cur = ""
        } else {
            cur.append(Character(UnicodeScalar(b)))
        }
    }
    parts.append(cur)
    return parts
}

func splitLines(s: string) -> [string] {
    var lines: [string] = []
    var cur = ""
    for b in s.utf8 {
        if b == 0x0A { // '\n'
            lines.append(cur)
            cur = ""
        } else if b != 0x0D { // skip '\r'
            cur.append(Character(UnicodeScalar(b)))
        }
    }
    if !cur.isEmpty {
        lines.append(cur)
    }
    return lines
}

func splitStatements(sql: string) -> [string] {
    var stmts: [string] = []
    var cur = ""
    var inQuotes = false
    let bytes = [uint8](sql.utf8)
    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        if b == 0x27 { // '\''
            inQuotes = !inQuotes
            cur.append(Character(UnicodeScalar(b)))
        } else if b == 0x3B && !inQuotes { // ';'
            let trimmed = trimString(cur)
            if !trimmed.isEmpty {
                stmts.append(trimmed)
            }
            cur = ""
        } else {
            cur.append(Character(UnicodeScalar(b)))
        }
        i += 1
    }
    let trimmed = trimString(cur)
    if !trimmed.isEmpty {
        stmts.append(trimmed)
    }
    return stmts
}

func trimString(s: string) -> string {
    let bytes = [uint8](s.utf8)
    if bytes.isEmpty { return "" }
    var st = 0
    while st < bytes.count && (bytes[st] == 32 || bytes[st] == 9 || bytes[st] == 10 || bytes[st] == 13) {
        st += 1
    }
    var en = bytes.count
    while en > st && (bytes[en - 1] == 32 || bytes[en - 1] == 9 || bytes[en - 1] == 10 || bytes[en - 1] == 13) {
        en -= 1
    }
    var result = ""
    var i = st
    while i < en {
        result.append(Character(UnicodeScalar(bytes[i])))
        i += 1
    }
    return result
}

func toHex(bytes: [uint8]) -> string {
    let hexDigits: [Character] = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"]
    var s = ""
    for b in bytes {
        let hi = int((b >> 4) & 0x0F)
        let lo = int(b & 0x0F)
        s.append(hexDigits[hi])
        s.append(hexDigits[lo])
    }
    return s
}

func fromHex(s: string) -> [uint8] {
    let b = [uint8](s.utf8)
    var out: [uint8] = []
    var i = 0
    while i + 1 < b.count {
        let h1 = hexVal(b[i])
        let h2 = hexVal(b[i + 1])
        out.append(uint8((h1 << 4) | h2))
        i += 2
    }
    return out
}

func hexVal(b: uint8) -> int {
    if b >= 48 && b <= 57 { return int(b - 48) }
    if b >= 97 && b <= 102 { return int(b - 97 + 10) }
    if b >= 65 && b <= 70 { return int(b - 65 + 10) }
    return 0
}
