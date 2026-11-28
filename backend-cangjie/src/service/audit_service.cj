package hrms_backend.service

import hrms_backend.common.*
import hrms_backend.db.*

public func writeAuditLog(user: AuthUser, module: String, action: String, detail: String): Unit {
    let sql = "INSERT INTO sys_audit_log (user_id, username, module, action, detail) VALUES (${user.userId}, ${sqlStr(user.username)}, ${sqlStr(module)}, ${sqlStr(action)}, ${sqlStr(detail)})"
    // 审计日志是旁路能力：写日志失败不应把已经成功的业务操作变成 500，
    // 但必须在控制台留下痕迹，方便排查。
    try {
        executeSql(sql)
    } catch (e: Exception) {
        println("审计日志写入失败（不影响业务结果）：${e.message}")
    }
}

public func writeAuditLogRaw(userId: Int64, username: String, module: String, action: String, detail: String): Unit {
    let sql = "INSERT INTO sys_audit_log (user_id, username, module, action, detail) VALUES (${userId}, ${sqlStr(username)}, ${sqlStr(module)}, ${sqlStr(action)}, ${sqlStr(detail)})"
    try {
        executeSql(sql)
    } catch (e: Exception) {
        println("审计日志写入失败（不影响业务结果）：${e.message}")
    }
}
