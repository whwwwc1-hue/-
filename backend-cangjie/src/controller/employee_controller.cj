package hrms_backend.controller

import std.collection.*
import std.convert.*
import stdx.net.http.*
import hrms_backend.common.*
import hrms_backend.db.*
import hrms_backend.middleware.*
import hrms_backend.service.*

func maskIdCard(raw: String): String {
    let s = raw.trimAscii()
    if (s.size <= 8) {
        return s
    }
    let runes = s.toRuneArray()
    if (runes.size <= 10) {
        return s
    }
    var masked = ""
    for (i in 0..runes.size) {
        if (i < 6 || i >= runes.size - 4) {
            masked = masked + runes[i].toString()
        } else {
            masked = masked + "*"
        }
    }
    return masked
}

public func generateNextEmpNo(): String {
    let maxId = querySingleInt("SELECT IFNULL(MAX(id), 0) FROM hr_employee", 0)
    var seq = maxId + 1
    while (true) {
        var seqStr = "${seq}"
        while (seqStr.size < 4) {
            seqStr = "0" + seqStr
        }
        let candidate = "EMP2026${seqStr}"
        let existsCnt = querySingleInt("SELECT COUNT(*) FROM hr_employee WHERE emp_no = ${sqlStr(candidate)}", 0)
        if (existsCnt == 0) {
            return candidate
        }
        seq += 1
    }
    return "EMP20269999"
}

func employeeRowToJson(r: ArrayList<String>): String {
    return "{" +
        "\"id\":${r[0]}," +
        "\"empNo\":${jsonStr(r[1])}," +
        "\"name\":${jsonStr(r[2])}," +
        "\"gender\":${r[3]}," +
        "\"phone\":${jsonStr(r[4])}," +
        "\"email\":${jsonStr(r[5])}," +
        "\"idCard\":${jsonStr(maskIdCard(r[6]))}," +
        "\"deptId\":${r[7]}," +
        "\"deptName\":${jsonStr(r[8])}," +
        "\"positionId\":${r[9]}," +
        "\"positionName\":${jsonStr(r[10])}," +
        "\"baseSalary\":${r[11]}," +
        "\"annualLeaveBalance\":${r[12]}," +
        "\"hireDate\":${jsonStr(r[13])}," +
        "\"probationEndDate\":${jsonStr(r[14])}," +
        "\"contractEndDate\":${jsonStr(r[15])}," +
        "\"resignDate\":${jsonStr(r[16])}," +
        "\"resignReason\":${jsonStr(r[17])}," +
        "\"status\":${jsonStr(r[18])}," +
        "\"createdAt\":${jsonStr(r[19])}" +
    "}"
}

public func handleEmployeeList(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR", "MANAGER"])) {
        case None => return
        case Some(u) =>
            let keyword = getQueryStr(ctx, "keyword", "").trimAscii()
            let reqDeptId = getQueryInt(ctx, "deptId", 0)
            let status = getQueryStr(ctx, "status", "").trimAscii()
            var page = getQueryInt(ctx, "page", 1)
            var pageSize = getQueryInt(ctx, "pageSize", 10)
            if (page < 1) { page = 1 }
            if (pageSize < 1 || pageSize > 100) { pageSize = 10 }

            let conds = ArrayList<String>()
            conds.add("1=1")
            if (u.role == "MANAGER") {
                let myDept = getUserDeptId(u)
                conds.add("e.dept_id = ${myDept}")
            } else if (reqDeptId > 0) {
                conds.add("e.dept_id = ${reqDeptId}")
            }
            if (!status.isEmpty()) {
                conds.add("e.status = ${sqlStr(status)}")
            }
            if (!keyword.isEmpty()) {
                let kw = sqlStr("%" + keyword + "%")
                conds.add("(e.name LIKE ${kw} OR e.emp_no LIKE ${kw} OR e.phone LIKE ${kw})")
            }
            let whereSql = "WHERE " + String.join(conds.toArray(), delimiter: " AND ")
            let total = querySingleInt("SELECT COUNT(*) FROM hr_employee e ${whereSql}", 0)
            let offset = (page - 1) * pageSize
            let sql = """
SELECT e.id, e.emp_no, e.name, e.gender, e.phone, IFNULL(e.email, ''), IFNULL(e.id_card, ''),
       e.dept_id, IFNULL(d.dept_name, ''), IFNULL(e.position_id, 0), e.position_name,
       e.base_salary, e.annual_leave_balance,
       IFNULL(DATE_FORMAT(e.hire_date, '%Y-%m-%d'), ''),
       IFNULL(DATE_FORMAT(e.probation_end_date, '%Y-%m-%d'), ''),
       IFNULL(DATE_FORMAT(e.contract_end_date, '%Y-%m-%d'), ''),
       IFNULL(DATE_FORMAT(e.resign_date, '%Y-%m-%d'), ''),
       IFNULL(e.resign_reason, ''), e.status,
       DATE_FORMAT(e.created_at, '%Y-%m-%d %H:%i:%s')
FROM hr_employee e
LEFT JOIN hr_department d ON e.dept_id = d.id
${whereSql}
ORDER BY e.id DESC
LIMIT ${pageSize} OFFSET ${offset}
"""
            let rows = queryRows(sql)
            let items = ArrayList<String>()
            for (r in rows) {
                items.add(employeeRowToJson(r))
            }
            sendPage(ctx, "[" + String.join(items.toArray(), delimiter: ",") + "]", total, page, pageSize)
    }
}

public func handleEmployeeDetail(ctx: HttpContext, empId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR", "MANAGER"])) {
        case None => return
        case Some(u) =>
            let sql = """
SELECT e.id, e.emp_no, e.name, e.gender, e.phone, IFNULL(e.email, ''), IFNULL(e.id_card, ''),
       e.dept_id, IFNULL(d.dept_name, ''), IFNULL(e.position_id, 0), e.position_name,
       e.base_salary, e.annual_leave_balance,
       IFNULL(DATE_FORMAT(e.hire_date, '%Y-%m-%d'), ''),
       IFNULL(DATE_FORMAT(e.probation_end_date, '%Y-%m-%d'), ''),
       IFNULL(DATE_FORMAT(e.contract_end_date, '%Y-%m-%d'), ''),
       IFNULL(DATE_FORMAT(e.resign_date, '%Y-%m-%d'), ''),
       IFNULL(e.resign_reason, ''), e.status,
       DATE_FORMAT(e.created_at, '%Y-%m-%d %H:%i:%s')
FROM hr_employee e
LEFT JOIN hr_department d ON e.dept_id = d.id
WHERE e.id = ${empId}
LIMIT 1
"""
            let rows = queryRows(sql)
            if (rows.size == 0) {
                sendErr(ctx, 404, 404, "员工档案不存在")
                return
            }
            let empDept = Int64.tryParse(rows[0][7]) ?? 0
            if (u.role == "MANAGER" && empDept != getUserDeptId(u)) {
                sendErr(ctx, 403, 403, "仅可查看本部门员工档案")
                return
            }
            let transSql = """
SELECT t.id, t.transfer_type, IFNULL(t.before_dept_id, 0), IFNULL(bd.dept_name, ''),
       IFNULL(t.after_dept_id, 0), IFNULL(ad.dept_name, ''),
       IFNULL(t.before_position, ''), IFNULL(t.after_position, ''),
       IFNULL(t.before_salary, 0.0), IFNULL(t.after_salary, 0.0),
       DATE_FORMAT(t.effective_date, '%Y-%m-%d'), IFNULL(t.remark, ''),
       DATE_FORMAT(t.created_at, '%Y-%m-%d %H:%i:%s')
FROM hr_emp_transfer t
LEFT JOIN hr_department bd ON t.before_dept_id = bd.id
LEFT JOIN hr_department ad ON t.after_dept_id = ad.id
WHERE t.employee_id = ${empId}
ORDER BY t.id DESC
"""
            let transRows = queryRows(transSql)
            let transList = ArrayList<String>()
            for (tr in transRows) {
                let toObj = "{" +
                    "\"id\":${tr[0]}," +
                    "\"transferType\":${jsonStr(tr[1])}," +
                    "\"beforeDeptId\":${tr[2]}," +
                    "\"beforeDeptName\":${jsonStr(tr[3])}," +
                    "\"afterDeptId\":${tr[4]}," +
                    "\"afterDeptName\":${jsonStr(tr[5])}," +
                    "\"beforePosition\":${jsonStr(tr[6])}," +
                    "\"afterPosition\":${jsonStr(tr[7])}," +
                    "\"beforeSalary\":${tr[8]}," +
                    "\"afterSalary\":${tr[9]}," +
                    "\"effectiveDate\":${jsonStr(tr[10])}," +
                    "\"remark\":${jsonStr(tr[11])}," +
                    "\"createdAt\":${jsonStr(tr[12])}" +
                "}"
                transList.add(toObj)
            }
            let empJson = employeeRowToJson(rows[0])
            let transJson = "[" + String.join(transList.toArray(), delimiter: ",") + "]"
            sendOk(ctx, "{\"employee\":${empJson},\"transfers\":${transJson}}")
    }
}

public func handleEmployeeCreate(ctx: HttpContext): Unit {
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
                    let idCard = getJsonStr(obj, "idCard", "").trimAscii()
                    let deptId = getJsonInt(obj, "deptId", 0)
                    let posId = getJsonInt(obj, "positionId", 0)
                    var posName = getJsonStr(obj, "positionName", "").trimAscii()
                    if (posName.isEmpty() && posId > 0) {
                        posName = querySingleValue("SELECT pos_name FROM hr_position WHERE id = ${posId}")
                    }
                    let baseSalary = getJsonFloat(obj, "baseSalary", 8000.0)
                    let annualLeave = getJsonFloat(obj, "annualLeaveBalance", 5.0)
                    var hireDate = getJsonStr(obj, "hireDate", "").trimAscii()
                    if (hireDate.isEmpty()) {
                        hireDate = querySingleValue("SELECT CURDATE()")
                    }
                    let probEndDate = getJsonStr(obj, "probationEndDate", "").trimAscii()
                    var contractEndDate = getJsonStr(obj, "contractEndDate", "").trimAscii()
                    if (contractEndDate.isEmpty()) {
                        contractEndDate = querySingleValue("SELECT DATE_ADD(${sqlStr(hireDate)}, INTERVAL 3 YEAR)")
                    }
                    let status = getJsonStr(obj, "status", "PROBATION").trimAscii()
                    let createAccount = getJsonBool(obj, "createAccount", true)
                    var reqUsername = getJsonStr(obj, "username", "").trimAscii()

                    if (name.isEmpty() || phone.isEmpty() || deptId <= 0 || posName.isEmpty()) {
                        sendErr(ctx, 400, 400, "姓名、手机号、部门和岗位不能为空")
                        return
                    }
                    let empNo = generateNextEmpNo()
                    let posIdSql = if (posId > 0) { "${posId}" } else { "NULL" }
                    let insertSql = """
INSERT INTO hr_employee (emp_no, name, gender, phone, email, id_card, dept_id, position_id, position_name, base_salary, annual_leave_balance, hire_date, probation_end_date, contract_end_date, status)
VALUES (${sqlStr(empNo)}, ${sqlStr(name)}, ${gender}, ${sqlStr(phone)}, ${sqlNullableStr(email)}, ${sqlNullableStr(idCard)}, ${deptId}, ${posIdSql}, ${sqlStr(posName)}, ${formatNum2(baseSalary)}, ${formatNum2(annualLeave)}, ${sqlStr(hireDate)}, ${sqlNullableStr(probEndDate)}, ${sqlNullableStr(contractEndDate)}, ${sqlStr(status)})
"""
                    let newEmpId = insertAndGetId(insertSql)
                    if (newEmpId <= 0) {
                        sendErr(ctx, 500, 500, "员工入职登记失败")
                        return
                    }
                    var createdAccountName = ""
                    if (createAccount) {
                        if (reqUsername.isEmpty()) {
                            reqUsername = empNo.toAsciiLower()
                        }
                        let dupUser = querySingleInt("SELECT COUNT(*) FROM sys_user WHERE username = ${sqlStr(reqUsername)}", 0)
                        if (dupUser > 0) {
                            reqUsername = "${reqUsername}_${newEmpId}"
                        }
                        let defaultHash = hashPassword("123456")
                        executeSql("INSERT INTO sys_user (username, password_hash, role, employee_id, is_active) VALUES (${sqlStr(reqUsername)}, ${sqlStr(defaultHash)}, 'EMPLOYEE', ${newEmpId}, 1)")
                        createdAccountName = reqUsername
                    }
                    writeAuditLog(u, "员工管理", "入职登记", "办理员工 ${name} (${empNo}) 入职，部门ID=${deptId}，账号=${createdAccountName}")
                    sendOk(ctx, "{\"id\":${newEmpId},\"empNo\":${jsonStr(empNo)},\"accountUsername\":${jsonStr(createdAccountName)}}")
            }
    }
}

public func handleEmployeeUpdate(ctx: HttpContext, empId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    // 先读出库里现值：更新接口采用「字段存在才覆盖」的补丁语义，
                    // 避免前端只提交部分字段时把月薪、年假、试用期日期等静默清零。
                    let existRows = queryRows("""
SELECT e.name, e.gender, e.phone, IFNULL(e.email, ''), e.dept_id, IFNULL(e.position_id, 0), e.position_name,
       e.base_salary, e.annual_leave_balance,
       IFNULL(DATE_FORMAT(e.probation_end_date, '%Y-%m-%d'), ''),
       IFNULL(DATE_FORMAT(e.contract_end_date, '%Y-%m-%d'), ''),
       IFNULL(DATE_FORMAT(e.hire_date, '%Y-%m-%d'), ''), e.status
FROM hr_employee e
WHERE e.id = ${empId} LIMIT 1
""")
                    if (existRows.size == 0) {
                        sendErr(ctx, 404, 404, "员工不存在")
                        return
                    }
                    let cur = existRows[0]
                    var name = cur[0]
                    var gender = Int64.tryParse(cur[1]) ?? 1
                    var phone = cur[2]
                    var email = cur[3]
                    var deptId = Int64.tryParse(cur[4]) ?? 0
                    var posId = Int64.tryParse(cur[5]) ?? 0
                    var posName = cur[6]
                    var baseSalary = Float64.tryParse(cur[7]) ?? 0.0
                    var annualLeave = Float64.tryParse(cur[8]) ?? 0.0
                    var probEndDate = cur[9]
                    var contractEndDate = cur[10]
                    var hireDate = cur[11]
                    var status = cur[12]

                    if (hasJsonKey(obj, "name")) { name = getJsonStr(obj, "name", name).trimAscii() }
                    if (hasJsonKey(obj, "gender")) { gender = getJsonInt(obj, "gender", gender) }
                    if (hasJsonKey(obj, "phone")) { phone = getJsonStr(obj, "phone", phone).trimAscii() }
                    if (hasJsonKey(obj, "email")) { email = getJsonStr(obj, "email", email).trimAscii() }
                    if (hasJsonKey(obj, "deptId")) { deptId = getJsonInt(obj, "deptId", deptId) }
                    if (hasJsonKey(obj, "positionId")) { posId = getJsonInt(obj, "positionId", posId) }
                    if (hasJsonKey(obj, "positionName")) { posName = getJsonStr(obj, "positionName", posName).trimAscii() }
                    if (hasJsonKey(obj, "baseSalary")) { baseSalary = getJsonFloat(obj, "baseSalary", baseSalary) }
                    if (hasJsonKey(obj, "annualLeaveBalance")) { annualLeave = getJsonFloat(obj, "annualLeaveBalance", annualLeave) }
                    if (hasJsonKey(obj, "probationEndDate")) { probEndDate = getJsonStr(obj, "probationEndDate", probEndDate).trimAscii() }
                    if (hasJsonKey(obj, "contractEndDate")) { contractEndDate = getJsonStr(obj, "contractEndDate", contractEndDate).trimAscii() }
                    if (hasJsonKey(obj, "hireDate")) { hireDate = getJsonStr(obj, "hireDate", hireDate).trimAscii() }
                    if (hasJsonKey(obj, "status")) { status = getJsonStr(obj, "status", status).trimAscii() }

                    if (posName.isEmpty() && posId > 0) {
                        posName = querySingleValue("SELECT pos_name FROM hr_position WHERE id = ${posId}")
                    }
                    if (name.isEmpty() || phone.isEmpty() || deptId <= 0 || posName.isEmpty()) {
                        sendErr(ctx, 400, 400, "姓名、手机号、部门和岗位不能为空")
                        return
                    }
                    if (status != "PROBATION" && status != "ACTIVE" && status != "RESIGNED") {
                        sendErr(ctx, 400, 400, "员工状态取值非法（仅支持 PROBATION/ACTIVE/RESIGNED）")
                        return
                    }
                    if (baseSalary < 0.0 || annualLeave < 0.0) {
                        sendErr(ctx, 400, 400, "月薪与剩余年假不能为负数")
                        return
                    }
                    let posIdSql = if (posId > 0) { "${posId}" } else { "NULL" }
                    let sql = "UPDATE hr_employee SET name=${sqlStr(name)}, gender=${gender}, phone=${sqlStr(phone)}, email=${sqlNullableStr(email)}, dept_id=${deptId}, position_id=${posIdSql}, position_name=${sqlStr(posName)}, base_salary=${formatNum2(baseSalary)}, annual_leave_balance=${formatNum2(annualLeave)}, hire_date=IF(${sqlStr(hireDate)} = '', hire_date, ${sqlStr(hireDate)}), probation_end_date=${sqlNullableStr(probEndDate)}, contract_end_date=${sqlNullableStr(contractEndDate)}, status=${sqlStr(status)} WHERE id=${empId}"
                    if (!executeSql(sql)) {
                        sendErr(ctx, 500, 500, "员工档案更新失败")
                        return
                    }
                    writeAuditLog(u, "员工管理", "修改档案", "更新员工 ${name} (ID=${empId}) 基础信息")
                    sendOk(ctx, "{\"id\":${empId}}")
            }
    }
}

public func handleEmployeeTransfer(ctx: HttpContext, empId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            let rows = queryRows("SELECT name, dept_id, position_name, base_salary, status FROM hr_employee WHERE id = ${empId} LIMIT 1")
            if (rows.size == 0) {
                sendErr(ctx, 404, 404, "员工不存在")
                return
            }
            let cur = rows[0]
            let empName = cur[0]
            let beforeDeptId = Int64.tryParse(cur[1]) ?? 0
            let beforePos = cur[2]
            let beforeSalary = Float64.tryParse(cur[3]) ?? 0.0
            let curStatus = cur[4]
            if (curStatus == "RESIGNED") {
                sendErr(ctx, 400, 400, "离职员工不能办理异动")
                return
            }
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let transferType = getJsonStr(obj, "transferType", "TRANSFER").trimAscii()
                    var afterDeptId = getJsonInt(obj, "afterDeptId", beforeDeptId)
                    if (afterDeptId <= 0) { afterDeptId = beforeDeptId }
                    let afterPosId = getJsonInt(obj, "afterPositionId", 0)
                    var afterPos = getJsonStr(obj, "afterPosition", beforePos).trimAscii()
                    if (afterPos.isEmpty()) { afterPos = beforePos }
                    var afterSalary = getJsonFloat(obj, "afterSalary", beforeSalary)
                    if (afterSalary <= 0.0) { afterSalary = beforeSalary }
                    var effectiveDate = getJsonStr(obj, "effectiveDate", "").trimAscii()
                    if (effectiveDate.isEmpty()) {
                        effectiveDate = querySingleValue("SELECT CURDATE()")
                    }
                    let remark = getJsonStr(obj, "remark", "").trimAscii()

                    let transSql = """
INSERT INTO hr_emp_transfer (employee_id, transfer_type, before_dept_id, after_dept_id, before_position, after_position, before_salary, after_salary, effective_date, remark, operator_id)
VALUES (${empId}, ${sqlStr(transferType)}, ${beforeDeptId}, ${afterDeptId}, ${sqlStr(beforePos)}, ${sqlStr(afterPos)}, ${formatNum2(beforeSalary)}, ${formatNum2(afterSalary)}, ${sqlStr(effectiveDate)}, ${sqlNullableStr(remark)}, ${u.userId})
"""
                    let nextStatus = if (transferType == "REGULARIZE") { "ACTIVE" } else { curStatus }
                    let posIdUpdate = if (afterPosId > 0) { ", position_id=${afterPosId}" } else { "" }
                    let updSql = "UPDATE hr_employee SET dept_id=${afterDeptId}, position_name=${sqlStr(afterPos)}, base_salary=${formatNum2(afterSalary)}, status=${sqlStr(nextStatus)}${posIdUpdate} WHERE id=${empId}"
                    executeSql("START TRANSACTION;\n${transSql};\n${updSql};\nCOMMIT;")
                    writeAuditLog(u, "员工管理", "员工异动", "员工 ${empName} (ID=${empId}) 办理 ${transferType}：部门 ${beforeDeptId}->${afterDeptId}，岗位 ${beforePos}->${afterPos}，薪资 ${formatNum2(beforeSalary)}->${formatNum2(afterSalary)}")
                    sendOk(ctx, "null")
            }
    }
}

public func handleEmployeeResign(ctx: HttpContext, empId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            let rows = queryRows("SELECT name, dept_id, position_name, base_salary, status FROM hr_employee WHERE id = ${empId} LIMIT 1")
            if (rows.size == 0) {
                sendErr(ctx, 404, 404, "员工不存在")
                return
            }
            let cur = rows[0]
            if (cur[4] == "RESIGNED") {
                sendErr(ctx, 400, 400, "该员工已处于离职状态")
                return
            }
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    var resignDate = getJsonStr(obj, "resignDate", "").trimAscii()
                    if (resignDate.isEmpty()) {
                        resignDate = querySingleValue("SELECT CURDATE()")
                    }
                    let resignReason = getJsonStr(obj, "resignReason", "个人原因").trimAscii()
                    let transSql = """
INSERT INTO hr_emp_transfer (employee_id, transfer_type, before_dept_id, after_dept_id, before_position, after_position, before_salary, after_salary, effective_date, remark, operator_id)
VALUES (${empId}, 'RESIGN', ${cur[1]}, ${cur[1]}, ${sqlStr(cur[2])}, ${sqlStr(cur[2])}, ${cur[3]}, ${cur[3]}, ${sqlStr(resignDate)}, ${sqlStr(resignReason)}, ${u.userId})
"""
                    let updEmpSql = "UPDATE hr_employee SET status='RESIGNED', resign_date=${sqlStr(resignDate)}, resign_reason=${sqlStr(resignReason)} WHERE id=${empId}"
                    let disableUserSql = "UPDATE sys_user SET is_active=0 WHERE employee_id=${empId}"
                    executeSql("START TRANSACTION;\n${transSql};\n${updEmpSql};\n${disableUserSql};\nCOMMIT;")
                    writeAuditLog(u, "员工管理", "办理离职", "员工 ${cur[0]} (ID=${empId}) 离职，日期=${resignDate}，已自动禁用登录账号")
                    sendOk(ctx, "null")
            }
    }
}
