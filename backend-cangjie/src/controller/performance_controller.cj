package hrms_backend.controller

import std.collection.*
import std.convert.*
import stdx.net.http.*
import hrms_backend.common.*
import hrms_backend.db.*
import hrms_backend.middleware.*
import hrms_backend.service.*

func mapPerformanceGrade(score: Float64): (String, Float64) {
    if (score >= 90.0) {
        return ("S", 1.20)
    } else if (score >= 80.0) {
        return ("A", 1.10)
    } else if (score >= 70.0) {
        return ("B", 1.00)
    } else if (score >= 60.0) {
        return ("C", 0.80)
    }
    return ("D", 0.50)
}

func perfRowToJson(r: ArrayList<String>): String {
    return "{" +
        "\"id\":${r[0]}," +
        "\"cycleName\":${jsonStr(r[1])}," +
        "\"employeeId\":${r[2]}," +
        "\"empNo\":${jsonStr(r[3])}," +
        "\"empName\":${jsonStr(r[4])}," +
        "\"deptName\":${jsonStr(r[5])}," +
        "\"positionName\":${jsonStr(r[6])}," +
        "\"selfSummary\":${jsonStr(r[7])}," +
        "\"selfScore\":${if (r[8].isEmpty()) { "null" } else { r[8] }}," +
        "\"finalScore\":${if (r[9].isEmpty()) { "null" } else { r[9] }}," +
        "\"grade\":${jsonStr(r[10])}," +
        "\"bonusRatio\":${r[11]}," +
        "\"reviewerComment\":${jsonStr(r[12])}," +
        "\"status\":${jsonStr(r[13])}," +
        "\"updatedAt\":${jsonStr(r[14])}" +
    "}"
}

public func handlePerformanceInitCycle(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let cycleName = getJsonStr(obj, "cycleName", "").trimAscii()
                    if (cycleName.isEmpty()) {
                        sendErr(ctx, 400, 400, "考核周期名称不能为空（如 2026-Q4）")
                        return
                    }
                    let sql = """
INSERT IGNORE INTO hr_performance (cycle_name, employee_id, status)
SELECT ${sqlStr(cycleName)}, id, 'SELF_EVAL'
FROM hr_employee
WHERE status IN ('ACTIVE', 'PROBATION')
"""
                    executeSql(sql)
                    let cnt = querySingleInt("SELECT COUNT(*) FROM hr_performance WHERE cycle_name = ${sqlStr(cycleName)}", 0)
                    writeAuditLog(u, "绩效管理", "初始化考核周期", "初始化周期 ${cycleName}，当前周期人数=${cnt}")
                    sendOk(ctx, "{\"cycleName\":${jsonStr(cycleName)},\"count\":${cnt}}")
            }
    }
}

public func handlePerformanceList(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            let cycleName = getQueryStr(ctx, "cycleName", "").trimAscii()
            let status = getQueryStr(ctx, "status", "").trimAscii()
            let reqDeptId = getQueryInt(ctx, "deptId", 0)
            let conds = ArrayList<String>()
            conds.add("1=1")
            if (u.role == "EMPLOYEE") {
                conds.add("p.employee_id = ${u.employeeId}")
            } else if (u.role == "MANAGER") {
                conds.add("e.dept_id = ${getUserDeptId(u)}")
            } else if (reqDeptId > 0) {
                conds.add("e.dept_id = ${reqDeptId}")
            }
            if (!cycleName.isEmpty()) {
                conds.add("p.cycle_name = ${sqlStr(cycleName)}")
            }
            if (!status.isEmpty()) {
                conds.add("p.status = ${sqlStr(status)}")
            }
            let whereSql = "WHERE " + String.join(conds.toArray(), delimiter: " AND ")
            let sql = """
SELECT p.id, p.cycle_name, p.employee_id, IFNULL(e.emp_no, ''), IFNULL(e.name, ''),
       IFNULL(d.dept_name, ''), IFNULL(e.position_name, ''),
       IFNULL(p.self_summary, ''), IFNULL(CAST(p.self_score AS CHAR), ''),
       IFNULL(CAST(p.final_score AS CHAR), ''), IFNULL(p.grade, ''), p.bonus_ratio,
       IFNULL(p.reviewer_comment, ''), p.status, DATE_FORMAT(p.updated_at, '%Y-%m-%d %H:%i:%s')
FROM hr_performance p
LEFT JOIN hr_employee e ON p.employee_id = e.id
LEFT JOIN hr_department d ON e.dept_id = d.id
${whereSql}
ORDER BY p.cycle_name DESC, p.id DESC
"""
            let rows = queryRows(sql)
            let list = ArrayList<String>()
            for (r in rows) {
                list.add(perfRowToJson(r))
            }
            sendOk(ctx, "[" + String.join(list.toArray(), delimiter: ",") + "]")
    }
}

public func handlePerformanceSelfEval(ctx: HttpContext, perfId: Int64): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            let ownerEmpId = querySingleInt("SELECT employee_id FROM hr_performance WHERE id = ${perfId}", 0)
            if (ownerEmpId <= 0) {
                sendErr(ctx, 404, 404, "绩效考核单不存在")
                return
            }
            if (ownerEmpId != u.employeeId && u.role != "ADMIN" && u.role != "HR") {
                sendErr(ctx, 403, 403, "仅可提交本人绩效自评")
                return
            }
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let selfSummary = getJsonStr(obj, "selfSummary", "").trimAscii()
                    let selfScore = getJsonFloat(obj, "selfScore", -1.0)
                    if (selfSummary.isEmpty() || selfScore < 0.0 || selfScore > 100.0) {
                        sendErr(ctx, 400, 400, "自评总结不能为空且自评分必须在 0-100 之间")
                        return
                    }
                    executeSql("UPDATE hr_performance SET self_summary=${sqlStr(selfSummary)}, self_score=${formatNum2(selfScore)}, status='REVIEWING' WHERE id=${perfId}")
                    sendOk(ctx, "{\"id\":${perfId},\"status\":\"REVIEWING\"}")
            }
    }
}

public func handlePerformanceReview(ctx: HttpContext, perfId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR", "MANAGER"])) {
        case None => return
        case Some(u) =>
            let rows = queryRows("SELECT p.employee_id, e.dept_id, e.name, p.cycle_name FROM hr_performance p LEFT JOIN hr_employee e ON p.employee_id = e.id WHERE p.id = ${perfId} LIMIT 1")
            if (rows.size == 0) {
                sendErr(ctx, 404, 404, "绩效考核单不存在")
                return
            }
            let empDept = Int64.tryParse(rows[0][1]) ?? 0
            if (u.role == "MANAGER" && empDept != getUserDeptId(u)) {
                sendErr(ctx, 403, 403, "部门主管仅可评定本部门员工绩效")
                return
            }
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let finalScore = getJsonFloat(obj, "finalScore", -1.0)
                    let comment = getJsonStr(obj, "reviewerComment", "").trimAscii()
                    if (finalScore < 0.0 || finalScore > 100.0) {
                        sendErr(ctx, 400, 400, "终评分数必须在 0-100 之间")
                        return
                    }
                    let (grade, ratio) = mapPerformanceGrade(finalScore)
                    let sql = "UPDATE hr_performance SET final_score=${formatNum2(finalScore)}, grade=${sqlStr(grade)}, bonus_ratio=${formatNum2(ratio)}, reviewer_id=${u.userId}, reviewer_comment=${sqlNullableStr(comment)}, status='COMPLETED' WHERE id=${perfId}"
                    executeSql(sql)
                    writeAuditLog(u, "绩效管理", "绩效评定", "评定 ${rows[0][2]} (${rows[0][3]})：分数=${formatNum2(finalScore)}，等级=${grade}，系数=${formatNum2(ratio)}")
                    sendOk(ctx, "{\"id\":${perfId},\"grade\":${jsonStr(grade)},\"bonusRatio\":${formatNum2(ratio)},\"status\":\"COMPLETED\"}")
            }
    }
}
