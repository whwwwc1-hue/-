package hrms_backend.config

import std.env.*
import std.fs.*
import std.convert.*

public class AppConfig {
    public var dbHost: String = "127.0.0.1"
    public var dbPort: String = "3306"
    public var dbUser: String = "root"
    public var dbPass: String = "root"
    public var dbName: String = "hrms_db"
    public var jwtSecret: String = "hrms_cangjie_jwt_secret_key_2026"
    public var serverPort: UInt16 = 8080
    public var mysqlExe: String = "C:\\Program Files\\MySQL\\MySQL Server 8.0\\bin\\mysql.exe"
    public var tempDir: String = "E:\\homework\\hrms-cangjie\\backend-cangjie\\tmp_sql"

    public init() {
        loadDotEnv(".env")
        this.dbHost = readEnvOrDefault("DB_HOST", this.dbHost)
        this.dbPort = readEnvOrDefault("DB_PORT", this.dbPort)
        this.dbUser = readEnvOrDefault("DB_USER", this.dbUser)
        this.dbPass = readEnvOrDefault("DB_PASS", this.dbPass)
        this.dbName = readEnvOrDefault("DB_NAME", this.dbName)
        this.jwtSecret = readEnvOrDefault("JWT_SECRET", this.jwtSecret)
        this.mysqlExe = readEnvOrDefault("MYSQL_EXE", this.mysqlExe)
        let portStr = readEnvOrDefault("SERVER_PORT", "8080")
        if (let Some(p) <- UInt16.tryParse(portStr)) {
            this.serverPort = p
        }
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
