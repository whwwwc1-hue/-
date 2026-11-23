package hrms_backend.db

import std.collection.*
import std.convert.*
import std.fs.*
import std.process.*
import std.sync.*
import hrms_backend.config.*

// =============================================================================
// 数据访问层（P0.1 渐进加固版）
//
// 设计约束：对外签名与重构前完全一致
//   queryRows / querySingleValue / querySingleInt / executeSql / insertAndGetId
//   ensureTempDir / sqlEscape / sqlStr / sqlNullableStr
// 因此五个 controller 目录零改动，风险被限制在本文件内。
//
// 本次加固的六件事：
//   D1 密码不再出现在进程命令行（改用一次性 --defaults-extra-file 配置），
//      避免任何本机进程通过任务列表 / 进程快照读到 root 密码。
//   D2 去掉 --raw：--raw 会关闭 mysql 批量模式的转义编码，导致 NULL 被输出成
//      字面量 "NULL"、字段内容里的制表符/换行直接破坏行列切分。现在按官方编码
//      （\N、\\、\t、\n、\r、\0、\Z）逐字段反向还原。
//   D3 SQL 错误不再被 println 吞掉后返回空集：查询与自增主键失败直接抛出，
//      由 main.cj 的 dispatchRequest 统一转成 500，杜绝「200 + 空数据」假成功。
//   D4 子进程串行闸门 + 每次调用唯一文件名，消除并发请求互相覆盖临时 SQL 的隐患。
//   D5 结果集列数一致性校验，避免控制器按下标取值时因脏行越界崩溃。
//   D6 非 ASCII 临时目录预检：mysql.exe 的 SOURCE 打不开含中文的路径，
//      以前表现为「表数据凭空为空」，现在直接给出可操作的报错。
//   D7 暴露 lastDbError / dbStats / dbPing，供 P0.2 健康检查与线上排障使用。
//
// 注意：这里不做「连接池」。当前实现每条 SQL 起一个 mysql.exe 子进程，
// 真正的连接复用需要官方驱动或自研 TCP 协议层，属于独立里程碑（见 FOLLOWUP_PLAN）。
// =============================================================================

let ASCII_UPPER: UInt8 = 127

let B_BACKSLASH: UInt8 = 0x5C
let B_LETTER_T: UInt8 = 0x74
let B_LETTER_N: UInt8 = 0x6E
let B_LETTER_R: UInt8 = 0x72
let B_LETTER_Z: UInt8 = 0x5A
let B_DIGIT_ZERO: UInt8 = 0x30
let B_TAB: UInt8 = 0x09
let B_LF: UInt8 = 0x0A
let B_CR: UInt8 = 0x0D
let B_NUL: UInt8 = 0x00
let B_SUB: UInt8 = 0x1A

// 诊断信息只在 dbGate 闸内写入，读取时单独加锁，保证跨线程可见且不会撕裂
class DbDiagnostics {
    public var lastError: String = ""
    public var lastCode: Int64 = 0
    public var totalCount: Int64 = 0
    public var errorCount: Int64 = 0
}

let dbDiag = DbDiagnostics()
let diagGate = ReentrantMutex()
let queryCounter = AtomicInt64(0)
// 子进程串行闸门：并发度固定为 1，防止临时文件互踩与连接风暴
let dbGate = ReentrantMutex()

func recordDiag(code: Int64, err: String): Unit {
    diagGate.lock()
    dbDiag.totalCount = dbDiag.totalCount + 1
    if (code != 0) {
        dbDiag.errorCount = dbDiag.errorCount + 1
        dbDiag.lastCode = code
        dbDiag.lastError = err
    }
    diagGate.unlock()
}

// 最近一次 SQL 失败的 stderr（空串表示没有失败记录）
public func lastDbError(): String {
    diagGate.lock()
    let e = dbDiag.lastError
    diagGate.unlock()
    return e
}

// 最近一次失败的单行摘要，适合直接放进响应体 / 日志
public func lastDbErrorMessage(): String {
    return firstMeaningfulLine(lastDbError())
}

// (累计执行次数, 累计失败次数)
public func dbStats(): (Int64, Int64) {
    diagGate.lock()
    let total = dbDiag.totalCount
    let failed = dbDiag.errorCount
    diagGate.unlock()
    return (total, failed)
}

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

func containsNonAscii(text: String): Bool {
    var found = false
    for (b in text.toArray()) {
        if (b > ASCII_UPPER) {
            found = true
        }
    }
    return found
}

// SOURCE 走的是 mysql.exe 内部的 fopen，中文路径会得到 error: 2（文件不存在）
func assertTempDirUsable(): Unit {
    if (containsNonAscii(globalConfig.tempDir)) {
        throw Exception("临时 SQL 目录 \"${globalConfig.tempDir}\" 含非 ASCII 字符，mysql.exe 的 SOURCE 无法打开，请把 TMP_SQL_DIR 设置为纯英文可写目录")
    }
}

func removeQuiet(path: String): Unit {
    try {
        if (exists(path)) {
            remove(path)
        }
    } catch (_: Exception) {
    }
}

// my.ini 值语法：双引号包裹，内部的双引号与反斜杠需要转义
func iniValue(raw: String): String {
    var out = raw.replace("\\", "\\\\")
    out = out.replace("\"", "\\\"")
    return out
}

func buildClientCnf(): String {
    var content = "[client]\n"
    content = content + "host=${globalConfig.dbHost}\n"
    content = content + "port=${globalConfig.dbPort}\n"
    content = content + "user=${globalConfig.dbUser}\n"
    content = content + "password=\"${iniValue(globalConfig.dbPass)}\"\n"
    content = content + "default-character-set=utf8mb4\n"
    return content
}

// 执行一段 SQL，返回 (退出码, stdout, stderr)；进程创建失败等异常直接向上抛出
func runMysqlFile(sql: String): (Int64, String, String) {
    ensureTempDir()
    assertTempDirUsable()
    let seq = queryCounter.fetchAdd(1)
    let dir = globalConfig.tempDir
    let sqlPath = "${dir}\\q_${seq}.sql"
    let cnfPath = "${dir}\\c_${seq}.cnf"
    let fullSql = "SET NAMES utf8mb4;\n" + sql + "\n"
    dbGate.lock()
    try {
        File.writeTo(cnfPath, buildClientCnf().toArray())
        File.writeTo(sqlPath, fullSql.toArray())
        let unixSqlPath = sqlPath.replace("\\", "/")
        // --defaults-extra-file 必须是第一个参数，否则会被后续全局配置覆盖
        let args = [
            "--defaults-extra-file=${cnfPath}",
            "-D", globalConfig.dbName,
            "--connect-timeout=${globalConfig.dbTimeoutSec}",
            "--batch",
            "-N",
            "-e", "SOURCE ${unixSqlPath}"
        ]
        let (code, outBytes, errBytes) = executeWithOutput(globalConfig.mysqlExe, args)
        let outStr = String.fromUtf8(outBytes)
        let errStr = String.fromUtf8(errBytes)
        recordDiag(code, errStr)
        return (code, outStr, errStr)
    } finally {
        removeQuiet(cnfPath)
        removeQuiet(sqlPath)
        dbGate.unlock()
    }
}

// stderr 里第一条非空信息，通常是 "ERROR 1045 (28000): Access denied ..."
public func firstMeaningfulLine(text: String): String {
    let lines = text.replace("\r\n", "\n").split("\n")
    for (rawLine in lines) {
        let line = rawLine.trimAscii()
        if (!line.isEmpty()) {
            return line
        }
    }
    return ""
}

// 去掉输出末尾因换行产生的空元素，返回有效行数
func effectiveLineCount(lines: Array<String>): Int64 {
    var count = lines.size
    while (count > 0 && lines[count - 1].isEmpty()) {
        count = count - 1
    }
    return count
}

// mysql 批量模式（未加 --raw）的字段反转义
func unescapeField(raw: String): String {
    if (raw == "\\N") {
        return ""
    }
    let bytes = raw.toArray()
    let total = bytes.size
    var needUnescape = false
    for (b in bytes) {
        if (b == B_BACKSLASH) {
            needUnescape = true
        }
    }
    if (!needUnescape) {
        return raw
    }
    let out = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < total) {
        let b = bytes[i]
        if (b != B_BACKSLASH || i + 1 >= total) {
            out.add(b)
            i = i + 1
        } else {
            let n = bytes[i + 1]
            if (n == B_BACKSLASH) {
                out.add(B_BACKSLASH)
            } else if (n == B_LETTER_T) {
                out.add(B_TAB)
            } else if (n == B_LETTER_N) {
                out.add(B_LF)
            } else if (n == B_LETTER_R) {
                out.add(B_CR)
            } else if (n == B_DIGIT_ZERO) {
                out.add(B_NUL)
            } else if (n == B_LETTER_Z) {
                out.add(B_SUB)
            } else {
                // 未知转义序列保持原样，交由上层判断，不做有损猜测
                out.add(b)
                out.add(n)
            }
            i = i + 2
        }
    }
    return String.fromUtf8(out.toArray())
}

public func queryRows(sql: String): ArrayList<ArrayList<String>> {
    let rows = ArrayList<ArrayList<String>>()
    let (code, outStr, errStr) = runMysqlFile(sql)
    if (code != 0) {
        throw Exception("查询执行失败(exit=${code}): ${firstMeaningfulLine(errStr)}")
    }
    let lines = outStr.replace("\r\n", "\n").split("\n")
    let count = effectiveLineCount(lines)
    var expectedCols: Int64 = -1
    var i: Int64 = 0
    while (i < count) {
        let cols = lines[i].split("\t")
        if (expectedCols < 0) {
            expectedCols = cols.size
        } else if (cols.size != expectedCols) {
            throw Exception("结果集列数不一致（期望 ${expectedCols} 列，实际 ${cols.size} 列），第 ${i} 行内容异常: ${lines[i]}")
        }
        let row = ArrayList<String>()
        for (c in cols) {
            row.add(unescapeField(c))
        }
        rows.add(row)
        i = i + 1
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

// 更新/删除类语句：保持「返回 Bool」的历史契约，调用方自行决定是否中止
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
        // 这里绝不能返回 0：控制器会把它当作「失败」，但 INSERT 可能已经落库，
        // 于是产生没有后续关联记录的脏数据
        throw Exception("写入执行失败(exit=${code}): ${firstMeaningfulLine(errStr)}")
    }
    let lines = outStr.replace("\r\n", "\n").split("\n")
    let count = effectiveLineCount(lines)
    if (count == 0) {
        return 0
    }
    let lastLine = lines[count - 1].trimAscii()
    var value: Int64 = 0
    match (Int64.tryParse(lastLine)) {
        case Some(n) => value = n
        case None => throw Exception("无法解析自增主键，返回内容为: ${lastLine}")
    }
    return value
}

// 供 /health 使用：不抛异常，返回 (是否可用, 版本/库名 或 错误摘要)
public func dbPing(): (Bool, String) {
    try {
        let rows = queryRows("SELECT VERSION(), DATABASE()")
        if (rows.size > 0 && rows[0].size >= 2) {
            let version = rows[0][0]
            let dbName = rows[0][1]
            return (true, "${version}@${dbName}")
        }
        return (true, "")
    } catch (e: Exception) {
        return (false, e.message)
    }
}
