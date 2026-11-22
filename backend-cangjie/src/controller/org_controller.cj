package hrms_backend.controller

import std.collection.*
import std.convert.*
import stdx.net.http.*
import hrms_backend.common.*
import hrms_backend.db.*
import hrms_backend.middleware.*
import hrms_backend.service.*

class DeptRow {
    public let id: Int64
    public let parentId: Int64
    public let deptName: String
    public let leaderName: String
    public let headcountLimit: Int64
    public let description: String
    public let activeCount: Int64

    public init(id: Int64, parentId: Int64, deptName: String, leaderName: String, headcountLimit: Int64, description: String, activeCount: Int64) {
        this.id = id
        this.parentId = parentId
        this.deptName = deptName
        this.leaderName = leaderName
        this.headcountLimit = headcountLimit
        this.description = description
        this.activeCount = activeCount
    }
}

func buildDeptChildrenJson(allDepts: ArrayList<DeptRow>, parentId: Int64): String {
    let items = ArrayList<String>()
    for (d in allDepts) {
        if (d.parentId == parentId) {
            let childrenJson = buildDeptChildrenJson(allDepts, d.id)
            let obj = "{" +
                "\"id\":${d.id}," +
                "\"parentId\":${d.parentId}," +
                "\"deptName\":${jsonStr(d.deptName)}," +
                "\"leaderName\":${jsonStr(d.leaderName)}," +
                "\"headcountLimit\":${d.headcountLimit}," +
                "\"description\":${jsonStr(d.description)}," +
                "\"activeCount\":${d.activeCount}," +
                "\"children\":${childrenJson}" +
            "}"
            items.add(obj)
        }
    }
    return "[" + String.join(items.toArray(), delimiter: ",") + "]"
}

public func handleDepartmentsTree(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(_) =>
            let sql = """
SELECT d.id, d.parent_id, d.dept_name, IFNULL(d.leader_name, ''), d.headcount_limit,
       IFNULL(d.description, ''),
       (SELECT COUNT(*) FROM hr_employee e WHERE e.dept_id = d.id AND e.status != 'RESIGNED') AS active_cnt
FROM hr_department d
ORDER BY d.id ASC
"""
            let rows = queryRows(sql)
            let depts = ArrayList<DeptRow>()
            for (r in rows) {
                let id = Int64.tryParse(r[0]) ?? 0
                let pid = Int64.tryParse(r[1]) ?? 0
                let limit = Int64.tryParse(r[4]) ?? 20
                let activeCnt = Int64.tryParse(r[6]) ?? 0
                depts.add(DeptRow(id, pid, r[2], r[3], limit, r[5], activeCnt))
            }
            let treeJson = buildDeptChildrenJson(depts, 0)
            sendOk(ctx, treeJson)
    }
}

public func handleDepartmentCreate(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let parentId = getJsonInt(obj, "parentId", 0)
                    let deptName = getJsonStr(obj, "deptName", "").trimAscii()
                    let leaderName = getJsonStr(obj, "leaderName", "").trimAscii()
                    let headcountLimit = getJsonInt(obj, "headcountLimit", 20)
                    let description = getJsonStr(obj, "description", "").trimAscii()
                    if (deptName.isEmpty()) {
                        sendErr(ctx, 400, 400, "部门名称不能为空")
                        return
                    }
                    let sql = "INSERT INTO hr_department (parent_id, dept_name, leader_name, headcount_limit, description) VALUES (${parentId}, ${sqlStr(deptName)}, ${sqlNullableStr(leaderName)}, ${headcountLimit}, ${sqlNullableStr(description)})"
                    let newId = insertAndGetId(sql)
                    if (newId <= 0) {
                        sendErr(ctx, 500, 500, "创建部门失败")
                        return
                    }
                    writeAuditLog(u, "组织架构", "新增部门", "新增部门：${deptName} (ID=${newId})")
                    sendOk(ctx, "{\"id\":${newId}}")
            }
    }
}

public func handleDepartmentUpdate(ctx: HttpContext, deptId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            if (deptId <= 0) {
                sendErr(ctx, 400, 400, "无效的部门ID")
                return
            }
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let parentId = getJsonInt(obj, "parentId", 0)
                    let deptName = getJsonStr(obj, "deptName", "").trimAscii()
                    let leaderName = getJsonStr(obj, "leaderName", "").trimAscii()
                    let headcountLimit = getJsonInt(obj, "headcountLimit", 20)
                    let description = getJsonStr(obj, "description", "").trimAscii()
                    if (deptName.isEmpty()) {
                        sendErr(ctx, 400, 400, "部门名称不能为空")
                        return
                    }
                    if (parentId == deptId) {
                        sendErr(ctx, 400, 400, "父部门不能设为自身")
                        return
                    }
                    let sql = "UPDATE hr_department SET parent_id=${parentId}, dept_name=${sqlStr(deptName)}, leader_name=${sqlNullableStr(leaderName)}, headcount_limit=${headcountLimit}, description=${sqlNullableStr(description)} WHERE id=${deptId}"
                    executeSql(sql)
                    writeAuditLog(u, "组织架构", "修改部门", "修改部门ID=${deptId}：${deptName}")
                    sendOk(ctx, "{\"id\":${deptId}}")
            }
    }
}

public func handleDepartmentDelete(ctx: HttpContext, deptId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            let childCnt = querySingleInt("SELECT COUNT(*) FROM hr_department WHERE parent_id = ${deptId}", 0)
            if (childCnt > 0) {
                sendErr(ctx, 400, 400, "该部门下存在子部门，请先处理子部门")
                return
            }
            let empCnt = querySingleInt("SELECT COUNT(*) FROM hr_employee WHERE dept_id = ${deptId} AND status != 'RESIGNED'", 0)
            if (empCnt > 0) {
                sendErr(ctx, 400, 400, "该部门下仍有 ${empCnt} 名在职/试用员工，无法删除")
                return
            }
            let deptName = querySingleValue("SELECT dept_name FROM hr_department WHERE id = ${deptId}")
            if (deptName.isEmpty()) {
                sendErr(ctx, 404, 404, "部门不存在")
                return
            }
            executeSql("DELETE FROM hr_department WHERE id = ${deptId}")
            writeAuditLog(u, "组织架构", "删除部门", "删除部门：${deptName} (ID=${deptId})")
            sendOk(ctx, "null")
    }
}

public func handlePositionList(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(_) =>
            let deptId = getQueryInt(ctx, "deptId", 0)
            let whereClause = if (deptId > 0) { "WHERE p.dept_id = ${deptId}" } else { "" }
            let sql = """
SELECT p.id, p.pos_code, p.pos_name, p.dept_id, IFNULL(d.dept_name, ''),
       IFNULL(p.level_range, ''), p.min_salary, p.max_salary, DATE_FORMAT(p.created_at, '%Y-%m-%d %H:%i:%s')
FROM hr_position p
LEFT JOIN hr_department d ON p.dept_id = d.id
${whereClause}
ORDER BY p.id ASC
"""
            let rows = queryRows(sql)
            let list = ArrayList<String>()
            for (r in rows) {
                let obj = "{" +
                    "\"id\":${r[0]}," +
                    "\"posCode\":${jsonStr(r[1])}," +
                    "\"posName\":${jsonStr(r[2])}," +
                    "\"deptId\":${r[3]}," +
                    "\"deptName\":${jsonStr(r[4])}," +
                    "\"levelRange\":${jsonStr(r[5])}," +
                    "\"minSalary\":${r[6]}," +
                    "\"maxSalary\":${r[7]}," +
                    "\"createdAt\":${jsonStr(r[8])}" +
                "}"
                list.add(obj)
            }
            sendOk(ctx, "[" + String.join(list.toArray(), delimiter: ",") + "]")
    }
}

public func handlePositionCreate(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let posCode = getJsonStr(obj, "posCode", "").trimAscii()
                    let posName = getJsonStr(obj, "posName", "").trimAscii()
                    let deptId = getJsonInt(obj, "deptId", 0)
                    let levelRange = getJsonStr(obj, "levelRange", "P5-P7").trimAscii()
                    let minSalary = getJsonFloat(obj, "minSalary", 6000.0)
                    let maxSalary = getJsonFloat(obj, "maxSalary", 20000.0)
                    if (posCode.isEmpty() || posName.isEmpty() || deptId <= 0) {
                        sendErr(ctx, 400, 400, "岗位编码、岗位名称和所属部门必填")
                        return
                    }
                    let dup = querySingleInt("SELECT COUNT(*) FROM hr_position WHERE pos_code = ${sqlStr(posCode)}", 0)
                    if (dup > 0) {
                        sendErr(ctx, 400, 400, "岗位编码已存在")
                        return
                    }
                    let sql = "INSERT INTO hr_position (pos_code, pos_name, dept_id, level_range, min_salary, max_salary) VALUES (${sqlStr(posCode)}, ${sqlStr(posName)}, ${deptId}, ${sqlStr(levelRange)}, ${formatNum2(minSalary)}, ${formatNum2(maxSalary)})"
                    let newId = insertAndGetId(sql)
                    writeAuditLog(u, "组织架构", "新增岗位", "新增岗位：${posName} (${posCode})")
                    sendOk(ctx, "{\"id\":${newId}}")
            }
    }
}

public func handlePositionUpdate(ctx: HttpContext, posId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let posCode = getJsonStr(obj, "posCode", "").trimAscii()
                    let posName = getJsonStr(obj, "posName", "").trimAscii()
                    let deptId = getJsonInt(obj, "deptId", 0)
                    let levelRange = getJsonStr(obj, "levelRange", "P5-P7").trimAscii()
                    let minSalary = getJsonFloat(obj, "minSalary", 6000.0)
                    let maxSalary = getJsonFloat(obj, "maxSalary", 20000.0)
                    if (posCode.isEmpty() || posName.isEmpty() || deptId <= 0) {
                        sendErr(ctx, 400, 400, "岗位编码、岗位名称和所属部门必填")
                        return
                    }
                    let sql = "UPDATE hr_position SET pos_code=${sqlStr(posCode)}, pos_name=${sqlStr(posName)}, dept_id=${deptId}, level_range=${sqlStr(levelRange)}, min_salary=${formatNum2(minSalary)}, max_salary=${formatNum2(maxSalary)} WHERE id=${posId}"
                    executeSql(sql)
                    writeAuditLog(u, "组织架构", "修改岗位", "修改岗位：${posName} (ID=${posId})")
                    sendOk(ctx, "{\"id\":${posId}}")
            }
    }
}

public func handlePositionDelete(ctx: HttpContext, posId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            let empCnt = querySingleInt("SELECT COUNT(*) FROM hr_employee WHERE position_id = ${posId} AND status != 'RESIGNED'", 0)
            if (empCnt > 0) {
                sendErr(ctx, 400, 400, "该岗位仍有在职员工绑定，无法删除")
                return
            }
            executeSql("DELETE FROM hr_position WHERE id = ${posId}")
            writeAuditLog(u, "组织架构", "删除岗位", "删除岗位 ID=${posId}")
            sendOk(ctx, "null")
    }
}
