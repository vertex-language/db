package sqlite

import "db/sql"

public enum Statement {
    case createTable(name: string, ifNotExists: bool, columns: [Column])
    case dropTable(name: string, ifExists: bool)
    case insert(table: string, columns: [string], values: [[Expr]])
    case select(
        distinct: bool,
        columns: [SelectColumn],
        table: string,
        where: Expr?,
        orderBy: (column: string, desc: bool)?,
        limit: int?,
        offset: int?
    )
    case update(table: string, assignments: [(column: string, value: Expr)], where: Expr?)
    case delete(table: string, where: Expr?)
    case begin
    case commit
    case rollback
}

public enum SelectColumn {
    case all // *
    case column(string)
    case countAll
    case count(string)
    case sum(string)
    case avg(string)
    case min(string)
    case max(string)

    public var alias: string {
        switch self {
        case .all: return "*"
        case .column(let name): return name
        case .countAll: return "COUNT(*)"
        case .count(let col): return "COUNT(\(col))"
        case .sum(let col): return "SUM(\(col))"
        case .avg(let col): return "AVG(\(col))"
        case .min(let col): return "MIN(\(col))"
        case .max(let col): return "MAX(\(col))"
        }
    }
}

public class Parser {
    var tokens: [string]
    var pos: int
    var paramIndex: int

    public init(sql: string) {
        self.tokens = tokenize(sql)
        self.pos = 0
        self.paramIndex = 0
    }

    func peek() -> string? {
        if self.pos < self.tokens.count {
            return self.tokens[self.pos]
        }
        return nil
    }

    func consume() -> string {
        let tok = self.tokens[self.pos]
        self.pos += 1
        return tok
    }

    func match(expectedUpper: string) -> bool {
        if let p = self.peek() {
            if p.uppercased() == expectedUpper {
                self.pos += 1
                return true
            }
        }
        return false
    }

    func expect(expectedUpper: string) throws {
        guard self.match(expectedUpper) else {
            let got = self.peek() ?? "EOF"
            throw sql.DbError.syntaxError("expected '\(expectedUpper)', got '\(got)'")
        }
    }

    public func parse() throws -> Statement {
        guard let first = self.peek() else {
            throw sql.DbError.syntaxError("empty SQL string")
        }
        let upper = first.uppercased()

        if upper == "CREATE" {
            return try self.parseCreate()
        } else if upper == "DROP" {
            return try self.parseDrop()
        } else if upper == "INSERT" {
            return try self.parseInsert()
        } else if upper == "SELECT" {
            return try self.parseSelect()
        } else if upper == "UPDATE" {
            return try self.parseUpdate()
        } else if upper == "DELETE" {
            return try self.parseDelete()
        } else if upper == "BEGIN" {
            self.pos += 1
            _ = self.match("TRANSACTION")
            return .begin
        } else if upper == "COMMIT" {
            self.pos += 1
            _ = self.match("TRANSACTION")
            return .commit
        } else if upper == "ROLLBACK" {
            self.pos += 1
            _ = self.match("TRANSACTION")
            return .rollback
        } else {
            throw sql.DbError.syntaxError("unexpected token '\(first)'")
        }
    }

    func parseCreate() throws -> Statement {
        try self.expect("CREATE")
        try self.expect("TABLE")
        var ifNotExists = false
        if self.match("IF") {
            try self.expect("NOT")
            try self.expect("EXISTS")
            ifNotExists = true
        }

        let tableName = self.consume()
        try self.expect("(")

        var cols: [Column] = []
        while true {
            let colName = self.consume()
            let typeName = self.consume()
            let dt = DataType.parse(typeName)

            var isPk = false
            var notNull = false
            var defVal: sql.Value? = nil

            while let p = self.peek() {
                let up = p.uppercased()
                if up == "PRIMARY" {
                    self.pos += 1
                    try self.expect("KEY")
                    isPk = true
                } else if up == "NOT" {
                    self.pos += 1
                    try self.expect("NULL")
                    notNull = true
                } else if up == "DEFAULT" {
                    self.pos += 1
                    let litToken = self.consume()
                    defVal = parseLiteralToken(litToken)
                } else {
                    break
                }
            }

            cols.append(Column(name: colName, type: dt, isPrimaryKey: isPk, notNull: notNull, defaultValue: defVal))

            if self.match(",") {
                continue
            } else if self.match(")") {
                break
            } else {
                throw sql.DbError.syntaxError("expected ',' or ')' in table definition")
            }
        }

        return .createTable(name: tableName, ifNotExists: ifNotExists, columns: cols)
    }

    func parseDrop() throws -> Statement {
        try self.expect("DROP")
        try self.expect("TABLE")
        var ifExists = false
        if self.match("IF") {
            try self.expect("EXISTS")
            ifExists = true
        }
        let tableName = self.consume()
        return .dropTable(name: tableName, ifExists: ifExists)
    }

    func parseInsert() throws -> Statement {
        try self.expect("INSERT")
        try self.expect("INTO")
        let tableName = self.consume()

        var cols: [string] = []
        if self.match("(") {
            while true {
                cols.append(self.consume())
                if self.match(",") {
                    continue
                } else if self.match(")") {
                    break
                } else {
                    throw sql.DbError.syntaxError("expected ',' or ')' in column list")
                }
            }
        }

        try self.expect("VALUES")
        var rows: [[Expr]] = []

        while true {
            try self.expect("(")
            var row: [Expr] = []
            while true {
                let expr = try self.parseExpr()
                row.append(expr)
                if self.match(",") {
                    continue
                } else if self.match(")") {
                    break
                } else {
                    throw sql.DbError.syntaxError("expected ',' or ')' in values list")
                }
            }
            rows.append(row)
            if self.match(",") {
                continue
            } else {
                break
            }
        }

        return .insert(table: tableName, columns: cols, values: rows)
    }

    func parseSelect() throws -> Statement {
        try self.expect("SELECT")
        let distinct = self.match("DISTINCT")

        var selectCols: [SelectColumn] = []

        while true {
            guard let tok = self.peek() else {
                throw sql.DbError.syntaxError("unexpected EOF in SELECT columns")
            }

            if tok == "*" {
                self.pos += 1
                selectCols.append(.all)
            } else {
                let upper = tok.uppercased()
                if (upper == "COUNT" || upper == "SUM" || upper == "AVG" || upper == "MIN" || upper == "MAX") && self.pos + 1 < self.tokens.count && self.tokens[self.pos + 1] == "(" {
                    self.pos += 2 // skip name and '('
                    let arg = self.consume()
                    try self.expect(")")

                    if upper == "COUNT" {
                        selectCols.append(arg == "*" ? .countAll : .count(arg))
                    } else if upper == "SUM" {
                        selectCols.append(.sum(arg))
                    } else if upper == "AVG" {
                        selectCols.append(.avg(arg))
                    } else if upper == "MIN" {
                        selectCols.append(.min(arg))
                    } else if upper == "MAX" {
                        selectCols.append(.max(arg))
                    }
                } else {
                    let colName = self.consume()
                    selectCols.append(.column(colName))
                }
            }

            if self.match(",") {
                continue
            } else {
                break
            }
        }

        try self.expect("FROM")
        let tableName = self.consume()

        var whereExpr: Expr? = nil
        if self.match("WHERE") {
            whereExpr = try self.parseExpr()
        }

        var orderBy: (column: string, desc: bool)? = nil
        if self.match("ORDER") {
            try self.expect("BY")
            let orderCol = self.consume()
            var desc = false
            if self.match("DESC") {
                desc = true
            } else {
                _ = self.match("ASC")
            }
            orderBy = (column: orderCol, desc: desc)
        }

        var limit: int? = nil
        var offset: int? = nil

        if self.match("LIMIT") {
            let lit = self.consume()
            limit = Int(lit)
            if self.match("OFFSET") {
                let offLit = self.consume()
                offset = Int(offLit)
            }
        }

        return .select(
            distinct: distinct,
            columns: selectCols,
            table: tableName,
            where: whereExpr,
            orderBy: orderBy,
            limit: limit,
            offset: offset
        )
    }

    func parseUpdate() throws -> Statement {
        try self.expect("UPDATE")
        let tableName = self.consume()
        try self.expect("SET")

        var assignments: [(column: string, value: Expr)] = []
        while true {
            let col = self.consume()
            try self.expect("=")
            let val = try self.parseExpr()
            assignments.append((column: col, value: val))
            if self.match(",") {
                continue
            } else {
                break
            }
        }

        var whereExpr: Expr? = nil
        if self.match("WHERE") {
            whereExpr = try self.parseExpr()
        }

        return .update(table: tableName, assignments: assignments, where: whereExpr)
    }

    func parseDelete() throws -> Statement {
        try self.expect("DELETE")
        try self.expect("FROM")
        let tableName = self.consume()

        var whereExpr: Expr? = nil
        if self.match("WHERE") {
            whereExpr = try self.parseExpr()
        }

        return .delete(table: tableName, where: whereExpr)
    }

    // Expressions parser: handles OR, AND, NOT, Comparisons, LIKE, IN, BETWEEN, +, -, *, /
    func parseExpr() throws -> Expr {
        return try self.parseOr()
    }

    func parseOr() throws -> Expr {
        var left = try self.parseAnd()
        while self.match("OR") {
            let right = try self.parseAnd()
            left = .binary(op: "OR", left: left, right: right)
        }
        return left
    }

    func parseAnd() throws -> Expr {
        var left = try self.parseComparison()
        while self.match("AND") {
            let right = try self.parseComparison()
            left = .binary(op: "AND", left: left, right: right)
        }
        return left
    }

    func parseComparison() throws -> Expr {
        let left = try self.parseAddition()

        if let tok = self.peek() {
            let up = tok.uppercased()

            // IS NULL / IS NOT NULL
            if up == "IS" {
                self.pos += 1
                let not = self.match("NOT")
                try self.expect("NULL")
                return .isNull(operand: left, not: not)
            }

            // LIKE / NOT LIKE
            if up == "LIKE" {
                self.pos += 1
                let pattern = try self.parseAddition()
                return .like(operand: left, pattern: pattern, not: false)
            }
            if up == "NOT" && self.pos + 1 < self.tokens.count && self.tokens[self.pos + 1].uppercased() == "LIKE" {
                self.pos += 2
                let pattern = try self.parseAddition()
                return .like(operand: left, pattern: pattern, not: true)
            }

            // IN (val1, val2, ...)
            if up == "IN" {
                self.pos += 1
                try self.expect("(")
                var list: [Expr] = []
                while true {
                    list.append(try self.parseExpr())
                    if self.match(",") { continue }
                    else if self.match(")") { break }
                    else { throw sql.DbError.syntaxError("expected ',' or ')' in IN list") }
                }
                return .in(operand: left, list: list, not: false)
            }

            // BETWEEN a AND b
            if up == "BETWEEN" {
                self.pos += 1
                let low = try self.parseAddition()
                try self.expect("AND")
                let high = try self.parseAddition()
                return .between(operand: left, low: low, high: high, not: false)
            }

            // Standard comparison operators
            if tok == "=" || tok == "==" || tok == "!=" || tok == "<>" || tok == "<" || tok == "<=" || tok == ">" || tok == ">=" {
                self.pos += 1
                let right = try self.parseAddition()
                return .binary(op: tok, left: left, right: right)
            }
        }

        return left
    }

    func parseAddition() throws -> Expr {
        var left = try self.parseMultiplication()
        while let tok = self.peek(), (tok == "+" || tok == "-") {
            self.pos += 1
            let right = try self.parseMultiplication()
            left = .binary(op: tok, left: left, right: right)
        }
        return left
    }

    func parseMultiplication() throws -> Expr {
        var left = try self.parsePrimary()
        while let tok = self.peek(), (tok == "*" || tok == "/") {
            self.pos += 1
            let right = try self.parsePrimary()
            left = .binary(op: tok, left: left, right: right)
        }
        return left
    }

    func parsePrimary() throws -> Expr {
        guard let tok = self.peek() else {
            throw sql.DbError.syntaxError("unexpected EOF in expression")
        }

        if tok == "(" {
            self.pos += 1
            let expr = try self.parseExpr()
            try self.expect(")")
            return expr
        }

        if tok == "?" {
            self.pos += 1
            let idx = self.paramIndex
            self.paramIndex += 1
            return .placeholder(idx)
        }

        if tok.hasPrefix("$") {
            self.pos += 1
            let numStr = string(tok.dropFirst(1))
            let idx = (Int(numStr) ?? 1) - 1
            return .placeholder(idx)
        }

        // Literals: string starting with single quote
        if tok.hasPrefix("'") && tok.hasSuffix("'") && tok.count >= 2 {
            self.pos += 1
            let content = string(tok.dropFirst(1).dropLast(1))
            return .literal(.text(content))
        }

        // Numeric or Boolean or Null literal
        let upper = tok.uppercased()
        if upper == "NULL" {
            self.pos += 1
            return .literal(.null)
        }
        if upper == "TRUE" {
            self.pos += 1
            return .literal(.boolean(true))
        }
        if upper == "FALSE" {
            self.pos += 1
            return .literal(.boolean(false))
        }

        if let i = parseInt64(tok) {
            self.pos += 1
            return .literal(.integer(i))
        }
        if let f = parseFloat64(tok) {
            self.pos += 1
            return .literal(.real(f))
        }

        // Column identifier
        self.pos += 1
        return .column(tok)
    }
}

func parseLiteralToken(tok: string) -> sql.Value {
    if tok.hasPrefix("'") && tok.hasSuffix("'") && tok.count >= 2 {
        return .text(string(tok.dropFirst(1).dropLast(1)))
    }
    let upper = tok.uppercased()
    if upper == "NULL" { return .null }
    if upper == "TRUE" { return .boolean(true) }
    if upper == "FALSE" { return .boolean(false) }
    if let i = parseInt64(tok) { return .integer(i) }
    if let f = parseFloat64(tok) { return .real(f) }
    return .text(tok)
}

func tokenize(s: string) -> [string] {
    var tokens: [string] = []
    let bytes = [uint8](s.utf8)
    var i = 0

    while i < bytes.count {
        let b = bytes[i]

        // Skip whitespace and semicolons
        if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x3B {
            i += 1
            continue
        }

        // String literal: '...'
        if b == 0x27 { // '\''
            var str = "'"
            i += 1
            while i < bytes.count {
                let sb = bytes[i]
                if sb == 0x27 {
                    str.append("'")
                    i += 1
                    break
                }
                str.append(Character(UnicodeScalar(sb)))
                i += 1
            }
            tokens.append(str)
            continue
        }

        // Single character punctuation
        if b == 0x28 || b == 0x29 || b == 0x2C || b == 0x2A || b == 0x2F || b == 0x3F { // '(', ')', ',', '*', '/', '?'
            tokens.append(string(Character(UnicodeScalar(b))))
            i += 1
            continue
        }

        // Two-character operators: <=, >=, !=, <>, ==
        if i + 1 < bytes.count {
            let nextB = bytes[i + 1]
            if (b == 0x3C && (nextB == 0x3D || nextB == 0x3E)) || // <=, <>
               (b == 0x3E && nextB == 0x3D) || // >=
               (b == 0x21 && nextB == 0x3D) || // !=
               (b == 0x3D && nextB == 0x3D) {  // ==
                let op = string(Character(UnicodeScalar(b))) + string(Character(UnicodeScalar(nextB)))
                tokens.append(op)
                i += 2
                continue
            }
        }

        // Single character comparison/operator: =, <, >, +, -
        if b == 0x3D || b == 0x3C || b == 0x3E || b == 0x2B || b == 0x2D {
            tokens.append(string(Character(UnicodeScalar(b))))
            i += 1
            continue
        }

        // Identifiers, numbers, parameters ($1)
        var word = ""
        while i < bytes.count {
            let wb = bytes[i]
            if wb == 0x20 || wb == 0x09 || wb == 0x0A || wb == 0x0D || wb == 0x3B ||
               wb == 0x28 || wb == 0x29 || wb == 0x2C || wb == 0x3D || wb == 0x3C ||
               wb == 0x3E || wb == 0x21 || wb == 0x2B || wb == 0x2A || wb == 0x2F {
                break
            }
            word.append(Character(UnicodeScalar(wb)))
            i += 1
        }
        if !word.isEmpty {
            tokens.append(word)
        }
    }

    return tokens
}
