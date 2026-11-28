package hrms_backend.controller

import std.collection.*
import std.convert.*
import stdx.net.http.*
import hrms_backend.common.*
import hrms_backend.db.*
import hrms_backend.middleware.*
import hrms_backend.service.*

func requestRowToJson(r: ArrayList<String>): String {
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
        "\"createdAt\":${jsonStr(r[16])}" +
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
                    if (category != "LEAVE" && category != "OVERTIME") {
                        sendErr(ctx, 400, 400, "申请类别取值非法（仅支持 LEAVE/OVERTIME）")
                        return
                    }
                    // 时长由前端提交，必须服务端再校验一遍与起止时间的跨度是否匹配，
                    // 否则可以申报远超实际时段的加班/请假，直接影响薪资与年假扣减。
                    let spanMins = querySingleInt("SELECT IFNULL(TIMESTAMPDIFF(MINUTE, ${sqlStr(startTime)}, ${sqlStr(endTime)}), -1)", -1)
                    if (spanMins <= 0) {
                        sendErr(ctx, 400, 400, "结束时间必须晚于开始时间，且格式须为 YYYY-MM-DD HH:mm:ss")
                        return
                    }
                    if (category == "OVERTIME") {
                        let maxHours = Float64(spanMins) / 60.0
                        if (duration > maxHours + 0.01) {
                            sendErr(ctx, 400, 400, "加班时长（${formatNum2(duration)} 小时）不能超过起止时间跨度（${formatNum2(maxHours)} 小时）")
                            return
                        }
                    } else {
                        let maxDays = Float64(spanMins) / 1440.0 + 1.0
                        if (duration > maxDays) {
                            sendErr(ctx, 400, 400, "请假时长（${formatNum2(duration)} 天）不能超过起止时间跨度（约 ${formatNum2(maxDays)} 天）")
                            return
                        }
                    }
                    if (category == "LEAVE" && subType == "ANNUAL") {
                        let balStr = querySingleValue("SELECT annual_leave_balance FROM hr_employee WHERE id = ${u.employeeId}")
                        let bal = Float64.tryParse(balStr) ?? 0.0
                        if (bal < duration) {
                            sendErr(ctx, 400, 400, "剩余年假天数不足（当前剩余 ${formatNum2(bal)} 天）")
                            return
                        }
                    }
                    let sql = """
INSERT INTO hr_leave_overtime (employee_id, category, sub_type, start_time, end_time, duration, reason, status)
VALUES (${u.employeeId}, ${sqlStr(category)}, ${sqlStr(subType)}, ${sqlStr(startTime)}, ${sqlStr(endTime)}, ${formatNum2(duration)}, ${sqlStr(reason)}, 'PENDING')
"""
                    let newId = insertAndGetId(sql)
                    if (newId <= 0) {
                        sendErr(ctx, 500, 500, "提交申请失败，请检查日期时间格式")
                        return
                    }
                    sendOk(ctx, "{\"id\":${newId},\"status\":\"PENDING\"}")
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
            let list = ArrayList<String>()
            for (r in rows) {
                list.add(requestRowToJson(r))
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
            if (rows[0][1] != "PENDING") {
                sendErr(ctx, 400, 400, "仅待审批状态可以撤回")
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
            if (!status.isEmpty()) {
                conds.add("lo.status = ${sqlStr(status)}")
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
            let list = ArrayList<String>()
            for (r in rows) {
                list.add(requestRowToJson(r))
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

            if (u.role == "MANAGER" && empDept != getUserDeptId(u)) {
                sendErr(ctx, 403, 403, "部门主管仅可审批本部门申请")
                return
            }
            if (empId == u.employeeId) {
                sendErr(ctx, 403, 403, "不能审批本人提交的申请，请交由上级或 HR 处理")
                return
            }
            if (curStatus != "PENDING") {
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
                    let remark = getJsonStr(obj, "approveRemark", "").trimAscii()
                    if (action == "APPROVED" && category == "LEAVE" && subType == "ANNUAL") {
                        if (curBalance < duration) {
                            sendErr(ctx, 400, 400, "员工剩余年假不足（当前 ${formatNum2(curBalance)} 天），无法审批通过")
                            return
                        }
                        // 条件更新抢占 PENDING -> APPROVED，并发审批时只有一次会成功，避免重复扣年假。
                        let affected = querySingleInt("""
UPDATE hr_leave_overtime SET status = 'APPROVED', approver_id = ${u.userId}, approve_remark = ${sqlNullableStr(remark)}, approved_at = NOW() WHERE id = ${reqId} AND status = 'PENDING';
SELECT ROW_COUNT();
""", 0)
                        if (affected <= 0) {
                            sendErr(ctx, 400, 400, "该申请单已被其他审批人处理，请刷新后重试")
                            return
                        }
                        if (!executeSql("UPDATE hr_employee SET annual_leave_balance = annual_leave_balance - ${formatNum2(duration)} WHERE id = ${empId} AND annual_leave_balance >= ${formatNum2(duration)}")) {
                            // 扣减失败要把状态回滚，避免「已批准但年假没扣」的不一致
                            executeSql("UPDATE hr_leave_overtime SET status = 'PENDING', approver_id = NULL, approved_at = NULL, approve_remark = NULL WHERE id = ${reqId}")
                            sendErr(ctx, 500, 500, "年假扣减失败，审批已回滚，请重试")
                            return
                        }
                    } else {
                        let affected = querySingleInt("""
UPDATE hr_leave_overtime SET status = ${sqlStr(action)}, approver_id = ${u.userId}, approve_remark = ${sqlNullableStr(remark)}, approved_at = NOW() WHERE id = ${reqId} AND status = 'PENDING';
SELECT ROW_COUNT();
""", 0)
                        if (affected <= 0) {
                            sendErr(ctx, 400, 400, "该申请单已被其他审批人处理，请刷新后重试")
                            return
                        }
                    }
                    writeAuditLog(u, "假勤审批", "审批${category}", "审批单 ID=${reqId} (${empName}, ${subType}, 时长=${formatNum2(duration)}) -> ${action}")
                    sendOk(ctx, "{\"id\":${reqId},\"status\":${jsonStr(action)}}")
            }
    }
}
