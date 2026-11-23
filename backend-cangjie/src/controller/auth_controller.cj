package hrms_backend.controller

import std.convert.*
import stdx.net.http.*
import hrms_backend.common.*
import hrms_backend.db.*
import hrms_backend.middleware.*
import hrms_backend.service.*

func buildUserProfileJson(userId: Int64): String {
    let sql = """
SELECT u.id, u.username, u.role, IFNULL(u.employee_id, 0), u.is_active,
       IFNULL(e.name, u.username), IFNULL(e.emp_no, ''), IFNULL(e.dept_id, 0),
       IFNULL(d.dept_name, ''), IFNULL(e.position_name, ''),
       IFNULL(e.phone, ''), IFNULL(e.email, ''), IFNULL(e.status, 'ACTIVE'),
       IFNULL(e.annual_leave_balance, 0.0), IFNULL(DATE_FORMAT(e.hire_date, '%Y-%m-%d'), ''),
       IFNULL(DATE_FORMAT(e.contract_end_date, '%Y-%m-%d'), ''), IFNULL(e.base_salary, 0.0)
FROM sys_user u
LEFT JOIN hr_employee e ON u.employee_id = e.id
LEFT JOIN hr_department d ON e.dept_id = d.id
WHERE u.id = ${userId}
LIMIT 1
"""
    let rows = queryRows(sql)
    if (rows.size == 0) {
        return "{}"
    }
    let r = rows[0]
    return "{" +
        "\"id\":${r[0]}," +
        "\"username\":${jsonStr(r[1])}," +
        "\"role\":${jsonStr(r[2])}," +
        "\"employeeId\":${r[3]}," +
        "\"isActive\":${r[4] == "1"}," +
        "\"name\":${jsonStr(r[5])}," +
        "\"empNo\":${jsonStr(r[6])}," +
        "\"deptId\":${r[7]}," +
        "\"deptName\":${jsonStr(r[8])}," +
        "\"positionName\":${jsonStr(r[9])}," +
        "\"phone\":${jsonStr(r[10])}," +
        "\"email\":${jsonStr(r[11])}," +
        "\"empStatus\":${jsonStr(r[12])}," +
        "\"annualLeaveBalance\":${r[13]}," +
        "\"hireDate\":${jsonStr(r[14])}," +
        "\"contractEndDate\":${jsonStr(r[15])}," +
        "\"baseSalary\":${r[16]}" +
    "}"
}

public func handleAuthLogin(ctx: HttpContext): Unit {
    let body = readRequestBody(ctx)
    match (parseJsonObject(body)) {
        case None =>
            sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
            return
        case Some(obj) =>
            let username = getJsonStr(obj, "username", "").trimAscii()
            let password = getJsonStr(obj, "password", "")
            if (username.isEmpty() || password.isEmpty()) {
                sendErr(ctx, 400, 400, "请输入账号和密码")
                return
            }
            // P0.3：失败限流。键 = 用户名 + 来源标识，避免同一账号被无限爆破。
            let tkey = loginThrottleKey(username, clientIp(ctx))
            let blocked = loginBlockedSeconds(tkey)
            if (blocked > 0) {
                writeAuditLogRaw(0, username, "系统认证", "登录被拒", "失败次数过多，${blocked} 秒内禁止重试")
                sendErr(ctx, 429, 429, "登录失败次数过多，请 ${blocked} 秒后重试")
                return
            }
            let rows = queryRows("SELECT id, username, password_hash, role, IFNULL(employee_id, 0), is_active FROM sys_user WHERE username = ${sqlStr(username)} LIMIT 1")
            if (rows.size == 0) {
                let remain = remainingAfterFailure(loginRemainingAttempts(tkey))
                recordLoginFailure(tkey)
                sendErr(ctx, 400, 400, "账号或密码错误（剩余尝试 ${remain} 次）")
                return
            }
            let r = rows[0]
            let uid = Int64.tryParse(r[0]) ?? 0
            let uname = r[1]
            let pwdHash = r[2]
            let role = r[3]
            let empId = Int64.tryParse(r[4]) ?? 0
            let isActive = r[5]
            if (!verifyPassword(password, pwdHash)) {
                let remain = remainingAfterFailure(loginRemainingAttempts(tkey))
                recordLoginFailure(tkey)
                writeAuditLogRaw(uid, uname, "系统认证", "登录失败", "用户 ${uname} 密码校验未通过")
                sendErr(ctx, 400, 400, "账号或密码错误（剩余尝试 ${remain} 次）")
                return
            }
            if (isActive != "1") {
                sendErr(ctx, 403, 403, "账号已被禁用，请联系管理员")
                return
            }
            clearLoginFailures(tkey)
            // P0.3：口令哈希静默升级。遗留「全局固定盐 SHA-256」在首次成功登录时
            // 自动改写为「每用户随机盐 + 迭代派生」格式，无需用户改密码。
            if (needsRehash(pwdHash)) {
                executeSql("UPDATE sys_user SET password_hash = ${sqlStr(hashPassword(password))} WHERE id = ${uid}")
            }
            executeSql("UPDATE sys_user SET last_login_at = NOW() WHERE id = ${uid}")
            let token = createToken(uid, uname, role, empId)
            let userJson = buildUserProfileJson(uid)
            writeAuditLogRaw(uid, uname, "系统认证", "登录", "用户 ${uname} 登录系统")
            sendOk(ctx, "{\"token\":${jsonStr(token)},\"user\":${userJson}}")
    }
}

public func handleAuthMe(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            // 契约保持不变：data 依然是扁平的用户档案。
            // P0.3 的滑动续期通过响应头 X-Renewed-Token 回发，避免破坏前端既有取值逻辑。
            let userJson = buildUserProfileJson(u.userId)
            match (renewTokenIfExpiring(u)) {
                case None => sendOk(ctx, userJson)
                case Some(fresh) => sendJsonWithToken(ctx, fresh, userJson)
            }
    }
}

public func handleAuthPassword(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            let body = readRequestBody(ctx)
            match (parseJsonObject(body)) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let oldPwd = getJsonStr(obj, "oldPassword", "")
                    let newPwd = getJsonStr(obj, "newPassword", "")
                    if (oldPwd.isEmpty() || newPwd.size < 6) {
                        sendErr(ctx, 400, 400, "新密码长度不能少于 6 位")
                        return
                    }
                    let currentHash = querySingleValue("SELECT password_hash FROM sys_user WHERE id = ${u.userId}")
                    if (!verifyPassword(oldPwd, currentHash)) {
                        sendErr(ctx, 400, 400, "原密码不正确")
                        return
                    }
                    let nextHash = hashPassword(newPwd)
                    executeSql("UPDATE sys_user SET password_hash = ${sqlStr(nextHash)} WHERE id = ${u.userId}")
                    writeAuditLog(u, "系统认证", "修改密码", "用户 ${u.username} 修改个人登录密码")
                    sendOkMsg(ctx, "密码修改成功", "null")
            }
    }
}
