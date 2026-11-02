package sql

/// Value represents a dynamically typed SQL value.
public enum Value: Equatable, CustomStringConvertible {
    case null
    case integer(int64)
    case real(float64)
    case text(string)
    case blob([uint8])
    case boolean(bool)

    public var isNull: bool {
        switch self {
        case .null: return true
        default: return false
        }
    }

    public func asInt() -> int64? {
        switch self {
        case .integer(let v): return v
        case .real(let v): return int64(v)
        case .text(let v): return parseInt64(v)
        case .boolean(let v): return v ? 1 : 0
        default: return nil
        }
    }

    public func asFloat() -> float64? {
        switch self {
        case .real(let v): return v
        case .integer(let v): return float64(v)
        case .text(let v): return parseFloat64(v)
        default: return nil
        }
    }

    public func asString() -> string? {
        switch self {
        case .text(let v): return v
        case .integer(let v): return "\(v)"
        case .real(let v): return "\(v)"
        case .boolean(let v): return v ? "true" : "false"
        case .null: return nil
        case .blob: return nil
        }
    }

    public func asBool() -> bool? {
        switch self {
        case .boolean(let v): return v
        case .integer(let v): return v != 0
        case .text(let v):
            let lower = v.lowercased()
            return lower == "true" || lower == "1" || lower == "yes" || lower == "t"
        default: return nil
        }
    }

    public func asBlob() -> [uint8]? {
        switch self {
        case .blob(let v): return v
        case .text(let v):
            var b: [uint8] = []
            for c in v.utf8 { b.append(c) }
            return b
        default: return nil
        }
    }

    public var description: string {
        switch self {
        case .null: return "NULL"
        case .integer(let v): return "\(v)"
        case .real(let v): return "\(v)"
        case .text(let v): return v
        case .blob(let v): return "<blob \(v.count) bytes>"
        case .boolean(let v): return v ? "true" : "false"
        }
    }
}

package func parseInt64(s: string) -> int64? {
    if s.isEmpty { return nil }
    var neg = false
    var i = 0
    var res: int64 = 0
    let bytes = [uint8](s.utf8)
    if bytes[0] == 0x2D { // '-'
        neg = true
        i = 1
    } else if bytes[0] == 0x2B { // '+'
        i = 1
    }
    if i >= bytes.count { return nil }
    while i < bytes.count {
        let b = bytes[i]
        if b < 0x30 || b > 0x39 { return nil }
        res = res * 10 + int64(b - 0x30)
        i += 1
    }
    return neg ? -res : res
}

package func parseFloat64(s: string) -> float64? {
    if s.isEmpty { return nil }
    var neg = false
    var i = 0
    let bytes = [uint8](s.utf8)
    if bytes[0] == 0x2D {
        neg = true
        i = 1
    } else if bytes[0] == 0x2B {
        i = 1
    }
    if i >= bytes.count { return nil }

    var intPart: float64 = 0.0
    var fracPart: float64 = 0.0
    var divisor: float64 = 1.0
    var hasDot = false

    while i < bytes.count {
        let b = bytes[i]
        if b == 0x2E { // '.'
            if hasDot { return nil }
            hasDot = true
        } else if b >= 0x30 && b <= 0x39 {
            if hasDot {
                divisor *= 10.0
                fracPart += float64(b - 0x30) / divisor
            } else {
                intPart = intPart * 10.0 + float64(b - 0x30)
            }
        } else {
            return nil
        }
        i += 1
    }
    let res = intPart + fracPart
    return neg ? -res : res
}
