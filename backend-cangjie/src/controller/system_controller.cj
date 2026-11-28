package hrms_backend.controller

import std.collection.*
import stdx.net.http.*
import hrms_backend.common.*
import hrms_backend.db.*
import hrms_backend.middleware.*
import hrms_backend.service.*

public func handleSystemUsers(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN"])) {
        case None => return
        case Some(_) =>
            let sql = """
SELECT u.id, u.username, u.role, IFNULL(u.employee_id, 0), IFNULL(e.name, ''),
       IFNULL(e.emp_no, ''), IFNULL(d.dept_name, ''), u.is_active,
       IFNULL(DATE_FORMAT(u.last_login_at, '%Y-%m-%d %H:%i:%s'), ''),
       DATE_FORMAT(u.created_at, '%Y-%m-%d %H:%i:%s')
FROM sys_user u
LEFT JOIN hr_employee e ON u.employee_id = e.id
LEFT JOIN hr_department d ON e.dept_id = d.id
ORDER BY u.id ASC
"""
            let rows = queryRows(sql)
            let list = ArrayList<String>()
            for (r in rows) {
                let obj = "{" +
                    "\"id\":${r[0]}," +
                    "\"username\":${jsonStr(r[1])}," +
                    "\"role\":${jsonStr(r[2])}," +
                    "\"employeeId\":${r[3]}," +
                    "\"empName\":${jsonStr(r[4])}," +
                    "\"empNo\":${jsonStr(r[5])}," +
                    "\"deptName\":${jsonStr(r[6])}," +
                    "\"isActive\":${r[7] == "1"}," +
                    "\"lastLoginAt\":${jsonStr(r[8])}," +
                    "\"createdAt\":${jsonStr(r[9])}" +
                "}"
                list.add(obj)
            }
            sendOk(ctx, "[" + String.join(list.toArray(), delimiter: ",") + "]")
    }
}

public func handleSystemUserUpdate(ctx: HttpContext, targetUserId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN"])) {
        case None => return
        case Some(u) =>
            let targetUsername = querySingleValue("SELECT username FROM sys_user WHERE id = ${targetUserId}")
            if (targetUsername.isEmpty()) {
                sendErr(ctx, 404, 404, "账号不存在")
                return
            }
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let role = getJsonStr(obj, "role", "").trimAscii()
                    let resetPwd = getJsonBool(obj, "resetPassword", false)
                    let sets = ArrayList<String>()
                    if (hasJsonKey(obj, "role") && !role.isEmpty()) {
                        let allowedRoles = ["ADMIN", "HR", "MANAGER", "EMPLOYEE"]
                        var roleOk = false
                        for (r in allowedRoles) {
                            if (role == r) { roleOk = true }
                        }
                        if (!roleOk) {
                            sendErr(ctx, 400, 400, "角色取值非法（仅支持 ADMIN/HR/MANAGER/EMPLOYEE）")
                            return
                        }
                        sets.add("role=${sqlStr(role)}")
                    }
                    // 只有请求体里显式带了 isActive 才改启用状态：
                    // 「重置密码」这类操作不该顺手把已停用（如离职）账号重新启用。
                    var activeDesc = "未变更"
                    if (hasJsonKey(obj, "isActive")) {
                        let isActive = getJsonBool(obj, "isActive", true)
                        if (!isActive && targetUserId == u.userId) {
                            sendErr(ctx, 400, 400, "不能停用当前登录的账号")
                            return
                        }
                        let activeVal = if (isActive) { 1 } else { 0 }
                        sets.add("is_active=${activeVal}")
                        activeDesc = "${activeVal}"
                    }
                    if (resetPwd) {
                        sets.add("password_hash=${sqlStr(hashPassword("123456"))}")
                    }
                    if (sets.size == 0) {
                        sendErr(ctx, 400, 400, "请求体中没有需要更新的字段")
                        return
                    }
                    let sql = "UPDATE sys_user SET " + String.join(sets.toArray(), delimiter: ", ") + " WHERE id=${targetUserId}"
                    if (!executeSql(sql)) {
                        sendErr(ctx, 500, 500, "账号更新失败")
                        return
                    }
                    writeAuditLog(u, "系统管理", "更新账号权限", "更新账号 ${targetUsername} (ID=${targetUserId})：role=${role}, isActive=${activeDesc}, resetPwd=${resetPwd}")
                    sendOk(ctx, "null")
            }
    }
}

public func handleSystemAuditLogs(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN"])) {
        case None => return
        case Some(_) =>
            let module = getQueryStr(ctx, "module", "").trimAscii()
            let keyword = getQueryStr(ctx, "keyword", "").trimAscii()
            var page = getQueryInt(ctx, "page", 1)
            var pageSize = getQueryInt(ctx, "pageSize", 15)
            if (page < 1) { page = 1 }
            if (pageSize < 1 || pageSize > 100) { pageSize = 15 }

            let conds = ArrayList<String>()
            conds.add("1=1")
            if (!module.isEmpty()) {
                conds.add("module = ${sqlStr(module)}")
            }
            if (!keyword.isEmpty()) {
                let kw = sqlStr("%" + keyword + "%")
                conds.add("(username LIKE ${kw} OR action LIKE ${kw} OR detail LIKE ${kw})")
            }
            let whereSql = "WHERE " + String.join(conds.toArray(), delimiter: " AND ")
            let total = querySingleInt("SELECT COUNT(*) FROM sys_audit_log ${whereSql}", 0)
            let offset = (page - 1) * pageSize
            let sql = """
SELECT id, IFNULL(user_id, 0), IFNULL(username, ''), module, action, IFNULL(detail, ''),
       DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s')
FROM sys_audit_log
${whereSql}
ORDER BY id DESC
LIMIT ${pageSize} OFFSET ${offset}
"""
            let rows = queryRows(sql)
            let list = ArrayList<String>()
            for (r in rows) {
                let obj = "{" +
                    "\"id\":${r[0]}," +
                    "\"userId\":${r[1]}," +
                    "\"username\":${jsonStr(r[2])}," +
                    "\"module\":${jsonStr(r[3])}," +
                    "\"action\":${jsonStr(r[4])}," +
                    "\"detail\":${jsonStr(r[5])}," +
                    "\"createdAt\":${jsonStr(r[6])}" +
                "}"
                list.add(obj)
            }
            sendPage(ctx, "[" + String.join(list.toArray(), delimiter: ",") + "]", total, page, pageSize)
    }
}
