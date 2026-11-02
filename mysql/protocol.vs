package mysql

import "db/sql"

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

func writeInt24LE(val: int) -> [uint8] {
    return [
        uint8(val & 0xFF),
        uint8((val >> 8) & 0xFF),
        uint8((val >> 16) & 0xFF),
    ]
}

func readInt24LE(bytes: [uint8], from: int) -> int {
    let b0 = int(bytes[from])
    let b1 = int(bytes[from + 1])
    let b2 = int(bytes[from + 2])
    return b0 | (b1 << 8) | (b2 << 16)
}

func writeInt32LE(val: uint32) -> [uint8] {
    return [
        uint8(val & 0xFF),
        uint8((val >> 8) & 0xFF),
        uint8((val >> 16) & 0xFF),
        uint8((val >> 24) & 0xFF),
    ]
}

func readInt32LE(bytes: [uint8], from: int) -> uint32 {
    let b0 = uint32(bytes[from])
    let b1 = uint32(bytes[from + 1])
    let b2 = uint32(bytes[from + 2])
    let b3 = uint32(bytes[from + 3])
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

func readInt16LE(bytes: [uint8], from: int) -> uint16 {
    let b0 = uint16(bytes[from])
    let b1 = uint16(bytes[from + 1])
    return b0 | (b1 << 8)
}

public struct MySqlColumnDesc {
    public var schema: string
    public var table: string
    public var name: string
    public var columnType: uint8

    public init(schema: string = "", table: string = "", name: string = "", columnType: uint8 = 0) {
        self.schema = schema
        self.table = table
        self.name = name
        self.columnType = columnType
    }
}

public class MySqlProtocol {
    public static func encodePacket(payload: [uint8], seq: uint8) -> [uint8] {
        var packet: [uint8] = []
        packet.append(contentsOf: writeInt24LE(payload.count))
        packet.append(seq)
        packet.append(contentsOf: payload)
        return packet
    }

    public static func encodeHandshakeResponse41(
        user: string,
        password: string,
        database: string,
        seq: uint8
    ) -> [uint8] {
        var caps: uint32 = 0x00000001 // CLIENT_LONG_PASSWORD
        caps |= 0x00000200 // CLIENT_PROTOCOL_41
        caps |= 0x00008000 // CLIENT_SECURE_CONNECTION
        if !database.isEmpty {
            caps |= 0x00000008 // CLIENT_CONNECT_WITH_DB
        }

        var body: [uint8] = []
        body.append(contentsOf: writeInt32LE(caps))
        body.append(contentsOf: writeInt32LE(0x01000000)) // max packet size 16MB
        body.append(33) // utf8 charset
        body.append(contentsOf: [uint8](repeating: 0, count: 23)) // reserved

        body.append(contentsOf: [uint8](user.utf8))
        body.append(0x00)

        if password.isEmpty {
            body.append(0x00)
        } else {
            let pBytes = [uint8](password.utf8)
            body.append(uint8(pBytes.count))
            body.append(contentsOf: pBytes)
        }

        if !database.isEmpty {
            body.append(contentsOf: [uint8](database.utf8))
            body.append(0x00)
        }

        return encodePacket(payload: body, seq: seq)
    }

    public static func encodeQuery(sql: string, seq: uint8 = 0) -> [uint8] {
        var body: [uint8] = [0x03] // COM_QUERY
        body.append(contentsOf: [uint8](sql.utf8))
        return encodePacket(payload: body, seq: seq)
    }

    public static func decodeOkPacket(payload: [uint8]) -> (affectedRows: int64, lastInsertId: int64) {
        var offset = 1 // skip 0x00 header
        let affected = readLenEncInt(payload, from: &offset) ?? 0
        let lastId = readLenEncInt(payload, from: &offset) ?? 0
        return (affectedRows: affected, lastInsertId: lastId)
    }

    public static func decodeErrPacket(payload: [uint8]) -> string {
        if payload.count < 3 { return "unknown MySQL error" }
        let errCode = readInt16LE(payload, from: 1)
        var offset = 3
        if offset < payload.count && payload[offset] == 0x23 { // '#' SQL state marker
            offset += 6 // skip marker and 5-char SQL state
        }
        var msg = ""
        while offset < payload.count {
            msg.append(Character(UnicodeScalar(payload[offset])))
            offset += 1
        }
        return "MySQL error \(errCode): \(msg)"
    }

    public static func decodeColumnDefinition(payload: [uint8]) -> MySqlColumnDesc {
        var offset = 0
        _ = readLenEncString(payload, from: &offset) // catalog
        let schema = readLenEncString(payload, from: &offset) ?? ""
        let table = readLenEncString(payload, from: &offset) ?? ""
        _ = readLenEncString(payload, from: &offset) // org_table
        let name = readLenEncString(payload, from: &offset) ?? ""
        _ = readLenEncString(payload, from: &offset) // org_name

        var colType: uint8 = 0
        if offset + 13 <= payload.count {
            offset += 1 // length of fixed fields (0x0c)
            offset += 2 // character set
            offset += 4 // column length
            colType = payload[offset]
        }
        return MySqlColumnDesc(schema: schema, table: table, name: name, columnType: colType)
    }

    public static func decodeRowData(payload: [uint8], columns: [MySqlColumnDesc]) -> sql.Row {
        var offset = 0
        var colNames: [string] = []
        var vals: [sql.Value] = []

        var i = 0
        while i < columns.count && offset < payload.count {
            colNames.append(columns[i].name)
            if payload[offset] == 0xFB {
                vals.append(.null)
                offset += 1
            } else if let s = readLenEncString(payload, from: &offset) {
                if let num = int64(s) {
                    vals.append(.integer(num))
                } else if let f = float64(s) {
                    vals.append(.real(f))
                } else {
                    vals.append(.text(s))
                }
            } else {
                vals.append(.null)
            }
            i += 1
        }
        return sql.Row(columns: colNames, values: vals)
    }
}

func readLenEncInt(bytes: [uint8], from: inout int) -> int64? {
    if from >= bytes.count { return nil }
    let b = bytes[from]
    from += 1
    if b < 0xFB {
        return int64(b)
    }
    if b == 0xFB {
        return nil
    }
    if b == 0xFC {
        if from + 2 > bytes.count { return nil }
        let val = int64(readInt16LE(bytes, from: from))
        from += 2
        return val
    }
    if b == 0xFD {
        if from + 3 > bytes.count { return nil }
        let val = int64(readInt24LE(bytes, from: from))
        from += 3
        return val
    }
    if b == 0xFE {
        if from + 8 > bytes.count { return nil }
        let b0 = int64(bytes[from])
        let b1 = int64(bytes[from + 1])
        let b2 = int64(bytes[from + 2])
        let b3 = int64(bytes[from + 3])
        let b4 = int64(bytes[from + 4])
        let b5 = int64(bytes[from + 5])
        let b6 = int64(bytes[from + 6])
        let b7 = int64(bytes[from + 7])
        from += 8
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24) | (b4 << 32) | (b5 << 40) | (b6 << 48) | (b7 << 56)
    }
    return nil
}

func readLenEncString(bytes: [uint8], from: inout int) -> string? {
    guard let len = readLenEncInt(bytes, from: &from) else {
        return nil
    }
    let length = int(len)
    if from + length > bytes.count { return nil }
    let slice = sliceBytes(bytes, from: from, to: from + length)
    from += length
    var s = ""
    for b in slice {
        s.append(Character(UnicodeScalar(b)))
    }
    return s
}
