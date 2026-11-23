package hrms_backend.controller

import std.collection.*
import std.convert.*
import stdx.net.http.*
import hrms_backend.common.*
import hrms_backend.db.*
import hrms_backend.middleware.*
import hrms_backend.service.*

func candidateRowToJson(r: ArrayList<String>): String {
    return "{" +
        "\"id\":${r[0]}," +
        "\"name\":${jsonStr(r[1])}," +
        "\"gender\":${r[2]}," +
        "\"phone\":${jsonStr(r[3])}," +
        "\"email\":${jsonStr(r[4])}," +
        "\"targetDeptId\":${r[5]}," +
        "\"targetDeptName\":${jsonStr(r[6])}," +
        "\"targetPosition\":${jsonStr(r[7])}," +
        "\"expectedSalary\":${r[8]}," +
        "\"source\":${jsonStr(r[9])}," +
        "\"stage\":${jsonStr(r[10])}," +
        "\"interviewNotes\":${jsonStr(r[11])}," +
        "\"createdAt\":${jsonStr(r[12])}" +
    "}"
}

public func handleCandidateList(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(_) =>
            let stage = getQueryStr(ctx, "stage", "").trimAscii()
            let keyword = getQueryStr(ctx, "keyword", "").trimAscii()
            let conds = ArrayList<String>()
            conds.add("1=1")
            if (!stage.isEmpty()) {
                conds.add("c.stage = ${sqlStr(stage)}")
            }
            if (!keyword.isEmpty()) {
                let kw = sqlStr("%" + keyword + "%")
                conds.add("(c.name LIKE ${kw} OR c.phone LIKE ${kw} OR c.target_position LIKE ${kw})")
            }
            let whereSql = "WHERE " + String.join(conds.toArray(), delimiter: " AND ")
            let sql = """
SELECT c.id, c.name, c.gender, c.phone, IFNULL(c.email, ''), c.target_dept_id,
       IFNULL(d.dept_name, ''), c.target_position, c.expected_salary, IFNULL(c.source, ''),
       c.stage, IFNULL(c.interview_notes, ''), DATE_FORMAT(c.created_at, '%Y-%m-%d %H:%i:%s')
FROM hr_recruitment_candidate c
LEFT JOIN hr_department d ON c.target_dept_id = d.id
${whereSql}
ORDER BY c.id DESC
"""
            let rows = queryRows(sql)
            let list = ArrayList<String>()
            for (r in rows) {
                list.add(candidateRowToJson(r))
            }
            sendOk(ctx, "[" + String.join(list.toArray(), delimiter: ",") + "]")
    }
}

public func handleCandidateCreate(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let name = getJsonStr(obj, "name", "").trimAscii()
                    let gender = getJsonInt(obj, "gender", 1)
                    let phone = getJsonStr(obj, "phone", "").trimAscii()
                    let email = getJsonStr(obj, "email", "").trimAscii()
                    let targetDeptId = getJsonInt(obj, "targetDeptId", 0)
                    let targetPos = getJsonStr(obj, "targetPosition", "").trimAscii()
                    let expectedSalary = getJsonFloat(obj, "expectedSalary", 12000.0)
                    let source = getJsonStr(obj, "source", "BOSS直聘").trimAscii()
                    let stage = getJsonStr(obj, "stage", "NEW").trimAscii()
                    let notes = getJsonStr(obj, "interviewNotes", "").trimAscii()
                    if (name.isEmpty() || phone.isEmpty() || targetDeptId <= 0 || targetPos.isEmpty()) {
                        sendErr(ctx, 400, 400, "候选人姓名、手机号、目标部门与应聘岗位必填")
                        return
                    }
                    let sql = "INSERT INTO hr_recruitment_candidate (name, gender, phone, email, target_dept_id, target_position, expected_salary, source, stage, interview_notes) VALUES (${sqlStr(name)}, ${gender}, ${sqlStr(phone)}, ${sqlNullableStr(email)}, ${targetDeptId}, ${sqlStr(targetPos)}, ${formatNum2(expectedSalary)}, ${sqlStr(source)}, ${sqlStr(stage)}, ${sqlNullableStr(notes)})"
                    let newId = insertAndGetId(sql)
                    writeAuditLog(u, "招聘管理", "新增候选人", "新增候选人：${name} 应聘 ${targetPos}")
                    sendOk(ctx, "{\"id\":${newId}}")
            }
    }
}

public func handleCandidateUpdate(ctx: HttpContext, candId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let name = getJsonStr(obj, "name", "").trimAscii()
                    let gender = getJsonInt(obj, "gender", 1)
                    let phone = getJsonStr(obj, "phone", "").trimAscii()
                    let email = getJsonStr(obj, "email", "").trimAscii()
                    let targetDeptId = getJsonInt(obj, "targetDeptId", 0)
                    let targetPos = getJsonStr(obj, "targetPosition", "").trimAscii()
                    let expectedSalary = getJsonFloat(obj, "expectedSalary", 12000.0)
                    let source = getJsonStr(obj, "source", "BOSS直聘").trimAscii()
                    let stage = getJsonStr(obj, "stage", "NEW").trimAscii()
                    let notes = getJsonStr(obj, "interviewNotes", "").trimAscii()
                    let sets = ArrayList<String>()
                    if (!name.isEmpty()) { sets.add("name=${sqlStr(name)}") }
                    if (gender == 1 || gender == 2) { sets.add("gender=${gender}") }
                    if (!phone.isEmpty()) { sets.add("phone=${sqlStr(phone)}") }
                    sets.add("email=${sqlNullableStr(email)}")
                    if (targetDeptId > 0) { sets.add("target_dept_id=${targetDeptId}") }
                    if (!targetPos.isEmpty()) { sets.add("target_position=${sqlStr(targetPos)}") }
                    if (expectedSalary > 0.0) { sets.add("expected_salary=${formatNum2(expectedSalary)}") }
                    if (!source.isEmpty()) { sets.add("source=${sqlStr(source)}") }
                    if (!stage.isEmpty()) { sets.add("stage=${sqlStr(stage)}") }
                    sets.add("interview_notes=${sqlNullableStr(notes)}")
                    executeSql("UPDATE hr_recruitment_candidate SET " + String.join(sets.toArray(), delimiter: ", ") + " WHERE id=${candId}")
                    writeAuditLog(u, "招聘管理", "更新候选人", "更新候选人 ID=${candId} 阶段=${stage}")
                    sendOk(ctx, "{\"id\":${candId}}")
            }
    }
}

public func handleCandidateHire(ctx: HttpContext, candId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            let rows = queryRows("SELECT name, gender, phone, IFNULL(email, ''), target_dept_id, target_position, expected_salary, stage FROM hr_recruitment_candidate WHERE id = ${candId} LIMIT 1")
            if (rows.size == 0) {
                sendErr(ctx, 404, 404, "候选人不存在")
                return
            }
            let c = rows[0]
            if (c[7] == "HIRED") {
                sendErr(ctx, 400, 400, "该候选人已办理过入职")
                return
            }
            let body = readRequestBody(ctx)
            var salary = Float64.tryParse(c[6]) ?? 10000.0
            var hireDate = querySingleValue("SELECT CURDATE()")
            var status = "PROBATION"
            var reqUsername = ""
            if (let Some(obj) <- parseJsonObject(body)) {
                let s = getJsonFloat(obj, "baseSalary", 0.0)
                if (s > 0.0) { salary = s }
                let hd = getJsonStr(obj, "hireDate", "").trimAscii()
                if (!hd.isEmpty()) { hireDate = hd }
                let st = getJsonStr(obj, "status", "").trimAscii()
                if (!st.isEmpty()) { status = st }
                reqUsername = getJsonStr(obj, "username", "").trimAscii()
            }
            let contractEndDate = querySingleValue("SELECT DATE_ADD(${sqlStr(hireDate)}, INTERVAL 3 YEAR)")
            let empNo = generateNextEmpNo()
            let posIdStr = querySingleValue("SELECT IFNULL((SELECT id FROM hr_position WHERE dept_id = ${c[4]} AND pos_name = ${sqlStr(c[5])} LIMIT 1), 0)")
            let posIdVal = Int64.tryParse(posIdStr) ?? 0
            let posIdSql = if (posIdVal > 0) { "${posIdVal}" } else { "NULL" }

            let insertEmpSql = """
INSERT INTO hr_employee (emp_no, name, gender, phone, email, dept_id, position_id, position_name, base_salary, annual_leave_balance, hire_date, contract_end_date, status)
VALUES (${sqlStr(empNo)}, ${sqlStr(c[0])}, ${c[1]}, ${sqlStr(c[2])}, ${sqlNullableStr(c[3])}, ${c[4]}, ${posIdSql}, ${sqlStr(c[5])}, ${formatNum2(salary)}, 5.0, ${sqlStr(hireDate)}, ${sqlStr(contractEndDate)}, ${sqlStr(status)})
"""
            let newEmpId = insertAndGetId(insertEmpSql)
            if (newEmpId <= 0) {
                sendErr(ctx, 500, 500, "候选人转入职失败")
                return
            }
            if (reqUsername.isEmpty()) {
                reqUsername = empNo.toAsciiLower()
            }
            let dup = querySingleInt("SELECT COUNT(*) FROM sys_user WHERE username = ${sqlStr(reqUsername)}", 0)
            if (dup > 0) {
                reqUsername = "${reqUsername}_${newEmpId}"
            }
            let pwdHash = hashPassword("123456")
            executeSql("INSERT INTO sys_user (username, password_hash, role, employee_id, is_active) VALUES (${sqlStr(reqUsername)}, ${sqlStr(pwdHash)}, 'EMPLOYEE', ${newEmpId}, 1)")
            executeSql("UPDATE hr_recruitment_candidate SET stage = 'HIRED' WHERE id = ${candId}")
            writeAuditLog(u, "招聘管理", "候选人入职", "候选人 ${c[0]} 办理入职成功，生成工号 ${empNo} 与登录账号 ${reqUsername}")
            sendOk(ctx, "{\"employeeId\":${newEmpId},\"empNo\":${jsonStr(empNo)},\"username\":${jsonStr(reqUsername)}}")
    }
}
