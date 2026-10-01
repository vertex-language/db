# db/sql

Common SQL interfaces, dynamic `Value` types, row cursors, and error abstractions.

```vertex
import "db/sql"
```

## Types

- **`Row`** (struct): Row represents a single record of column values.
- **`Rows`** (class): Rows provides cursor iteration over query results.
- **`Result`** (struct): Result contains execution metadata (rows affected, last insert ID).
- **`DbError`** (enum): DbError represents errors encountered during database operations.
- **`Value`** (enum): Value represents a dynamically typed SQL value.

Part of the [`db`](https://github.com/vertex-language/db) repository.
