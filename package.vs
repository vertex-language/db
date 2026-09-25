// The 'db' repository: database drivers and storage engines for Vertex.
import PackageDescription

let package = Package(
    name: "db",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "db/sql", targets: ["db_sql"]),
        .library(name: "db/sqlite", targets: ["db_sqlite"]),
        .library(name: "db/postgres", targets: ["db_postgres"]),
        .library(name: "db/mysql", targets: ["db_mysql"]),
        .library(name: "db/redis", targets: ["db_redis"]),
        .executable(name: "check", targets: ["check"]),
    ],
    targets: [
        // Common SQL abstractions, value types, and interfaces.
        .target(
            name: "db_sql",
            path: "sql"
        ),
        // Pure Vertex embedded file-based SQL database engine.
        .target(
            name: "db_sqlite",
            dependencies: ["db_sql"],
            path: "sqlite"
        ),
        // PostgreSQL client wire protocol v3.0 over net/tcp.
        .target(
            name: "db_postgres",
            dependencies: ["db_sql"],
            path: "postgres"
        ),
        // MySQL client wire protocol over net/tcp.
        .target(
            name: "db_mysql",
            dependencies: ["db_sql"],
            path: "mysql"
        ),
        // Redis client wire protocol (RESP2/RESP3) over net/tcp.
        .target(
            name: "db_redis",
            path: "redis"
        ),
        // Comprehensive test suite.
        .executableTarget(
            name: "check",
            dependencies: ["db_sql", "db_sqlite", "db_postgres", "db_mysql", "db_redis"],
            path: "tests/check"
        ),
    ]
)
