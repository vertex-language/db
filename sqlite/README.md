# db/sqlite

Embedded file-based SQL database engine supporting `:memory:` and disk persistence.

## Example

```vertex
import "db/sqlite"

let db = try sqlite.Database.open()
try db.exec("CREATE TABLE users (name TEXT)")
try db.exec("INSERT INTO users VALUES ('Ada')")
let rows = try db.query("SELECT name FROM users")
```

## Types

- **`Database`** (class)
- **`Engine`** (class)
- **`Expr`** (class)
- **`Statement`** (enum)
- **`SelectColumn`** (enum)
- **`Parser`** (class)
- **`DataType`** (enum)
- **`Column`** (struct)
- **`Table`** (class)

## Functions

- `func evaluateExpr( _ expr: Expr, row: [sql.Value], table: Table?, params: [sql.Value] ) throws -> sql.Value`
- `func valuesEqual(_ a: sql.Value, _ b: sql.Value) -> bool`
- `func compareValues(_ a: sql.Value, _ b: sql.Value) -> int`

Part of the [`db`](https://github.com/vertex-language/db) repository.
