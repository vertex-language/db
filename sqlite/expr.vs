package sqlite

import "db/sql"

public class Expr {
    public enum Kind {
        case literal(sql.Value)
        case column(string)
        case placeholder(int)
        case binary(op: string, left: Expr, right: Expr)
        case unary(op: string, operand: Expr)
        case isNull(operand: Expr, not: bool)
        case `in`(operand: Expr, list: [Expr], not: bool)
        case between(operand: Expr, low: Expr, high: Expr, not: bool)
        case like(operand: Expr, pattern: Expr, not: bool)
        case functionCall(name: string, arg: string)
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public static func literal(v: sql.Value) -> Expr {
        return Expr(.literal(v))
    }
    public static func column(name: string) -> Expr {
        return Expr(.column(name))
    }
    public static func placeholder(idx: int) -> Expr {
        return Expr(.placeholder(idx))
    }
    public static func binary(op: string, left: Expr, right: Expr) -> Expr {
        return Expr(.binary(op: op, left: left, right: right))
    }
    public static func unary(op: string, operand: Expr) -> Expr {
        return Expr(.unary(op: op, operand: operand))
    }
    public static func isNull(operand: Expr, not: bool) -> Expr {
        return Expr(.isNull(operand: operand, not: not))
    }
    public static func `in`(operand: Expr, list: [Expr], not: bool) -> Expr {
        return Expr(.`in`(operand: operand, list: list, not: not))
    }
    public static func between(operand: Expr, low: Expr, high: Expr, not: bool) -> Expr {
        return Expr(.between(operand: operand, low: low, high: high, not: not))
    }
    public static func like(operand: Expr, pattern: Expr, not: bool) -> Expr {
        return Expr(.like(operand: operand, pattern: pattern, not: not))
    }
    public static func functionCall(name: string, arg: string) -> Expr {
        return Expr(.functionCall(name: name, arg: arg))
    }
}

public func evaluateExpr(
    expr: Expr,
    row: [sql.Value],
    table: Table?,
    params: [sql.Value]
) throws -> sql.Value {
    switch expr.kind {
    case .literal(let v):
        return v

    case .placeholder(let idx):
        if idx >= 0 && idx < params.count {
            return params[idx]
        }
        return .null

    case .column(let name):
        guard let t = table, let idx = t.columnIndex(name) else {
            throw sql.DbError.columnNotFound(name)
        }
        if idx < row.count {
            return row[idx]
        }
        return .null

    case .unary(let op, let operand):
        let val = try evaluateExpr(operand, row: row, table: table, params: params)
        if op == "NOT" || op == "!" {
            if let b = val.asBool() {
                return .boolean(!b)
            }
            return .null
        }
        if op == "-" {
            if let i = val.asInt() { return .integer(-i) }
            if let f = val.asFloat() { return .real(-f) }
        }
        return .null

    case .isNull(let operand, let not):
        let val = try evaluateExpr(operand, row: row, table: table, params: params)
        let isN = val.isNull
        return .boolean(not ? !isN : isN)

    case .like(let operand, let pattern, let not):
        let val = try evaluateExpr(operand, row: row, table: table, params: params)
        let pat = try evaluateExpr(pattern, row: row, table: table, params: params)
        guard let s = val.asString(), let p = pat.asString() else {
            return .boolean(false)
        }
        let matched = matchLike(s.lowercased(), p.lowercased())
        return .boolean(not ? !matched : matched)

    case .in(let operand, let list, let not):
        let val = try evaluateExpr(operand, row: row, table: table, params: params)
        var found = false
        for item in list {
            let itemVal = try evaluateExpr(item, row: row, table: table, params: params)
            if valuesEqual(val, itemVal) {
                found = true
                break
            }
        }
        return .boolean(not ? !found : found)

    case .between(let operand, let low, let high, let not):
        let val = try evaluateExpr(operand, row: row, table: table, params: params)
        let lowVal = try evaluateExpr(low, row: row, table: table, params: params)
        let highVal = try evaluateExpr(high, row: row, table: table, params: params)
        let geLow = compareValues(val, lowVal) >= 0
        let leHigh = compareValues(val, highVal) <= 0
        let inRange = geLow && leHigh
        return .boolean(not ? !inRange : inRange)

    case .binary(let op, let left, let right):
        let lVal = try evaluateExpr(left, row: row, table: table, params: params)
        let rVal = try evaluateExpr(right, row: row, table: table, params: params)

        let upperOp = op.uppercased()
        if upperOp == "AND" {
            let lB = lVal.asBool() ?? false
            let rB = rVal.asBool() ?? false
            return .boolean(lB && rB)
        }
        if upperOp == "OR" {
            let lB = lVal.asBool() ?? false
            let rB = rVal.asBool() ?? false
            return .boolean(lB || rB)
        }

        if op == "=" || op == "==" {
            return .boolean(valuesEqual(lVal, rVal))
        }
        if op == "!=" || op == "<>" {
            return .boolean(!valuesEqual(lVal, rVal))
        }
        if op == "<" {
            return .boolean(compareValues(lVal, rVal) < 0)
        }
        if op == "<=" {
            return .boolean(compareValues(lVal, rVal) <= 0)
        }
        if op == ">" {
            return .boolean(compareValues(lVal, rVal) > 0)
        }
        if op == ">=" {
            return .boolean(compareValues(lVal, rVal) >= 0)
        }

        // Arithmetic
        if op == "+" {
            if let lI = lVal.asInt(), let rI = rVal.asInt() {
                return .integer(lI + rI)
            }
            if let lF = lVal.asFloat(), let rF = rVal.asFloat() {
                return .real(lF + rF)
            }
            if let lS = lVal.asString(), let rS = rVal.asString() {
                return .text(lS + rS)
            }
        }
        if op == "-" {
            if let lI = lVal.asInt(), let rI = rVal.asInt() { return .integer(lI - rI) }
            if let lF = lVal.asFloat(), let rF = rVal.asFloat() { return .real(lF - rF) }
        }
        if op == "*" {
            if let lI = lVal.asInt(), let rI = rVal.asInt() { return .integer(lI * rI) }
            if let lF = lVal.asFloat(), let rF = rVal.asFloat() { return .real(lF * rF) }
        }
        if op == "/" {
            if let lF = lVal.asFloat(), let rF = rVal.asFloat() {
                if rF == 0.0 { return .null }
                return .real(lF / rF)
            }
        }
        return .null

    case .functionCall:
        return .null
    }
}

public func valuesEqual(a: sql.Value, b: sql.Value) -> bool {
    switch (a, b) {
    case (.null, .null): return true
    case (.integer(let x), .integer(let y)): return x == y
    case (.real(let x), .real(let y)): return x == y
    case (.integer(let x), .real(let y)): return float64(x) == y
    case (.real(let x), .integer(let y)): return x == float64(y)
    case (.text(let x), .text(let y)): return x == y
    case (.boolean(let x), .boolean(let y)): return x == y
    case (.blob(let x), .blob(let y)): return x == y
    default: return false
    }
}

public func compareValues(a: sql.Value, b: sql.Value) -> int {
    if a.isNull && b.isNull { return 0 }
    if a.isNull { return -1 }
    if b.isNull { return 1 }

    if let x = a.asFloat(), let y = b.asFloat() {
        if x < y { return -1 }
        if x > y { return 1 }
        return 0
    }
    if let x = a.asString(), let y = b.asString() {
        if x < y { return -1 }
        if x > y { return 1 }
        return 0
    }
    return 0
}

func matchLike(s: string, pattern: string) -> bool {
    let sBytes = [uint8](s.utf8)
    let pBytes = [uint8](pattern.utf8)
    return matchLikeRecursive(sBytes, 0, pBytes, 0)
}

func matchLikeRecursive(s: [uint8], sIdx: int, p: [uint8], pIdx: int) -> bool {
    var si = sIdx
    var pi = pIdx

    while pi < p.count {
        let pc = p[pi]
        if pc == 0x25 { // '%'
            // Try matching 0 or more characters
            var nextS = si
            while nextS <= s.count {
                if matchLikeRecursive(s, nextS, p, pi + 1) {
                    return true
                }
                nextS += 1
            }
            return false
        } else if pc == 0x5F { // '_'
            if si >= s.count { return false }
            si += 1
            pi += 1
        } else {
            if si >= s.count || s[si] != pc {
                return false
            }
            si += 1
            pi += 1
        }
    }
    return si == s.count
}
