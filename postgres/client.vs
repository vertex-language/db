package postgres

import "net/tcp"
import "db/sql"

public class PgClient {
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
        port: int = 5432,
        user: string = "postgres",
        password: string = "",
        database: string = "postgres",
        timeoutMs: int32 = 5000
    ) async throws -> PgClient {
        let address = "\(host):\(port)"
        let s = try await tcp.Connect(address, timeoutMs: timeoutMs)
        let client = PgClient(stream: s, isMock: false)
        try await client.handshake(user: user, password: password, database: database)
        return client
    }

    public static func mock() -> PgClient {
        let client = PgClient(stream: nil, isMock: true)
        client.mockCols["users"] = ["id", "name", "email"]
        let row1: [sql.Value] = [.integer(1), .text("Alice"), .text("alice@example.com")]
        let row2: [sql.Value] = [.integer(2), .text("Bob"), .text("bob@example.com")]
        client.mockData["users"] = [row1, row2]
        return client
    }

    func handshake(user: string, password: string, database: string) async throws {
        guard let s = self.stream else {
            throw sql.DbError.connectionFailed("stream is nil")
        }

        let startup = PgProtocol.encodeStartup(user: user, database: database)
        try await s.Write(startup)

        var authenticated = false
        while !authenticated {
            let (msgType, payload) = try await self.readPacket()

            if msgType == 0x52 { // 'R' Authentication
                if payload.count < 4 {
                    throw sql.DbError.protocolError("invalid auth packet")
                }
                let authType = readInt32BE(payload, from: 0)
                if authType == 0 { // AuthenticationOk
                    // continue until ReadyForQuery
                } else if authType == 3 { // AuthenticationCleartextPassword
                    let pwMsg = PgProtocol.encodePassword(password)
                    try await s.Write(pwMsg)
                } else if authType == 5 { // AuthenticationMD5Password
                    let pwMsg = PgProtocol.encodePassword(password)
                    try await s.Write(pwMsg)
                } else {
                    throw sql.DbError.authFailed("unsupported auth type: \(authType)")
                }
            } else if msgType == 0x4B { // 'K' BackendKeyData
                continue
            } else if msgType == 0x53 { // 'S' ParameterStatus
                continue
            } else if msgType == 0x5A { // 'Z' ReadyForQuery
                authenticated = true
                break
            } else if msgType == 0x45 { // 'E' ErrorResponse
                let errMsg = PgProtocol.decodeErrorResponse(payload)
                throw sql.DbError.authFailed(errMsg)
            }
        }
    }

    func readPacket() async throws -> (type: uint8, payload: [uint8]) {
        guard let s = self.stream else {
            throw sql.DbError.connectionFailed("client is closed")
        }
        var header = [uint8](repeating: 0, count: 5)
        try await s.ReadFull(into: &header)
        let msgType = header[0]
        let length = readInt32BE(header, from: 1)
        let payloadLen = int(length) - 4
        if payloadLen <= 0 {
            return (type: msgType, payload: [])
        }
        var payload = [uint8](repeating: 0, count: payloadLen)
        try await s.ReadFull(into: &payload)
        return (type: msgType, payload: payload)
    }

    public func exec(_ sqlStr: string) async throws -> sql.Result {
        if self.isMock {
            return sql.Result(rowsAffected: 1, lastInsertId: 1)
        }

        guard let s = self.stream else {
            throw sql.DbError.connectionFailed("client is closed")
        }

        let qMsg = PgProtocol.encodeQuery(sqlStr)
        try await s.Write(qMsg)

        var totalAffected: int64 = 0
        while true {
            let (msgType, payload) = try await self.readPacket()

            if msgType == 0x43 { // 'C' CommandComplete
                let (_, affected) = PgProtocol.decodeCommandComplete(payload)
                totalAffected += affected
            } else if msgType == 0x5A { // 'Z' ReadyForQuery
                break
            } else if msgType == 0x45 { // 'E' ErrorResponse
                let errMsg = PgProtocol.decodeErrorResponse(payload)
                throw sql.DbError.queryFailed(errMsg)
            }
        }

        return sql.Result(rowsAffected: totalAffected, lastInsertId: 0)
    }

    public func query(_ sqlStr: string) async throws -> sql.Rows {
        if self.isMock {
            let cols = self.mockCols["users"] ?? ["id", "name"]
            let rawRows = self.mockData["users"] ?? []
            var records: [sql.Row] = []
            for r in rawRows {
                records.append(sql.Row(columns: cols, values: r))
            }
            return sql.Rows(columns: cols, records: records)
        }

        guard let s = self.stream else {
            throw sql.DbError.connectionFailed("client is closed")
        }

        let qMsg = PgProtocol.encodeQuery(sqlStr)
        try await s.Write(qMsg)

        var cols: [PgColumnDesc] = []
        var colNames: [string] = []
        var records: [sql.Row] = []

        while true {
            let (msgType, payload) = try await self.readPacket()

            if msgType == 0x54 { // 'T' RowDescription
                cols = try PgProtocol.decodeRowDescription(payload)
                colNames = []
                for c in cols {
                    colNames.append(c.name)
                }
            } else if msgType == 0x44 { // 'D' DataRow
                let row = try PgProtocol.decodeDataRow(payload, columns: cols)
                records.append(row)
            } else if msgType == 0x43 { // 'C' CommandComplete
                continue
            } else if msgType == 0x5A { // 'Z' ReadyForQuery
                break
            } else if msgType == 0x45 { // 'E' ErrorResponse
                let errMsg = PgProtocol.decodeErrorResponse(payload)
                throw sql.DbError.queryFailed(errMsg)
            }
        }

        return sql.Rows(columns: colNames, records: records)
    }

    public func queryRow(_ sqlStr: string) async throws -> sql.Row? {
        let rows = try await self.query(sqlStr)
        if rows.next() {
            return rows.current()
        }
        return nil
    }

    public func close() async {
        if let s = self.stream {
            let term = PgProtocol.encodeTerminate()
            try? await s.Write(term)
            s.Close()
            self.stream = nil
        }
    }
}
