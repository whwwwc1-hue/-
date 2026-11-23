package hrms_backend.controller

import std.collection.*
import std.convert.*
import stdx.net.http.*
import hrms_backend.common.*
import hrms_backend.db.*
import hrms_backend.middleware.*

public func handleDashboardOverview(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(_) =>
            let totalActive = querySingleInt("SELECT COUNT(*) FROM hr_employee WHERE status != 'RESIGNED'", 0)
            let monthlyHires = querySingleInt("SELECT COUNT(*) FROM hr_employee WHERE DATE_FORMAT(hire_date, '%Y-%m') = DATE_FORMAT(CURDATE(), '%Y-%m')", 0)
            let monthlyResigns = querySingleInt("SELECT COUNT(*) FROM hr_employee WHERE status = 'RESIGNED' AND DATE_FORMAT(resign_date, '%Y-%m') = DATE_FORMAT(CURDATE(), '%Y-%m')", 0)
            let todayClockedIn = querySingleInt("SELECT COUNT(*) FROM hr_attendance WHERE work_date = CURDATE()", 0)
            let attendanceRate = if (totalActive > 0) {
                round2(Float64(todayClockedIn) * 100.0 / Float64(totalActive))
            } else {
                0.0
            }
            let pendingApprovals = querySingleInt("SELECT COUNT(*) FROM hr_leave_overtime WHERE ${reqPendingCountCondition()}", 0)
            let expiringContractsCount = querySingleInt("SELECT COUNT(*) FROM hr_employee WHERE status != 'RESIGNED' AND contract_end_date IS NOT NULL AND contract_end_date BETWEEN CURDATE() AND DATE_ADD(CURDATE(), INTERVAL 30 DAY)", 0)

            let expRows = queryRows("""
SELECT e.id, e.emp_no, e.name, IFNULL(d.dept_name, ''), e.position_name,
       DATE_FORMAT(e.contract_end_date, '%Y-%m-%d'),
       DATEDIFF(e.contract_end_date, CURDATE()) AS days_left
FROM hr_employee e
LEFT JOIN hr_department d ON e.dept_id = d.id
WHERE e.status != 'RESIGNED' AND e.contract_end_date IS NOT NULL
  AND e.contract_end_date BETWEEN CURDATE() AND DATE_ADD(CURDATE(), INTERVAL 30 DAY)
ORDER BY e.contract_end_date ASC
""")
            let expList = ArrayList<String>()
            for (r in expRows) {
                expList.add("{\"id\":${r[0]},\"empNo\":${jsonStr(r[1])},\"name\":${jsonStr(r[2])},\"deptName\":${jsonStr(r[3])},\"positionName\":${jsonStr(r[4])},\"contractEndDate\":${jsonStr(r[5])},\"daysLeft\":${r[6]}}")
            }

            let deptRows = queryRows("""
SELECT d.dept_name, COUNT(e.id) AS cnt
FROM hr_department d
LEFT JOIN hr_employee e ON e.dept_id = d.id AND e.status != 'RESIGNED'
GROUP BY d.id, d.dept_name
ORDER BY d.id ASC
""")
            let deptList = ArrayList<String>()
            for (r in deptRows) {
                deptList.add("{\"deptName\":${jsonStr(r[0])},\"count\":${r[1]}}")
            }

            let statusRows = queryRows("SELECT status, COUNT(*) FROM hr_employee GROUP BY status")
            let statusList = ArrayList<String>()
            for (r in statusRows) {
                statusList.add("{\"status\":${jsonStr(r[0])},\"count\":${r[1]}}")
            }

            let attTrendRows = queryRows("""
SELECT DATE_FORMAT(d_tbl.dt, '%m-%d') AS label,
       COUNT(a.id) AS total_cnt,
       SUM(CASE WHEN a.status = 'NORMAL' THEN 1 ELSE 0 END) AS normal_cnt
FROM (
    SELECT DATE_SUB(CURDATE(), INTERVAL 6 DAY) AS dt UNION ALL
    SELECT DATE_SUB(CURDATE(), INTERVAL 5 DAY) UNION ALL
    SELECT DATE_SUB(CURDATE(), INTERVAL 4 DAY) UNION ALL
    SELECT DATE_SUB(CURDATE(), INTERVAL 3 DAY) UNION ALL
    SELECT DATE_SUB(CURDATE(), INTERVAL 2 DAY) UNION ALL
    SELECT DATE_SUB(CURDATE(), INTERVAL 1 DAY) UNION ALL
    SELECT CURDATE()
) d_tbl
LEFT JOIN hr_attendance a ON a.work_date = d_tbl.dt
GROUP BY d_tbl.dt
ORDER BY d_tbl.dt ASC
""")
            let attTrendList = ArrayList<String>()
            for (r in attTrendRows) {
                attTrendList.add("{\"date\":${jsonStr(r[0])},\"clockedIn\":${r[1]},\"normalCount\":${r[2]}}")
            }

            let payTrendRows = queryRows("""
SELECT m_tbl.ym, IFNULL(SUM(p.net_salary), 0.0) AS total_net
FROM (
    SELECT DATE_FORMAT(DATE_SUB(CURDATE(), INTERVAL 5 MONTH), '%Y-%m') AS ym UNION ALL
    SELECT DATE_FORMAT(DATE_SUB(CURDATE(), INTERVAL 4 MONTH), '%Y-%m') UNION ALL
    SELECT DATE_FORMAT(DATE_SUB(CURDATE(), INTERVAL 3 MONTH), '%Y-%m') UNION ALL
    SELECT DATE_FORMAT(DATE_SUB(CURDATE(), INTERVAL 2 MONTH), '%Y-%m') UNION ALL
    SELECT DATE_FORMAT(DATE_SUB(CURDATE(), INTERVAL 1 MONTH), '%Y-%m') UNION ALL
    SELECT DATE_FORMAT(CURDATE(), '%Y-%m')
) m_tbl
LEFT JOIN hr_payroll p ON p.pay_month = m_tbl.ym
GROUP BY m_tbl.ym
ORDER BY m_tbl.ym ASC
""")
            let payTrendList = ArrayList<String>()
            for (r in payTrendRows) {
                payTrendList.add("{\"payMonth\":${jsonStr(r[0])},\"totalNetSalary\":${r[1]}}")
            }

            let kpisJson = "{" +
                "\"totalActiveEmployees\":${totalActive}," +
                "\"monthlyHires\":${monthlyHires}," +
                "\"monthlyResigns\":${monthlyResigns}," +
                "\"todayClockedIn\":${todayClockedIn}," +
                "\"todayAttendanceRate\":${formatNum2(attendanceRate)}," +
                "\"pendingApprovals\":${pendingApprovals}," +
                "\"expiringContractsCount\":${expiringContractsCount}" +
            "}"
            let dataJson = "{" +
                "\"kpis\":${kpisJson}," +
                "\"expiringContracts\":[${String.join(expList.toArray(), delimiter: ",")}]," +
                "\"deptDistribution\":[${String.join(deptList.toArray(), delimiter: ",")}]," +
                "\"statusDistribution\":[${String.join(statusList.toArray(), delimiter: ",")}]," +
                "\"attendanceTrend\":[${String.join(attTrendList.toArray(), delimiter: ",")}]," +
                "\"payrollTrend\":[${String.join(payTrendList.toArray(), delimiter: ",")}]" +
            "}"
            sendOk(ctx, dataJson)
    }
}
