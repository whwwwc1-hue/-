package hrms_backend.controller

import std.collection.*
import std.convert.*
import stdx.net.http.*
import hrms_backend.common.*
import hrms_backend.db.*
import hrms_backend.middleware.*
import hrms_backend.service.*

// ==================== P3.2 站内通知中心（纯函数区，可脱离数据库单测） ====================
// 设计取舍：
// 1. 通知是「派生数据」，丢了不该影响主业务，所以 pushNotification 全程吞不到 500——
//    但 SQL 真失败时必须留下 lastDbError，不能静默当成功（与 P0.1 的 D1 修复口径一致）。
// 2. title / content 一律由本文件代码拼装，**绝不把用户输入的 reason / remark 塞进去**：
//    那两者可达数百字，会顶穿列宽（title 120 / content 500），
//    而通知点开后的跳转目标（refId + type）才是真正要回显的内容。
//    例外是员工姓名（`notifyNextLevel` / 合同到期批量提醒都会带），
//    它是受控短字段，且 `sqlStr` 与 `jsonEscape` 已覆盖 `' " \ CR LF TAB`（往返实测见第十一节）。
// 3. 去重靠 UNIQUE(user_id, type, ref_id) + 插入前的 COUNT 预检 + INSERT IGNORE：
//    同一个业务事件重复触发（例如 HR 连点两次「批量发薪」）只留一条通知。
//    其中 INSERT IGNORE 不是可有可无的保险——mysql.exe 跑脚本没有 --force，
//    一条 duplicate 报错会把同脚本后续所有语句一起中止，实测见 notifInsertSql 注释。

/** 通知类型白名单：只有这 5 类，越界一律拒绝写入，避免脏 type 让前端映射不到路由。 */
public func notifIsValidType(t: String): Bool {
    if (t == "CONTRACT_EXPIRING") { return true }
    if (t == "LEAVE_APPROVED") { return true }
    if (t == "LEAVE_REJECTED") { return true }
    if (t == "LEAVE_NEXT_LEVEL") { return true }
    if (t == "PAYROLL_PAID") { return true }
    return false
}

/** 类型 -> 中文标签，直接下发给前端，省得前端再维护一份映射表。 */
public func notifTypeLabel(t: String): String {
    if (t == "CONTRACT_EXPIRING") { return "合同到期提醒" }
    if (t == "LEAVE_APPROVED") { return "审批已通过" }
    if (t == "LEAVE_REJECTED") { return "审批已驳回" }
    if (t == "LEAVE_NEXT_LEVEL") { return "待你复核" }
    if (t == "PAYROLL_PAID") { return "工资条已发放" }
    return "系统通知"
}

/**
 * readFlag 查询参数 -> SQL 片段（白名单，非 0/1 一律视为「全部」）。
 *
 * 这是本模块唯一的注入面，所以只允许产出三种结果，其它输入必须回落空串。
 */
public func notifReadCond(raw: String): String {
    if (raw == "0") { return "AND read_flag = 0" }
    if (raw == "1") { return "AND read_flag = 1" }
    return ""
}

/** limit 钳位：<=0 视为默认 20，上限 50（铃铛抽屉是滚动加载，不该一次拖全表）。 */
public func notifClampLimit(raw: Int64): Int64 {
    if (raw <= 0) { return 20 }
    if (raw > 50) { return 50 }
    return raw
}

/** 未读数查询（红点轮询每 30 秒打一次，所以必须只有一列 COUNT，别复用列表 SQL）。 */
public func notifUnreadSql(userId: Int64): String {
    return "SELECT COUNT(*) FROM sys_notification WHERE user_id = ${userId} AND read_flag = 0"
}

/** 列表查询：只取本人通知，未读优先无意义，一律按时间倒序。 */
public func notifListSql(userId: Int64, readFlag: String, limit: Int64): String {
    return """SELECT id, type, title, IFNULL(content, ''), IFNULL(ref_id, ''), read_flag,
       DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s')
FROM sys_notification
WHERE user_id = ${userId} ${notifReadCond(readFlag)}
ORDER BY created_at DESC, id DESC
LIMIT ${limit}"""
}

/** 单条已读：WHERE 里带 user_id，越权改别人的通知会命中 0 行而不是成功。 */
public func notifReadSql(notifId: Int64, userId: Int64): String {
    return "UPDATE sys_notification SET read_flag = 1 WHERE id = ${notifId} AND user_id = ${userId} AND read_flag = 0"
}

/** 影响行数（用于区分「不存在/不属于你」与「已是已读」）。 */
public func notifReadCountSql(notifId: Int64, userId: Int64): String {
    return "SELECT COUNT(*) FROM sys_notification WHERE id = ${notifId} AND user_id = ${userId}"
}

public func notifIsReadSql(notifId: Int64, userId: Int64): String {
    return "SELECT read_flag FROM sys_notification WHERE id = ${notifId} AND user_id = ${userId} LIMIT 1"
}

public func notifReadAllSql(userId: Int64): String {
    return "UPDATE sys_notification SET read_flag = 1 WHERE user_id = ${userId} AND read_flag = 0"
}

/** 去重预检：同一 (user, type, ref) 只允许一条。 */
public func notifExistsSql(userId: Int64, type: String, refId: String): String {
    return "SELECT COUNT(*) FROM sys_notification WHERE user_id = ${userId} AND type = ${sqlStr(type)} AND ref_id = ${sqlStr(refId)}"
}

// 必须用 INSERT IGNORE：mysql.exe 执行脚本时没带 --force，
// 任一语句报错会**中止整个文件**（已在真实 hrms_db 实测：第二条撞 UNIQUE 后，
// 同脚本第 19 行之后的语句一条都没跑）。批量写入里一条重复就会吞掉后面所有人的通知。
// IGNORE 把 duplicate-key 降级为 warning，脚本继续且退出码为 0。
public func notifInsertSql(userId: Int64, type: String, title: String, content: String, refId: String): String {
    return """INSERT IGNORE INTO sys_notification (user_id, type, title, content, ref_id, read_flag)
VALUES (${userId}, ${sqlStr(type)}, ${sqlStr(title)}, ${sqlStr(content)}, ${sqlStr(refId)}, 0)"""
}

/** 按 employee_id 反查 sys_user.id；查不到（离职账号被删）返回 0，调用方据此跳过。 */
public func notifUserByEmpSql(empId: Int64): String {
    return "SELECT id FROM sys_user WHERE employee_id = ${empId} LIMIT 1"
}

/**
 * 通知行 -> JSON。列顺序必须与 notifListSql 的 SELECT 一致（7 列）。
 * readFlag 出成布尔，前端直接用 `v-if="n.isRead"`，不必再比 '0'/'1' 字符串。
 */
public func notifRowToJson(r: ArrayList<String>): String {
    if (r.size < 7) { return "" }
    let readFlag = if (r[5] == "1") { "true" } else { "false" }
    return "{" +
        "\"id\":${r[0]}," +
        "\"type\":${jsonStr(r[1])}," +
        "\"typeLabel\":${jsonStr(notifTypeLabel(r[1]))}," +
        "\"title\":${jsonStr(r[2])}," +
        "\"content\":${jsonStr(r[3])}," +
        "\"refId\":${jsonStr(r[4])}," +
        "\"isRead\":${readFlag}," +
        "\"createdAt\":${jsonStr(r[6])}" +
        "}"
}

/** 把多行通知拼成 JSON 数组（空集合必须是 []，不能是空串，否则前端 .map 直接抛）。 */
public func notifRowsToJsonArray(rows: ArrayList<ArrayList<String>>): String {
    let parts = ArrayList<String>()
    for (r in rows) {
        let j = notifRowToJson(r)
        if (!j.isEmpty()) { parts.add(j) }
    }
    if (parts.size == 0) { return "[]" }
    var out = "["
    var i: Int64 = 0
    while (i < parts.size) {
        out = out + parts[i]
        if (i + 1 < parts.size) { out = out + "," }
        i += 1
    }
    return out + "]"
}

// ============================ 写入侧：三个业务触发点 ============================

/**
 * 写一条通知（去重 + 失败不阻断主业务）。
 *
 * 返回 true 表示真的落库了，false 表示「已存在或写失败」——调用方不关心，
 * 但单测和排障时可以用它判断去重是否生效。
 */
public func pushNotification(userId: Int64, type: String, title: String, content: String, refId: String): Bool {
    if (userId <= 0) { return false }
    if (!notifIsValidType(type)) { return false }
    if (querySingleInt(notifExistsSql(userId, type, refId), 0) > 0) { return false }
    return executeSql(notifInsertSql(userId, type, title, content, refId))
}

/** 员工ID -> 用户ID（0 表示没有对应账号）。 */
public func notifResolveUser(empId: Int64): Int64 {
    if (empId <= 0) { return 0 }
    return querySingleInt(notifUserByEmpSql(empId), 0)
}

/**
 * 审批结果通知（P3.1 终态才发，中间态不发，避免一级签完就给员工推「已通过」）。
 *
 * nextStatus 由 request_controller 算好传进来，这里不再判状态机，
 * 避免同一套规则在两个文件里各写一遍（P3.1 已经吃过「两份实现漂移」的教训）。
 * refId **必须用申请单ID**：用 "approved" 这类常量会让 UNIQUE(user,type,ref)
 * 把该员工历史上所有通过通知吞成一条，第二张单子就不通知了。
 */
public func notifyRequestResult(requestId: Int64, applicantEmpId: Int64, nextStatus: String, category: String, duration: Float64): Unit {
    if (nextStatus != "APPROVED" && nextStatus != "REJECTED") { return }
    if (requestId <= 0) { return }
    let uid = notifResolveUser(applicantEmpId)
    if (uid <= 0) { return }
    let label = notifCategoryLabel(category)
    let daysText = notifDurationText(category, duration)
    let ref = "${requestId}"
    if (nextStatus == "APPROVED") {
        pushNotification(uid, "LEAVE_APPROVED", "${label}申请已通过",
            "你发起的${label}（${daysText}）已通过审批。", ref)
    } else {
        pushNotification(uid, "LEAVE_REJECTED", "${label}申请被驳回",
            "你发起的${label}（${daysText}）未通过审批，可在「我的申请记录」查看审批意见。", ref)
    }
}

/** 长假一级通过 -> 提醒 HR 有单待复核（refId 用申请单ID，天然去重）。 */
public func notifyNextLevel(requestId: Int64, applicantName: String, hrUserId: Int64): Unit {
    if (requestId <= 0 || hrUserId <= 0) { return }
    pushNotification(hrUserId, "LEAVE_NEXT_LEVEL", "有长假待你复核",
        "${applicantName} 的请假申请已超过 3 天，部门主管已通过一级，请复核。", "${requestId}")
}

/** 发薪成功 -> 通知该员工（refId 用工资单ID，点击跳「我的工资条」）。 */
public func notifyPayrollPaid(empId: Int64, payrollId: Int64, payMonth: String): Unit {
    if (payrollId <= 0) { return }
    let uid = notifResolveUser(empId)
    if (uid <= 0) { return }
    pushNotification(uid, "PAYROLL_PAID", "${payMonth} 工资条已发放",
        "${payMonth} 的工资已发放，点击查看详情。", "${payrollId}")
}

/** 谁该收到合同到期提醒：在职的 ADMIN + HR 账号。 */
public func notifManagerUserSql(): String {
    return "SELECT id FROM sys_user WHERE role IN ('ADMIN', 'HR') AND is_active = 1"
}

/** 长假二级流转后该由谁复核：在职的 HR 账号。 */
public func notifHrUserSql(): String {
    return "SELECT id FROM sys_user WHERE role = 'HR' AND is_active = 1"
}

/** 收集 user id 列；空集合直接返回空数组，调用方 for 一遍就是 no-op。 */
public func notifUserIds(rows: ArrayList<ArrayList<String>>): ArrayList<Int64> {
    let ids = ArrayList<Int64>()
    for (r in rows) {
        if (r.size >= 1) {
            let id = Int64.tryParse(r[0]) ?? 0
            if (id > 0) { ids.add(id) }
        }
    }
    return ids
}

/** 申请大类的中文说法（通知文案专用，别和前端下拉的选项名混用）。 */
public func notifCategoryLabel(category: String): String {
    if (category == "LEAVE") { return "请假" }
    if (category == "OVERTIME") { return "加班" }
    return "假勤"
}

/** 时长文案：请假按天、加班按小时，单位错了会被当成 bug 提。 */
public func notifDurationText(category: String, days: Float64): String {
    let n = formatNum2(days)
    if (category == "OVERTIME") { return "${n} 小时" }
    return "${n} 天"
}

// ==================== 批量发薪通知（N 个员工固定 3 次 mysql.exe） ====================
// 单条 pushNotification 是「1 次 COUNT + 1 次 INSERT」= 2 个子进程。
// 按 P0.1 体检的 D3（每条 SQL 起一个 mysql.exe），20 人批量发薪就是 40 个进程，
// 所以这里改成：2 条查询取回「已通知过的 ref」+「员工→用户映射」，
// 再把 N 条 INSERT 拼成 1 个 SQL 脚本一次执行 —— 总进程数与人数无关，恒为 3。
// 与 P3.1 审批链 loadApprovalTrail 的批量取回是同一个动因。

/** Int64 列表拼成 IN (...) 用的裸数字串；空列表必须给 0，否则 `IN ()` 是语法错误。 */
public func notifNumList(ids: ArrayList<Int64>): String {
    if (ids.size == 0) { return "0" }
    var out = ""
    var i: Int64 = 0
    while (i < ids.size) {
        out = out + "${ids[i]}"
        if (i + 1 < ids.size) { out = out + "," }
        i += 1
    }
    return out
}

/** 已经通知过的 ref_id（用于跳过重复发放，走索引 uk_notif_user_type_ref 的前缀）。 */
public func notifSeenRefsSql(type: String, refs: ArrayList<Int64>): String {
    return "SELECT ref_id FROM sys_notification WHERE type = ${sqlStr(type)} AND ref_id IN (${notifNumList(refs)})"
}

/** 员工ID -> 用户ID 映射，一次取回，别在循环里查。 */
public func notifUserMapSql(empIds: ArrayList<Int64>): String {
    return "SELECT id, employee_id FROM sys_user WHERE employee_id IN (${notifNumList(empIds)}) AND employee_id IS NOT NULL"
}

/** ref_id 是否已通知过（线性扫即可，批量发薪最多几十条，且不能用 String.contains——基线零先例）。 */
public func notifSeen(seenRefs: ArrayList<String>, ref: String): Bool {
    for (s in seenRefs) {
        if (s == ref) { return true }
    }
    return false
}

/** 从 [user_id, employee_id] 行集里找某员工的用户ID，找不到返回 0。 */
public func notifMapUser(userRows: ArrayList<ArrayList<String>>, empId: String): Int64 {
    for (r in userRows) {
        if (r.size >= 2 && r[1] == empId) {
            return Int64.tryParse(r[0]) ?? 0
        }
    }
    return 0
}

/**
 * 多条 INSERT 拼成一个脚本（一个脚本 = 一个 mysql.exe 进程）。
 *
 * 这里刻意不用 `INSERT ... VALUES (..),(..)` 的多值语法，而是逐条写：
 * 多值 INSERT 是**单条语句**，只要其中一行有问题整条就失败；逐条写把失败面缩小到自己那一行。
 *
 * ⚠️ 但「逐条写就能让某条失败不影响其它条」是**错的**，实测已推翻：
 * mysql.exe 未加 `--force`，脚本里任一语句报错都会中止后续所有语句。
 * 所以真正的容错来自 `notifInsertSql` 里的 `INSERT IGNORE`（见该函数注释），
 * 两者作用不同——IGNORE 负责不中止，逐条负责少伤。
 */
public func notifJoinInserts(parts: ArrayList<String>): String {
    if (parts.size == 0) { return "" }
    var out = ""
    var i: Int64 = 0
    while (i < parts.size) {
        out = out + parts[i] + ";\n"
        i += 1
    }
    return out
}

/**
 * 批量发薪后给每个员工推一条工资条通知。
 * items 行结构 = [工资单ID, 员工ID]，由调用方在 UPDATE 之前取好。
 */
public func notifyPayrollBatchPaid(items: ArrayList<ArrayList<String>>, payMonth: String): Unit {
    if (items.size == 0) { return }
    let empIds = ArrayList<Int64>()
    let refs = ArrayList<Int64>()
    for (r in items) {
        if (r.size >= 2) {
            let pid = Int64.tryParse(r[0]) ?? 0
            let eid = Int64.tryParse(r[1]) ?? 0
            if (pid > 0) { refs.add(pid) }
            if (eid > 0) { empIds.add(eid) }
        }
    }
    if (refs.size == 0 || empIds.size == 0) { return }
    let seenRefs = queryRows(notifSeenRefsSql("PAYROLL_PAID", refs))
    let userRows = queryRows(notifUserMapSql(empIds))
    let parts = ArrayList<String>()
    for (r in items) {
        if (r.size < 2) { continue }
        if (notifSeen(seenRefs, r[0])) { continue }
        let uid = notifMapUser(userRows, r[1])
        if (uid <= 0) { continue }
        parts.add(notifInsertSql(uid, "PAYROLL_PAID", "${payMonth} 工资条已发放",
            "${payMonth} 的工资已发放，点击查看详情。", r[0]))
    }
    let script = notifJoinInserts(parts)
    if (script.isEmpty()) { return }
    executeSql(script)
}

/** 字符串版 IN (...)：每个元素都必须过 sqlStr，不允许有任何未转义输入走到这里。 */
public func notifStrList(items: ArrayList<String>): String {
    if (items.size == 0) { return "''" }
    var out = ""
    var i: Int64 = 0
    while (i < items.size) {
        out = out + sqlStr(items[i])
        if (i + 1 < items.size) { out = out + "," }
        i += 1
    }
    return out
}

public func notifSeenStrRefsSql(type: String, refs: ArrayList<String>): String {
    return "SELECT ref_id FROM sys_notification WHERE type = ${sqlStr(type)} AND ref_id IN (${notifStrList(refs)})"
}

/**
 * 合同到期批量扫描（工作台触发）。
 * expRows 行结构沿用 dashboard 现有查询：[员工ID, 工号, 姓名, 部门, 岗位, 到期日, 剩余天数]。
 * managerUserIds 为空（没有在职 HR/ADMIN 账号）时直接不查库，避免员工刷新工作台也写库。
 */
public func notifyContractExpiringBatch(managerUserIds: ArrayList<Int64>, expRows: ArrayList<ArrayList<String>>): Unit {
    if (managerUserIds.size == 0 || expRows.size == 0) { return }
    let refs = ArrayList<String>()
    for (r in expRows) {
        if (r.size >= 7) { refs.add("${r[0]}:${r[5]}") }
    }
    if (refs.size == 0) { return }
    let seenRefs = queryRows(notifSeenStrRefsSql("CONTRACT_EXPIRING", refs))
    let parts = ArrayList<String>()
    for (r in expRows) {
        if (r.size < 7) { continue }
        let empId = Int64.tryParse(r[0]) ?? 0
        if (empId <= 0) { continue }
        let ref = "${r[0]}:${r[5]}"
        if (notifSeen(seenRefs, ref)) { continue }
        let daysLeft = Int64.tryParse(r[6]) ?? 0
        for (uid in managerUserIds) {
            parts.add(notifInsertSql(uid, "CONTRACT_EXPIRING", "合同即将到期",
                "${r[2]} 的劳动合同将于 ${r[5]} 到期（剩余 ${daysLeft} 天），请及时办理续签。", ref))
        }
    }
    let script = notifJoinInserts(parts)
    if (script.isEmpty()) { return }
    executeSql(script)
}

// ============================ HTTP 处理器 ============================

/** GET /api/v1/notifications?readFlag=&limit= */
public func handleNotificationList(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            let readFlag = getQueryStr(ctx, "readFlag", "")
            let limit = notifClampLimit(getQueryInt(ctx, "limit", 20))
            let rows = queryRows(notifListSql(u.userId, readFlag, limit))
            let unread = querySingleInt(notifUnreadSql(u.userId), 0)
            let total = querySingleInt("SELECT COUNT(*) FROM sys_notification WHERE user_id = ${u.userId}", 0)
            sendOk(ctx, "{\"list\":${notifRowsToJsonArray(rows)},\"unread\":${unread},\"total\":${total}}")
    }
}

/** GET /api/v1/notifications/unread-count —— 30 秒轮询专用，payload 只有一个整数 */
public func handleNotificationUnread(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            let unread = querySingleInt(notifUnreadSql(u.userId), 0)
            sendOk(ctx, "{\"unread\":${unread}}")
    }
}

/** PUT /api/v1/notifications/:id/read */
public func handleNotificationRead(ctx: HttpContext, notifId: Int64): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            if (notifId <= 0) {
                sendErr(ctx, 400, 400, "通知ID不合法")
                return
            }
            if (querySingleInt(notifReadCountSql(notifId, u.userId), 0) == 0) {
                sendErr(ctx, 404, 404, "通知不存在")
                return
            }
            if (querySingleValue(notifIsReadSql(notifId, u.userId)) == "1") {
                sendOkMsg(ctx, "该通知已是已读状态", "{\"id\":${notifId},\"changed\":0}")
                return
            }
            if (!executeSql(notifReadSql(notifId, u.userId))) {
                sendErr(ctx, 500, 500, "标记已读失败，请稍后重试")
                return
            }
            let unread = querySingleInt(notifUnreadSql(u.userId), 0)
            sendOk(ctx, "{\"id\":${notifId},\"changed\":1,\"unread\":${unread}}")
    }
}

/** POST /api/v1/notifications/read-all */
public func handleNotificationReadAll(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            let before = querySingleInt(notifUnreadSql(u.userId), 0)
            if (before == 0) {
                sendOk(ctx, "{\"changed\":0,\"unread\":0}")
                return
            }
            if (!executeSql(notifReadAllSql(u.userId))) {
                sendErr(ctx, 500, 500, "批量标记已读失败，请稍后重试")
                return
            }
            writeAuditLog(u, "通知中心", "全部已读", "一次性标记 ${before} 条通知为已读")
            sendOk(ctx, "{\"changed\":${before},\"unread\":0}")
    }
}
