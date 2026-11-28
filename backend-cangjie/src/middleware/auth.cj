package hrms_backend.middleware

import stdx.net.http.*
import hrms_backend.common.*
import hrms_backend.db.*

public func requireAuth(ctx: HttpContext): Option<AuthUser> {
    let authHeader = ctx.request.headers.getFirst("Authorization") ?? ""
    let trimmed = authHeader.trimAscii()
    if (!trimmed.startsWith("Bearer ")) {
        sendErr(ctx, 401, 401, "未登录或 Token 缺失")
        return Option<AuthUser>.None
    }
    let token = trimmed[7..].trimAscii()
    match (verifyToken(token)) {
        case None =>
            sendErr(ctx, 401, 401, "登录已过期或 Token 无效")
            return Option<AuthUser>.None
        case Some(u) =>
            let activeStr = querySingleValue("SELECT is_active FROM sys_user WHERE id = ${u.userId}")
            if (activeStr != "1") {
                sendErr(ctx, 401, 401, "账号已被禁用或不存在")
                return Option<AuthUser>.None
            }
            return Option<AuthUser>.Some(u)
    }
}

public func hasRole(user: AuthUser, allowedRoles: Array<String>): Bool {
    for (r in allowedRoles) {
        if (user.role == r) {
            return true
        }
    }
    return false
}

public func requireRoles(ctx: HttpContext, allowedRoles: Array<String>): Option<AuthUser> {
    match (requireAuth(ctx)) {
        case None => return Option<AuthUser>.None
        case Some(u) =>
            if (!hasRole(u, allowedRoles)) {
                sendErr(ctx, 403, 403, "权限不足，禁止访问该接口")
                return Option<AuthUser>.None
            }
            return Option<AuthUser>.Some(u)
    }
}

public func getUserDeptId(user: AuthUser): Int64 {
    if (user.employeeId <= 0) {
        return 0
    }
    return querySingleInt("SELECT dept_id FROM hr_employee WHERE id = ${user.employeeId}", 0)
}
