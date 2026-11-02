package main

import (
    "db/mysql"
    "db/postgres"
    "db/redis"
    "db/sql"
    "db/sqlite"
    "fs"
)

var failures: int32 = 0

func check(ok: bool, what: string) {
    if ok {
        print("ok    \(what)")
    } else {
        print("FAIL  \(what)")
        failures += 1
    }
}

// ---------------------------------------------------------------------------
// SQL Value and Row / Rows tests
// ---------------------------------------------------------------------------

func testSqlTypes() {
    let vNull = sql.Value.null
    check(vNull.isNull, "sql.Value null isNull")
    check(vNull.description == "NULL", "sql.Value null description")

    let vInt = sql.Value.integer(42)
    check(vInt.asInt() == 42, "sql.Value integer asInt")
    check(vInt.asFloat() == 42.0, "sql.Value integer asFloat")
    check(vInt.asString() == "42", "sql.Value integer asString")

    let vReal = sql.Value.real(3.14)
    check(vReal.asFloat() == 3.14, "sql.Value real asFloat")
    check(vReal.asInt() == 3, "sql.Value real asInt")

    let vText = sql.Value.text("vertex")
    check(vText.asString() == "vertex", "sql.Value text asString")

    let vBool = sql.Value.boolean(true)
    check(vBool.asBool() == true, "sql.Value boolean asBool")

    let vBlob = sql.Value.blob([0xDE, 0xAD, 0xBE, 0xEF])
    check(vBlob.asBlob()?.count == 4, "sql.Value blob asBlob")

    let row = sql.Row(
        columns: ["id", "name", "score", "active"],
        values: [.integer(101), .text("Alice"), .real(98.5), .boolean(true)]
    )
    check(row.int("id") == 101, "sql.Row int lookup")
    check(row.string("name") == "Alice", "sql.Row string lookup")
    check(row.float("score") == 98.5, "sql.Row float lookup")
    check(row.bool("active") == true, "sql.Row bool lookup")
    check(row.at(0)?.asInt() == 101, "sql.Row at index")
    check(row.get("nonexistent") == nil, "sql.Row nonexistent column is nil")

    let row2 = sql.Row(
        columns: ["id", "name", "score", "active"],
        values: [.integer(102), .text("Bob"), .real(85.0), .boolean(false)]
    )
    let rows = sql.Rows(columns: ["id", "name", "score", "active"], records: [row, row2])
    check(rows.count() == 2, "sql.Rows count")
    check(rows.next(), "sql.Rows next 1")
    check(rows.current()?.string("name") == "Alice", "sql.Rows current 1")
    check(rows.next(), "sql.Rows next 2")
    check(rows.current()?.string("name") == "Bob", "sql.Rows current 2")
    check(!rows.next(), "sql.Rows next EOF")

    let res = sql.Result(rowsAffected: 3, lastInsertId: 42)
    check(res.rowsAffected == 3, "sql.Result rowsAffected")
    check(res.lastInsertId == 42, "sql.Result lastInsertId")
}

// ---------------------------------------------------------------------------
// SQLite Engine and In-Memory Database tests
// ---------------------------------------------------------------------------

func testSqliteMemory() {
    do {
        let db = try sqlite.Database.open(":memory:")

        // 1. Create table
        _ = try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER, active BOOLEAN)")
        check(db.getTable("users") != nil, "sqlite create table")

        // 2. Insert records with auto-increment
        let r1 = try db.exec("INSERT INTO users (name, age, active) VALUES ('Alice', 30, true)")
        check(r1.lastInsertId == 1, "sqlite insert autoinc id 1")
        let r2 = try db.exec("INSERT INTO users (name, age, active) VALUES ('Bob', 25, false)")
        check(r2.lastInsertId == 2, "sqlite insert autoinc id 2")
        let r3 = try db.exec("INSERT INTO users (name, age, active) VALUES ('Charlie', 35, true)")
        check(r3.lastInsertId == 3, "sqlite insert autoinc id 3")

        // 3. Select all
        let allRows = try db.query("SELECT * FROM users")
        check(allRows.count() == 3, "sqlite select * count == 3")

        // 4. Select with WHERE and ORDER BY DESC
        let filterRows = try db.query("SELECT id, name, age FROM users WHERE age > 26 ORDER BY age DESC")
        check(filterRows.count() == 2, "sqlite select where age > 26 count == 2")
        if filterRows.next() {
            check(filterRows.current()?.string("name") == "Charlie", "sqlite order desc first Charlie")
        }
        if filterRows.next() {
            check(filterRows.current()?.string("name") == "Alice", "sqlite order desc second Alice")
        }

        // 5. Aggregations: COUNT, SUM, AVG, MIN, MAX
        let aggRows = try db.query("SELECT COUNT(*), SUM(age), AVG(age), MIN(age), MAX(age) FROM users")
        if aggRows.next() {
            let cur = aggRows.current()!
            check(cur.int("COUNT(*)") == 3, "sqlite agg COUNT(*) == 3")
            check(cur.float("SUM(age)") == 90.0, "sqlite agg SUM(age) == 90")
            check(cur.float("AVG(age)") == 30.0, "sqlite agg AVG(age) == 30")
            check(cur.int("MIN(age)") == 25, "sqlite agg MIN(age) == 25")
            check(cur.int("MAX(age)") == 35, "sqlite agg MAX(age) == 35")
        } else {
            check(false, "sqlite agg failed to return row")
        }

        // 6. LIKE expression
        let likeRows = try db.query("SELECT name FROM users WHERE name LIKE '%li%'")
        check(likeRows.count() == 2, "sqlite LIKE '%li%' matches Alice and Charlie")

        // 7. IN expression
        let inRows = try db.query("SELECT name FROM users WHERE name IN ('Alice', 'Bob')")
        check(inRows.count() == 2, "sqlite IN ('Alice', 'Bob') matches 2")

        // 8. BETWEEN expression
        let betweenRows = try db.query("SELECT name FROM users WHERE age BETWEEN 25 AND 32")
        check(betweenRows.count() == 2, "sqlite BETWEEN 25 AND 32 matches 2")

        // 9. UPDATE
        let updateRes = try db.exec("UPDATE users SET age = 31 WHERE name = 'Alice'")
        check(updateRes.rowsAffected == 1, "sqlite update rowsAffected == 1")
        let aliceRow = try db.queryRow("SELECT age FROM users WHERE name = 'Alice'")
        check(aliceRow?.int("age") == 31, "sqlite update applied age == 31")

        // 10. DELETE
        let delRes = try db.exec("DELETE FROM users WHERE name = 'Charlie'")
        check(delRes.rowsAffected == 1, "sqlite delete rowsAffected == 1")
        let remRows = try db.query("SELECT * FROM users")
        check(remRows.count() == 2, "sqlite remaining count after delete == 2")

        // 11. Transactions: Rollback
        try db.beginTransaction()
        _ = try db.exec("INSERT INTO users (name, age, active) VALUES ('Dave', 40, true)")
        let inTxRows = try db.query("SELECT * FROM users")
        check(inTxRows.count() == 3, "sqlite in transaction count == 3")
        try db.rollbackTransaction()
        let postRollback = try db.query("SELECT * FROM users")
        check(postRollback.count() == 2, "sqlite post-rollback count restored to 2")

        // 12. Transactions: Commit
        try db.beginTransaction()
        _ = try db.exec("INSERT INTO users (name, age, active) VALUES ('Eve', 22, true)")
        try db.commitTransaction()
        let postCommit = try db.query("SELECT * FROM users")
        check(postCommit.count() == 3, "sqlite post-commit count is 3")
    } catch {
        check(false, "sqlite memory tests threw: \(error)")
    }
}

// ---------------------------------------------------------------------------
// SQLite File Persistence tests
// ---------------------------------------------------------------------------

func testSqliteFilePersistence() {
    let testDbFile = "test_persistence.db"
    // Clean up if existing
    try? fs.Remove(fs.Path(testDbFile))

    do {
        // Step 1: Open, populate, and close
        let db1 = try sqlite.Database.open(testDbFile)
        _ = try db1.exec("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT, content TEXT)")
        _ = try db1.exec("INSERT INTO notes (title, content) VALUES ('Task 1', 'Buy milk')")
        _ = try db1.exec("INSERT INTO notes (title, content) VALUES ('Task 2', 'Write code')")
        db1.close()

        // Step 2: Reopen from disk
        let db2 = try sqlite.Database.open(testDbFile)
        let rows = try db2.query("SELECT id, title, content FROM notes ORDER BY id ASC")
        check(rows.count() == 2, "sqlite file persist restores 2 rows")

        if rows.next() {
            let r = rows.current()!
            check(r.int("id") == 1, "sqlite persist row 1 id == 1")
            check(r.string("title") == "Task 1", "sqlite persist row 1 title")
            check(r.string("content") == "Buy milk", "sqlite persist row 1 content")
        }
        if rows.next() {
            let r = rows.current()!
            check(r.int("id") == 2, "sqlite persist row 2 id == 2")
            check(r.string("title") == "Task 2", "sqlite persist row 2 title")
        }

        // Step 3: Insert new row and verify auto-increment continued
        let r3 = try db2.exec("INSERT INTO notes (title, content) VALUES ('Task 3', 'Ship release')")
        check(r3.lastInsertId == 3, "sqlite persist autoinc counter preserved (id == 3)")

        db2.close()
        try fs.Remove(fs.Path(testDbFile))
        check(true, "sqlite file persistence cleaned up")
    } catch {
        check(false, "sqlite file persistence threw: \(error)")
        try? fs.Remove(fs.Path(testDbFile))
    }
}

// ---------------------------------------------------------------------------
// Redis Client and RESP tests
// ---------------------------------------------------------------------------

func testRedisProtocol() {
    do {
        // 1. Serialization
        let cmd = redis.RespSerializer.encodeCommand(["SET", "key", "val"])
        let expected = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$3\r\nval\r\n"
        var cmdStr = ""
        for b in cmd { cmdStr.append(Character(UnicodeScalar(b))) }
        check(cmdStr == expected, "redis encodeCommand matches RESP2 format")

        // 2. Parser
        let parser = redis.RespParser()
        parser.feed([uint8]("+OK\r\n".utf8))
        if let val1 = try parser.parse() {
            check(val1.asString() == "OK", "redis parse simple string +OK")
        } else {
            check(false, "redis parse simple string +OK returned nil")
        }

        parser.feed([uint8](":12345\r\n".utf8))
        if let val2 = try parser.parse() {
            check(val2.asInt() == 12345, "redis parse integer :12345")
        } else {
            check(false, "redis parse integer :12345 returned nil")
        }

        parser.feed([uint8]("$5\r\nhello\r\n".utf8))
        if let val3 = try parser.parse() {
            check(val3.asString() == "hello", "redis parse bulk string $5\\r\\nhello")
        } else {
            check(false, "redis parse bulk string $5\\r\\nhello returned nil")
        }

        parser.feed([uint8]("$-1\r\n".utf8))
        if let val4 = try parser.parse() {
            check(val4.isNull == true, "redis parse null bulk string $-1")
        } else {
            check(false, "redis parse null bulk string $-1 returned nil")
        }

        parser.feed([uint8]("-ERR bad syntax\r\n".utf8))
        if let val5 = try parser.parse() {
            check(val5.asString() == "ERR bad syntax", "redis parse error -ERR bad syntax")
        } else {
            check(false, "redis parse error -ERR bad syntax returned nil")
        }
    } catch {
        check(false, "redis protocol test threw: \(error)")
    }
}

func testRedisClient() async {
    do {
        let r = redis.RedisClient.memory()

        // PING
        let pong = try await r.ping()
        check(pong == "PONG", "redis ping -> PONG")
        let echo = try await r.ping("hello redis")
        check(echo == "hello redis", "redis ping hello -> hello")

        // Strings
        let okSet = try await r.set("greet", "world")
        check(okSet, "redis set greet world")
        let valGet = try await r.get("greet")
        check(valGet == "world", "redis get greet == world")

        // Exists & Del
        let ex1 = try await r.exists("greet")
        check(ex1, "redis exists greet is true")
        let delCnt = try await r.del(["greet"])
        check(delCnt == 1, "redis del greet returned 1")
        let ex2 = try await r.exists("greet")
        check(!ex2, "redis exists greet after del is false")

        // Incr & Decr
        let n1 = try await r.incr("counter")
        check(n1 == 1, "redis incr counter == 1")
        let n2 = try await r.incr("counter")
        check(n2 == 2, "redis incr counter == 2")
        let n3 = try await r.decr("counter")
        check(n3 == 1, "redis decr counter == 1")

        // Hashes
        let h1 = try await r.hset("user:1", "name", "Alice")
        check(h1 == 1, "redis hset new field returned 1")
        _ = try await r.hset("user:1", "email", "alice@example.com")
        let hName = try await r.hget("user:1", "name")
        check(hName == "Alice", "redis hget user:1 name == Alice")
        let allFields = try await r.hgetall("user:1")
        check(allFields["name"] == "Alice", "redis hgetall contains name")
        check(allFields["email"] == "alice@example.com", "redis hgetall contains email")
        let hdelCnt = try await r.hdel("user:1", ["email"])
        check(hdelCnt == 1, "redis hdel email returned 1")

        // Lists
        let l1 = try await r.rpush("queue", ["job1", "job2", "job3"])
        check(l1 == 3, "redis rpush 3 items")
        let qLen = try await r.llen("queue")
        check(qLen == 3, "redis llen == 3")
        let popped = try await r.lpop("queue")
        check(popped == "job1", "redis lpop returned job1")
        let range = try await r.lrange("queue", start: 0, stop: -1)
        check(range.count == 2, "redis lrange returns remaining 2 items")

        // Flush
        let flushed = try await r.flushdb()
        check(flushed, "redis flushdb")
        let emptyLen = try await r.llen("queue")
        check(emptyLen == 0, "redis llen after flush is 0")
    } catch {
        check(false, "redis client tests threw: \(error)")
    }
}

// ---------------------------------------------------------------------------
// PostgreSQL Protocol and Client tests
// ---------------------------------------------------------------------------

func testPostgresProtocol() {
    let startup = postgres.PgProtocol.encodeStartup(user: "alice", database: "mydb")
    check(startup.count > 8, "pg encodeStartup generates valid packet")

    let query = postgres.PgProtocol.encodeQuery("SELECT 1;")
    check(query[0] == 0x51, "pg encodeQuery starts with 'Q'")

    let term = postgres.PgProtocol.encodeTerminate()
    check(term[0] == 0x58, "pg encodeTerminate starts with 'X'")

    let (tag, affected) = postgres.PgProtocol.decodeCommandComplete([uint8]("INSERT 0 42\0".utf8))
    check(tag == "INSERT 0 42", "pg decodeCommandComplete tag")
    check(affected == 42, "pg decodeCommandComplete affected rows == 42")
}

func testPostgresClient() async {
    do {
        let client = postgres.PgClient.mock()
        let rows = try await client.query("SELECT * FROM users")
        check(rows.count() == 2, "pg mock query returns 2 rows")
        if rows.next() {
            check(rows.current()?.string("name") == "Alice", "pg mock first user Alice")
        }

        let row = try await client.queryRow("SELECT * FROM users")
        check(row?.string("name") == "Alice", "pg mock queryRow returns Alice")

        let res = try await client.exec("INSERT INTO users VALUES (3, 'Charlie')")
        check(res.rowsAffected == 1, "pg mock exec rowsAffected == 1")
    } catch {
        check(false, "pg client tests threw: \(error)")
    }
}

// ---------------------------------------------------------------------------
// MySQL Protocol and Client tests
// ---------------------------------------------------------------------------

func testMySqlProtocol() {
    let q = mysql.MySqlProtocol.encodeQuery("SELECT 1;", seq: 0)
    check(q.count >= 5, "mysql encodeQuery packet length")
    check(q[3] == 0, "mysql encodeQuery packet sequence id == 0")
    check(q[4] == 0x03, "mysql COM_QUERY opcode == 0x03")

    let resp = mysql.MySqlProtocol.encodeHandshakeResponse41(
        user: "root",
        password: "secret",
        database: "shop",
        seq: 1
    )
    check(resp.count > 32, "mysql HandshakeResponse41 packet length")
    check(resp[3] == 1, "mysql HandshakeResponse41 sequence id == 1")

    // OK packet: header 0x00, affected rows 5, last insert id 10
    let okPayload: [uint8] = [0x00, 0x05, 0x0A, 0x02, 0x00, 0x00, 0x00]
    let (affected, lastId) = mysql.MySqlProtocol.decodeOkPacket(okPayload)
    check(affected == 5, "mysql decodeOkPacket affected rows == 5")
    check(lastId == 10, "mysql decodeOkPacket last insert id == 10")
}

func testMySqlClient() async {
    do {
        let client = mysql.MySqlClient.mock()
        let rows = try await client.query("SELECT * FROM products")
        check(rows.count() == 2, "mysql mock query returns 2 products")
        if rows.next() {
            check(rows.current()?.string("title") == "Keyboard", "mysql mock first product Keyboard")
            check(rows.current()?.float("price") == 99.99, "mysql mock price 99.99")
        }

        let row = try await client.queryRow("SELECT * FROM products")
        check(row?.string("title") == "Keyboard", "mysql mock queryRow Keyboard")

        let res = try await client.exec("INSERT INTO products VALUES (3, 'Monitor', 299.99)")
        check(res.rowsAffected == 1, "mysql mock exec rowsAffected == 1")
    } catch {
        check(false, "mysql client tests threw: \(error)")
    }
}

// ---------------------------------------------------------------------------
// Main test runner
// ---------------------------------------------------------------------------

func main() async -> int32 {
    print("=== Testing db/sql ===")
    testSqlTypes()

    print("\n=== Testing db/sqlite (In-Memory) ===")
    testSqliteMemory()

    print("\n=== Testing db/sqlite (File Persistence) ===")
    testSqliteFilePersistence()

    print("\n=== Testing db/redis (RESP & Client) ===")
    testRedisProtocol()
    await testRedisClient()

    print("\n=== Testing db/postgres (Protocol & Client) ===")
    testPostgresProtocol()
    await testPostgresClient()

    print("\n=== Testing db/mysql (Protocol & Client) ===")
    testMySqlProtocol()
    await testMySqlClient()

    print("\n===============================")
    if failures == 0 {
        print("ALL TESTS PASSED!")
        return 0
    } else {
        print("TESTS FAILED: \(failures) error(s)")
        return 1
    }
}
