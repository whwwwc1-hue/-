package hrms_backend.config

import std.env.*
import std.fs.*
import std.convert.*

// 内置示例密钥，仅用于开发演示；线上必须通过 JWT_SECRET 覆盖
let DEFAULT_JWT_SECRET = "hrms_cangjie_jwt_secret_key_2026"

public class AppConfig {
    public var dbHost: String = "127.0.0.1"
    public var dbPort: String = "3306"
    public var dbUser: String = "root"
    public var dbPass: String = "root"
    public var dbName: String = "hrms_db"
    public var jwtSecret: String = DEFAULT_JWT_SECRET
    public var serverPort: UInt16 = 8080

    // mysql.exe 路径：MYSQL_EXE 优先，缺省在 PATH 中自动探测，不再硬编码安装目录
    public var mysqlExe: String = "mysql.exe"

    // 临时 SQL 文件目录：TMP_SQL_DIR 优先，缺省使用系统临时目录，不再硬编码原作者机器路径
    public var tempDir: String = "tmp_sql"

    // 单条 SQL 子进程执行超时（秒），防止 MySQL 挂起导致请求线程无限阻塞
    public var dbTimeoutSec: Int64 = 10

    // 并发执行 SQL 的最大数量，避免瞬时请求把 mysql.exe 进程数打满
    public var dbMaxConcurrency: Int64 = 4

    // 是否仍在使用内置示例密钥
    public var jwtSecretIsDefault: Bool = true

    // 严格环境模式：为真时，密钥不合规直接拒绝启动
    public var strictEnv: Bool = false

    public init() {
        loadDotEnv(".env")
        this.dbHost = readEnvOrDefault("DB_HOST", this.dbHost)
        this.dbPort = readEnvOrDefault("DB_PORT", this.dbPort)
        this.dbUser = readEnvOrDefault("DB_USER", this.dbUser)
        this.dbPass = readEnvOrDefault("DB_PASS", this.dbPass)
        this.dbName = readEnvOrDefault("DB_NAME", this.dbName)
        this.jwtSecret = readEnvOrDefault("JWT_SECRET", this.jwtSecret)
        this.jwtSecretIsDefault = (this.jwtSecret == DEFAULT_JWT_SECRET)
        this.strictEnv = isTruthyEnv("STRICT_ENV")
        this.mysqlExe = resolveMysqlExe()
        this.tempDir = resolveTempDir()
        let timeoutStr = readEnvOrDefault("DB_TIMEOUT_SEC", "10")
        if (let Some(t) <- Int64.tryParse(timeoutStr)) {
            if (t > 0) {
                this.dbTimeoutSec = t
            }
        }
        let concurrencyStr = readEnvOrDefault("DB_MAX_CONCURRENCY", "4")
        if (let Some(c) <- Int64.tryParse(concurrencyStr)) {
            if (c > 0) {
                this.dbMaxConcurrency = c
            }
        }
        let portStr = readEnvOrDefault("SERVER_PORT", "8080")
        if (let Some(p) <- UInt16.tryParse(portStr)) {
            this.serverPort = p
        }
    }

    // TMP_SQL_DIR -> TEMP -> TMP -> 相对目录，保证任何机器上都能拿到可写目录
    private func resolveTempDir(): String {
        let explicit = readEnvOrDefault("TMP_SQL_DIR", "")
        if (!explicit.isEmpty()) {
            return normalizeDir(explicit)
        }
        let sysTemp = readEnvOrDefault("TEMP", "")
        if (!sysTemp.isEmpty()) {
            return normalizeDir(sysTemp)
        }
        let altTemp = readEnvOrDefault("TMP", "")
        if (!altTemp.isEmpty()) {
            return normalizeDir(altTemp)
        }
        return "tmp_sql"
    }

    // MYSQL_EXE 未配置时在 PATH 中逐个目录探测 mysql.exe
    private func resolveMysqlExe(): String {
        let explicit = readEnvOrDefault("MYSQL_EXE", "")
        if (!explicit.isEmpty()) {
            return explicit
        }
        let pathVar = readEnvOrDefault("PATH", "")
        for (rawDir in pathVar.split(";")) {
            let dir = rawDir.trimAscii()
            if (dir.isEmpty()) {
                continue
            }
            let candidate = "${dir}\\mysql.exe"
            try {
                if (exists(candidate)) {
                    return candidate
                }
            } catch (_: Exception) {
            }
        }
        return "mysql.exe"
    }

    private func normalizeDir(dir: String): String {
        let trimmed = dir.trimAscii()
        if (trimmed.endsWith("\\")) {
            return trimmed[..(trimmed.size - 1)]
        }
        return trimmed
    }

    private func isTruthyEnv(key: String): Bool {
        let v = readEnvOrDefault(key, "").trimAscii().toAsciiLower()
        return (v == "1" || v == "true" || v == "yes")
    }

    private func readEnvOrDefault(key: String, def: String): String {
        match (getVariable(key)) {
            case Some(v) =>
                let trimmed = v.trimAscii()
                if (trimmed.isEmpty()) { def } else { trimmed }
            case None => def
        }
    }

    private func loadDotEnv(path: String): Unit {
        try {
            if (!exists(path)) {
                return
            }
            let bytes = File.readFrom(path)
            let content = String.fromUtf8(bytes)
            let lines = content.split("\n")
            for (rawLine in lines) {
                let line = rawLine.trimAscii()
                if (line.isEmpty() || line.startsWith("#")) {
                    continue
                }
                if (let Some(idx) <- line.indexOf("=")) {
                    let k = line[..idx].trimAscii()
                    let v = line[(idx + 1)..].trimAscii()
                    if (!k.isEmpty()) {
                        match (getVariable(k)) {
                            case None => setVariable(k, v)
                            case Some(cur) =>
                                if (cur.isEmpty()) {
                                    setVariable(k, v)
                                }
                        }
                    }
                }
            }
        } catch (_: Exception) {
        }
    }
}

public let globalConfig = AppConfig()
