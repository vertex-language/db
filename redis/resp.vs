package redis

func sliceBytes(data: [uint8], from: int, to: int) -> [uint8] {
    if from >= to || from >= data.count { return [] }
    let end = to < data.count ? to : data.count
    var res = [uint8](repeating: 0, count: end - from)
    var i = from
    var j = 0
    while i < end {
        res[j] = data[i]
        i += 1
        j += 1
    }
    return res
}

public enum RespValue: Equatable, CustomStringConvertible {
    case simpleString(string)
    case error(string)
    case integer(int64)
    case bulkString([uint8]?)
    case array([RespValue]?)

    public var isNull: bool {
        switch self {
        case .bulkString(let b): return b == nil
        case .array(let a): return a == nil
        default: return false
        }
    }

    public func asString() -> string? {
        switch self {
        case .simpleString(let s): return s
        case .bulkString(let b):
            guard let bytes = b else { return nil }
            var s = ""
            for x in bytes {
                s.append(Character(UnicodeScalar(x)))
            }
            return s
        case .integer(let i): return string(i)
        case .error(let e): return e
        default: return nil
        }
    }

    public func asInt() -> int64? {
        switch self {
        case .integer(let i): return i
        case .simpleString(let s): return int64(s)
        case .bulkString(let b):
            if let s = self.asString() { return int64(s) }
            return nil
        default: return nil
        }
    }

    public var description: string {
        switch self {
        case .simpleString(let s): return s
        case .error(let e): return "ERR \(e)"
        case .integer(let i): return string(i)
        case .bulkString(let b):
            if let bytes = b {
                var s = ""
                for x in bytes { s.append(Character(UnicodeScalar(x))) }
                return s
            }
            return "(nil)"
        case .array(let a):
            if let arr = a {
                return "[\(arr.count) elements]"
            }
            return "(nil array)"
        }
    }
}

public class RespSerializer {
    public static func encodeCommand(args: [string]) -> [uint8] {
        var out = "*\(args.count)\r\n"
        for arg in args {
            let bytes = [uint8](arg.utf8)
            out.append("$\(bytes.count)\r\n")
            out.append(arg)
            out.append("\r\n")
        }
        return [uint8](out.utf8)
    }

    public static func encodeValue(val: RespValue) -> [uint8] {
        switch val {
        case .simpleString(let s):
            return [uint8]("+".utf8) + [uint8](s.utf8) + [0x0D, 0x0A]
        case .error(let e):
            return [uint8]("-".utf8) + [uint8](e.utf8) + [0x0D, 0x0A]
        case .integer(let i):
            return [uint8](":\(i)\r\n".utf8)
        case .bulkString(let b):
            guard let bytes = b else {
                return [uint8]("$-1\r\n".utf8)
            }
            var res = [uint8]("$\(bytes.count)\r\n".utf8)
            res.append(contentsOf: bytes)
            res.append(0x0D)
            res.append(0x0A)
            return res
        case .array(let a):
            guard let arr = a else {
                return [uint8]("*-1\r\n".utf8)
            }
            var res = [uint8]("*\(arr.count)\r\n".utf8)
            for item in arr {
                res.append(contentsOf: encodeValue(item))
            }
            return res
        }
    }
}

public class RespParser {
    var buffer: [uint8]
    var pos: int

    public init(data: [uint8] = []) {
        self.buffer = data
        self.pos = 0
    }

    public func feed(data: [uint8]) {
        self.buffer.append(contentsOf: data)
    }

    public func parse() throws -> RespValue? {
        if self.pos >= self.buffer.count {
            return nil
        }

        let savedPos = self.pos
        do {
            let val = try self.parseValue()
            // Trim consumed bytes if position is large
            if self.pos > 8192 {
                self.buffer = sliceBytes(self.buffer, from: self.pos, to: self.buffer.count)
                self.pos = 0
            }
            return val
        } catch {
            self.pos = savedPos
            return nil
        }
    }

    func parseValue() throws -> RespValue {
        guard self.pos < self.buffer.count else {
            throw RespError.incomplete
        }

        let prefix = self.buffer[self.pos]
        self.pos += 1

        switch prefix {
        case 0x2B: // '+' Simple String
            let line = try self.readLine()
            return .simpleString(line)

        case 0x2D: // '-' Error
            let line = try self.readLine()
            return .error(line)

        case 0x3A: // ':' Integer
            let line = try self.readLine()
            let num = int64(line) ?? 0
            return .integer(num)

        case 0x24: // '$' Bulk String
            let lenLine = try self.readLine()
            let length = int(lenLine) ?? 0
            if length == -1 {
                return .bulkString(nil)
            }
            if self.pos + length + 2 > self.buffer.count {
                throw RespError.incomplete
            }
            let bytes = sliceBytes(self.buffer, from: self.pos, to: self.pos + length)
            self.pos += length
            if self.pos + 1 < self.buffer.count && self.buffer[self.pos] == 0x0D && self.buffer[self.pos + 1] == 0x0A {
                self.pos += 2
            }
            return .bulkString(bytes)

        case 0x2A: // '*' Array
            let countLine = try self.readLine()
            let count = int(countLine) ?? 0
            if count == -1 {
                return .array(nil)
            }
            var elements: [RespValue] = []
            var i = 0
            while i < count {
                let el = try self.parseValue()
                elements.append(el)
                i += 1
            }
            return .array(elements)

        default:
            throw RespError.invalidFormat("unknown RESP prefix: \(prefix)")
        }
    }

    func readLine() throws -> string {
        var i = self.pos
        while i + 1 < self.buffer.count {
            if self.buffer[i] == 0x0D && self.buffer[i + 1] == 0x0A {
                var s = ""
                var j = self.pos
                while j < i {
                    s.append(Character(UnicodeScalar(self.buffer[j])))
                    j += 1
                }
                self.pos = i + 2
                return s
            }
            i += 1
        }
        throw RespError.incomplete
    }
}

public enum RespError: Error, Equatable {
    case incomplete
    case invalidFormat(string)
}
