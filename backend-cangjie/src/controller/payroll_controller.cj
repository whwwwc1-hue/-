package hrms_backend.controller

import std.collection.*
import std.convert.*
import stdx.net.http.*
import hrms_backend.common.*
import hrms_backend.db.*
import hrms_backend.middleware.*
import hrms_backend.service.*

func calculateTax(taxableRaw: Float64): Float64 {
    let taxable = if (taxableRaw < 0.0) { 0.0 } else { taxableRaw }
    if (taxable <= 0.0) {
        return 0.0
    } else if (taxable <= 3000.0) {
        return round2(taxable * 0.03)
    } else if (taxable <= 12000.0) {
        return round2(taxable * 0.10 - 210.0)
    } else if (taxable <= 25000.0) {
        return round2(taxable * 0.20 - 1410.0)
    } else {
        return round2(taxable * 0.25 - 2660.0)
    }
}

func calculatePayrollValues(baseSalary: Float64, bonus: Float64, overtimePay: Float64, attendanceDeduction: Float64, socialSecurity: Float64): (Float64, Float64) {
    let taxable = baseSalary + bonus + overtimePay - attendanceDeduction - socialSecurity - 5000.0
    let tax = calculateTax(taxable)
    let netSalary = round2(baseSalary + bonus + overtimePay - attendanceDeduction - socialSecurity - tax)
    return (tax, netSalary)
}

func payrollRowToJson(r: ArrayList<String>): String {
    return "{" +
        "\"id\":${r[0]}," +
        "\"employeeId\":${r[1]}," +
        "\"empNo\":${jsonStr(r[2])}," +
        "\"empName\":${jsonStr(r[3])}," +
        "\"deptName\":${jsonStr(r[4])}," +
        "\"positionName\":${jsonStr(r[5])}," +
        "\"payMonth\":${jsonStr(r[6])}," +
        "\"baseSalary\":${r[7]}," +
        "\"bonus\":${r[8]}," +
        "\"overtimePay\":${r[9]}," +
        "\"attendanceDeduction\":${r[10]}," +
        "\"socialSecurity\":${r[11]}," +
        "\"tax\":${r[12]}," +
        "\"netSalary\":${r[13]}," +
        "\"status\":${jsonStr(r[14])}," +
        "\"paidAt\":${jsonStr(r[15])}," +
        "\"remark\":${jsonStr(r[16])}" +
    "}"
}

public func handlePayrollGenerate(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    var payMonth = getJsonStr(obj, "payMonth", "").trimAscii()
                    if (payMonth.isEmpty()) {
                        payMonth = querySingleValue("SELECT DATE_FORMAT(CURDATE(), '%Y-%m')")
                    }
                    let emps = queryRows("SELECT id, name, base_salary FROM hr_employee WHERE status IN ('ACTIVE', 'PROBATION')")
                    var generatedCnt: Int64 = 0
                    for (emp in emps) {
                        let empId = Int64.tryParse(emp[0]) ?? 0
                        let baseSalary = Float64.tryParse(emp[2]) ?? 0.0
                        let existingStatus = querySingleValue("SELECT status FROM hr_payroll WHERE employee_id = ${empId} AND pay_month = ${sqlStr(payMonth)} LIMIT 1")
                        if (existingStatus == "PAID") {
                            continue
                        }
                        let dailySalary = baseSalary / 21.75
                        let hourlySalary = dailySalary / 8.0

                        let otHoursStr = querySingleValue("SELECT IFNULL(SUM(duration), 0.0) FROM hr_leave_overtime WHERE employee_id = ${empId} AND category = 'OVERTIME' AND status = 'APPROVED' AND DATE_FORMAT(start_time, '%Y-%m') = ${sqlStr(payMonth)}")
                        let otHours = Float64.tryParse(otHoursStr) ?? 0.0
                        let overtimePay = round2(otHours * hourlySalary * 1.5)

                        let lateCnt = querySingleInt("SELECT COUNT(*) FROM hr_attendance WHERE employee_id = ${empId} AND DATE_FORMAT(work_date, '%Y-%m') = ${sqlStr(payMonth)} AND late_minutes > 0", 0)
                        let earlyCnt = querySingleInt("SELECT COUNT(*) FROM hr_attendance WHERE employee_id = ${empId} AND DATE_FORMAT(work_date, '%Y-%m') = ${sqlStr(payMonth)} AND early_minutes > 0", 0)
                        let personalDaysStr = querySingleValue("SELECT IFNULL(SUM(duration), 0.0) FROM hr_leave_overtime WHERE employee_id = ${empId} AND category = 'LEAVE' AND sub_type = 'PERSONAL' AND status = 'APPROVED' AND DATE_FORMAT(start_time, '%Y-%m') = ${sqlStr(payMonth)}")
                        let personalDays = Float64.tryParse(personalDaysStr) ?? 0.0
                        let attendanceDeduction = round2(Float64(lateCnt + earlyCnt) * 50.0 + personalDays * dailySalary)

                        let ratioStr = querySingleValue("SELECT bonus_ratio FROM hr_performance WHERE employee_id = ${empId} AND status = 'COMPLETED' ORDER BY id DESC LIMIT 1")
                        let bonus = if (ratioStr.isEmpty()) {
                            0.0
                        } else {
                            let ratio = Float64.tryParse(ratioStr) ?? 1.0
                            round2(baseSalary * 0.1 * ratio)
                        }
                        let socialSecurity = round2(baseSalary * 0.185)
                        let (tax, netSalary) = calculatePayrollValues(baseSalary, bonus, overtimePay, attendanceDeduction, socialSecurity)

                        if (existingStatus == "DRAFT") {
                            executeSql("UPDATE hr_payroll SET base_salary=${formatNum2(baseSalary)}, bonus=${formatNum2(bonus)}, overtime_pay=${formatNum2(overtimePay)}, attendance_deduction=${formatNum2(attendanceDeduction)}, social_security=${formatNum2(socialSecurity)}, tax=${formatNum2(tax)}, net_salary=${formatNum2(netSalary)} WHERE employee_id=${empId} AND pay_month=${sqlStr(payMonth)}")
                        } else {
                            executeSql("INSERT INTO hr_payroll (employee_id, pay_month, base_salary, bonus, overtime_pay, attendance_deduction, social_security, tax, net_salary, status) VALUES (${empId}, ${sqlStr(payMonth)}, ${formatNum2(baseSalary)}, ${formatNum2(bonus)}, ${formatNum2(overtimePay)}, ${formatNum2(attendanceDeduction)}, ${formatNum2(socialSecurity)}, ${formatNum2(tax)}, ${formatNum2(netSalary)}, 'DRAFT')")
                        }
                        generatedCnt += 1
                    }
                    writeAuditLog(u, "薪酬管理", "生成工资单", "一键生成 ${payMonth} 月份工资单，共处理 ${generatedCnt} 人")
                    sendOk(ctx, "{\"payMonth\":${jsonStr(payMonth)},\"generatedCount\":${generatedCnt}}")
            }
    }
}

public func handlePayrollList(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(_) =>
            let payMonth = getQueryStr(ctx, "payMonth", "").trimAscii()
            let status = getQueryStr(ctx, "status", "").trimAscii()
            let keyword = getQueryStr(ctx, "keyword", "").trimAscii()
            var page = getQueryInt(ctx, "page", 1)
            var pageSize = getQueryInt(ctx, "pageSize", 20)
            if (page < 1) { page = 1 }
            if (pageSize < 1 || pageSize > 100) { pageSize = 20 }

            let conds = ArrayList<String>()
            conds.add("1=1")
            if (!payMonth.isEmpty()) {
                conds.add("p.pay_month = ${sqlStr(payMonth)}")
            }
            if (!status.isEmpty()) {
                conds.add("p.status = ${sqlStr(status)}")
            }
            if (!keyword.isEmpty()) {
                let kw = sqlStr("%" + keyword + "%")
                conds.add("(e.name LIKE ${kw} OR e.emp_no LIKE ${kw})")
            }
            let whereSql = "WHERE " + String.join(conds.toArray(), delimiter: " AND ")
            let total = querySingleInt("SELECT COUNT(*) FROM hr_payroll p LEFT JOIN hr_employee e ON p.employee_id = e.id ${whereSql}", 0)
            let offset = (page - 1) * pageSize
            let sql = """
SELECT p.id, p.employee_id, IFNULL(e.emp_no, ''), IFNULL(e.name, ''), IFNULL(d.dept_name, ''),
       IFNULL(e.position_name, ''), p.pay_month, p.base_salary, p.bonus, p.overtime_pay,
       p.attendance_deduction, p.social_security, p.tax, p.net_salary, p.status,
       IFNULL(DATE_FORMAT(p.paid_at, '%Y-%m-%d %H:%i:%s'), ''), IFNULL(p.remark, '')
FROM hr_payroll p
LEFT JOIN hr_employee e ON p.employee_id = e.id
LEFT JOIN hr_department d ON e.dept_id = d.id
${whereSql}
ORDER BY p.pay_month DESC, p.id DESC
LIMIT ${pageSize} OFFSET ${offset}
"""
            let rows = queryRows(sql)
            let list = ArrayList<String>()
            for (r in rows) {
                list.add(payrollRowToJson(r))
            }
            sendPage(ctx, "[" + String.join(list.toArray(), delimiter: ",") + "]", total, page, pageSize)
    }
}

public func handlePayrollUpdate(ctx: HttpContext, payrollId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            let rows = queryRows("SELECT base_salary, bonus, overtime_pay, attendance_deduction, social_security, status, IFNULL(remark, '') FROM hr_payroll WHERE id = ${payrollId} LIMIT 1")
            if (rows.size == 0) {
                sendErr(ctx, 404, 404, "工资单不存在")
                return
            }
            let r = rows[0]
            if (r[5] == "PAID") {
                sendErr(ctx, 400, 400, "已发放工资单不可修改")
                return
            }
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let baseSalary = Float64.tryParse(r[0]) ?? 0.0
                    let bonus = getJsonFloat(obj, "bonus", Float64.tryParse(r[1]) ?? 0.0)
                    let overtimePay = getJsonFloat(obj, "overtimePay", Float64.tryParse(r[2]) ?? 0.0)
                    let attDeduction = getJsonFloat(obj, "attendanceDeduction", Float64.tryParse(r[3]) ?? 0.0)
                    let socialSecurity = Float64.tryParse(r[4]) ?? 0.0
                    let remark = getJsonStr(obj, "remark", r[6]).trimAscii()
                    let (tax, netSalary) = calculatePayrollValues(baseSalary, bonus, overtimePay, attDeduction, socialSecurity)
                    let sql = "UPDATE hr_payroll SET bonus=${formatNum2(bonus)}, overtime_pay=${formatNum2(overtimePay)}, attendance_deduction=${formatNum2(attDeduction)}, tax=${formatNum2(tax)}, net_salary=${formatNum2(netSalary)}, remark=${sqlNullableStr(remark)} WHERE id=${payrollId}"
                    executeSql(sql)
                    writeAuditLog(u, "薪酬管理", "调整工资单", "调整工资单 ID=${payrollId}：奖金=${formatNum2(bonus)}，个税=${formatNum2(tax)}，实发=${formatNum2(netSalary)}")
                    sendOk(ctx, "{\"id\":${payrollId},\"tax\":${formatNum2(tax)},\"netSalary\":${formatNum2(netSalary)}}")
            }
    }
}

public func handlePayrollPaySingle(ctx: HttpContext, payrollId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            let rows = queryRows("SELECT p.status, p.pay_month, e.name, p.net_salary, p.employee_id FROM hr_payroll p LEFT JOIN hr_employee e ON p.employee_id = e.id WHERE p.id = ${payrollId} LIMIT 1")
            if (rows.size == 0) {
                sendErr(ctx, 404, 404, "工资单不存在")
                return
            }
            if (rows[0][0] == "PAID") {
                sendErr(ctx, 400, 400, "该工资单已发放")
                return
            }
            executeSql("UPDATE hr_payroll SET status='PAID', paid_at=NOW() WHERE id=${payrollId}")
            pushNotificationToEmployee(Int64.tryParse(rows[0][4]) ?? 0, "工资条已发放", "你的 ${rows[0][1]} 月度工资单已发放，实发 ${rows[0][3]} 元，可在「薪酬与工资条」查看电子凭条。", "PAYROLL")
            writeAuditLog(u, "薪酬管理", "发放工资", "确认发放 ${rows[0][2]} (${rows[0][1]}) 实发 ${rows[0][3]} 元")
            sendOk(ctx, "null")
    }
}

public func handlePayrollBatchPay(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let payMonth = getJsonStr(obj, "payMonth", "").trimAscii()
                    if (payMonth.isEmpty()) {
                        sendErr(ctx, 400, 400, "请指定发薪月份 payMonth")
                        return
                    }
                    let draftRows = queryRows("SELECT employee_id, net_salary FROM hr_payroll WHERE pay_month = ${sqlStr(payMonth)} AND status = 'DRAFT'")
                    let cnt = draftRows.size
                    if (cnt == 0) {
                        sendErr(ctx, 400, 400, "该月份没有待发放的工资单")
                        return
                    }
                    executeSql("UPDATE hr_payroll SET status='PAID', paid_at=NOW() WHERE pay_month=${sqlStr(payMonth)} AND status='DRAFT'")
                    for (r in draftRows) {
                        pushNotificationToEmployee(Int64.tryParse(r[0]) ?? 0, "工资条已发放", "你的 ${payMonth} 月度工资单已发放，实发 ${r[1]} 元。", "PAYROLL")
                    }
                    writeAuditLog(u, "薪酬管理", "批量发薪", "批量发放 ${payMonth} 月度工资单，共 ${cnt} 笔")
                    sendOk(ctx, "{\"paidCount\":${cnt}}")
            }
    }
}

public func handlePayrollMy(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            let sql = """
SELECT p.id, p.employee_id, IFNULL(e.emp_no, ''), IFNULL(e.name, ''), IFNULL(d.dept_name, ''),
       IFNULL(e.position_name, ''), p.pay_month, p.base_salary, p.bonus, p.overtime_pay,
       p.attendance_deduction, p.social_security, p.tax, p.net_salary, p.status,
       IFNULL(DATE_FORMAT(p.paid_at, '%Y-%m-%d %H:%i:%s'), ''), IFNULL(p.remark, '')
FROM hr_payroll p
LEFT JOIN hr_employee e ON p.employee_id = e.id
LEFT JOIN hr_department d ON e.dept_id = d.id
WHERE p.employee_id = ${u.employeeId} AND p.status = 'PAID'
ORDER BY p.pay_month DESC
"""
            let rows = queryRows(sql)
            let list = ArrayList<String>()
            for (r in rows) {
                list.add(payrollRowToJson(r))
            }
            sendOk(ctx, "[" + String.join(list.toArray(), delimiter: ",") + "]")
    }
}
