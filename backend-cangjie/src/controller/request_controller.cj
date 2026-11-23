package hrms_backend.controller

import std.collection.*
import std.convert.*
import stdx.net.http.*
import hrms_backend.common.*
import hrms_backend.db.*
import hrms_backend.middleware.*
import hrms_backend.service.*

// ============================ P3.1 审批状态机（纯函数） ============================
// 长假（请假且时长 > 3 天）走两级：PENDING_MGR -> PENDING_HR -> APPROVED；
// 其余单据保持历史单级 PENDING -> APPROVED/REJECTED，向后兼容既有数据与用例。
//
// 这一组函数刻意不碰数据库，全部可单测；越权与重复审批的判断只能出现在这里。

// 长假阈值：严格「大于」3 天才双级，正好 3 天仍走单级。
// 只有请假（LEAVE）参与分级，因为加班的 duration 单位是小时，不能共用阈值。
let reqLongLeaveDays: Float64 = 3.0

let reqPendingStatuses = ["PENDING", "PENDING_MGR", "PENDING_HR"]

public func reqIsPendingLike(status: String): Bool {
    for (s in reqPendingStatuses) {
        if (status == s) {
            return true
        }
    }
    return false
}

// 提交时的初始状态：长假进一级，其余进单级待审批。
public func reqInitialStatus(category: String, duration: Float64): String {
    if (category == "LEAVE" && duration > reqLongLeaveDays) {
        return "PENDING_MGR"
    }
    return "PENDING"
}

// 当前状态处于第几级；终态返回 0（-1 留给非法值）。
public func reqCurrentLevel(status: String): Int64 {
    if (status == "PENDING" || status == "PENDING_MGR") {
        return 1
    }
    if (status == "PENDING_HR") {
        return 2
    }
    if (reqIsPendingLike(status)) {
        return 1
    }
    if (status == "APPROVED" || status == "REJECTED" || status == "CANCELLED") {
        return 0
    }
    return -1
}

// 本级动作之后单据进入的状态。只有二级（或单级）通过才是 APPROVED，
// 长假一级通过推进到 PENDING_HR，任何级别的驳回都是终态 REJECTED。
public func reqNextStatus(status: String, action: String): String {
    if (action == "REJECTED") {
        return "REJECTED"
    }
    if (action != "APPROVED") {
        return ""
    }
    if (status == "PENDING_MGR") {
        return "PENDING_HR"
    }
    return "APPROVED"
}

// 单步推进：ADMIN 也只推一级，保证审批链不可跳过。
public func reqCanActStep(status: String, role: String, sameDept: Bool): Bool {
    if (!reqIsPendingLike(status)) {
        return false
    }
    if (role == "ADMIN") {
        return true
    }
    if (status == "PENDING_MGR") {
        return role == "MANAGER" && sameDept
    }
    if (status == "PENDING_HR") {
        return role == "HR"
    }
    if (role == "HR") {
        return true
    }
    return role == "MANAGER" && sameDept
}

public func reqActionDeniedMessage(status: String, role: String, sameDept: Bool): String {
    if (status == "PENDING_MGR") {
        if (role == "MANAGER" && !sameDept) {
            return "长假一级审批仅可由申请本部门主管处理"
        }
        return "长假一级审批请由部门主管或系统管理员处理"
    }
    if (status == "PENDING_HR") {
        return "长假已进入二级审批，请由人力资源部门或系统管理员处理"
    }
    return "该申请单已处理，无法重复审批"
}

// 年假只在「本次动作让单据变为 APPROVED」时扣减，
// 因此长假一级通过（PENDING_HR）不扣，二级通过才扣一次。
public func reqShouldDeductAnnual(category: String, subType: String, nextStatus: String): Bool {
    return category == "LEAVE" && subType == "ANNUAL" && nextStatus == "APPROVED"
}

// 审批状态筛选：PENDING 表示「任何一级待处理」，其余按精确值匹配。
public func reqStatusCondition(status: String): String {
    if (status == "") {
        return ""
    }
    if (status == "PENDING") {
        return "lo.status IN ('PENDING', 'PENDING_MGR', 'PENDING_HR')"
    }
    return "lo.status = " + sqlStr(status)
}

// 仪表盘「待我审批」口径：三档未终态都要计入，否则长假单会被漏计。
public func reqPendingCountCondition(): String {
    return "status IN ('PENDING', 'PENDING_MGR', 'PENDING_HR')"
}

// 审批链批量查询 SQL（一次取回本页所有单据的链历史，避免逐行 N+1 起子进程）。
public func reqTrailSql(idList: String): String {
    return """
SELECT request_id, step, approver_name, approver_role, action, result_status,
       IFNULL(remark, ''),
       DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s')
FROM hr_approval_log
WHERE request_id IN (${idList})
ORDER BY request_id ASC, step ASC
"""
}

// 从批量结果里挑出属于某个申请单的审批链，拼成 JSON 数组（保持 SQL 的 step 升序）。
public func reqTrailJsonFor(trailRows: ArrayList<ArrayList<String>>, reqId: String): String {
    let parts = ArrayList<String>()
    for (t in trailRows) {
        if (t.size >= 8 && t[0] == reqId) {
            parts.add(
                "{" +
                "\"step\":${t[1]}," +
                "\"approverName\":${jsonStr(t[2])}," +
                "\"approverRole\":${jsonStr(t[3])}," +
                "\"action\":${jsonStr(t[4])}," +
                "\"resultStatus\":${jsonStr(t[5])}," +
                "\"remark\":${jsonStr(t[6])}," +
                "\"at\":${jsonStr(t[7])}" +
                "}"
            )
        }
    }
    return "[" + String.join(parts.toArray(), delimiter: ",") + "]"
}

// 本页单据的 id 串，用于 IN 子句。
public func reqIdListFromRows(rows: ArrayList<ArrayList<String>>): String {
    let ids = ArrayList<String>()
    for (r in rows) {
        if (r.size > 0 && reqIsNumericId(r[0])) {
            ids.add(r[0])
        }
    }
    return String.join(ids.toArray(), delimiter: ",")
}

// 只有纯数字的 id 才能直接拼进 IN 子句，避免脏数据带来注入面。
public func reqIsNumericId(raw: String): Bool {
    let bytes = raw.toArray()
    if (bytes.size == 0) {
        return false
    }
    let zero: UInt8 = 0x30
    let nine: UInt8 = 0x39
    for (b in bytes) {
        if (b < zero || b > nine) {
            return false
        }
    }
    return true
}

public func loadApprovalTrail(rows: ArrayList<ArrayList<String>>): ArrayList<ArrayList<String>> {
    let idList = reqIdListFromRows(rows)
    if (idList == "") {
        return ArrayList<ArrayList<String>>()
    }
    return queryRows(reqTrailSql(idList))
}

// 17 列：id, employeeId, empNo, empName, deptName, category, subType, startTime, endTime,
// duration, reason, status, approverId, approverName, approveRemark, approvedAt, createdAt
public func requestRowToJson(r: ArrayList<String>, myAction: String, trail: String): String {
    return "{" +
        "\"id\":${r[0]}," +
        "\"employeeId\":${r[1]}," +
        "\"empNo\":${jsonStr(r[2])}," +
        "\"empName\":${jsonStr(r[3])}," +
        "\"deptName\":${jsonStr(r[4])}," +
        "\"category\":${jsonStr(r[5])}," +
        "\"subType\":${jsonStr(r[6])}," +
        "\"startTime\":${jsonStr(r[7])}," +
        "\"endTime\":${jsonStr(r[8])}," +
        "\"duration\":${r[9]}," +
        "\"reason\":${jsonStr(r[10])}," +
        "\"status\":${jsonStr(r[11])}," +
        "\"approverId\":${r[12]}," +
        "\"approverName\":${jsonStr(r[13])}," +
        "\"approveRemark\":${jsonStr(r[14])}," +
        "\"approvedAt\":${jsonStr(r[15])}," +
        "\"createdAt\":${jsonStr(r[16])}," +
        "\"currentLevel\":${reqCurrentLevel(r[11])}," +
        "\"myAction\":${jsonStr(myAction)}," +
        "\"approvalTrail\":${trail}" +
    "}"
}

public func handleRequestCreate(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            if (u.employeeId <= 0) {
                sendErr(ctx, 400, 400, "当前账号未绑定员工档案")
                return
            }
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let category = getJsonStr(obj, "category", "LEAVE").trimAscii()
                    let subType = getJsonStr(obj, "subType", "").trimAscii()
                    let startTime = getJsonStr(obj, "startTime", "").trimAscii()
                    let endTime = getJsonStr(obj, "endTime", "").trimAscii()
                    let duration = getJsonFloat(obj, "duration", 0.0)
                    let reason = getJsonStr(obj, "reason", "").trimAscii()
                    if (subType.isEmpty() || startTime.isEmpty() || endTime.isEmpty() || duration <= 0.0 || reason.isEmpty()) {
                        sendErr(ctx, 400, 400, "类型、开始时间、结束时间、时长与事由均不能为空")
                        return
                    }
                    if (category == "LEAVE" && subType == "ANNUAL") {
                        let balStr = querySingleValue("SELECT annual_leave_balance FROM hr_employee WHERE id = ${u.employeeId}")
                        let bal = Float64.tryParse(balStr) ?? 0.0
                        if (bal < duration) {
                            sendErr(ctx, 400, 400, "剩余年假天数不足（当前剩余 ${formatNum2(bal)} 天）")
                            return
                        }
                    }
                    // P3.1：长假自动进入一级审批，其余仍是单级 PENDING
                    let initStatus = reqInitialStatus(category, duration)
                    let sql = """
INSERT INTO hr_leave_overtime (employee_id, category, sub_type, start_time, end_time, duration, reason, status)
VALUES (${u.employeeId}, ${sqlStr(category)}, ${sqlStr(subType)}, ${sqlStr(startTime)}, ${sqlStr(endTime)}, ${formatNum2(duration)}, ${sqlStr(reason)}, ${sqlStr(initStatus)})
"""
                    let newId = insertAndGetId(sql)
                    if (newId <= 0) {
                        sendErr(ctx, 500, 500, "提交申请失败，请检查日期时间格式")
                        return
                    }
                    sendOk(ctx, "{\"id\":${newId},\"status\":${jsonStr(initStatus)},\"currentLevel\":${reqCurrentLevel(initStatus)}}")
            }
    }
}

public func handleRequestMy(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            let category = getQueryStr(ctx, "category", "").trimAscii()
            let conds = ArrayList<String>()
            conds.add("lo.employee_id = ${u.employeeId}")
            if (!category.isEmpty()) {
                conds.add("lo.category = ${sqlStr(category)}")
            }
            let whereSql = "WHERE " + String.join(conds.toArray(), delimiter: " AND ")
            let sql = """
SELECT lo.id, lo.employee_id, IFNULL(e.emp_no, ''), IFNULL(e.name, ''), IFNULL(d.dept_name, ''),
       lo.category, lo.sub_type,
       DATE_FORMAT(lo.start_time, '%Y-%m-%d %H:%i:%s'),
       DATE_FORMAT(lo.end_time, '%Y-%m-%d %H:%i:%s'),
       lo.duration, lo.reason, lo.status,
       IFNULL(lo.approver_id, 0), IFNULL(au.username, ''), IFNULL(lo.approve_remark, ''),
       IFNULL(DATE_FORMAT(lo.approved_at, '%Y-%m-%d %H:%i:%s'), ''),
       DATE_FORMAT(lo.created_at, '%Y-%m-%d %H:%i:%s')
FROM hr_leave_overtime lo
LEFT JOIN hr_employee e ON lo.employee_id = e.id
LEFT JOIN hr_department d ON e.dept_id = d.id
LEFT JOIN sys_user au ON lo.approver_id = au.id
${whereSql}
ORDER BY lo.id DESC
"""
            let rows = queryRows(sql)
            let trailRows = loadApprovalTrail(rows)
            let list = ArrayList<String>()
            for (r in rows) {
                // 「我的申请」不提供审批按钮：本人不能审自己的单，myAction 恒为空串
                list.add(requestRowToJson(r, "", reqTrailJsonFor(trailRows, r[0])))
            }
            sendOk(ctx, "[" + String.join(list.toArray(), delimiter: ",") + "]")
    }
}

public func handleRequestCancel(ctx: HttpContext, reqId: Int64): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            let rows = queryRows("SELECT employee_id, status FROM hr_leave_overtime WHERE id = ${reqId} LIMIT 1")
            if (rows.size == 0) {
                sendErr(ctx, 404, 404, "申请单不存在")
                return
            }
            let ownerEmpId = Int64.tryParse(rows[0][0]) ?? 0
            if (ownerEmpId != u.employeeId && u.role != "ADMIN") {
                sendErr(ctx, 403, 403, "只能撤回本人提交的申请")
                return
            }
            if (!reqIsPendingLike(rows[0][1])) {
                sendErr(ctx, 400, 400, "仅待审批状态（含长假一级/二级）可以撤回")
                return
            }
            executeSql("UPDATE hr_leave_overtime SET status = 'CANCELLED' WHERE id = ${reqId}")
            sendOk(ctx, "null")
    }
}

public func handleRequestList(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR", "MANAGER"])) {
        case None => return
        case Some(u) =>
            let category = getQueryStr(ctx, "category", "").trimAscii()
            let status = getQueryStr(ctx, "status", "").trimAscii()
            var page = getQueryInt(ctx, "page", 1)
            var pageSize = getQueryInt(ctx, "pageSize", 10)
            if (page < 1) { page = 1 }
            if (pageSize < 1 || pageSize > 100) { pageSize = 10 }

            let conds = ArrayList<String>()
            conds.add("1=1")
            if (u.role == "MANAGER") {
                conds.add("e.dept_id = ${getUserDeptId(u)}")
            }
            if (!category.isEmpty()) {
                conds.add("lo.category = ${sqlStr(category)}")
            }
            let statusCond = reqStatusCondition(status)
            if (statusCond != "") {
                conds.add(statusCond)
            }
            let whereSql = "WHERE " + String.join(conds.toArray(), delimiter: " AND ")
            let total = querySingleInt("SELECT COUNT(*) FROM hr_leave_overtime lo LEFT JOIN hr_employee e ON lo.employee_id = e.id ${whereSql}", 0)
            let offset = (page - 1) * pageSize
            let sql = """
SELECT lo.id, lo.employee_id, IFNULL(e.emp_no, ''), IFNULL(e.name, ''), IFNULL(d.dept_name, ''),
       lo.category, lo.sub_type,
       DATE_FORMAT(lo.start_time, '%Y-%m-%d %H:%i:%s'),
       DATE_FORMAT(lo.end_time, '%Y-%m-%d %H:%i:%s'),
       lo.duration, lo.reason, lo.status,
       IFNULL(lo.approver_id, 0), IFNULL(au.username, ''), IFNULL(lo.approve_remark, ''),
       IFNULL(DATE_FORMAT(lo.approved_at, '%Y-%m-%d %H:%i:%s'), ''),
       DATE_FORMAT(lo.created_at, '%Y-%m-%d %H:%i:%s')
FROM hr_leave_overtime lo
LEFT JOIN hr_employee e ON lo.employee_id = e.id
LEFT JOIN hr_department d ON e.dept_id = d.id
LEFT JOIN sys_user au ON lo.approver_id = au.id
${whereSql}
ORDER BY lo.id DESC
LIMIT ${pageSize} OFFSET ${offset}
"""
            let rows = queryRows(sql)
            let trailRows = loadApprovalTrail(rows)
            let list = ArrayList<String>()
            for (r in rows) {
                // 上面已按 e.dept_id 限定 MANAGER 可见范围，因此这里的行必然与主管同部门
                var myAction = ""
                if (reqCanActStep(r[11], u.role, true)) {
                    myAction = "APPROVE"
                }
                list.add(requestRowToJson(r, myAction, reqTrailJsonFor(trailRows, r[0])))
            }
            sendPage(ctx, "[" + String.join(list.toArray(), delimiter: ",") + "]", total, page, pageSize)
    }
}

public func handleRequestApprove(ctx: HttpContext, reqId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR", "MANAGER"])) {
        case None => return
        case Some(u) =>
            let rows = queryRows("""
SELECT lo.employee_id, lo.category, lo.sub_type, lo.duration, lo.status, e.dept_id, e.name, e.annual_leave_balance
FROM hr_leave_overtime lo
LEFT JOIN hr_employee e ON lo.employee_id = e.id
WHERE lo.id = ${reqId}
LIMIT 1
""")
            if (rows.size == 0) {
                sendErr(ctx, 404, 404, "审批单不存在")
                return
            }
            let r = rows[0]
            let empId = Int64.tryParse(r[0]) ?? 0
            let category = r[1]
            let subType = r[2]
            let duration = Float64.tryParse(r[3]) ?? 0.0
            let curStatus = r[4]
            let empDept = Int64.tryParse(r[5]) ?? 0
            let empName = r[6]
            let curBalance = Float64.tryParse(r[7]) ?? 0.0

            let stepLevel = reqCurrentLevel(curStatus)
            let sameDept = empDept == getUserDeptId(u)
            if (u.role == "MANAGER" && !sameDept) {
                sendErr(ctx, 403, 403, "部门主管仅可审批本部门申请")
                return
            }
            if (!reqIsPendingLike(curStatus)) {
                sendErr(ctx, 400, 400, "该申请单已处理，无法重复审批")
                return
            }
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    var action = getJsonStr(obj, "action", "").trimAscii()
                    if (action.isEmpty()) {
                        action = getJsonStr(obj, "status", "").trimAscii()
                    }
                    if (action != "APPROVED" && action != "REJECTED") {
                        sendErr(ctx, 400, 400, "审批动作必须为 APPROVED 或 REJECTED")
                        return
                    }
                    // P3.1 级次权限：一级只能由本部门主管/ADMIN 推进，二级只能由 HR/ADMIN 推进，
                    // 每次调用只推进一级，因此长假无法被单点跳过。
                    if (!reqCanActStep(curStatus, u.role, sameDept)) {
                        sendErr(ctx, 403, 403, reqActionDeniedMessage(curStatus, u.role, sameDept))
                        return
                    }
                    let remark = getJsonStr(obj, "approveRemark", "").trimAscii()
                    let nextStatus = reqNextStatus(curStatus, action)
                    let deductAnnual = reqShouldDeductAnnual(category, subType, nextStatus)
                    if (deductAnnual && curBalance < duration) {
                        sendErr(ctx, 400, 400, "员工剩余年假不足（当前 ${formatNum2(curBalance)} 天），无法审批通过")
                        return
                    }
                    let updateSql = "UPDATE hr_leave_overtime SET status = ${sqlStr(nextStatus)}, approver_id = ${u.userId}, approve_remark = ${sqlNullableStr(remark)}, approved_at = NOW() WHERE id = ${reqId}"
                    let logSql = "INSERT INTO hr_approval_log (request_id, step, approver_id, approver_name, approver_role, action, result_status, remark) VALUES (${reqId}, ${stepLevel}, ${u.userId}, ${sqlStr(u.username)}, ${sqlStr(u.role)}, ${sqlStr(action)}, ${sqlStr(nextStatus)}, ${sqlNullableStr(remark)})"
                    var txSql = "START TRANSACTION;\n"
                    if (deductAnnual) {
                        txSql = txSql + "UPDATE hr_employee SET annual_leave_balance = annual_leave_balance - ${formatNum2(duration)} WHERE id = ${empId};\n"
                    }
                    txSql = txSql + updateSql + ";\n" + logSql + ";\nCOMMIT;"
                    if (!executeSql(txSql)) {
                        // UNIQUE(request_id, step) 命中说明这一级已被别人签过，绝不能当作成功返回
                        sendErr(ctx, 500, 500, "审批写入失败：${lastDbErrorMessage()}")
                        return
                    }
                    writeAuditLog(u, "假勤审批", "审批${category}", "审批单 ID=${reqId} (${empName}, ${subType}, 时长=${formatNum2(duration)}) 第${stepLevel}级 ${action} -> ${nextStatus}")
                    // P3.2 通知：终态只通知申请人；推进到二级时额外通知 HR 去复核。
                    // 放在 sendOk 之前、事务成功之后——写通知失败不该回滚已经生效的审批，
                    // pushNotification 内部也不会抛，最多是铃铛少一条，可接受。
                    notifyRequestResult(reqId, empId, nextStatus, category, duration)
                    if (nextStatus == "PENDING_HR") {
                        let hrIds = notifUserIds(queryRows(notifHrUserSql()))
                        for (hid in hrIds) {
                            notifyNextLevel(reqId, empName, hid)
                        }
                    }
                    sendOk(ctx, "{\"id\":${reqId},\"status\":${jsonStr(nextStatus)},\"action\":${jsonStr(action)},\"currentLevel\":${stepLevel},\"nextLevel\":${reqCurrentLevel(nextStatus)}}")
            }
    }
}
