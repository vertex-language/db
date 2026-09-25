package redis

import "net/tcp"

public class RedisClient {
    var stream: tcp.TcpStream?
    var parser: RespParser
    var isMemory: bool

    // In-memory data store for offline tests and simulation
    var memStrings: [string: string]
    var memHashes: [string: [string: string]]
    var memLists: [string: [string]]

    public init(stream: tcp.TcpStream? = nil, isMemory: bool = false) {
        self.stream = stream
        self.parser = RespParser()
        self.isMemory = isMemory
        self.memStrings = [:]
        self.memHashes = [:]
        self.memLists = [:]
    }

    public static func connect(host: string = "127.0.0.1", port: int = 6379, timeoutMs: int32 = 5000) async throws -> RedisClient {
        let address = "\(host):\(port)"
        let s = try await tcp.Connect(address, timeoutMs: timeoutMs)
        return RedisClient(stream: s, isMemory: false)
    }

    public static func memory() -> RedisClient {
        return RedisClient(stream: nil, isMemory: true)
    }

    public func close() {
        if let s = self.stream {
            s.Close()
            self.stream = nil
        }
    }

    public func sendCommand(_ args: [string]) async throws -> RespValue {
        if self.isMemory {
            return self.executeMemory(args)
        }

        guard let s = self.stream else {
            throw RespError.invalidFormat("client is closed")
        }

        let payload = RespSerializer.encodeCommand(args)
        try await s.Write(payload)

        while true {
            if let val = try self.parser.parse() {
                return val
            }
            var buf = [uint8](repeating: 0, count: 4096)
            let n = try await s.Read(into: &buf)
            if n == 0 {
                throw RespError.invalidFormat("server closed connection")
            }
            let chunk = sliceBytes(buf, from: 0, to: n)
            self.parser.feed(chunk)
        }
    }

    func executeMemory(_ args: [string]) -> RespValue {
        if args.isEmpty {
            return .error("empty command")
        }
        let cmd = args[0].uppercased()

        switch cmd {
        case "PING":
            if args.count > 1 {
                return .simpleString(args[1])
            }
            return .simpleString("PONG")

        case "GET":
            if args.count < 2 { return .error("ERR wrong number of arguments for 'get' command") }
            let key = args[1]
            if let val = self.memStrings[key] {
                return .bulkString([uint8](val.utf8))
            }
            return .bulkString(nil)

        case "SET":
            if args.count < 3 { return .error("ERR wrong number of arguments for 'set' command") }
            let key = args[1]
            let val = args[2]
            self.memStrings[key] = val
            return .simpleString("OK")

        case "DEL":
            if args.count < 2 { return .error("ERR wrong number of arguments for 'del' command") }
            var count: int64 = 0
            var i = 1
            while i < args.count {
                let k = args[i]
                if self.memStrings[k] != nil {
                    self.memStrings[k] = nil
                    count += 1
                }
                if self.memHashes[k] != nil {
                    self.memHashes[k] = nil
                    count += 1
                }
                if self.memLists[k] != nil {
                    self.memLists[k] = nil
                    count += 1
                }
                i += 1
            }
            return .integer(count)

        case "EXISTS":
            if args.count < 2 { return .error("ERR wrong number of arguments for 'exists' command") }
            let key = args[1]
            let ex = self.memStrings[key] != nil || self.memHashes[key] != nil || self.memLists[key] != nil
            return .integer(ex ? 1 : 0)

        case "INCR":
            if args.count < 2 { return .error("ERR wrong number of arguments for 'incr' command") }
            let key = args[1]
            let current = int64(self.memStrings[key] ?? "0") ?? 0
            let newVal = current + 1
            self.memStrings[key] = string(newVal)
            return .integer(newVal)

        case "DECR":
            if args.count < 2 { return .error("ERR wrong number of arguments for 'decr' command") }
            let key = args[1]
            let current = int64(self.memStrings[key] ?? "0") ?? 0
            let newVal = current - 1
            self.memStrings[key] = string(newVal)
            return .integer(newVal)

        case "HSET":
            if args.count < 4 { return .error("ERR wrong number of arguments for 'hset' command") }
            let key = args[1]
            let field = args[2]
            let val = args[3]
            var h = self.memHashes[key] ?? [:]
            let isNew = h[field] == nil
            h[field] = val
            self.memHashes[key] = h
            return .integer(isNew ? 1 : 0)

        case "HGET":
            if args.count < 3 { return .error("ERR wrong number of arguments for 'hget' command") }
            let key = args[1]
            let field = args[2]
            if let h = self.memHashes[key], let val = h[field] {
                return .bulkString([uint8](val.utf8))
            }
            return .bulkString(nil)

        case "HGETALL":
            if args.count < 2 { return .error("ERR wrong number of arguments for 'hgetall' command") }
            let key = args[1]
            var list: [RespValue] = []
            if let h = self.memHashes[key] {
                for (f, v) in h {
                    list.append(.bulkString([uint8](f.utf8)))
                    list.append(.bulkString([uint8](v.utf8)))
                }
            }
            return .array(list)

        case "HDEL":
            if args.count < 3 { return .error("ERR wrong number of arguments for 'hdel' command") }
            let key = args[1]
            var h = self.memHashes[key] ?? [:]
            var count: int64 = 0
            var i = 2
            while i < args.count {
                let f = args[i]
                if h[f] != nil {
                    h[f] = nil
                    count += 1
                }
                i += 1
            }
            self.memHashes[key] = h
            return .integer(count)

        case "LPUSH":
            if args.count < 3 { return .error("ERR wrong number of arguments for 'lpush' command") }
            let key = args[1]
            var l = self.memLists[key] ?? []
            var i = 2
            while i < args.count {
                l.insert(args[i], at: 0)
                i += 1
            }
            self.memLists[key] = l
            return .integer(int64(l.count))

        case "RPUSH":
            if args.count < 3 { return .error("ERR wrong number of arguments for 'rpush' command") }
            let key = args[1]
            var l = self.memLists[key] ?? []
            var i = 2
            while i < args.count {
                l.append(args[i])
                i += 1
            }
            self.memLists[key] = l
            return .integer(int64(l.count))

        case "LPOP":
            if args.count < 2 { return .error("ERR wrong number of arguments for 'lpop' command") }
            let key = args[1]
            guard var l = self.memLists[key], !l.isEmpty else {
                return .bulkString(nil)
            }
            let val = l.remove(at: 0)
            self.memLists[key] = l
            return .bulkString([uint8](val.utf8))

        case "RPOP":
            if args.count < 2 { return .error("ERR wrong number of arguments for 'rpop' command") }
            let key = args[1]
            guard var l = self.memLists[key], !l.isEmpty else {
                return .bulkString(nil)
            }
            let val = l.remove(at: l.count - 1)
            self.memLists[key] = l
            return .bulkString([uint8](val.utf8))

        case "LRANGE":
            if args.count < 4 { return .error("ERR wrong number of arguments for 'lrange' command") }
            let key = args[1]
            var start = int(args[2]) ?? 0
            var stop = int(args[3]) ?? 0
            guard let l = self.memLists[key] else {
                let emptyList: [RespValue] = []
                return .array(emptyList)
            }
            let len = l.count
            if start < 0 { start = len + start }
            if stop < 0 { stop = len + stop }
            if start < 0 { start = 0 }
            if stop >= len { stop = len - 1 }
            if start > stop || start >= len {
                let emptyList: [RespValue] = []
                return .array(emptyList)
            }
            var result: [RespValue] = []
            var idx = start
            while idx <= stop {
                result.append(.bulkString([uint8](l[idx].utf8)))
                idx += 1
            }
            return .array(result)

        case "LLEN":
            if args.count < 2 { return .error("ERR wrong number of arguments for 'llen' command") }
            let key = args[1]
            let len = self.memLists[key]?.count ?? 0
            return .integer(int64(len))

        case "FLUSHDB":
            self.memStrings = [:]
            self.memHashes = [:]
            self.memLists = [:]
            return .simpleString("OK")

        default:
            return .error("ERR unknown command '\(args[0])'")
        }
    }

    // High-level API
    public func ping(_ msg: string? = nil) async throws -> string {
        var args = ["PING"]
        if let m = msg { args.append(m) }
        let res = try await self.sendCommand(args)
        return res.asString() ?? "PONG"
    }

    public func get(_ key: string) async throws -> string? {
        let res = try await self.sendCommand(["GET", key])
        return res.asString()
    }

    public func set(_ key: string, _ value: string) async throws -> bool {
        let res = try await self.sendCommand(["SET", key, value])
        return res.asString() == "OK"
    }

    public func del(_ keys: [string]) async throws -> int64 {
        if keys.isEmpty { return 0 }
        var args = ["DEL"]
        args.append(contentsOf: keys)
        let res = try await self.sendCommand(args)
        return res.asInt() ?? 0
    }

    public func exists(_ key: string) async throws -> bool {
        let res = try await self.sendCommand(["EXISTS", key])
        return (res.asInt() ?? 0) > 0
    }

    public func incr(_ key: string) async throws -> int64 {
        let res = try await self.sendCommand(["INCR", key])
        return res.asInt() ?? 0
    }

    public func decr(_ key: string) async throws -> int64 {
        let res = try await self.sendCommand(["DECR", key])
        return res.asInt() ?? 0
    }

    public func hset(_ key: string, _ field: string, _ value: string) async throws -> int64 {
        let res = try await self.sendCommand(["HSET", key, field, value])
        return res.asInt() ?? 0
    }

    public func hget(_ key: string, _ field: string) async throws -> string? {
        let res = try await self.sendCommand(["HGET", key, field])
        return res.asString()
    }

    public func hgetall(_ key: string) async throws -> [string: string] {
        let res = try await self.sendCommand(["HGETALL", key])
        var map: [string: string] = [:]
        switch res {
        case .array(let a):
            if let arr = a {
                var i = 0
                while i + 1 < arr.count {
                    if let f = arr[i].asString(), let v = arr[i + 1].asString() {
                        map[f] = v
                    }
                    i += 2
                }
            }
        default:
            break
        }
        return map
    }

    public func hdel(_ key: string, _ fields: [string]) async throws -> int64 {
        if fields.isEmpty { return 0 }
        var args = ["HDEL", key]
        args.append(contentsOf: fields)
        let res = try await self.sendCommand(args)
        return res.asInt() ?? 0
    }

    public func lpush(_ key: string, _ values: [string]) async throws -> int64 {
        if values.isEmpty { return 0 }
        var args = ["LPUSH", key]
        args.append(contentsOf: values)
        let res = try await self.sendCommand(args)
        return res.asInt() ?? 0
    }

    public func rpush(_ key: string, _ values: [string]) async throws -> int64 {
        if values.isEmpty { return 0 }
        var args = ["RPUSH", key]
        args.append(contentsOf: values)
        let res = try await self.sendCommand(args)
        return res.asInt() ?? 0
    }

    public func lpop(_ key: string) async throws -> string? {
        let res = try await self.sendCommand(["LPOP", key])
        return res.asString()
    }

    public func rpop(_ key: string) async throws -> string? {
        let res = try await self.sendCommand(["RPOP", key])
        return res.asString()
    }

    public func lrange(_ key: string, start: int, stop: int) async throws -> [string] {
        let res = try await self.sendCommand(["LRANGE", key, string(start), string(stop)])
        var items: [string] = []
        switch res {
        case .array(let a):
            if let arr = a {
                for item in arr {
                    if let s = item.asString() {
                        items.append(s)
                    }
                }
            }
        default:
            break
        }
        return items
    }

    public func llen(_ key: string) async throws -> int64 {
        let res = try await self.sendCommand(["LLEN", key])
        return res.asInt() ?? 0
    }

    public func flushdb() async throws -> bool {
        let res = try await self.sendCommand(["FLUSHDB"])
        return res.asString() == "OK"
    }
}
