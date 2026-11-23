package hrms_backend

import stdx.net.http.*
import stdx.log.*
import hrms_backend.config.*
import hrms_backend.db.*
import hrms_backend.common.*
import hrms_backend.middleware.*
import hrms_backend.controller.*

// 运行元信息（供 /health 计算运行时长）
class ServerMeta {
    public var startAt: Int64 = 0
}

let serverMeta = ServerMeta()

// P0.2：健康检查必须真实探活，不能再无条件返回 UP。
// 数据库不可用时返回 503，让容器编排 / 反向代理能够正确摘流。
func handleHealth(ctx: HttpContext): Unit {
    let (dbUp, dbInfo) = dbPing()
    let (queryTotal, queryFailed) = dbStats()
    let lastError = truncateUtf8(lastDbErrorMessage(), 300)
    let statusText = if (dbUp) { "UP" } else { "DOWN" }
    let message = if (dbUp) { "success" } else { "数据库不可用" }
    let httpStatus: UInt16 = if (dbUp) { 200 } else { 503 }
    let bizCode: Int64 = if (dbUp) { 200 } else { 503 }
    let uptime = nowUnixSeconds() - serverMeta.startAt
    let (trackedKeys, blockedKeys, totalFailures) = loginThrottleStats()
    let data = "{\"status\":\"${statusText}\",\"uptimeSeconds\":${uptime},"
        + "\"db\":{\"status\":\"${statusText}\",\"detail\":${jsonStr(truncateUtf8(dbInfo, 200))},\"lastError\":${jsonStr(lastError)}},"
        + "\"stats\":{\"queryTotal\":${queryTotal},\"queryFailed\":${queryFailed}},"
        + "\"loginThrottle\":{\"trackedKeys\":${trackedKeys},\"blockedKeys\":${blockedKeys},\"failures\":${totalFailures},\"totalBlocked\":${loginThrottleTotalBlocked()}},"
        + "\"security\":{\"warnings\":${securityWarningsJson()}}}"
    sendJson(ctx, httpStatus, bizCode, message, data)
}

// 把启动期安全自检结果暴露给 /health，便于自动化巡检发现「还在用示例密钥」。
func securityWarningsJson(): String {
    let warnings = globalConfig.securityWarnings()
    var json = "["
    for (i in 0..warnings.size) {
        if (i > 0) {
            json = "${json},"
        }
        json = "${json}${jsonStr(warnings[i])}"
    }
    return "${json}]"
}

func seedDefaultUsers(): Unit {
    let cnt = querySingleInt("SELECT COUNT(*) FROM sys_user", 0)
    if (cnt > 0) {
        return
    }
    let defaultHash = hashPassword("123456")
    let sql = """
INSERT INTO sys_user (username, password_hash, role, employee_id, is_active) VALUES
('admin', ${sqlStr(defaultHash)}, 'ADMIN', 1, 1),
('hr', ${sqlStr(defaultHash)}, 'HR', 2, 1),
('manager', ${sqlStr(defaultHash)}, 'MANAGER', 3, 1),
('emp01', ${sqlStr(defaultHash)}, 'EMPLOYEE', 4, 1);
"""
    if (executeSql(sql)) {
        println("Default demo accounts initialized (admin, hr, manager, emp01 / 123456).")
    }
}

// P0.3：把环境/配置问题在启动阶段就说清楚，而不是等第一个请求 500。
func printStartupDiagnostics(): Unit {
    let secretState = describeJwtSecret()
    println("==================================================")
    println("HRMS Cangjie Backend 启动自检")
    println("  监听地址  : http://127.0.0.1:${globalConfig.serverPort}")
    println("  数据库    : ${globalConfig.dbUser}@${globalConfig.dbHost}:${globalConfig.dbPort}/${globalConfig.dbName}")
    println("  mysql.exe : ${globalConfig.mysqlExe}")
    println("  临时目录  : ${globalConfig.tempDir}")
    println("  查询超时  : ${globalConfig.dbTimeoutSec}s")
    println("  JWT 密钥  : ${secretState}, 长度 ${globalConfig.jwtSecret.size}")
    println("  STRICT_ENV: ${globalConfig.strictEnv}")
    let warnings = globalConfig.securityWarnings()
    for (w in warnings) {
        println("  [安全告警] ${w}")
    }
    println("==================================================")
}

func describeJwtSecret(): String {
    if (globalConfig.jwtSecretIsDefault) {
        return "内置示例（不安全）"
    }
    if (globalConfig.jwtSecret.size < MIN_JWT_SECRET_LEN) {
        return "自定义但过短（不安全）"
    }
    return "自定义（合规）"
}

func dispatchRequest(ctx: HttpContext): Unit {
    if (handleCorsPreflight(ctx)) {
        return
    }
    try {
        let method = ctx.request.method
        let path = ctx.request.url.path
        let segs = parsePathSegments(path)

        // /api/v1/health：真实探活，DB 不可用时返回 503
        if (segs.size == 3 && segs[0] == "api" && segs[1] == "v1" && segs[2] == "health" && method == "GET") {
            handleHealth(ctx)
            return
        }

        // Auth routes
        if (path == "/api/v1/auth/login" && method == "POST") { handleAuthLogin(ctx); return }
        if (path == "/api/v1/auth/me" && method == "GET") { handleAuthMe(ctx); return }
        if (path == "/api/v1/auth/password" && method == "PUT") { handleAuthPassword(ctx); return }

        // Department routes
        if (path == "/api/v1/departments/tree" && method == "GET") { handleDepartmentsTree(ctx); return }
        if (path == "/api/v1/departments" && method == "POST") { handleDepartmentCreate(ctx); return }
        if (segs.size == 4 && segs[0] == "api" && segs[1] == "v1" && segs[2] == "departments") {
            let id = parseIntId(segs[3])
            if (id > 0 && method == "PUT") { handleDepartmentUpdate(ctx, id); return }
            if (id > 0 && method == "DELETE") { handleDepartmentDelete(ctx, id); return }
        }

        // Position routes
        if (path == "/api/v1/positions" && method == "GET") { handlePositionList(ctx); return }
        if (path == "/api/v1/positions" && method == "POST") { handlePositionCreate(ctx); return }
        if (segs.size == 4 && segs[0] == "api" && segs[1] == "v1" && segs[2] == "positions") {
            let id = parseIntId(segs[3])
            if (id > 0 && method == "PUT") { handlePositionUpdate(ctx, id); return }
            if (id > 0 && method == "DELETE") { handlePositionDelete(ctx, id); return }
        }

        // Employee routes
        if (path == "/api/v1/employees" && method == "GET") { handleEmployeeList(ctx); return }
        if (path == "/api/v1/employees" && method == "POST") { handleEmployeeCreate(ctx); return }
        // 批量导入必须排在 `segs.size == 4` 的员工详情分支之前：
        // /api/v1/employees/import 同为 4 段，只是最后一段不是数字 ID。
        if (path == "/api/v1/employees/import" && method == "POST") { handleEmployeeImport(ctx); return }
        if (segs.size == 4 && segs[0] == "api" && segs[1] == "v1" && segs[2] == "employees") {
            let id = parseIntId(segs[3])
            if (id > 0 && method == "GET") { handleEmployeeDetail(ctx, id); return }
            if (id > 0 && method == "PUT") { handleEmployeeUpdate(ctx, id); return }
        }
        if (segs.size == 5 && segs[0] == "api" && segs[1] == "v1" && segs[2] == "employees") {
            let id = parseIntId(segs[3])
            if (id > 0 && segs[4] == "transfer" && method == "POST") { handleEmployeeTransfer(ctx, id); return }
            if (id > 0 && segs[4] == "resign" && method == "POST") { handleEmployeeResign(ctx, id); return }
        }

        // Dashboard routes
        if (path == "/api/v1/dashboard/overview" && method == "GET") { handleDashboardOverview(ctx); return }

        // Attendance routes
        if (path == "/api/v1/attendance/clock-in" && method == "POST") { handleAttendanceClockIn(ctx); return }
        if (path == "/api/v1/attendance/clock-out" && method == "POST") { handleAttendanceClockOut(ctx); return }
        if (path == "/api/v1/attendance/today" && method == "GET") { handleAttendanceToday(ctx); return }
        if (path == "/api/v1/attendance/my" && method == "GET") { handleAttendanceMy(ctx); return }
        if (path == "/api/v1/attendance" && method == "GET") { handleAttendanceList(ctx); return }
        // P2.4 月度汇总：必须排在 `/attendance` 之后、`segs.size == 4` 的补卡分支之前。
        // 它是 5 段路径，不会被 4 段分支误吞，但放在一起更好读。
        if (path == "/api/v1/attendance/monthly-summary" && method == "GET") { handleAttendanceMonthlySummary(ctx); return }
        if (segs.size == 4 && segs[0] == "api" && segs[1] == "v1" && segs[2] == "attendance" && method == "PUT") {
            let id = parseIntId(segs[3])
            if (id > 0) { handleAttendanceUpdate(ctx, id); return }
        }

        // Request (Leave & Overtime) routes
        if (path == "/api/v1/requests" && method == "POST") { handleRequestCreate(ctx); return }
        if (path == "/api/v1/requests/my" && method == "GET") { handleRequestMy(ctx); return }
        if (path == "/api/v1/requests" && method == "GET") { handleRequestList(ctx); return }
        if (segs.size == 5 && segs[0] == "api" && segs[1] == "v1" && segs[2] == "requests" && method == "POST") {
            let id = parseIntId(segs[3])
            if (id > 0 && segs[4] == "cancel") { handleRequestCancel(ctx, id); return }
            if (id > 0 && segs[4] == "approve") { handleRequestApprove(ctx, id); return }
        }

        // Notification (P3.2 站内通知中心) routes
        // 注意顺序：unread-count / read-all 是固定路径，必须排在 :id 形式的分支之前，
        // 否则 "unread-count" 会被 parseIntId 解析成 0 而落到 404。
        if (path == "/api/v1/notifications/unread-count" && method == "GET") { handleNotificationUnread(ctx); return }
        if (path == "/api/v1/notifications/read-all" && method == "POST") { handleNotificationReadAll(ctx); return }
        if (path == "/api/v1/notifications" && method == "GET") { handleNotificationList(ctx); return }
        if (segs.size == 5 && segs[0] == "api" && segs[1] == "v1" && segs[2] == "notifications" && method == "PUT") {
            let id = parseIntId(segs[3])
            if (id > 0 && segs[4] == "read") { handleNotificationRead(ctx, id); return }
        }

        // Performance routes
        if (path == "/api/v1/performances/init-cycle" && method == "POST") { handlePerformanceInitCycle(ctx); return }
        if (path == "/api/v1/performances" && method == "GET") { handlePerformanceList(ctx); return }
        if (segs.size == 5 && segs[0] == "api" && segs[1] == "v1" && segs[2] == "performances" && method == "PUT") {
            let id = parseIntId(segs[3])
            if (id > 0 && segs[4] == "self-eval") { handlePerformanceSelfEval(ctx, id); return }
            if (id > 0 && segs[4] == "review") { handlePerformanceReview(ctx, id); return }
        }

        // Payroll routes
        if (path == "/api/v1/payrolls/generate" && method == "POST") { handlePayrollGenerate(ctx); return }
        if (path == "/api/v1/payrolls/batch-pay" && method == "POST") { handlePayrollBatchPay(ctx); return }
        if (path == "/api/v1/payrolls/my" && method == "GET") { handlePayrollMy(ctx); return }
        if (path == "/api/v1/payrolls" && method == "GET") { handlePayrollList(ctx); return }
        if (segs.size == 4 && segs[0] == "api" && segs[1] == "v1" && segs[2] == "payrolls" && method == "PUT") {
            let id = parseIntId(segs[3])
            if (id > 0) { handlePayrollUpdate(ctx, id); return }
        }
        if (segs.size == 5 && segs[0] == "api" && segs[1] == "v1" && segs[2] == "payrolls" && method == "POST") {
            let id = parseIntId(segs[3])
            if (id > 0 && segs[4] == "pay") { handlePayrollPaySingle(ctx, id); return }
        }

        // Recruitment candidate routes
        if (path == "/api/v1/candidates" && method == "GET") { handleCandidateList(ctx); return }
        if (path == "/api/v1/candidates" && method == "POST") { handleCandidateCreate(ctx); return }
        if (segs.size == 4 && segs[0] == "api" && segs[1] == "v1" && segs[2] == "candidates" && method == "PUT") {
            let id = parseIntId(segs[3])
            if (id > 0) { handleCandidateUpdate(ctx, id); return }
        }
        if (segs.size == 5 && segs[0] == "api" && segs[1] == "v1" && segs[2] == "candidates" && method == "POST") {
            let id = parseIntId(segs[3])
            if (id > 0 && segs[4] == "hire") { handleCandidateHire(ctx, id); return }
        }

        // System routes
        if (path == "/api/v1/system/users" && method == "GET") { handleSystemUsers(ctx); return }
        if (segs.size == 5 && segs[0] == "api" && segs[1] == "v1" && segs[2] == "system" && segs[3] == "users" && method == "PUT") {
            let id = parseIntId(segs[4])
            if (id > 0) { handleSystemUserUpdate(ctx, id); return }
        }
        if (path == "/api/v1/system/audit-logs" && method == "GET") { handleSystemAuditLogs(ctx); return }

        sendErr(ctx, 404, 404, "接口不存在: ${method} ${path}")
    } catch (e: Exception) {
        sendErr(ctx, 500, 500, "服务器内部异常: ${e.message}")
    }
}

class AppDistributor <: HttpRequestDistributor {
    public func register(_: String, _: HttpRequestHandler): Unit {}
    public func distribute(_: String): HttpRequestHandler {
        return FuncHandler({ ctx => dispatchRequest(ctx) })
    }
}

main(): Int64 {
    serverMeta.startAt = nowUnixSeconds()
    printStartupDiagnostics()

    // P0.3 fail-fast：严格模式下带着不合规的密钥启动是不允许的。
    if (globalConfig.strictEnv && globalConfig.securityWarnings().size > 0) {
        println("[FATAL] STRICT_ENV=1，但存在安全配置问题，拒绝启动。请修复上述告警后重试。")
        return 1
    }

    try {
        ensureTempDir()
    } catch (e: Exception) {
        println("[FATAL] 临时目录初始化失败: ${e.message}")
        println("        请设置 TMP_SQL_DIR 指向一个纯英文、可写的目录，例如 D:\\hrms_tmp")
        return 1
    }

    try {
        seedDefaultUsers()
    } catch (e: Exception) {
        // P0.1 之后数据访问层不再静默吞异常，这里把根因直接摊给开发者。
        println("[WARN] 初始化演示账号失败：${e.message}")
        println("       可能原因：MySQL 未启动 / 账号口令错误 / ${globalConfig.dbName} 未建库。")
        let (dbUp, dbInfo) = dbPing()
        if (dbUp) {
            println("       连通性探测：正常（${dbInfo}），请确认 hrms_db 中已建表。")
        } else {
            println("       连通性探测：失败（${dbInfo}）。")
        }
        println("       建库脚本：sql/init_db.sql；Windows 可用 scripts/init-db.ps1")
        println("       服务仍会启动，但所有依赖数据库的接口将返回 500。")
    }

    let server = ServerBuilder()
        .addr("127.0.0.1")
        .port(globalConfig.serverPort)
        .distributor(AppDistributor())
        .build()
    server.logger.level = LogLevel.WARN
    println("HRMS Cangjie Backend listening on http://127.0.0.1:${globalConfig.serverPort}")
    println("健康检查: GET http://127.0.0.1:${globalConfig.serverPort}/api/v1/health")
    server.serve()
    return 0
}
