package hrms_backend.controller

import std.collection.*
import std.convert.*
import stdx.net.http.*
import hrms_backend.common.*
import hrms_backend.db.*
import hrms_backend.middleware.*
import hrms_backend.service.*

// P2.4 月度汇总的「应出勤天数」。
// 与 handleAttendanceMy 里既有的 22 保持同一口径：本项目没有排班/工作日历表，
// 因此按「每周 5 天 × 4.4 周」的固定值统计，不随法定节假日变化（见 FOLLOWUP_PLAN 第十节 L-ATT-1）。
let attShouldAttendDays: Int64 = 22

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
            var attendCnt: Int64 = 0
            for (r in rows) {
                list.add(attendanceRowToJson(r))
                // 判定逻辑与 P2.4 月度汇总共用同一组纯函数，避免「我的考勤」和
                // 「月度汇总导出」对同一条记录给出不同的迟到/早退结论。
                let lm = Int64.tryParse(r[8]) ?? 0
                let em = Int64.tryParse(r[9]) ?? 0
                if (attMonthIsLate(lm, r[10])) { lateCnt += 1 }
                if (attMonthIsEarly(em, r[10])) { earlyCnt += 1 }
                if (r[10] != "ABSENT") { attendCnt += 1 }
            }
            let leaveDays = querySingleValue("SELECT IFNULL(SUM(duration), 0.0) FROM hr_leave_overtime WHERE employee_id = ${u.employeeId} AND category = 'LEAVE' AND status = 'APPROVED' AND DATE_FORMAT(start_time, '%Y-%m') = ${sqlStr(month)}")
            let otHours = querySingleValue("SELECT IFNULL(SUM(duration), 0.0) FROM hr_leave_overtime WHERE employee_id = ${u.employeeId} AND category = 'OVERTIME' AND status = 'APPROVED' AND DATE_FORMAT(start_time, '%Y-%m') = ${sqlStr(month)}")
            // actualAttendDays 用 attendCnt 而不是 rows.size：
            // 缺勤（ABSENT）当天有记录，但不算做出勤天数，口径与月度汇总一致。
            let summary = "{" +
                "\"month\":${jsonStr(month)}," +
                "\"shouldAttendDays\":${attShouldAttendDays}," +
                "\"actualAttendDays\":${attendCnt}," +
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
                    let status = getJsonStr(obj, "status", "NORMAL").trimAscii()
                    let lateMinutes = getJsonInt(obj, "lateMinutes", 0)
                    let earlyMinutes = getJsonInt(obj, "earlyMinutes", 0)
                    let remark = getJsonStr(obj, "remark", "").trimAscii()
                    let sql = "UPDATE hr_attendance SET status=${sqlStr(status)}, late_minutes=${lateMinutes}, early_minutes=${earlyMinutes}, remark=${sqlNullableStr(remark)} WHERE id=${attId}"
                    executeSql(sql)
                    writeAuditLog(u, "考勤管理", "修正考勤", "修正考勤记录 ID=${attId}：状态=${status}，迟到=${lateMinutes}分，早退=${earlyMinutes}分，备注=${remark}")
                    sendOk(ctx, "null")
            }
    }
}

// ===================== P2.4 考勤月度汇总 =====================
// 下面 5 个函数都不碰数据库，是为了能被 attendance_controller_test.cj 直接单测：
// 「页面数字」和「导出 CSV 数字」必须来自同一份计算，否则验收项「报表与页面一致」无从谈起。

// 迟到判定：分钟数 > 0 或状态标记为迟到。
// 与 handleAttendanceMy 完全一致（薪酬扣款口径只看 late_minutes > 0，两者不同，见 FOLLOWUP_PLAN 第十节 L-ATT-2）。
func attMonthIsLate(lateMinutes: Int64, status: String): Bool {
    return lateMinutes > 0 || status == "LATE" || status == "LATE_AND_EARLY"
}

// 早退判定：与 attMonthIsLate 对称。
func attMonthIsEarly(earlyMinutes: Int64, status: String): Bool {
    return earlyMinutes > 0 || status == "EARLY_LEAVE" || status == "LATE_AND_EARLY"
}

// 出勤率（百分数，两位小数）。
// 应出勤 <= 0 时返回 0 而不是抛异常：新员工入职能不能满月是常态，报表不该因为除零而整页 500。
// 超过 100% 一律截到 100%：本项目没有排班表，员工在周末补打卡会让实际天数 > 22，
// 报表里出现 109.09% 只会让读者怀疑数据错了，所以按行业惯例封顶。
func attendanceRatePercent(attendDays: Int64, shouldDays: Int64): Float64 {
    if (shouldDays <= 0) {
        return 0.0
    }
    let rate = Float64(attendDays) * 100.0 / Float64(shouldDays)
    if (rate < 0.0) {
        return 0.0
    }
    if (rate > 100.0) {
        return 100.0
    }
    return round2(rate)
}

// DB 返回的数值文本安全化：空串（NULL）或非法数字一律回退到 defaultText。
// 拼 JSON 时一个空串会让整个响应体变成非法 JSON，前端直接白屏，比返回 0 严重得多。
// 这里刻意不用 Float64.tryParse 做校验：它会接受 1e5 / NaN / Infinity 这些
// JSON.parse 侧直接报错的写法，所以改成逐字节白名单（可选负号 + 数字 + 至多一个小数点）。
func attMonthSafeNum(raw: String, defaultText: String): String {
    let s = raw.trimAscii()
    if (s.isEmpty()) {
        return defaultText
    }
    let bytes = s.toArray()
    let zero: UInt8 = 0x30
    let nine: UInt8 = 0x39
    let dot: UInt8 = 0x2E
    let minus: UInt8 = 0x2D
    var i: Int64 = 0
    if (bytes[0] == minus) {
        if (bytes.size == 1) {
            return defaultText
        }
        i = 1
    }
    var dots: Int64 = 0
    var digits: Int64 = 0
    while (i < bytes.size) {
        let b = bytes[i]
        if (b >= zero && b <= nine) {
            digits += 1
        } else if (b == dot) {
            dots += 1
            if (dots > 1) {
                return defaultText
            }
        } else {
            return defaultText
        }
        i = i + 1
    }
    if (digits == 0) {
        return defaultText
    }
    return s
}

// 严格校验 'YYYY-MM'：长度 7、第 5 位是 '-'、数字位全为 0-9、年首位为 2、月份为 01-12。
// 这个参数会被直接拼进 DATE_FORMAT 的比较值，校验通过后可以确定只剩数字和 '-'，
// 因此不需要再走 sqlStr 的转义路径；校验失败则回退到当前月，不报错。
func isValidYearMonth(s: String): Bool {
    let bytes = s.toArray()
    if (bytes.size != 7) {
        return false
    }
    let dash: UInt8 = 0x2D
    let zero: UInt8 = 0x30
    let one: UInt8 = 0x31
    let two: UInt8 = 0x32
    let nine: UInt8 = 0x39
    if (bytes[4] != dash) {
        return false
    }
    if (bytes[0] != two) {
        return false
    }
    let digitIdx = ArrayList<Int64>()
    digitIdx.add(1)
    digitIdx.add(2)
    digitIdx.add(3)
    digitIdx.add(5)
    digitIdx.add(6)
    for (i in digitIdx) {
        let b = bytes[i]
        if (b < zero || b > nine) {
            return false
        }
    }
    // 月份十位只能是 0 或 1
    if (bytes[5] == zero) {
        return bytes[6] != zero
    }
    if (bytes[5] == one) {
        return bytes[6] >= zero && bytes[6] <= two
    }
    return false
}

// 11 列 -> 单人月度 JSON。列顺序与 handleAttendanceMonthlySummary 的 SELECT 一一对应。
func attMonthlyRowToJson(r: ArrayList<String>): String {
    let attendDays = Int64.tryParse(attMonthSafeNum(r[4], "0")) ?? 0
    let rate = attendanceRatePercent(attendDays, attShouldAttendDays)
    return "{" +
        "\"employeeId\":${attMonthSafeNum(r[0], "0")}," +
        "\"empNo\":${jsonStr(r[1])}," +
        "\"empName\":${jsonStr(r[2])}," +
        "\"deptName\":${jsonStr(r[3])}," +
        "\"attendDays\":${attendDays}," +
        "\"lateCount\":${Int64.tryParse(attMonthSafeNum(r[5], "0")) ?? 0}," +
        "\"earlyCount\":${Int64.tryParse(attMonthSafeNum(r[6], "0")) ?? 0}," +
        "\"lateMinutes\":${Int64.tryParse(attMonthSafeNum(r[7], "0")) ?? 0}," +
        "\"earlyMinutes\":${Int64.tryParse(attMonthSafeNum(r[8], "0")) ?? 0}," +
        "\"leaveDays\":${formatNum2(Float64.tryParse(attMonthSafeNum(r[9], "0")) ?? 0.0)}," +
        "\"overtimeHours\":${formatNum2(Float64.tryParse(attMonthSafeNum(r[10], "0")) ?? 0.0)}," +
        "\"attendanceRate\":${formatNum2(rate)}" +
    "}"
}

// 合计行：由已经算好的明细行累加而来，保证「合计 = 明细之和」这条最基本的报表约束。
// 整体出勤率按 headcount × 应出勤天数计算，而不是各人出勤率的算术平均，
// 后者会让人少的部门把整体数字拉偏。
func attMonthlyTotalsJson(rows: ArrayList<ArrayList<String>>): String {
    var headcount: Int64 = 0
    var attendDays: Int64 = 0
    var lateCount: Int64 = 0
    var earlyCount: Int64 = 0
    var lateMinutes: Int64 = 0
    var earlyMinutes: Int64 = 0
    var leaveDays: Float64 = 0.0
    var overtimeHours: Float64 = 0.0
    for (r in rows) {
        headcount += 1
        attendDays += Int64.tryParse(attMonthSafeNum(r[4], "0")) ?? 0
        lateCount += Int64.tryParse(attMonthSafeNum(r[5], "0")) ?? 0
        earlyCount += Int64.tryParse(attMonthSafeNum(r[6], "0")) ?? 0
        lateMinutes += Int64.tryParse(attMonthSafeNum(r[7], "0")) ?? 0
        earlyMinutes += Int64.tryParse(attMonthSafeNum(r[8], "0")) ?? 0
        leaveDays += Float64.tryParse(attMonthSafeNum(r[9], "0")) ?? 0.0
        overtimeHours += Float64.tryParse(attMonthSafeNum(r[10], "0")) ?? 0.0
    }
    let overallRate = attendanceRatePercent(attendDays, headcount * attShouldAttendDays)
    return "{" +
        "\"headcount\":${headcount}," +
        "\"shouldAttendDays\":${attShouldAttendDays}," +
        "\"actualAttendDays\":${attendDays}," +
        "\"lateCount\":${lateCount}," +
        "\"earlyCount\":${earlyCount}," +
        "\"lateMinutes\":${lateMinutes}," +
        "\"earlyMinutes\":${earlyMinutes}," +
        "\"leaveDays\":${formatNum2(round2(leaveDays))}," +
        "\"overtimeHours\":${formatNum2(round2(overtimeHours))}," +
        "\"attendanceRate\":${formatNum2(overallRate)}" +
    "}"
}

public func handleAttendanceMonthlySummary(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR", "MANAGER"])) {
        case None => return
        case Some(u) =>
            var month = getQueryStr(ctx, "month", "").trimAscii()
            if (!isValidYearMonth(month)) {
                month = querySingleValue("SELECT DATE_FORMAT(CURDATE(), '%Y-%m')")
            }
            let reqDeptId = getQueryInt(ctx, "deptId", 0)

            let conds = ArrayList<String>()
            conds.add("e.status <> 'RESIGNED'")
            if (u.role == "MANAGER") {
                conds.add("e.dept_id = ${getUserDeptId(u)}")
            } else if (reqDeptId > 0) {
                conds.add("e.dept_id = ${reqDeptId}")
            }
            let whereSql = "WHERE " + String.join(conds.toArray(), delimiter: " AND ")

            // 主表必须是 hr_employee 而不是 hr_attendance：
            // 整月没打过一次卡的员工作为「0 天出勤」出现在汇总里才是有意义的，
            // 以考勤表为主表会把这类人整行隐藏掉，出勤率反而虚高。
            // 请假/加班先在派生表里按人聚合再 LEFT JOIN，这样外层 GROUP BY 只需 MAX() 取出唯一值，
            // 既避开 ONLY_FULL_GROUP_BY 的坑，也不需要仓颉侧再维护一份按 employee_id 合并的表
            //（本项目 src 里没有用到 HashMap，聚合尽量交给 SQL）。
            let sql = """
SELECT e.id, e.emp_no, e.name, IFNULL(d.dept_name, ''),
       SUM(CASE WHEN a.id IS NOT NULL AND a.status <> 'ABSENT' THEN 1 ELSE 0 END),
       SUM(CASE WHEN a.id IS NOT NULL AND (IFNULL(a.late_minutes, 0) > 0 OR a.status IN ('LATE', 'LATE_AND_EARLY')) THEN 1 ELSE 0 END),
       SUM(CASE WHEN a.id IS NOT NULL AND (IFNULL(a.early_minutes, 0) > 0 OR a.status IN ('EARLY_LEAVE', 'LATE_AND_EARLY')) THEN 1 ELSE 0 END),
       SUM(IFNULL(a.late_minutes, 0)),
       SUM(IFNULL(a.early_minutes, 0)),
       IFNULL(MAX(lo.leave_days), 0),
       IFNULL(MAX(lo.overtime_hours), 0)
FROM hr_employee e
LEFT JOIN hr_department d ON e.dept_id = d.id
LEFT JOIN hr_attendance a ON a.employee_id = e.id AND DATE_FORMAT(a.work_date, '%Y-%m') = ${sqlStr(month)}
LEFT JOIN (
    SELECT employee_id,
           SUM(CASE WHEN category = 'LEAVE' THEN duration ELSE 0 END) AS leave_days,
           SUM(CASE WHEN category = 'OVERTIME' THEN duration ELSE 0 END) AS overtime_hours
    FROM hr_leave_overtime
    WHERE status = 'APPROVED' AND DATE_FORMAT(start_time, '%Y-%m') = ${sqlStr(month)}
    GROUP BY employee_id
) lo ON lo.employee_id = e.id
${whereSql}
GROUP BY e.id, e.emp_no, e.name, d.dept_name
ORDER BY d.dept_name ASC, e.emp_no ASC
"""
            let rows = queryRows(sql)
            let list = ArrayList<String>()
            for (r in rows) {
                list.add(attMonthlyRowToJson(r))
            }
            let summary = attMonthlyTotalsJson(rows)
            sendOk(ctx, "{\"month\":${jsonStr(month)},\"shouldAttendDays\":${attShouldAttendDays},\"summary\":${summary},\"list\":[" + String.join(list.toArray(), delimiter: ",") + "]}")
    }
}
