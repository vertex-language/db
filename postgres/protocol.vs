package postgres

import "db/sql"

func sliceBytes(_ data: [uint8], from: int, to: int) -> [uint8] {
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

func writeInt32BE(_ val: int32) -> [uint8] {
    let u = uint32(bitPattern: val)
    return [
        uint8((u >> 24) & 0xFF),
        uint8((u >> 16) & 0xFF),
        uint8((u >> 8) & 0xFF),
        uint8(u & 0xFF),
    ]
}

func readInt32BE(_ bytes: [uint8], from: int) -> int32 {
    let b0 = uint32(bytes[from])
    let b1 = uint32(bytes[from + 1])
    let b2 = uint32(bytes[from + 2])
    let b3 = uint32(bytes[from + 3])
    let u = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    return int32(bitPattern: u)
}

func writeInt16BE(_ val: int16) -> [uint8] {
    let u = uint16(bitPattern: val)
    return [
        uint8((u >> 8) & 0xFF),
        uint8(u & 0xFF),
    ]
}

func readInt16BE(_ bytes: [uint8], from: int) -> int16 {
    let b0 = uint16(bytes[from])
    let b1 = uint16(bytes[from + 1])
    let u = (b0 << 8) | b1
    return int16(bitPattern: u)
}

public struct PgColumnDesc {
    public var name: string
    public var tableOID: int32
    public var columnAttrNumber: int16
    public var typeOID: int32
    public var typeSize: int16
    public var typeModifier: int32
    public var formatCode: int16

    public init(
        name: string,
        tableOID: int32 = 0,
        columnAttrNumber: int16 = 0,
        typeOID: int32 = 0,
        typeSize: int16 = -1,
        typeModifier: int32 = -1,
        formatCode: int16 = 0
    ) {
        self.name = name
        self.tableOID = tableOID
        self.columnAttrNumber = columnAttrNumber
        self.typeOID = typeOID
        self.typeSize = typeSize
        self.typeModifier = typeModifier
        self.formatCode = formatCode
    }
}

public class PgProtocol {
    public static func encodeStartup(user: string, database: string) -> [uint8] {
        var body: [uint8] = []
        // Protocol 3.0: 196608 (0x00030000)
        body.append(contentsOf: [0x00, 0x03, 0x00, 0x00])

        body.append(contentsOf: [uint8]("user".utf8))
        body.append(0x00)
        body.append(contentsOf: [uint8](user.utf8))
        body.append(0x00)

        body.append(contentsOf: [uint8]("database".utf8))
        body.append(0x00)
        body.append(contentsOf: [uint8](database.utf8))
        body.append(0x00)

        body.append(contentsOf: [uint8]("client_encoding".utf8))
        body.append(0x00)
        body.append(contentsOf: [uint8]("UTF8".utf8))
        body.append(0x00)

        body.append(0x00) // terminating null

        let length = int32(body.count + 4)
        var msg = writeInt32BE(length)
        msg.append(contentsOf: body)
        return msg
    }

    public static func encodePassword(_ password: string) -> [uint8] {
        var body = [uint8](password.utf8)
        body.append(0x00)
        let length = int32(body.count + 4)
        var msg: [uint8] = [0x70] // 'p'
        msg.append(contentsOf: writeInt32BE(length))
        msg.append(contentsOf: body)
        return msg
    }

    public static func encodeQuery(_ sql: string) -> [uint8] {
        var body = [uint8](sql.utf8)
        body.append(0x00)
        let length = int32(body.count + 4)
        var msg: [uint8] = [0x51] // 'Q'
        msg.append(contentsOf: writeInt32BE(length))
        msg.append(contentsOf: body)
        return msg
    }

    public static func encodeTerminate() -> [uint8] {
        var msg: [uint8] = [0x58] // 'X'
        msg.append(contentsOf: writeInt32BE(4))
        return msg
    }

    public static func decodeRowDescription(_ payload: [uint8]) throws -> [PgColumnDesc] {
        if payload.count < 2 {
            throw sql.DbError.protocolError("invalid RowDescription packet")
        }
        let colCount = int(readInt16BE(payload, from: 0))
        var offset = 2
        var cols: [PgColumnDesc] = []

        var i = 0
        while i < colCount {
            var name = ""
            while offset < payload.count && payload[offset] != 0x00 {
                name.append(Character(UnicodeScalar(payload[offset])))
                offset += 1
            }
            offset += 1 // skip null byte

            if offset + 18 > payload.count {
                throw sql.DbError.protocolError("truncated column description")
            }

            let tOid = readInt32BE(payload, from: offset)
            let colAttr = readInt16BE(payload, from: offset + 4)
            let typeOid = readInt32BE(payload, from: offset + 6)
            let tSize = readInt16BE(payload, from: offset + 10)
            let tMod = readInt32BE(payload, from: offset + 12)
            let fmt = readInt16BE(payload, from: offset + 16)
            offset += 18

            cols.append(PgColumnDesc(
                name: name,
                tableOID: tOid,
                columnAttrNumber: colAttr,
                typeOID: typeOid,
                typeSize: tSize,
                typeModifier: tMod,
                formatCode: fmt
            ))
            i += 1
        }
        return cols
    }

    public static func decodeDataRow(_ payload: [uint8], columns: [PgColumnDesc]) throws -> sql.Row {
        if payload.count < 2 {
            throw sql.DbError.protocolError("invalid DataRow packet")
        }
        let colCount = int(readInt16BE(payload, from: 0))
        var offset = 2
        var colNames: [string] = []
        var vals: [sql.Value] = []

        var i = 0
        while i < colCount {
            let colName = i < columns.count ? columns[i].name : "col\(i)"
            colNames.append(colName)

            if offset + 4 > payload.count {
                throw sql.DbError.protocolError("truncated DataRow column length")
            }
            let len = readInt32BE(payload, from: offset)
            offset += 4

            if len == -1 {
                vals.append(.null)
            } else {
                let vLen = int(len)
                if offset + vLen > payload.count {
                    throw sql.DbError.protocolError("truncated DataRow value bytes")
                }
                let valBytes = sliceBytes(payload, from: offset, to: offset + vLen)
                offset += vLen

                var s = ""
                for b in valBytes {
                    s.append(Character(UnicodeScalar(b)))
                }
                // Try converting to integer or real if applicable
                if let iVal = int64(s) {
                    vals.append(.integer(iVal))
                } else if let fVal = float64(s) {
                    vals.append(.real(fVal))
                } else if s.uppercased() == "TRUE" || s.uppercased() == "T" {
                    vals.append(.boolean(true))
                } else if s.uppercased() == "FALSE" || s.uppercased() == "F" {
                    vals.append(.boolean(false))
                } else {
                    vals.append(.text(s))
                }
            }
            i += 1
        }
        return sql.Row(columns: colNames, values: vals)
    }

func splitSpaces(_ s: string) -> [string] {
    var parts: [string] = []
    var cur = ""
    for b in s.utf8 {
        if b == 0x20 || b == 0x09 {
            if !cur.isEmpty {
                parts.append(cur)
                cur = ""
            }
        } else {
            cur.append(Character(UnicodeScalar(b)))
        }
    }
    if !cur.isEmpty {
        parts.append(cur)
    }
    return parts
}

func parseInteger(_ s: string) -> int64? {
    let b = [uint8](s.utf8)
    if b.isEmpty { return nil }
    var neg = false
    var start = 0
    if b[0] == 0x2D {
        neg = true
        start = 1
    } else if b[0] == 0x2B {
        start = 1
    }
    if start >= b.count { return nil }
    var n: int64 = 0
    var i = start
    while i < b.count {
        let ch = b[i]
        if ch < 48 || ch > 57 { return nil }
        n = n * 10 + int64(ch - 48)
        i += 1
    }
    return neg ? -n : n
}

    public static func decodeCommandComplete(_ payload: [uint8]) -> (tag: string, affected: int64) {
        var s = ""
        var i = 0
        while i < payload.count && payload[i] != 0x00 {
            s.append(Character(UnicodeScalar(payload[i])))
            i += 1
        }
        // E.g. "INSERT 0 1", "DELETE 5", "UPDATE 3", "SELECT 42"
        let parts = splitSpaces(s)
        var affected: int64 = 0
        if !parts.isEmpty {
            if let num = parseInteger(parts[parts.count - 1]) {
                affected = num
            }
        }
        return (tag: s, affected: affected)
    }

    public static func decodeErrorResponse(_ payload: [uint8]) -> string {
        var msg = ""
        var offset = 0
        while offset < payload.count && payload[offset] != 0x00 {
            let fieldType = payload[offset]
            offset += 1
            var fieldVal = ""
            while offset < payload.count && payload[offset] != 0x00 {
                fieldVal.append(Character(UnicodeScalar(payload[offset])))
                offset += 1
            }
            offset += 1 // null terminator
            if fieldType == 0x4D { // 'M' Human-readable message
                msg = fieldVal
            }
        }
        return msg.isEmpty ? "unknown PostgreSQL error" : msg
    }
}
