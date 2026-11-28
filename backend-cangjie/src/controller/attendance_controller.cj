package hrms_backend.controller

import std.collection.*
import std.convert.*
import stdx.net.http.*
import hrms_backend.common.*
import hrms_backend.db.*
import hrms_backend.middleware.*
import hrms_backend.service.*

func attendanceRowToJson(r: ArrayList<String>): String {
    return "{" +
        "\"id\":${r[0]}," +
        "\"employeeId\":${r[1]}," +
        "\"empNo\":${jsonStr(r[2])}," +
        "\"empName\":${jsonStr(r[3])}," +
        "\"deptName\":${jsonStr(r[4])}," +
        "\"workDate\":${jsonStr(r[5])}," +
        "\"clockInTime\":${jsonStr(r[6])}," +
        "\"clockOutTime\":${jsonStr(r[7])}," +
        "\"lateMinutes\":${r[8]}," +
        "\"earlyMinutes\":${r[9]}," +
        "\"status\":${jsonStr(r[10])}," +
        "\"remark\":${jsonStr(r[11])}" +
    "}"
}

func getTodayAttendanceJson(empId: Int64): String {
    let sql = """
SELECT a.id, a.employee_id, IFNULL(e.emp_no, ''), IFNULL(e.name, ''), IFNULL(d.dept_name, ''),
       DATE_FORMAT(a.work_date, '%Y-%m-%d'),
       IFNULL(DATE_FORMAT(a.clock_in_time, '%Y-%m-%d %H:%i:%s'), ''),
       IFNULL(DATE_FORMAT(a.clock_out_time, '%Y-%m-%d %H:%i:%s'), ''),
       a.late_minutes, a.early_minutes, a.status, IFNULL(a.remark, '')
FROM hr_attendance a
LEFT JOIN hr_employee e ON a.employee_id = e.id
LEFT JOIN hr_department d ON e.dept_id = d.id
WHERE a.employee_id = ${empId} AND a.work_date = CURDATE()
LIMIT 1
"""
    let rows = queryRows(sql)
    if (rows.size == 0) {
        return "null"
    }
    return attendanceRowToJson(rows[0])
}

public func handleAttendanceClockIn(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            if (u.employeeId <= 0) {
                sendErr(ctx, 400, 400, "当前账号未绑定员工档案")
                return
            }
            let existing = queryRows("SELECT id, IFNULL(DATE_FORMAT(clock_in_time, '%Y-%m-%d %H:%i:%s'), '') FROM hr_attendance WHERE employee_id = ${u.employeeId} AND work_date = CURDATE() LIMIT 1")
            if (existing.size > 0 && !existing[0][1].isEmpty()) {
                sendErr(ctx, 400, 400, "今日已完成上班打卡（${existing[0][1]}）")
                return
            }
            let lateMins = querySingleInt("SELECT GREATEST(0, TIMESTAMPDIFF(MINUTE, CONCAT(CURDATE(), ' 09:00:00'), NOW()))", 0)
            let status = if (lateMins > 0) { "LATE" } else { "NORMAL" }
            if (existing.size == 0) {
                executeSql("INSERT INTO hr_attendance (employee_id, work_date, clock_in_time, late_minutes, early_minutes, status) VALUES (${u.employeeId}, CURDATE(), NOW(), ${lateMins}, 0, ${sqlStr(status)})")
            } else {
                executeSql("UPDATE hr_attendance SET clock_in_time = NOW(), late_minutes = ${lateMins}, status = ${sqlStr(status)} WHERE id = ${existing[0][0]}")
            }
            sendOk(ctx, getTodayAttendanceJson(u.employeeId))
    }
}

public func handleAttendanceClockOut(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            if (u.employeeId <= 0) {
                sendErr(ctx, 400, 400, "当前账号未绑定员工档案")
                return
            }
            let earlyMins = querySingleInt("SELECT GREATEST(0, TIMESTAMPDIFF(MINUTE, NOW(), CONCAT(CURDATE(), ' 18:00:00')))", 0)
            let existing = queryRows("SELECT id, late_minutes FROM hr_attendance WHERE employee_id = ${u.employeeId} AND work_date = CURDATE() LIMIT 1")
            if (existing.size == 0) {
                let status = if (earlyMins > 0) { "EARLY_LEAVE" } else { "NORMAL" }
                executeSql("INSERT INTO hr_attendance (employee_id, work_date, clock_out_time, late_minutes, early_minutes, status) VALUES (${u.employeeId}, CURDATE(), NOW(), 0, ${earlyMins}, ${sqlStr(status)})")
            } else {
                let lateMins = Int64.tryParse(existing[0][1]) ?? 0
                let status = if (lateMins > 0 && earlyMins > 0) {
                    "LATE_AND_EARLY"
                } else if (lateMins > 0) {
                    "LATE"
                } else if (earlyMins > 0) {
                    "EARLY_LEAVE"
                } else {
                    "NORMAL"
                }
                executeSql("UPDATE hr_attendance SET clock_out_time = NOW(), early_minutes = ${earlyMins}, status = ${sqlStr(status)} WHERE id = ${existing[0][0]}")
            }
            sendOk(ctx, getTodayAttendanceJson(u.employeeId))
    }
}

public func handleAttendanceToday(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            if (u.employeeId <= 0) {
                sendOk(ctx, "null")
                return
            }
            sendOk(ctx, getTodayAttendanceJson(u.employeeId))
    }
}

public func handleAttendanceMy(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            var month = getQueryStr(ctx, "month", "").trimAscii()
            if (month.isEmpty()) {
                month = querySingleValue("SELECT DATE_FORMAT(CURDATE(), '%Y-%m')")
            }
            let sql = """
SELECT a.id, a.employee_id, IFNULL(e.emp_no, ''), IFNULL(e.name, ''), IFNULL(d.dept_name, ''),
       DATE_FORMAT(a.work_date, '%Y-%m-%d'),
       IFNULL(DATE_FORMAT(a.clock_in_time, '%Y-%m-%d %H:%i:%s'), ''),
       IFNULL(DATE_FORMAT(a.clock_out_time, '%Y-%m-%d %H:%i:%s'), ''),
       a.late_minutes, a.early_minutes, a.status, IFNULL(a.remark, '')
FROM hr_attendance a
LEFT JOIN hr_employee e ON a.employee_id = e.id
LEFT JOIN hr_department d ON e.dept_id = d.id
WHERE a.employee_id = ${u.employeeId} AND DATE_FORMAT(a.work_date, '%Y-%m') = ${sqlStr(month)}
ORDER BY a.work_date DESC
"""
            let rows = queryRows(sql)
            let list = ArrayList<String>()
            var lateCnt: Int64 = 0
            var earlyCnt: Int64 = 0
            for (r in rows) {
                list.add(attendanceRowToJson(r))
                let lm = Int64.tryParse(r[8]) ?? 0
                let em = Int64.tryParse(r[9]) ?? 0
                if (lm > 0 || r[10] == "LATE" || r[10] == "LATE_AND_EARLY") { lateCnt += 1 }
                if (em > 0 || r[10] == "EARLY_LEAVE" || r[10] == "LATE_AND_EARLY") { earlyCnt += 1 }
            }
            let leaveDays = querySingleValue("SELECT IFNULL(SUM(duration), 0.0) FROM hr_leave_overtime WHERE employee_id = ${u.employeeId} AND category = 'LEAVE' AND status = 'APPROVED' AND DATE_FORMAT(start_time, '%Y-%m') = ${sqlStr(month)}")
            let otHours = querySingleValue("SELECT IFNULL(SUM(duration), 0.0) FROM hr_leave_overtime WHERE employee_id = ${u.employeeId} AND category = 'OVERTIME' AND status = 'APPROVED' AND DATE_FORMAT(start_time, '%Y-%m') = ${sqlStr(month)}")
            let summary = "{" +
                "\"month\":${jsonStr(month)}," +
                "\"shouldAttendDays\":22," +
                "\"actualAttendDays\":${rows.size}," +
                "\"lateCount\":${lateCnt}," +
                "\"earlyCount\":${earlyCnt}," +
                "\"leaveDays\":${if (leaveDays.isEmpty()) { "0.0" } else { leaveDays }}," +
                "\"overtimeHours\":${if (otHours.isEmpty()) { "0.0" } else { otHours }}" +
            "}"
            let listJson = "[" + String.join(list.toArray(), delimiter: ",") + "]"
            sendOk(ctx, "{\"list\":${listJson},\"summary\":${summary}}")
    }
}

public func handleAttendanceList(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR", "MANAGER"])) {
        case None => return
        case Some(u) =>
            let month = getQueryStr(ctx, "month", "").trimAscii()
            let workDate = getQueryStr(ctx, "date", "").trimAscii()
            let reqDeptId = getQueryInt(ctx, "deptId", 0)
            let status = getQueryStr(ctx, "status", "").trimAscii()
            let keyword = getQueryStr(ctx, "keyword", "").trimAscii()
            var page = getQueryInt(ctx, "page", 1)
            var pageSize = getQueryInt(ctx, "pageSize", 10)
            if (page < 1) { page = 1 }
            if (pageSize < 1 || pageSize > 100) { pageSize = 10 }

            let conds = ArrayList<String>()
            conds.add("1=1")
            if (u.role == "MANAGER") {
                conds.add("e.dept_id = ${getUserDeptId(u)}")
            } else if (reqDeptId > 0) {
                conds.add("e.dept_id = ${reqDeptId}")
            }
            if (!month.isEmpty()) {
                conds.add("DATE_FORMAT(a.work_date, '%Y-%m') = ${sqlStr(month)}")
            }
            if (workDate.size == 10) {
                conds.add("a.work_date = ${sqlStr(workDate)}")
            }
            if (!status.isEmpty()) {
                conds.add("a.status = ${sqlStr(status)}")
            }
            if (!keyword.isEmpty()) {
                let kw = sqlStr("%" + keyword + "%")
                conds.add("(e.name LIKE ${kw} OR e.emp_no LIKE ${kw})")
            }
            let whereSql = "WHERE " + String.join(conds.toArray(), delimiter: " AND ")
            let total = querySingleInt("SELECT COUNT(*) FROM hr_attendance a LEFT JOIN hr_employee e ON a.employee_id = e.id ${whereSql}", 0)
            let offset = (page - 1) * pageSize
            let sql = """
SELECT a.id, a.employee_id, IFNULL(e.emp_no, ''), IFNULL(e.name, ''), IFNULL(d.dept_name, ''),
       DATE_FORMAT(a.work_date, '%Y-%m-%d'),
       IFNULL(DATE_FORMAT(a.clock_in_time, '%Y-%m-%d %H:%i:%s'), ''),
       IFNULL(DATE_FORMAT(a.clock_out_time, '%Y-%m-%d %H:%i:%s'), ''),
       a.late_minutes, a.early_minutes, a.status, IFNULL(a.remark, '')
FROM hr_attendance a
LEFT JOIN hr_employee e ON a.employee_id = e.id
LEFT JOIN hr_department d ON e.dept_id = d.id
${whereSql}
ORDER BY a.work_date DESC, a.id DESC
LIMIT ${pageSize} OFFSET ${offset}
"""
            let rows = queryRows(sql)
            let list = ArrayList<String>()
            for (r in rows) {
                list.add(attendanceRowToJson(r))
            }
            sendPage(ctx, "[" + String.join(list.toArray(), delimiter: ",") + "]", total, page, pageSize)
    }
}

public func handleAttendanceUpdate(ctx: HttpContext, attId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    // 补卡接口只更新请求体里出现的字段，避免 HR 仅改备注时把迟到/早退分钟数清零，
                    // 这两个字段直接参与月度薪资的考勤扣款计算。
                    let fixRows = queryRows("SELECT status, late_minutes, early_minutes, IFNULL(remark, '') FROM hr_attendance WHERE id = ${attId} LIMIT 1")
                    if (fixRows.size == 0) {
                        sendErr(ctx, 404, 404, "考勤记录不存在")
                        return
                    }
                    let cur = fixRows[0]
                    var status = cur[0]
                    var lateMinutes = Int64.tryParse(cur[1]) ?? 0
                    var earlyMinutes = Int64.tryParse(cur[2]) ?? 0
                    var remark = cur[3]
                    if (hasJsonKey(obj, "status")) { status = getJsonStr(obj, "status", status).trimAscii() }
                    if (hasJsonKey(obj, "lateMinutes")) { lateMinutes = getJsonInt(obj, "lateMinutes", lateMinutes) }
                    if (hasJsonKey(obj, "earlyMinutes")) { earlyMinutes = getJsonInt(obj, "earlyMinutes", earlyMinutes) }
                    if (hasJsonKey(obj, "remark")) { remark = getJsonStr(obj, "remark", remark).trimAscii() }
                    let allowedStatus = ["NORMAL", "LATE", "EARLY_LEAVE", "LATE_AND_EARLY", "LEAVE", "ABSENT"]
                    var statusOk = false
                    for (s in allowedStatus) {
                        if (status == s) { statusOk = true }
                    }
                    if (!statusOk) {
                        sendErr(ctx, 400, 400, "考勤状态取值非法（仅支持 NORMAL/LATE/EARLY_LEAVE/LATE_AND_EARLY/LEAVE/ABSENT）")
                        return
                    }
                    if (lateMinutes < 0 || earlyMinutes < 0) {
                        sendErr(ctx, 400, 400, "迟到/早退分钟数不能为负数")
                        return
                    }
                    let sql = "UPDATE hr_attendance SET status=${sqlStr(status)}, late_minutes=${lateMinutes}, early_minutes=${earlyMinutes}, remark=${sqlNullableStr(remark)} WHERE id=${attId}"
                    if (!executeSql(sql)) {
                        sendErr(ctx, 500, 500, "考勤记录修正失败")
                        return
                    }
                    writeAuditLog(u, "考勤管理", "修正考勤", "修正考勤记录 ID=${attId}：状态=${status}，迟到=${lateMinutes}分，早退=${earlyMinutes}分，备注=${remark}")
                    sendOk(ctx, "null")
            }
    }
}
