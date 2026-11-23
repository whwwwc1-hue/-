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
                    let name = getJsonStr(obj, "name", "").trimAscii()
                    let gender = getJsonInt(obj, "gender", 1)
                    let phone = getJsonStr(obj, "phone", "").trimAscii()
                    let email = getJsonStr(obj, "email", "").trimAscii()
                    let deptId = getJsonInt(obj, "deptId", 0)
                    let posId = getJsonInt(obj, "positionId", 0)
                    let posName = getJsonStr(obj, "positionName", "").trimAscii()
                    let baseSalary = getJsonFloat(obj, "baseSalary", 0.0)
                    let annualLeave = getJsonFloat(obj, "annualLeaveBalance", 5.0)
                    let contractEndDate = getJsonStr(obj, "contractEndDate", "").trimAscii()
                    let probEndDate = getJsonStr(obj, "probationEndDate", "").trimAscii()
                    if (name.isEmpty() || phone.isEmpty() || deptId <= 0 || posName.isEmpty()) {
                        sendErr(ctx, 400, 400, "姓名、手机号、部门、岗位必填")
                        return
                    }
                    let posIdSql = if (posId > 0) { "${posId}" } else { "NULL" }
                    let sql = "UPDATE hr_employee SET name=${sqlStr(name)}, gender=${gender}, phone=${sqlStr(phone)}, email=${sqlNullableStr(email)}, dept_id=${deptId}, position_id=${posIdSql}, position_name=${sqlStr(posName)}, base_salary=${formatNum2(baseSalary)}, annual_leave_balance=${formatNum2(annualLeave)}, probation_end_date=${sqlNullableStr(probEndDate)}, contract_end_date=${sqlNullableStr(contractEndDate)} WHERE id=${empId}"
                    executeSql(sql)
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

// =============================================================================
// P2.1 员工花名册批量导入
//
// 传输契约：
//   POST /api/v1/employees/import   body = {"csv": "<CSV 纯文本>", "dryRun": true|false}
//   200 data = {
//     "total": 数据行数, "successCount": 校验通过行数, "failedCount": 校验失败行数,
//     "imported": 实际落库行数, "dryRun": Bool,
//     "failed": [{"row": CSV 物理行号, "field": "字段名", "reason": "原因"}]
//   }
//
// 事务语义：整批「校验全通过才写库」。任一行有错 → 不落库、返回逐行定位。
// 落库只有 1 次 mysql.exe 调用（多行 VALUES + INSERT...SELECT 建账号），
// 避免「每行一次子进程」把 D3 的缺陷放大 100 倍。
//
// 为什么 CSV 解析放在后端而不是前端（对原计划的偏离，理由记录在 FOLLOWUP_PLAN 第四节）：
//   1) 校验口径（工号唯一、部门存在、日期格式）必须有唯一权威实现。前端另写一份
//      必然与后端漂移，且漂移会表现为「前端说能过、后端说不能过」。
//   2) stdx.encoding.json 的**数组**取值 API（asArray / JsonKind.JsArray）在本仓库
//      基线 6e79923 中零先例，按第十一节考证纪律不得使用；于是请求体退化为
//      {"csv": String}，只用已证实的 getJsonStr 取字符串。自研 CSV 解析器是纯函数，
//      可脱离数据库单测（见 employee_import_test.cj）。
// 前端仍解析一次 CSV 只为「预览前 20 行」，不做任何校验判定，避免第二套口径。
// =============================================================================

let EMP_IMPORT_MAX_ROWS: Int64 = 500
let BOM_EF: UInt8 = 0xEF
let BOM_BB: UInt8 = 0xBB
let BOM_BF: UInt8 = 0xBF
let DIGIT_0: UInt8 = 0x30
let DIGIT_9: UInt8 = 0x39

// RFC4180 子集解析器。
// 行号必须单独收集：引号内可以含换行，「数组下标」不等于「物理行号」，
// 直接按下标 +1 报行号会把用户引到错误的行上去改数据。
func parseCsvInto(text: String, allFields: ArrayList<String>, fieldCounts: ArrayList<Int64>, rowLines: ArrayList<Int64>): Unit {
    let runes = csvStripBom(text).toRuneArray()
    let total = runes.size
    var curLine: Int64 = 1
    var rowStartLine: Int64 = 1
    var rowFields: Int64 = 0
    var field = ""
    var inQuotes = false
    var i: Int64 = 0
    while (i < total) {
        let ch = runes[i].toString()
        if (ch == "\"") {
            if (inQuotes && i + 1 < total && runes[i + 1].toString() == "\"") {
                field = field + "\""
                i = i + 2
            } else {
                if (inQuotes) { inQuotes = false } else { inQuotes = true }
                i = i + 1
            }
        } else if (!inQuotes && ch == ",") {
            allFields.add(field)
            rowFields = rowFields + 1
            field = ""
            i = i + 1
        } else if (!inQuotes && (ch == "\n" || ch == "\r")) {
            if (ch == "\r" && i + 1 < total && runes[i + 1].toString() == "\n") {
                i = i + 1
            }
            i = i + 1
            allFields.add(field)
            rowFields = rowFields + 1
            field = ""
            fieldCounts.add(rowFields)
            rowLines.add(rowStartLine)
            rowStartLine = curLine + 1
            curLine = curLine + 1
            rowFields = 0
        } else {
            if (inQuotes && (ch == "\n" || ch == "\r")) {
                curLine = curLine + 1
            }
            field = field + ch
            i = i + 1
        }
    }
    // 文件末尾没有换行时，最后一行不会被上面的分支冲刷出来
    if (!field.isEmpty() || rowFields > 0) {
        allFields.add(field)
        rowFields = rowFields + 1
        fieldCounts.add(rowFields)
        rowLines.add(rowStartLine)
    }
}

func csvStripBom(text: String): String {
    let bytes = text.toArray()
    if (bytes.size >= 3 && bytes[0] == BOM_EF && bytes[1] == BOM_BB && bytes[2] == BOM_BF) {
        let out = ArrayList<UInt8>()
        var i: Int64 = 3
        while (i < bytes.size) {
            out.add(bytes[i])
            i = i + 1
        }
        return String.fromUtf8(out.toArray())
    }
    return text
}

// 把「扁平字段 + 每行字段数」还原成二维表。
// 这里在 while 内每次新建 ArrayList，与基线 mysql_pool.cj:96 的 queryRows 同构。
func csvSplitRows(allFields: ArrayList<String>, fieldCounts: ArrayList<Int64>): ArrayList<ArrayList<String>> {
    let rows = ArrayList<ArrayList<String>>()
    var pos: Int64 = 0
    var r: Int64 = 0
    while (r < fieldCounts.size) {
        let row = ArrayList<String>()
        var k: Int64 = 0
        while (k < fieldCounts[r]) {
            row.add(allFields[pos])
            pos = pos + 1
            k = k + 1
        }
        rows.add(row)
        r = r + 1
    }
    return rows
}

func csvColIndex(header: ArrayList<String>, title: String): Int64 {
    var idx: Int64 = -1
    var i: Int64 = 0
    while (i < header.size) {
        if (idx < 0 && header[i].trimAscii() == title) {
            idx = i
        }
        i = i + 1
    }
    return idx
}

func csvCell(row: ArrayList<String>, idx: Int64): String {
    if (idx < 0 || idx >= row.size) {
        return ""
    }
    return row[idx].trimAscii()
}

// 整行是否「没有任何数据」。
// RFC4180 里一个空行本身就是一条记录（1 个空字段），解析器必须忠实于该语义，
// 但导入时它是纯格式噪音：Excel 另存为常带尾随空行，若按普通行校验会一次性
// 报出 6 条「必填为空」，把真实错误淹没。因此这里显式跳过空行。
func csvRowIsBlank(row: ArrayList<String>): Bool {
    var blank = true
    var i: Int64 = 0
    while (i < row.size) {
        if (!row[i].trimAscii().isEmpty()) {
            blank = false
        }
        i = i + 1
    }
    return blank
}

func listIndexOf(list: ArrayList<String>, v: String): Int64 {
    var idx: Int64 = -1
    var i: Int64 = 0
    while (i < list.size) {
        if (idx < 0 && list[i] == v) {
            idx = i
        }
        i = i + 1
    }
    return idx
}

// MySQL 的 VARCHAR(n) 按**字符**计长，而仓颉 String.size 是 UTF-8 字节数，
// 所以长度上限一律先转 Rune 再数，否则「王梓涵」这种 3 字姓名会被按 9 字节误判。
func strRuneLen(s: String): Int64 {
    return s.toRuneArray().size
}

func isAllDigits(s: String): Bool {
    var ok = if (s.isEmpty()) { false } else { true }
    let bytes = s.toArray()
    for (b in bytes) {
        if (b < DIGIT_0 || b > DIGIT_9) {
            ok = false
        }
    }
    return ok
}

// 子串存在性判定。刻意用 replace 后的长度差而不是 String.contains：
// 后者在基线里零使用，可用性未经证实；而 replace 是 jsonEscape 的核心依赖，确证。
// （用长度差而不是「是否等于原串」也一样可靠：sub 非空时删掉一次必然变短。）
func strHas(s: String, sub: String): Bool {
    if (sub.isEmpty()) {
        return true
    }
    return s.replace(sub, "").size != s.size
}

// 只校验字面量与分量范围（年 4 位、月 1..12、日 1..31），
// 不校验「2 月 30 日」这类日历合法性 —— 落库时交给 MySQL 的 DATE 列拒绝，
// 自己实现公历闰年判断属于无收益的重复造轮子。
func isValidYmd(s: String): Bool {
    var ok = false
    let parts = s.split("-")
    if (parts.size == 3) {
        let y = parts[0]
        let m = parts[1]
        let d = parts[2]
        var good = true
        if (y.size != 4 || !isAllDigits(y)) { good = false }
        if (m.size != 2 || !isAllDigits(m)) { good = false }
        if (d.size != 2 || !isAllDigits(d)) { good = false }
        if (good) {
            let mi = Int64.tryParse(m) ?? 0
            let di = Int64.tryParse(d) ?? 0
            if (mi < 1 || mi > 12) { good = false }
            if (di < 1 || di > 31) { good = false }
        }
        ok = good
    }
    return ok
}

// 归一化在函数内部完成（与 empImportStatus 一致）：调用方传进来的是用户手写的
// 原始单元格，大小写不定；若在外层大写，非 ASCII 的「男/女」会被 toAsciiUpper
// 原样保留，两条路径的口径就必须处处对齐，容易漏。
func empImportGender(raw: String): Int64 {
    let s = raw.trimAscii().toAsciiUpper()
    if (s == "1" || s == "男" || s == "M" || s == "MALE") {
        return 1
    }
    if (s == "2" || s == "女" || s == "F" || s == "FEMALE") {
        return 2
    }
    return 0
}

func empImportStatus(raw: String): String {
    let s = raw.toAsciiUpper()
    if (s == "ACTIVE" || s == "PROBATION" || s == "RESIGNED") {
        return s
    }
    if (s == "在职" || s == "正式") { return "ACTIVE" }
    if (s == "试用期") { return "PROBATION" }
    if (s == "离职") { return "RESIGNED" }
    return ""
}

func validateImportRow(row: ArrayList<String>, lineNo: Int64, cols: ArrayList<Int64>, existingEmpNos: ArrayList<String>, fileEmpNos: ArrayList<String>, deptNames: ArrayList<String>, failedJson: ArrayList<String>): Bool {
    var rowOk = true
    let colEmpNo = cols[0]
    let colName = cols[1]
    let colGender = cols[2]
    let colPhone = cols[3]
    let colEmail = cols[4]
    let colIdCard = cols[5]
    let colDept = cols[6]
    let colPos = cols[7]
    let colSalary = cols[8]
    let colHire = cols[10]
    let colContract = cols[11]
    let colStatus = cols[12]

    let empNo = csvCell(row, colEmpNo)
    let name = csvCell(row, colName)
    let phone = csvCell(row, colPhone)
    let deptName = csvCell(row, colDept)
    let posName = csvCell(row, colPos)
    let hireDate = csvCell(row, colHire)

    if (empNo.isEmpty()) {
        failedJson.add(importFailJson(lineNo, "工号", "不能为空"))
        rowOk = false
    } else if (strRuneLen(empNo) > 32) {
        failedJson.add(importFailJson(lineNo, "工号", "长度超过 32 字符"))
        rowOk = false
    } else if (listIndexOf(fileEmpNos, empNo) >= 0) {
        failedJson.add(importFailJson(lineNo, "工号", "工号 ${empNo} 在本次文件内重复"))
        rowOk = false
    } else if (listIndexOf(existingEmpNos, empNo) >= 0) {
        failedJson.add(importFailJson(lineNo, "工号", "工号 ${empNo} 已存在于系统，导入不覆盖已有档案"))
        rowOk = false
    }

    if (name.isEmpty()) {
        failedJson.add(importFailJson(lineNo, "姓名", "不能为空"))
        rowOk = false
    } else if (strRuneLen(name) > 64) {
        failedJson.add(importFailJson(lineNo, "姓名", "长度超过 64 字符"))
        rowOk = false
    }

    if (!phone.isEmpty() && !isAllDigits(phone)) {
        failedJson.add(importFailJson(lineNo, "手机号", "手机号只能由数字组成"))
        rowOk = false
    }
    if (phone.isEmpty()) {
        failedJson.add(importFailJson(lineNo, "手机号", "不能为空"))
        rowOk = false
    }

    if (!deptName.isEmpty() && listIndexOf(deptNames, deptName) < 0) {
        failedJson.add(importFailJson(lineNo, "部门", "部门「${deptName}」不存在，请先在组织架构中创建"))
        rowOk = false
    }
    if (deptName.isEmpty()) {
        failedJson.add(importFailJson(lineNo, "部门", "不能为空"))
        rowOk = false
    }

    if (posName.isEmpty()) {
        failedJson.add(importFailJson(lineNo, "岗位", "不能为空"))
        rowOk = false
    }

    if (hireDate.isEmpty()) {
        failedJson.add(importFailJson(lineNo, "入职日期", "不能为空"))
        rowOk = false
    }
    if (!hireDate.isEmpty() && !isValidYmd(hireDate)) {
        failedJson.add(importFailJson(lineNo, "入职日期", "日期格式应为 YYYY-MM-DD，实际为「${hireDate}」"))
        rowOk = false
    }

    let genderRaw = csvCell(row, colGender)
    if (!genderRaw.isEmpty() && empImportGender(genderRaw) == 0) {
        failedJson.add(importFailJson(lineNo, "性别", "只接受 1/2 或 男/女"))
        rowOk = false
    }

    let salaryRaw = csvCell(row, colSalary)
    if (!salaryRaw.isEmpty()) {
        let sv = Float64.tryParse(salaryRaw) ?? -1.0
        if (sv < 0.0) {
            failedJson.add(importFailJson(lineNo, "基本薪资", "不是合法数字"))
            rowOk = false
        }
    }

    let contractRaw = csvCell(row, colContract)
    if (!contractRaw.isEmpty() && !isValidYmd(contractRaw)) {
        failedJson.add(importFailJson(lineNo, "合同到期日期", "日期格式应为 YYYY-MM-DD，实际为「${contractRaw}」"))
        rowOk = false
    }

    let statusRaw = csvCell(row, colStatus)
    if (!statusRaw.isEmpty() && empImportStatus(statusRaw).isEmpty()) {
        failedJson.add(importFailJson(lineNo, "状态", "只接受 PROBATION/ACTIVE/RESIGNED 或 试用期/在职/离职"))
        rowOk = false
    }

    let idCard = csvCell(row, colIdCard)
    if (!idCard.isEmpty() && strRuneLen(idCard) != 15 && strRuneLen(idCard) != 18) {
        failedJson.add(importFailJson(lineNo, "身份证号", "长度应为 15 或 18 位"))
        rowOk = false
    }

    let email = csvCell(row, colEmail)
    if (!email.isEmpty() && !strHas(email, "@")) {
        failedJson.add(importFailJson(lineNo, "邮箱", "缺少 @ 符号"))
        rowOk = false
    }

    return rowOk
}

func importFailJson(lineNo: Int64, field: String, reason: String): String {
    return "{\"row\":${lineNo},\"field\":${jsonStr(field)},\"reason\":${jsonStr(reason)}}"
}

// 模板列（顺序固定，与前端 templateCsv() 一一对应）
func empImportHeader(): ArrayList<String> {
    let h = ArrayList<String>()
    h.add("工号")
    h.add("姓名")
    h.add("性别")
    h.add("手机号")
    h.add("邮箱")
    h.add("身份证号")
    h.add("部门")
    h.add("岗位")
    h.add("基本薪资")
    h.add("年假余额")
    h.add("入职日期")
    h.add("合同到期日期")
    h.add("状态")
    return h
}

// 表头 → 列下标（缺失记 -1，csvCell 对 -1 返回空串，从而由必填校验兜住）。
// 返回 missing 用 ArrayList 承载，避免依赖未证实的元组 / 多返回值写法。
func empImportCols(header: ArrayList<String>, missing: ArrayList<String>): ArrayList<Int64> {
    let cols = ArrayList<Int64>()
    let titles = empImportHeader()
    var i: Int64 = 0
    while (i < titles.size) {
        let idx = csvColIndex(header, titles[i])
        cols.add(idx)
        if (idx < 0) {
            missing.add(titles[i])
        }
        i = i + 1
    }
    return cols
}

public func handleEmployeeImport(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let csvText = getJsonStr(obj, "csv", "")
                    let dryRun = getJsonBool(obj, "dryRun", false)
                    if (csvText.trimAscii().isEmpty()) {
                        sendErr(ctx, 400, 400, "csv 不能为空，请下载模板填写后上传")
                        return
                    }
                    doEmployeeImport(ctx, u, csvText, dryRun)
            }
    }
}

func doEmployeeImport(ctx: HttpContext, u: AuthUser, csvText: String, dryRun: Bool): Unit {
    let allFields = ArrayList<String>()
    let fieldCounts = ArrayList<Int64>()
    let rowLines = ArrayList<Int64>()
    parseCsvInto(csvText, allFields, fieldCounts, rowLines)
    let parsed = csvSplitRows(allFields, fieldCounts)
    // 先剔除空行，再算行数上限与 dataCount：空行不配占用 500 行的额度，
    // 更不能作为数据行去报 6 条必填错误。行号取自 rowLines，剔除后仍指向原始物理行。
    let rows = ArrayList<ArrayList<String>>()
    let keepLines = ArrayList<Int64>()
    var fIdx: Int64 = 0
    while (fIdx < parsed.size) {
        if (!csvRowIsBlank(parsed[fIdx])) {
            rows.add(parsed[fIdx])
            keepLines.add(rowLines[fIdx])
        }
        fIdx = fIdx + 1
    }

    if (rows.size < 2) {
        sendErr(ctx, 400, 400, "CSV 至少需要表头行与 1 行数据")
    } else {
        let missing = ArrayList<String>()
        let cols = empImportCols(rows[0], missing)
        if (cols.size < 13 || missing.size == 13) {
            sendErr(ctx, 400, 400, "表头无法识别，请使用系统提供的模板（第 1 行为列名）")
        } else {
            let dataCount = rows.size - 1
            if (dataCount > EMP_IMPORT_MAX_ROWS) {
                sendErr(ctx, 400, 400, "单次导入最多 ${EMP_IMPORT_MAX_ROWS} 行，当前 ${dataCount} 行，请拆分文件")
            } else {
                // 需要查库的两项校验，各自只起 1 次子进程，绝不在行循环里查库
                let existingEmpNos = ArrayList<String>()
                for (r in queryRows("SELECT emp_no FROM hr_employee LIMIT 5000")) {
                    existingEmpNos.add(r[0])
                }
                let deptNames = ArrayList<String>()
                let deptIds = ArrayList<String>()
                for (r in queryRows("SELECT dept_name, id FROM hr_department LIMIT 500")) {
                    deptNames.add(r[0])
                    deptIds.add(r[1])
                }

                let failedJson = ArrayList<String>()
                let accepted = ArrayList<Int64>()
                let fileEmpNos = ArrayList<String>()
                var failedRows: Int64 = 0
                var ridx: Int64 = 1
                while (ridx < rows.size) {
                    let before = failedJson.size
                    let ok = validateImportRow(rows[ridx], keepLines[ridx], cols, existingEmpNos, fileEmpNos, deptNames, failedJson)
                    if (ok) {
                        accepted.add(ridx)
                        fileEmpNos.add(csvCell(rows[ridx], cols[0]))
                    } else {
                        failedRows = failedRows + 1
                        if (before == failedJson.size) {
                            // validateImportRow 的契约是「返回 false 必然写过至少一条错误」。
                            // 走到这里说明契约被破坏；宁可显式报错，也不让无声跳过的行混进库里。
                            failedJson.add(importFailJson(keepLines[ridx], "整行", "校验器内部异常，请改用单条入职登记"))
                        }
                    }
                    ridx = ridx + 1
                }

                if (failedRows > 0) {
                    sendOkMsg(ctx, "校验未通过 ${failedRows} 行，整批未写入", importResultJson(dataCount, accepted.size, failedRows, 0, dryRun, failedJson))
                } else if (dryRun) {
                    sendOkMsg(ctx, "试运行通过 ${accepted.size} 行，未写入", importResultJson(dataCount, accepted.size, 0, 0, dryRun, failedJson))
                } else {
                    persistImport(ctx, u, accepted, rows, cols, deptNames, deptIds, dataCount, failedJson)
                }
            }
        }
    }
}

func importResultJson(total: Int64, successCount: Int64, failedCount: Int64, imported: Int64, dryRun: Bool, failedJson: ArrayList<String>): String {
    var dryFlag = "false"
    if (dryRun) { dryFlag = "true" }
    return "{\"total\":${total},\"successCount\":${successCount},\"failedCount\":${failedCount},\"imported\":${imported},\"dryRun\":${dryFlag},\"failed\":[${String.join(failedJson.toArray(), delimiter: \",\")}]}"
}

// 整批只发 1 次 mysql.exe 调用：START TRANSACTION + 多行 VALUES INSERT
// + INSERT...SELECT 建登录账号 + COMMIT。
// 账号初始口令不共用一个哈希：每行独立随机盐重算，避免「一条被撞开就全线沦陷」。
func persistImport(ctx: HttpContext, u: AuthUser, accepted: ArrayList<Int64>, rows: ArrayList<ArrayList<String>>, cols: ArrayList<Int64>, deptNames: ArrayList<String>, deptIds: ArrayList<String>, dataCount: Int64, failedJson: ArrayList<String>): Unit {
    let valueTuples = ArrayList<String>()
    let caseWhens = ArrayList<String>()
    let empNoLiterals = ArrayList<String>()
    for (k in accepted) {
        let row = rows[k]
        let empNo = csvCell(row, cols[0])
        let name = csvCell(row, cols[1])
        var gender = empImportGender(csvCell(row, cols[2]))
        if (gender == 0) { gender = 1 }
        let phone = csvCell(row, cols[3])
        let email = csvCell(row, cols[4])
        let idCard = csvCell(row, cols[5])
        let deptName = csvCell(row, cols[6])
        let posName = csvCell(row, cols[7])
        let salary = Float64.tryParse(csvCell(row, cols[8])) ?? 0.0
        let leave = Float64.tryParse(csvCell(row, cols[9])) ?? 5.0
        let hireDate = csvCell(row, cols[10])
        let contractEnd = csvCell(row, cols[11])
        var status = empImportStatus(csvCell(row, cols[12]))
        if (status.isEmpty()) { status = "PROBATION" }
        let dIdx = listIndexOf(deptNames, deptName)
        let deptIdSql = if (dIdx >= 0) { deptIds[dIdx] } else { "NULL" }
        let empNoSql = sqlStr(empNo)
        let pwdHashSql = sqlStr(hashPassword("123456"))
        valueTuples.add("(${empNoSql}, ${sqlStr(name)}, ${gender}, ${sqlStr(phone)}, ${sqlNullableStr(email)}, ${sqlNullableStr(idCard)}, ${deptIdSql}, NULL, ${sqlStr(posName)}, ${formatNum2(salary)}, ${formatNum2(leave)}, ${sqlStr(hireDate)}, NULL, ${sqlNullableStr(contractEnd)}, ${sqlStr(status)})")
        caseWhens.add("WHEN ${empNoSql} THEN ${pwdHashSql}")
        empNoLiterals.add(empNoSql)
    }

    let colsSpec = "emp_no, name, gender, phone, email, id_card, dept_id, position_id, position_name, base_salary, annual_leave_balance, hire_date, probation_end_date, contract_end_date, status"
    let valuesSql = String.join(valueTuples.toArray(), delimiter: ",")
    let inList = String.join(empNoLiterals.toArray(), delimiter: ",")
    let whenList = String.join(caseWhens.toArray(), delimiter: " ")
    let accountSql = "INSERT INTO sys_user (username, password_hash, role, employee_id, is_active) SELECT LOWER(e.emp_no), CASE e.emp_no ${whenList} ELSE '' END, 'EMPLOYEE', e.id, 1 FROM hr_employee e WHERE e.emp_no IN (${inList}) AND NOT EXISTS (SELECT 1 FROM sys_user su WHERE su.username = LOWER(e.emp_no))"
    let txSql = "START TRANSACTION;\nINSERT INTO hr_employee (${colsSpec}) VALUES ${valuesSql};\n${accountSql};\nCOMMIT;"

    if (!executeSql(txSql)) {
        let reason = lastDbErrorMessage()
        writeAuditLog(u, "员工管理", "批量导入", "导入 ${accepted.size} 行失败：${truncateUtf8(reason, 180)}")
        sendErr(ctx, 500, 500, "批量写入失败：${truncateUtf8(reason, 200)}")
    } else {
        writeAuditLog(u, "员工管理", "批量导入", "成功导入 ${accepted.size} 名员工并同步创建登录账号")
        sendOkMsg(ctx, "成功导入 ${accepted.size} 名员工", importResultJson(dataCount, accepted.size, 0, accepted.size, false, failedJson))
    }
}
