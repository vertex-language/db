package mysql

import (
    "db/sql"
    "net/tcp"
)

public class MySqlClient {
    var stream: tcp.TcpStream?
    var isMock: bool
    var mockData: [string: [[sql.Value]]]
    var mockCols: [string: [string]]

    public init(stream: tcp.TcpStream? = nil, isMock: bool = false) {
        self.stream = stream
        self.isMock = isMock
        self.mockData = [:]
        self.mockCols = [:]
    }

    public static func connect(
        host: string = "127.0.0.1",
        port: int = 3306,
        user: string = "root",
        password: string = "",
        database: string = "",
        timeoutMs: int32 = 5000
    ) async throws -> MySqlClient {
        let address = "\(host):\(port)"
        let s = try await tcp.Connect(address, timeoutMs: timeoutMs)
        let client = MySqlClient(stream: s, isMock: false)
        try await client.handshake(user: user, password: password, database: database)
        return client
    }

    public static func mock() -> MySqlClient {
        let client = MySqlClient(stream: nil, isMock: true)
        client.mockCols["products"] = ["id", "title", "price"]
        let r1: [sql.Value] = [.integer(1), .text("Keyboard"), .real(99.99)]
        let r2: [sql.Value] = [.integer(2), .text("Mouse"), .real(49.99)]
        client.mockData["products"] = [r1, r2]
        return client
    }

    func handshake(user: string, password: string, database: string) async throws {
        guard let s = self.stream else {
            throw sql.DbError.connectionFailed("stream is nil")
        }

        // 1. Read initial HandshakeV10 packet
        let (seq, handshakePayload) = try await self.readPacket()
        if handshakePayload.isEmpty || handshakePayload[0] == 0xFF {
            let errMsg = MySqlProtocol.decodeErrPacket(handshakePayload)
            throw sql.DbError.connectionFailed(errMsg)
        }

        // 2. Send HandshakeResponse41
        let resp = MySqlProtocol.encodeHandshakeResponse41(
            user: user,
            password: password,
            database: database,
            seq: seq + 1
        )
        try await s.Write(resp)

        // 3. Read OK or ERR
        let (_, authResult) = try await self.readPacket()
        if authResult.isEmpty {
            throw sql.DbError.authFailed("empty auth response")
        }
        if authResult[0] == 0xFF {
            let errMsg = MySqlProtocol.decodeErrPacket(authResult)
            throw sql.DbError.authFailed(errMsg)
        }
    }

    func readPacket() async throws -> (seq: uint8, payload: [uint8]) {
        guard let s = self.stream else {
            throw sql.DbError.connectionFailed("client is closed")
        }
        var header = [uint8](repeating: 0, count: 4)
        try await s.ReadFull(into: &header)
        let payloadLen = readInt24LE(header, from: 0)
        let seq = header[3]
        if payloadLen <= 0 {
            return (seq: seq, payload: [])
        }
        var payload = [uint8](repeating: 0, count: payloadLen)
        try await s.ReadFull(into: &payload)
        return (seq: seq, payload: payload)
    }

    public func exec(sqlStr: string) async throws -> sql.Result {
        if self.isMock {
            return sql.Result(rowsAffected: 1, lastInsertId: 1)
        }

        guard let s = self.stream else {
            throw sql.DbError.connectionFailed("client is closed")
        }

        let qPacket = MySqlProtocol.encodeQuery(sqlStr, seq: 0)
        try await s.Write(qPacket)

        let (_, payload) = try await self.readPacket()
        if payload.isEmpty {
            return sql.Result(rowsAffected: 0, lastInsertId: 0)
        }
        if payload[0] == 0xFF {
            let errMsg = MySqlProtocol.decodeErrPacket(payload)
            throw sql.DbError.queryFailed(errMsg)
        }
        if payload[0] == 0x00 {
            let (affected, lastId) = MySqlProtocol.decodeOkPacket(payload)
            return sql.Result(rowsAffected: affected, lastInsertId: lastId)
        }

        return sql.Result(rowsAffected: 0, lastInsertId: 0)
    }

    public func query(sqlStr: string) async throws -> sql.Rows {
        if self.isMock {
            let cols = self.mockCols["products"] ?? ["id", "title"]
            let rawRows = self.mockData["products"] ?? []
            var records: [sql.Row] = []
            for r in rawRows {
                records.append(sql.Row(columns: cols, values: r))
            }
            return sql.Rows(columns: cols, records: records)
        }

        guard let s = self.stream else {
            throw sql.DbError.connectionFailed("client is closed")
        }

        let qPacket = MySqlProtocol.encodeQuery(sqlStr, seq: 0)
        try await s.Write(qPacket)

        let (_, firstPayload) = try await self.readPacket()
        if firstPayload.isEmpty {
            return sql.Rows(columns: [], records: [])
        }
        if firstPayload[0] == 0xFF {
            let errMsg = MySqlProtocol.decodeErrPacket(firstPayload)
            throw sql.DbError.queryFailed(errMsg)
        }

        var offset = 0
        let colCount = int(readLenEncInt(firstPayload, from: &offset) ?? 0)

        // Read column definitions
        var columns: [MySqlColumnDesc] = []
        var colNames: [string] = []
        var ci = 0
        while ci < colCount {
            let (_, colPayload) = try await self.readPacket()
            let cDesc = MySqlProtocol.decodeColumnDefinition(colPayload)
            columns.append(cDesc)
            colNames.append(cDesc.name)
            ci += 1
        }

        // Read EOF after columns (unless deprecated)
        let (_, eofPayload) = try await self.readPacket()
        if eofPayload.first == 0xFE && eofPayload.count < 9 {
            // EOF packet
        }

        // Read rows until EOF packet (0xFE)
        var records: [sql.Row] = []
        while true {
            let (_, rowPayload) = try await self.readPacket()
            if rowPayload.isEmpty { break }
            if rowPayload[0] == 0xFE && rowPayload.count < 9 {
                // EOF packet terminating row data
                break
            }
            if rowPayload[0] == 0xFF {
                let errMsg = MySqlProtocol.decodeErrPacket(rowPayload)
                throw sql.DbError.queryFailed(errMsg)
            }

            let row = MySqlProtocol.decodeRowData(rowPayload, columns: columns)
            records.append(row)
        }

        return sql.Rows(columns: colNames, records: records)
    }

    public func queryRow(sqlStr: string) async throws -> sql.Row? {
        let rows = try await self.query(sqlStr)
        if rows.next() {
            return rows.current()
        }
        return nil
    }

    public func close() async {
        if let s = self.stream {
            s.Close()
            self.stream = nil
        }
    }
}
