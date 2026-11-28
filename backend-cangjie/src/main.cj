package hrms_backend

import stdx.net.http.*
import stdx.log.*
import hrms_backend.config.*
import hrms_backend.db.*
import hrms_backend.common.*
import hrms_backend.middleware.*
import hrms_backend.controller.*

func seedDefaultUsers(): Unit {
    try {
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
    } catch (e: Exception) {
        println("数据库初始化失败：${e.message}")
        println("请确认 MySQL 服务已启动、backend-cangjie/.env 连接配置正确，并已导入 sql/init.sql。")
        throw e
    }
}

func dispatchRequest(ctx: HttpContext): Unit {
    if (handleCorsPreflight(ctx)) {
        return
    }
    try {
        let method = ctx.request.method
        let path = ctx.request.url.path
        let segs = parsePathSegments(path)

        // /api/v1/health
        if (segs.size == 3 && segs[0] == "api" && segs[1] == "v1" && segs[2] == "health" && method == "GET") {
            sendOk(ctx, "{\"status\":\"UP\"}")
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
    ensureTempDir()
    seedDefaultUsers()
    let server = ServerBuilder()
        .addr("127.0.0.1")
        .port(globalConfig.serverPort)
        .distributor(AppDistributor())
        .build()
    server.logger.level = LogLevel.WARN
    println("HRMS Cangjie Backend listening on http://127.0.0.1:${globalConfig.serverPort}")
    server.serve()
    return 0
}
