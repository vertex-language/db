package sqlite

import "db/sql"

public class Engine {
    public static func execute(
        _ stmt: Statement,
        db: Database,
        params: [sql.Value]
    ) throws -> (result: sql.Result?, rows: sql.Rows?) {
        switch stmt {
        case .createTable(let name, let ifNotExists, let columns):
            let lowerName = name.lowercased()
            if db.tables[lowerName] != nil {
                if ifNotExists {
                    return (sql.Result(rowsAffected: 0), nil)
                }
                throw sql.DbError.queryFailed("table '\(name)' already exists")
            }
            let t = Table(name: name, columns: columns)
            db.tables[lowerName] = t
            try db.save()
            return (sql.Result(rowsAffected: 0), nil)

        case .dropTable(let name, let ifExists):
            let lowerName = name.lowercased()
            if db.tables[lowerName] == nil {
                if ifExists {
                    return (sql.Result(rowsAffected: 0), nil)
                }
                throw sql.DbError.tableNotFound(name)
            }
            db.tables[lowerName] = nil
            try db.save()
            return (sql.Result(rowsAffected: 0), nil)

        case .insert(let tableName, let colNames, let valueRows):
            guard let table = db.getTable(tableName) else {
                throw sql.DbError.tableNotFound(tableName)
            }

            var lastId: int64 = 0
            var affected: int64 = 0

            for vRow in valueRows {
                var rowData: [sql.Value] = []

                if colNames.isEmpty {
                    // Positional mapping
                    var c = 0
                    while c < table.columns.count {
                        if c < vRow.count {
                            let evaluated = try evaluateExpr(vRow[c], row: [], table: nil, params: params)
                            rowData.append(evaluated)
                        } else if let def = table.columns[c].defaultValue {
                            rowData.append(def)
                        } else {
                            rowData.append(.null)
                        }
                        c += 1
                    }
                } else {
                    // Named mapping
                    var c = 0
                    while c < table.columns.count {
                        let col = table.columns[c]
                        var foundIdx: int? = nil
                        var ci = 0
                        while ci < colNames.count {
                            if colNames[ci].lowercased() == col.name.lowercased() {
                                foundIdx = ci
                                break
                            }
                            ci += 1
                        }

                        if let fi = foundIdx, fi < vRow.count {
                            let evaluated = try evaluateExpr(vRow[fi], row: [], table: nil, params: params)
                            rowData.append(evaluated)
                        } else if let def = col.defaultValue {
                            rowData.append(def)
                        } else {
                            rowData.append(.null)
                        }
                        c += 1
                    }
                }

                // Handle primary key auto-increment
                if let pkIdx = table.primaryKeyColIndex {
                    let curVal = rowData[pkIdx]
                    if curVal.isNull || (curVal.asInt() ?? 0) <= 0 {
                        table.autoIncCounter += 1
                        rowData[pkIdx] = .integer(table.autoIncCounter)
                        lastId = table.autoIncCounter
                    } else if let idVal = curVal.asInt() {
                        if idVal > table.autoIncCounter {
                            table.autoIncCounter = idVal
                        }
                        lastId = idVal
                    }
                }

                table.rows.append(rowData)
                affected += 1
            }

            try db.save()
            return (sql.Result(rowsAffected: affected, lastInsertId: lastId), nil)

        case .select(let distinct, let columns, let tableName, let whereExpr, let orderBy, let limit, let offset):
            guard let table = db.getTable(tableName) else {
                throw sql.DbError.tableNotFound(tableName)
            }

            // 1. Filter rows matching WHERE clause
            var matchedRows: [[sql.Value]] = []
            for r in table.rows {
                if let w = whereExpr {
                    let condVal = try evaluateExpr(w, row: r, table: table, params: params)
                    if condVal.asBool() != true {
                        continue
                    }
                }
                matchedRows.append(r)
            }

            // Check if this is an aggregate query: COUNT, SUM, AVG, MIN, MAX
            var isAggregate = false
            for c in columns {
                switch c {
                case .countAll, .count, .sum, .avg, .min, .max:
                    isAggregate = true
                default:
                    break
                }
            }

            if isAggregate {
                return (nil, try executeAggregate(columns, matchedRows: matchedRows, table: table))
            }

            // 2. Sorting
            if let ord = orderBy {
                if let ordColIdx = table.columnIndex(ord.column) {
                    matchedRows = sortRows(matchedRows, colIdx: ordColIdx, desc: ord.desc)
                }
            }

            // 3. Offset and Limit
            var finalRawRows: [[sql.Value]] = []
            var start = offset ?? 0
            if start < 0 { start = 0 }
            var count = 0

            var ri = start
            while ri < matchedRows.count {
                if let lim = limit {
                    if count >= lim { break }
                }
                finalRawRows.append(matchedRows[ri])
                count += 1
                ri += 1
            }

            // 4. Projection
            var resultColNames: [string] = []
            var resultProjectIdx: [int] = []

            for c in columns {
                switch c {
                case .all:
                    for tc in table.columns {
                        resultColNames.append(tc.name)
                        resultProjectIdx.append(table.columnIndex(tc.name)!)
                    }
                case .column(let name):
                    if let cIdx = table.columnIndex(name) {
                        resultColNames.append(table.columns[cIdx].name)
                        resultProjectIdx.append(cIdx)
                    } else {
                        throw sql.DbError.columnNotFound(name)
                    }
                default:
                    break
                }
            }

            var sqlRows: [sql.Row] = []
            for rawRow in finalRawRows {
                var vals: [sql.Value] = []
                for pIdx in resultProjectIdx {
                    vals.append(rawRow[pIdx])
                }

                if distinct {
                    var exists = false
                    for existing in sqlRows {
                        if rowsEqual(existing.values, vals) {
                            exists = true
                            break
                        }
                    }
                    if exists { continue }
                }

                sqlRows.append(sql.Row(columns: resultColNames, values: vals))
            }

            return (nil, sql.Rows(columns: resultColNames, records: sqlRows))

        case .update(let tableName, let assignments, let whereExpr):
            guard let table = db.getTable(tableName) else {
                throw sql.DbError.tableNotFound(tableName)
            }

            var affected: int64 = 0
            var i = 0
            while i < table.rows.count {
                var r = table.rows[i]
                var matches = true
                if let w = whereExpr {
                    let cond = try evaluateExpr(w, row: r, table: table, params: params)
                    matches = (cond.asBool() == true)
                }

                if matches {
                    for assign in assignments {
                        guard let colIdx = table.columnIndex(assign.column) else {
                            throw sql.DbError.columnNotFound(assign.column)
                        }
                        let newVal = try evaluateExpr(assign.value, row: r, table: table, params: params)
                        r[colIdx] = newVal
                    }
                    table.rows[i] = r
                    affected += 1
                }
                i += 1
            }

            try db.save()
            return (sql.Result(rowsAffected: affected), nil)

        case .delete(let tableName, let whereExpr):
            guard let table = db.getTable(tableName) else {
                throw sql.DbError.tableNotFound(tableName)
            }

            var remaining: [[sql.Value]] = []
            var affected: int64 = 0

            for r in table.rows {
                var matches = true
                if let w = whereExpr {
                    let cond = try evaluateExpr(w, row: r, table: table, params: params)
                    matches = (cond.asBool() == true)
                }

                if matches {
                    affected += 1
                } else {
                    remaining.append(r)
                }
            }

            table.rows = remaining
            try db.save()
            return (sql.Result(rowsAffected: affected), nil)

        case .begin:
            try db.beginTransaction()
            return (sql.Result(rowsAffected: 0), nil)

        case .commit:
            try db.commitTransaction()
            return (sql.Result(rowsAffected: 0), nil)

        case .rollback:
            try db.rollbackTransaction()
            return (sql.Result(rowsAffected: 0), nil)
        }
    }

    static func executeAggregate(
        _ columns: [SelectColumn],
        matchedRows: [[sql.Value]],
        table: Table
    ) throws -> sql.Rows {
        var colNames: [string] = []
        var vals: [sql.Value] = []

        for c in columns {
            colNames.append(c.alias)
            switch c {
            case .countAll:
                vals.append(.integer(int64(matchedRows.count)))

            case .count(let colName):
                guard let idx = table.columnIndex(colName) else {
                    throw sql.DbError.columnNotFound(colName)
                }
                var cnt: int64 = 0
                for r in matchedRows {
                    if !r[idx].isNull { cnt += 1 }
                }
                vals.append(.integer(cnt))

            case .sum(let colName):
                guard let idx = table.columnIndex(colName) else {
                    throw sql.DbError.columnNotFound(colName)
                }
                var sumF: float64 = 0.0
                var hasVal = false
                for r in matchedRows {
                    if let f = r[idx].asFloat() {
                        sumF += f
                        hasVal = true
                    }
                }
                vals.append(hasVal ? .real(sumF) : .null)

            case .avg(let colName):
                guard let idx = table.columnIndex(colName) else {
                    throw sql.DbError.columnNotFound(colName)
                }
                var sumF: float64 = 0.0
                var cnt = 0
                for r in matchedRows {
                    if let f = r[idx].asFloat() {
                        sumF += f
                        cnt += 1
                    }
                }
                vals.append(cnt > 0 ? .real(sumF / float64(cnt)) : .null)

            case .min(let colName):
                guard let idx = table.columnIndex(colName) else {
                    throw sql.DbError.columnNotFound(colName)
                }
                var minVal: sql.Value = .null
                for r in matchedRows {
                    let v = r[idx]
                    if v.isNull { continue }
                    if minVal.isNull || compareValues(v, minVal) < 0 {
                        minVal = v
                    }
                }
                vals.append(minVal)

            case .max(let colName):
                guard let idx = table.columnIndex(colName) else {
                    throw sql.DbError.columnNotFound(colName)
                }
                var maxVal: sql.Value = .null
                for r in matchedRows {
                    let v = r[idx]
                    if v.isNull { continue }
                    if maxVal.isNull || compareValues(v, maxVal) > 0 {
                        maxVal = v
                    }
                }
                vals.append(maxVal)

            default:
                vals.append(.null)
            }
        }

        let row = sql.Row(columns: colNames, values: vals)
        return sql.Rows(columns: colNames, records: [row])
    }
}

func rowsEqual(_ a: [sql.Value], _ b: [sql.Value]) -> bool {
    if a.count != b.count { return false }
    var i = 0
    while i < a.count {
        if !valuesEqual(a[i], b[i]) { return false }
        i += 1
    }
    return true
}

func sortRows(_ rows: [[sql.Value]], colIdx: int, desc: bool) -> [[sql.Value]] {
    var sorted = rows
    var i = 0
    while i < sorted.count {
        var j = i + 1
        while j < sorted.count {
            let cmp = compareValues(sorted[i][colIdx], sorted[j][colIdx])
            if desc ? (cmp < 0) : (cmp > 0) {
                let tmp = sorted[i]
                sorted[i] = sorted[j]
                sorted[j] = tmp
            }
            j += 1
        }
        i += 1
    }
    return sorted
}
