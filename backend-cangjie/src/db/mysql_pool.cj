package hrms_backend.db

import std.collection.*
import std.convert.*
import std.fs.*
import std.process.*
import std.sync.*
import hrms_backend.config.*

let queryCounter = AtomicInt64(0)

public func ensureTempDir(): Unit {
    try {
        if (!exists(globalConfig.tempDir)) {
            Directory.create(globalConfig.tempDir, recursive: true)
        }
    } catch (_: Exception) {
    }
}

public func sqlEscape(raw: String): String {
    var out = raw.replace("\\", "\\\\")
    out = out.replace("'", "\\'")
    out = out.replace("\r", "\\r")
    out = out.replace("\n", "\\n")
    return out
}

public func sqlStr(raw: String): String {
    return "'" + sqlEscape(raw) + "'"
}

public func sqlNullableStr(raw: String): String {
    let trimmed = raw.trimAscii()
    if (trimmed.isEmpty()) {
        return "NULL"
    }
    return sqlStr(trimmed)
}

func runMysqlFile(sql: String): (Int64, String, String) {
    ensureTempDir()
    let seq = queryCounter.fetchAdd(1)
    let filePath = "${globalConfig.tempDir}\\q_${seq}.sql"
    let fullSql = "SET NAMES utf8mb4;\n" + sql + "\n"
    try {
        File.writeTo(filePath, fullSql.toArray())
        let unixPath = filePath.replace("\\", "/")
        let args = [
            "-h", globalConfig.dbHost,
            "-P", globalConfig.dbPort,
            "-u", globalConfig.dbUser,
            "-p${globalConfig.dbPass}",
            "-D", globalConfig.dbName,
            "--default-character-set=utf8mb4",
            "--batch",
            "--raw",
            "-N",
            "-e", "SOURCE ${unixPath}"
        ]
        let (code, outBytes, errBytes) = executeWithOutput(globalConfig.mysqlExe, args)
        let outStr = String.fromUtf8(outBytes)
        let errStr = String.fromUtf8(errBytes)
        return (code, outStr, errStr)
    } finally {
        try {
            if (exists(filePath)) {
                remove(filePath)
            }
        } catch (_: Exception) {
        }
    }
}

func unescapeField(raw: String): String {
    if (raw == "\\N") {
        return ""
    }
    return raw
}

public func queryRows(sql: String): ArrayList<ArrayList<String>> {
    let rows = ArrayList<ArrayList<String>>()
    let (code, outStr, errStr) = runMysqlFile(sql)
    if (code != 0) {
        println("SQL Error (${code}): ${errStr}")
        return rows
    }
    let lines = outStr.split("\n")
    for (rawLine in lines) {
        let line = rawLine.replace("\r", "")
        if (line.isEmpty()) {
            continue
        }
        let cols = line.split("\t")
        let row = ArrayList<String>()
        for (c in cols) {
            row.add(unescapeField(c))
        }
        rows.add(row)
    }
    return rows
}

public func querySingleValue(sql: String): String {
    let rows = queryRows(sql)
    if (rows.size == 0) {
        return ""
    }
    let row = rows[0]
    if (row.size == 0) {
        return ""
    }
    return row[0]
}

public func querySingleInt(sql: String, defaultVal: Int64): Int64 {
    let v = querySingleValue(sql).trimAscii()
    if (v.isEmpty()) {
        return defaultVal
    }
    return Int64.tryParse(v) ?? defaultVal
}

public func executeSql(sql: String): Bool {
    let (code, _, errStr) = runMysqlFile(sql)
    if (code != 0) {
        println("SQL Exec Error (${code}): ${errStr}")
        return false
    }
    return true
}

public func insertAndGetId(insertSql: String): Int64 {
    let combined = insertSql + ";\nSELECT LAST_INSERT_ID();"
    let (code, outStr, errStr) = runMysqlFile(combined)
    if (code != 0) {
        println("SQL Insert Error (${code}): ${errStr}")
        return 0
    }
    let lines = outStr.split("\n")
    var lastVal: Int64 = 0
    for (rawLine in lines) {
        let s = rawLine.replace("\r", "").trimAscii()
        if (!s.isEmpty()) {
            if (let Some(n) <- Int64.tryParse(s)) {
                lastVal = n
            }
        }
    }
    return lastVal
}
