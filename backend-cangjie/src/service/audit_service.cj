package hrms_backend.service

import hrms_backend.common.*
import hrms_backend.db.*

public func writeAuditLog(user: AuthUser, module: String, action: String, detail: String): Unit {
    let sql = "INSERT INTO sys_audit_log (user_id, username, module, action, detail) VALUES (${user.userId}, ${sqlStr(user.username)}, ${sqlStr(module)}, ${sqlStr(action)}, ${sqlStr(detail)})"
    executeSql(sql)
}

public func writeAuditLogRaw(userId: Int64, username: String, module: String, action: String, detail: String): Unit {
    let sql = "INSERT INTO sys_audit_log (user_id, username, module, action, detail) VALUES (${userId}, ${sqlStr(username)}, ${sqlStr(module)}, ${sqlStr(action)}, ${sqlStr(detail)})"
    executeSql(sql)
}
