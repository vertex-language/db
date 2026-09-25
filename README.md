# db

[![package: vs-package](https://img.shields.io/badge/package-vs--package-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](https://github.com/vertex-language)
[![sub-packages: sql | sqlite | redis | postgres | mysql](https://img.shields.io/badge/sub--packages-sql%20%7C%20sqlite%20%7C%20redis%20%7C%20postgres%20%7C%20mysql-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](https://github.com/vertex-language/db)

Database drivers, embedded SQL storage engine, and database wire protocols.

---

## Sub-Packages

| Package | Description | Common Uses |
| --- | --- | --- |
| [`db/sql`](#dbsql) | Common SQL interfaces, dynamic `Value` types, row cursors, and error abstractions | Shared SQL contract across drivers and query engines |
| [`db/sqlite`](#dbsqlite) | Embedded file-based SQL database engine supporting `:memory:` and disk persistence | Local storage, embedded databases, testing, offline state |
| [`db/redis`](#dbredis) | Redis client wire protocol (RESP2/RESP3) with full command suite and in-memory engine | Key-value caching, queues, pub/sub, session stores |
| [`db/postgres`](#dbpostgres) | PostgreSQL wire protocol v3.0 client over TCP | PostgreSQL server connections, transactional workloads |
| [`db/mysql`](#dbmysql) | MySQL client wire protocol over TCP | MySQL / MariaDB server connections, relational queries |

---

## Quick Start

Run any entry point with:

```bash
vsc run main.vs
```

---

### Embedded SQL (`db/sqlite`)

```swift
package main

import "db/sqlite"

func main() -> int32 {
    do {
        // Open an in-memory database (or a file path like "app.db")
        let db = try sqlite.Database.open(":memory:")
        defer { db.close() }

        // Create table
        _ = try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")

        // Insert rows with auto-incrementing ID
        _ = try db.exec("INSERT INTO users (name, age) VALUES ('Alice', 30)")
        _ = try db.exec("INSERT INTO users (name, age) VALUES ('Bob', 25)")

        // Query rows with filtering and sorting
        let rows = try db.query("SELECT id, name, age FROM users WHERE age >= 25 ORDER BY age DESC")
        while rows.next() {
            if let r = rows.current() {
                let name = r.string("name") ?? ""
                let age = r.int("age") ?? 0
                print("User: \(name), Age: \(age)")
            }
        }

        // Transactions
        try db.beginTransaction()
        _ = try db.exec("INSERT INTO users (name, age) VALUES ('Charlie', 35)")
        try db.commitTransaction()

    } catch {
        print("Database error: \(error)")
        return 1
    }
    return 0
}
```

---

### Redis Client (`db/redis`)

```swift
package main

import "db/redis"

func main() async -> int32 {
    do {
        // Connect over TCP or use the in-memory engine for local testing
        let client = try await redis.RedisClient.connect(host: "127.0.0.1", port: 6379)
        defer { client.close() }

        // Strings
        _ = try await client.set("session:token", "abc123xyz")
        if let val = try await client.get("session:token") {
            print("Token: \(val)")
        }

        // Atomic counters
        let hits = try await client.incr("page:views")
        print("Page views: \(hits)")

        // Hashes
        _ = try await client.hset("user:101", "name", "Alice")
        _ = try await client.hset("user:101", "email", "alice@example.com")
        let profile = try await client.hgetall("user:101")
        print("Name: \(profile["name"] ?? "")")

    } catch {
        print("Redis error: \(error)")
        return 1
    }
    return 0
}
```

---

### PostgreSQL Client (`db/postgres`)

```swift
package main

import "db/postgres"

func main() async -> int32 {
    do {
        let pg = try await postgres.PgClient.connect(
            host: "127.0.0.1",
            port: 5432,
            user: "postgres",
            password: "",
            database: "postgres"
        )
        defer { await pg.close() }

        let rows = try await pg.query("SELECT id, name FROM users WHERE active = true")
        while rows.next() {
            if let r = rows.current() {
                print("User: \(r.string("name") ?? "")")
            }
        }
    } catch {
        print("Postgres error: \(error)")
        return 1
    }
    return 0
}
```

---

### MySQL Client (`db/mysql`)

```swift
package main

import "db/mysql"

func main() async -> int32 {
    do {
        let mysqlClient = try await mysql.MySqlClient.connect(
            host: "127.0.0.1",
            port: 3306,
            user: "root",
            password: "",
            database: "shop"
        )
        defer { await mysqlClient.close() }

        let rows = try await mysqlClient.query("SELECT id, title, price FROM products")
        while rows.next() {
            if let r = rows.current() {
                print("Product: \(r.string("title") ?? ""), Price: \(r.float("price") ?? 0.0)")
            }
        }
    } catch {
        print("MySQL error: \(error)")
        return 1
    }
    return 0
}
```

---

## Testing

Run the test suite:

```bash
vsc run check
```

---

## License

[MIT](LICENSE)
