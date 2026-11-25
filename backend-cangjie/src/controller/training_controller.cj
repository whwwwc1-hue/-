package hrms_backend.controller

import std.time.*
import std.convert.*
import std.collection.*
import hrms_backend.common.*
import hrms_backend.db.*
import hrms_backend.middleware.*
import hrms_backend.service.*

// ============================================================================
// P4.1 培训与学分（hr_training + hr_training_record）
//
// 模块职责：HR 发布培训计划 → 员工自助报名（含名额校验）→ 开课时窗签到 →
//           HR 录入出勤与考核分 → 系统按规则折算学分 → 个人学分汇总 / 部门排行。
//
// 设计约束（与 P3.1/P3.2 保持同一套纪律）：
// 1. 所有 SQL 由本文件的纯函数生成，处理器里不拼原始用户输入；查询参数一律过
//    sqlStr，筛选条件一律走白名单（trainingStatusCond / trainingCategoryCond）。
// 2. 学分折算、状态机、名额与时窗判定全部是**无数据库依赖的纯函数**，可被
//    training_controller_test.cj 逐条断言；本模块的「业务规则」只存在于这些函数里。
// 3. 时间比较交给 MySQL 的 TIMESTAMPDIFF，而不是在仓颉里解析日期字符串——
//    本机没有仓颉 SDK（L-CJ-1），任何自己手写的时间解析都无法验证，
//    把它交给已经在跑的那一侧（DB）是唯一诚实的做法。列格式固定 DATETIME，
//    前端 el-date-picker 用 value-format="YYYY-MM-DD HH:mm:ss" 严格对齐。
// 4. 数值列（DECIMAL）出 JSON 时用 `CAST(x AS CHAR)`，NULL 直接在 SQL 里落成字面量
//    null / 0.0，避免在仓颉侧再判一次「空串是 0 还是无值」——这两种语义在
//    培训域里完全不同（0 分 ≠ 未考核）。
// ============================================================================

// ======================== 纯函数：字典与状态机 ========================

/** 培训状态白名单，与建表 COMMENT 逐字一致；越界一律拒绝，防止脏值让前端映射不到标签。 */
public func trainingIsValidStatus(s: String): Bool {
    if (s == "DRAFT") { return true }
    if (s == "PUBLISHED") { return true }
    if (s == "DONE") { return true }
    if (s == "CANCELLED") { return true }
    return false
}

/** 课程类别白名单。COMPLIANCE = 合规必修，员工端会强调「必修」，学分影响年度评级。 */
public func trainingIsValidCategory(s: String): Bool {
    if (s == "INTERNAL") { return true }
    if (s == "ONLINE") { return true }
    if (s == "EXTERNAL") { return true }
    if (s == "COMPLIANCE") { return true }
    return false
}

/** 报名/签到记录状态白名单（记录态与计划态是两套，不能混用）。 */
public func trainingIsValidRecordStatus(s: String): Bool {
    if (s == "REGISTERED") { return true }
    if (s == "ATTENDED") { return true }
    if (s == "ABSENT") { return true }
    if (s == "CANCELLED") { return true }
    return false
}

public func trainingStatusLabel(s: String): String {
    if (s == "DRAFT") { return "草稿" }
    if (s == "PUBLISHED") { return "已发布" }
    if (s == "DONE") { return "已结课" }
    if (s == "CANCELLED") { return "已取消" }
    if (s == "REGISTERED") { return "已报名" }
    if (s == "ATTENDED") { return "已出勤" }
    if (s == "ABSENT") { return "缺席" }
    return "未知"
}

public func trainingCategoryLabel(s: String): String {
    if (s == "INTERNAL") { return "内部培训" }
    if (s == "ONLINE") { return "在线课程" }
    if (s == "EXTERNAL") { return "外部课程" }
    if (s == "COMPLIANCE") { return "合规必修" }
    return "其它"
}

/**
 * 状态机：
 *   DRAFT     -> PUBLISHED / CANCELLED
 *   PUBLISHED -> DONE / CANCELLED
 *   DONE / CANCELLED 是终态
 * 同态流转返回 false，由处理器先判并给「无需重复操作」的友好提示，
 * 避免把「已经是已发布」当成错误抛给前端。
 */
public func trainingStatusTransition(from: String, to: String): Bool {
    if (!trainingIsValidStatus(from) || !trainingIsValidStatus(to)) { return false }
    if (from == to) { return false }
    if (from == "DRAFT") {
        return to == "PUBLISHED" || to == "CANCELLED"
    }
    if (from == "PUBLISHED") {
        return to == "DONE" || to == "CANCELLED"
    }
    return false
}

/** 状态流转被拒时的提示语（分三种成因，前端直接展示，不再自己判分支）。 */
public func trainingTransitionDenied(from: String, to: String): String {
    if (from == to) {
        return "该培训计划已是「${trainingStatusLabel(from)}」状态"
    }
    if (from == "DONE" || from == "CANCELLED") {
        return "「${trainingStatusLabel(from)}」为终态，不能再变更"
    }
    return "不支持的状态流转：${trainingStatusLabel(from)} → ${trainingStatusLabel(to)}"
}

// ======================== 纯函数：数值与规则 ========================

/**
 * 保留 1 位小数、四舍五入（学分的天然精度）。
 * 与 round2 同构，但不复用：round2 是两位小数，直接拿来会算出 0.75 这类
 * 无法写入 DECIMAL(4,1) 的值，MySQL 会再静默舍一次，出现「库里 0.8、返回 0.75」。
 */
public func roundDec1(v: Float64): Float64 {
    let neg = v < 0.0
    let abs = if (neg) {
        -v
    } else {
        v
    }
    let tenths = Int64(abs * 10.0 + 0.5)
    let r = Float64(tenths) / 10.0
    return if (neg) {
        -r
    } else {
        r
    }
}

/** 名额钳位：<=0 归一为 0（= 不限），上限 500（一场培训不可能超过这个量）。 */
public func trainingClampCapacity(raw: Int64): Int64 {
    if (raw <= 0) { return 0 }
    if (raw > 500) { return 500 }
    return raw
}

/** 学分钳位：0~10 分，1 位小数；0 合法（宣讲类课程不给学分）。 */
public func trainingClampCredit(raw: Float64): Float64 {
    if (raw <= 0.0) { return 0.0 }
    if (raw > 10.0) { return 10.0 }
    return roundDec1(raw)
}

/**
 * 考核分钳位。
 * 返回 -1.0 是本模块的一个**约定哨兵值**：表示「本次无考核环节 / 未录入分数」，
 * 与真实的 0 分严格区分——0 分是不合格（0 学分），-1 是出勤即得满分学分。
 * 任何负数输入（含前端传 null 被 getJsonFloat 兜底成 -1 的情况）都归一到 -1.0。
 */
public func trainingClampScore(raw: Float64): Float64 {
    if (raw < 0.0) { return -1.0 }
    if (raw > 100.0) { return 100.0 }
    return roundDec1(raw)
}

/**
 * 出勤 + 考核分 -> 实际学分。
 *   未出勤（ABSENT）           -> 0 学分
 *   出勤且无考核（score < 0）   -> 全额学分
 *   出勤且 score >= 80         -> 全额学分
 *   出勤且 60 <= score < 80    -> 半额（按 1 位小数四舍五入）
 *   出勤且 score < 60          -> 0 学分（不合格）
 */
public func trainingCreditOf(courseCredit: Float64, attended: Bool, score: Float64): Float64 {
    if (!attended) { return 0.0 }
    let base = trainingClampCredit(courseCredit)
    if (base <= 0.0) { return 0.0 }
    let s = trainingClampScore(score)
    if (s < 0.0) { return base }
    if (s >= 80.0) { return base }
    if (s >= 60.0) { return roundDec1(base * 0.5) }
    return 0.0
}

/** 剩余名额；-1 表示不限（capacity = 0）。 */
public func trainingCapacityLeft(capacity: Int64, signed: Int64): Int64 {
    if (capacity <= 0) { return -1 }
    let left = capacity - signed
    if (left < 0) { return 0 }
    return left
}

/**
 * 报名对象的拒绝原因。返回空串 = 允许报名。
 * 顺序「先受众、再状态、再时间、最后名额」：受众是「这门课压根没对你开放」，
 * 比「名额已满」更需要先说清楚，否则员工会去抢一个自己上不了的课。
 * deptId = 0 表示全员课；empDeptId <= 0 表示该账号没有绑定在职员工，一律拒绝。
 */
public func trainingAudienceDenied(deptId: Int64, empDeptId: Int64): String {
    if (deptId <= 0) { return "" }
    if (empDeptId <= 0) { return "该培训面向指定部门，请先在员工档案中完善部门信息" }
    if (deptId != empDeptId) { return "该培训仅面向其它部门开放，你无法报名" }
    return ""
}

/**
 * 报名拒绝原因。返回空串 = 允许报名。
 * minToStart = TIMESTAMPDIFF(MINUTE, NOW(), start_time)，>0 表示尚未开课。
 * 三条规则按「先状态、再时间、最后名额」排序，因为前者是不可逾越的，
 * 后者可能在别人报名的瞬间变化，提示语要能引导用户下一步做什么。
 */
public func trainingSignupDenied(status: String, minToStart: Int64, left: Int64): String {
    if (status != "PUBLISHED") {
        return "该培训计划为「${trainingStatusLabel(status)}」，暂不可报名"
    }
    if (minToStart <= 0) {
        return "该培训已开课或已结束，无法报名"
    }
    if (left == 0) {
        return "该培训名额已满，如需加位请联系 HR"
    }
    return ""
}

/**
 * 签到窗口拒绝原因。返回空串 = 允许签到。
 * 开窗：开课前 15 分钟；关窗：结课后 60 分钟。
 * minSinceEnd <= 0 表示课程仍在进行（此时它一定是负数），所以只需判上界。
 */
public func trainingCheckinDenied(minToStart: Int64, minSinceEnd: Int64): String {
    if (minSinceEnd > 60) {
        return "该培训结束已超过 1 小时，签到通道已关闭"
    }
    if (minToStart > 15) {
        return "签到将在开课前 15 分钟开放"
    }
    return ""
}

/** 录分时的记录状态：缺席行的分数无意义，由调用方置 NULL，这里只给出状态字面量。 */
public func trainingResultRecordStatus(attended: Bool): String {
    return if (attended) {
        "ATTENDED"
    } else {
        "ABSENT"
    }
}

/** 取消报名的前置校验：只有尚未开课的 REGISTERED 行可自助取消。 */
public func trainingUnsignupDenied(recordStatus: String, minToStart: Int64): String {
    if (recordStatus.isEmpty()) {
        return "你尚未报名该培训"
    }
    if (recordStatus == "CANCELLED") {
        return "该报名已取消"
    }
    if (recordStatus != "REGISTERED") {
        return "已签到的记录不能自助取消，请联系 HR 调整"
    }
    if (minToStart <= 0) {
        return "培训已开始，取消报名请联系 HR"
    }
    return ""
}

/** 已结课/已取消的培训不允许再录结果——否则会出现「结课后追加学分」的账实不符。 */
public func trainingResultDenied(status: String): String {
    if (status == "DRAFT") {
        return "培训计划尚未发布，无需录入结果"
    }
    if (status == "CANCELLED") {
        return "该培训已取消，不再录入结果"
    }
    return ""
}

/** 草稿课不能直接跳到 DONE；同时给出「未发布不能报名」之外的镜像约束。 */
public func trainingEditDenied(status: String): String {
    if (status == "DONE" || status == "CANCELLED") {
        return "「${trainingStatusLabel(status)}」的培训内容已锁定，不能再修改"
    }
    return ""
}

/**
 * 已有报名时能否改学分。
 * 已发放过学分（attended > 0）还改学分，会让历史记录的 credit 与新规则脱节，
 * 因此这里只在「无人上过课」时放行；仅有人报名（还没上课）改学分是安全的。
 */
public func trainingCreditChangeDenied(attended: Int64): String {
    if (attended > 0) {
        return "该培训已有出勤记录，学分不能再修改（避免与已发放学分离谱）"
    }
    return ""
}

// ======================== 纯函数：筛选条件（本模块唯一注入面） ========================

public func trainingStatusCond(raw: String): String {
    if (trainingIsValidStatus(raw)) {
        return "AND t.status = ${sqlStr(raw)}"
    }
    return ""
}

public func trainingCategoryCond(raw: String): String {
    if (trainingIsValidCategory(raw)) {
        return "AND t.category = ${sqlStr(raw)}"
    }
    return ""
}

/**
 * LIKE 通配符转义：\ % _ 三个字符必须处理，否则用户输入 "%" 就能拖全表，
 * 输入 "_" 会把「培 训」这类带下划线的搜索条件变形。
 * 注意顺序：先转义反斜杠，再转义 % 和 _，否则会把上一步产生的 "\\" 二次转义。
 */
public func trainingLikeLit(raw: String): String {
    let kw = raw.trimAscii()
    if (kw.isEmpty()) { return "" }
    var esc = kw.replace("\\", "\\\\")
    esc = esc.replace("%", "\\%")
    esc = esc.replace("_", "\\_")
    return esc
}

public func trainingKeywordCond(raw: String): String {
    let kw = trainingLikeLit(raw)
    if (kw.isEmpty()) { return "" }
    let lit = sqlStr("%" + kw + "%")
    return "AND (t.title LIKE ${lit} OR t.trainer LIKE ${lit} OR t.location LIKE ${lit})"
}

public func trainingDeptCond(raw: Int64): String {
    if (raw > 0) {
        return "AND t.dept_id = ${raw}"
    }
    return ""
}

/** 面向某员工的可见范围：全员课（dept_id=0）+ 本部门课。 */
public func trainingVisibleCond(deptId: Int64): String {
    return "AND (t.dept_id = 0 OR t.dept_id = ${deptId})"
}

// ======================== 纯函数：SQL 生成 ========================

/**
 * HR/主管视角的培训列表。15 列，顺序必须与 trainingPlanRowToJson 严格对应。
 * signed_count 排除 CANCELLED——取消的报名不占名额，这是报名并发校验的同一口径。
 */
public func trainingListSql(statusCond: String, categoryCond: String, keywordCond: String, deptCond: String): String {
    return """SELECT t.id, t.title, t.category, t.trainer, t.dept_id, IFNULL(d.dept_name, '全员'),
       t.start_time, t.end_time, t.capacity, CAST(t.credit AS CHAR), IFNULL(t.location, ''),
       IFNULL(t.description, ''), t.status,
       (SELECT COUNT(*) FROM hr_training_record r WHERE r.training_id = t.id AND r.status <> 'CANCELLED'),
       (SELECT COUNT(*) FROM hr_training_record r WHERE r.training_id = t.id AND r.status = 'ATTENDED')
FROM hr_training t LEFT JOIN hr_department d ON t.dept_id = d.id
WHERE 1 = 1 ${statusCond} ${categoryCond} ${keywordCond} ${deptCond}
ORDER BY t.start_time DESC, t.id DESC"""
}

/**
 * 员工端「可报名 / 我相关的课」。17 列，比列表多出两个时间差与我的报名态。
 * min_to_start / min_since_end 直接喂给 trainingSignupDenied / trainingCheckinDenied，
 * 让「时窗规则」只在仓颉侧表达一次。
 */
public func trainingAvailableSql(deptId: Int64, empId: Int64, visibleCond: String): String {
    return """SELECT t.id, t.title, t.category, t.trainer, t.dept_id, IFNULL(d.dept_name, '全员'),
       t.start_time, t.end_time, t.capacity, CAST(t.credit AS CHAR), IFNULL(t.location, ''), t.status,
       TIMESTAMPDIFF(MINUTE, NOW(), t.start_time), TIMESTAMPDIFF(MINUTE, t.end_time, NOW()),
       IFNULL(r.status, ''),
       (SELECT COUNT(*) FROM hr_training_record r2 WHERE r2.training_id = t.id AND r2.status <> 'CANCELLED'),
       IFNULL(CAST(r.checkin_at AS CHAR), '')
FROM hr_training t
LEFT JOIN hr_department d ON t.dept_id = d.id
LEFT JOIN hr_training_record r ON r.training_id = t.id AND r.employee_id = ${empId}
WHERE t.status = 'PUBLISHED' ${visibleCond}
ORDER BY t.start_time ASC, t.id ASC"""
}

/** 我的培训与学分。13 列。score 为 NULL 时在 SQL 里落成字面量 null，不用空串冒充 0 分。 */
public func trainingMyRecordsSql(empId: Int64): String {
    return """SELECT r.id, r.training_id, t.title, t.category, t.trainer, t.start_time, t.end_time,
       CAST(t.credit AS CHAR), r.status, IFNULL(CAST(r.checkin_at AS CHAR), ''),
       IFNULL(CAST(r.score AS CHAR), 'null'), CAST(r.credit AS CHAR), IFNULL(r.remark, '')
FROM hr_training_record r JOIN hr_training t ON r.training_id = t.id
WHERE r.employee_id = ${empId}
ORDER BY t.start_time DESC, r.id DESC"""
}

/** 我的学分汇总（4 列）：获得学分 / 报名数 / 出勤数 / 出勤分钟数。 */
public func trainingMySummarySql(empId: Int64): String {
    return """SELECT IFNULL(SUM(r.credit), 0), COUNT(*),
       IFNULL(SUM(r.status = 'ATTENDED'), 0),
       IFNULL(SUM(CASE WHEN r.status = 'ATTENDED' THEN TIMESTAMPDIFF(MINUTE, t.start_time, t.end_time) ELSE 0 END), 0)
FROM hr_training_record r JOIN hr_training t ON r.training_id = t.id
WHERE r.employee_id = ${empId} AND r.status <> 'CANCELLED'"""
}

/** 培训名册（HR 视角）。11 列。 */
public func trainingRosterSql(trainingId: Int64): String {
    return """SELECT r.id, r.employee_id, e.name, e.emp_no, IFNULL(d.dept_name, ''), r.status,
       IFNULL(CAST(r.checkin_at AS CHAR), ''), IFNULL(CAST(r.score AS CHAR), 'null'),
       CAST(r.credit AS CHAR), IFNULL(r.remark, ''), IFNULL(u.id, 0)
FROM hr_training_record r
JOIN hr_employee e ON r.employee_id = e.id
LEFT JOIN hr_department d ON e.dept_id = d.id
LEFT JOIN sys_user u ON u.employee_id = e.id
WHERE r.training_id = ${trainingId}
ORDER BY FIELD(r.status, 'REGISTERED', 'ATTENDED', 'ABSENT', 'CANCELLED'), r.id ASC"""
}

/** 概览统计（5 列）：总数 / 已发布 / 已结课 / 草稿 / 已取消。 */
public func trainingOverviewSql(): String {
    return """SELECT COUNT(*), IFNULL(SUM(status = 'PUBLISHED'), 0), IFNULL(SUM(status = 'DONE'), 0),
       IFNULL(SUM(status = 'DRAFT'), 0), IFNULL(SUM(status = 'CANCELLED'), 0)
FROM hr_training"""
}

/** 累计学时（1 列）：已发布 + 已结课课程的总分钟数（结课的不重复计）。 */
public func trainingAggregateSql(): String {
    return """SELECT IFNULL(SUM(TIMESTAMPDIFF(MINUTE, start_time, end_time)), 0)
FROM hr_training WHERE status IN ('PUBLISHED', 'DONE')"""
}

public func trainingScoreAvgSql(): String {
    return "SELECT IFNULL(CAST(AVG(score) AS CHAR), '0') FROM hr_training_record WHERE score IS NOT NULL"
}

public func trainingCoveredEmpSql(): String {
    return "SELECT COUNT(DISTINCT employee_id) FROM hr_training_record WHERE status IN ('ATTENDED', 'REGISTERED')"
}

/** 学分排行前 10（4 列）：员工ID / 姓名 / 部门 / 学分。 */
public func trainingCreditRankSql(): String {
    return """SELECT e.id, e.name, IFNULL(d.dept_name, ''), CAST(SUM(r.credit) AS CHAR)
FROM hr_training_record r
JOIN hr_employee e ON r.employee_id = e.id
LEFT JOIN hr_department d ON e.dept_id = d.id
WHERE r.status <> 'CANCELLED'
GROUP BY e.id, e.name, d.dept_name
ORDER BY SUM(r.credit) DESC, e.id ASC
LIMIT 10"""
}

/** 课程维度统计（报名/出勤/出勤率），按课程聚合，用于管理视图。 */
public func trainingCourseStatsSql(limit: Int64): String {
    return """SELECT t.id, t.title, IFNULL(CAST(AVG(r.score) AS CHAR), 'null'),
       (SELECT COUNT(*) FROM hr_training_record x WHERE x.training_id = t.id AND x.status <> 'CANCELLED'),
       (SELECT COUNT(*) FROM hr_training_record x WHERE x.training_id = t.id AND x.status = 'ATTENDED'),
       CAST(SUM(r.credit) AS CHAR)
FROM hr_training t JOIN hr_training_record r ON r.training_id = t.id
GROUP BY t.id, t.title
ORDER BY SUM(r.credit) DESC, t.id ASC
LIMIT ${limit}"""
}

/** 单课快照（校验存在性、状态机与学分折算时复用，11 列，是列表 SQL 的子集 + 时间差）。 */
public func trainingOneSql(trainingId: Int64): String {
    return """SELECT t.id, t.title, t.category, t.trainer, t.dept_id, t.status,
       CAST(t.credit AS CHAR), t.capacity,
       (SELECT COUNT(*) FROM hr_training_record r WHERE r.training_id = t.id AND r.status <> 'CANCELLED'),
       (SELECT COUNT(*) FROM hr_training_record r WHERE r.training_id = t.id AND r.status = 'ATTENDED'),
       TIMESTAMPDIFF(MINUTE, NOW(), t.start_time)
FROM hr_training t WHERE t.id = ${trainingId}"""
}

/** 该课面向部门的在职工号，发布通知时用（dept_id = 0 表示全员）。 */
public func trainingAudienceSql(deptId: Int64): String {
    if (deptId > 0) {
        return """SELECT u.id FROM sys_user u JOIN hr_employee e ON u.employee_id = e.id
WHERE u.is_active = 1 AND e.status = 'ACTIVE' AND e.dept_id = ${deptId}"""
    }
    return """SELECT u.id FROM sys_user u JOIN hr_employee e ON u.employee_id = e.id
WHERE u.is_active = 1 AND e.status = 'ACTIVE'"""
}

public func trainingInsertSql(title: String, category: String, trainer: String, deptId: Int64, startAt: String, endAt: String, capacity: Int64, credit: Float64, location: String, description: String, creatorId: Int64): String {
    return """INSERT INTO hr_training (title, category, trainer, dept_id, start_time, end_time,
       capacity, credit, location, description, status, creator_id)
VALUES (${sqlStr(title)}, ${sqlStr(category)}, ${sqlStr(trainer)}, ${deptId}, ${sqlStr(startAt)}, ${sqlStr(endAt)},
       ${capacity}, ${formatNum2(credit)}, ${sqlStr(location)}, ${sqlStr(description)}, 'DRAFT', ${creatorId})"""
}

/**
 * 更新语句（整份内容覆盖，10 个业务字段）：编辑弹窗回填完整表单，
 * location/description 传空串即为清空，不做「未传即不改」的猜测——
 * 那种语义要靠「键是否存在」判断，而 getJsonStr 只能给默认值，无法区分。
 */
public func trainingUpdateSet(title: String, category: String, trainer: String, deptId: Int64, startAt: String, endAt: String, capacity: Int64, credit: Float64, location: String, description: String): String {
    return """title = ${sqlStr(title)}, category = ${sqlStr(category)}, trainer = ${sqlStr(trainer)},
       dept_id = ${deptId}, start_time = ${sqlStr(startAt)}, end_time = ${sqlStr(endAt)},
       capacity = ${capacity}, credit = ${formatNum2(credit)}, location = ${sqlStr(location)},
       description = ${sqlStr(description)}"""
}

/** 学分是否真的变了（在库里比，避免把 "2.0" 与 "2" 的字符串差异误判成改动）。 */
public func trainingCreditChangedSql(trainingId: Int64, credit: Float64): String {
    return "SELECT SUM(credit <> ${formatNum2(credit)}) FROM hr_training_record WHERE training_id = ${trainingId} AND status = 'ATTENDED'"
}

/** 开课时间是否已经过去（1=已过）。发布与改期两处要用同一个口径判断。 */
public func trainingStartPassedSql(startAt: String): Int64 {
    if (startAt.isEmpty()) { return 0 }
    return querySingleInt("SELECT TIMESTAMPDIFF(MINUTE, NOW(), ${sqlStr(startAt)}) < 0", 0)
}

/** 结课结算 1：报名但始终未签到 -> 缺席。 */
public func trainingSettleAbsentSql(trainingId: Int64): String {
    return """UPDATE hr_training_record SET status = 'ABSENT', remark = '结课时未签到'
WHERE training_id = ${trainingId} AND status = 'REGISTERED'"""
}

/** 结课结算 2：已出勤但从未录入考核分（score IS NULL）-> 按「无考核」发全额学分。 */
public func trainingSettleCreditSql(trainingId: Int64, credit: Float64): String {
    return """UPDATE hr_training_record SET credit = ${formatNum2(credit)}
WHERE training_id = ${trainingId} AND status = 'ATTENDED' AND score IS NULL"""
}

/**
 * 报名/取消/签到三个动作共用的前置读（7 列）：
 * [计划状态, 距开课分钟, 已报名数, 名额, 面向部门, 距结课分钟, 我的记录状态]
 * 「我的记录状态」用 LEFT JOIN + IFNULL 拿到，未报名时是空串而不是 NULL——
 * 空串在纯函数 trainingUnsignupDenied 里有独立语义（尚未报名）。
 */
public func trainingActionCheckSql(trainingId: Int64, empId: Int64): String {
    return """SELECT t.status, TIMESTAMPDIFF(MINUTE, NOW(), t.start_time),
       (SELECT COUNT(*) FROM hr_training_record x WHERE x.training_id = t.id AND x.status <> 'CANCELLED'),
       t.capacity, t.dept_id, TIMESTAMPDIFF(MINUTE, t.end_time, NOW()), IFNULL(r.status, '')
FROM hr_training t LEFT JOIN hr_training_record r ON r.training_id = t.id AND r.employee_id = ${empId}
WHERE t.id = ${trainingId}"""
}

/** 指定报名行的状态（不存在返回空串）。 */
public func trainingRecordStatusSql(trainingId: Int64, empId: Int64): String {
    return "SELECT status FROM hr_training_record WHERE training_id = ${trainingId} AND employee_id = ${empId} LIMIT 1"
}

public func trainingUpdateStatusSql(trainingId: Int64, status: String): String {
    return "UPDATE hr_training SET status = ${sqlStr(status)} WHERE id = ${trainingId}"
}

public func trainingSignupInsertSql(trainingId: Int64, empId: Int64): String {
    return """INSERT INTO hr_training_record (training_id, employee_id, status, credit)
VALUES (${trainingId}, ${empId}, 'REGISTERED', 0.0)"""
}

/** 复用被取消过的行（UNIQUE(training_id, employee_id) 决定了不能再插新行）。 */
public func trainingSignupReactivateSql(trainingId: Int64, empId: Int64): String {
    return """UPDATE hr_training_record SET status = 'REGISTERED', credit = 0.0, checkin_at = NULL,
       score = NULL, remark = NULL
WHERE training_id = ${trainingId} AND employee_id = ${empId} AND status = 'CANCELLED'"""
}

public func trainingCancelSignupSql(trainingId: Int64, empId: Int64): String {
    return "UPDATE hr_training_record SET status = 'CANCELLED' WHERE training_id = ${trainingId} AND employee_id = ${empId} AND status = 'REGISTERED'"
}

public func trainingCheckinSql(trainingId: Int64, empId: Int64): String {
    return """UPDATE hr_training_record SET status = 'ATTENDED', checkin_at = NOW()
WHERE training_id = ${trainingId} AND employee_id = ${empId} AND status = 'REGISTERED'"""
}

/**
 * 录分：attended = false 时 score 传 NULL（不是 0），credit 传 0，
 * 保证「缺席」与「考了 0 分」在库里可区分——这是年度合规统计的口径基础。
 */
public func trainingResultSql(trainingId: Int64, empId: Int64, attended: Bool, score: Float64, credit: Float64, remark: String): String {
    let scoreLit = if (attended && score >= 0.0) {
        "${formatNum2(score)}"
    } else {
        "NULL"
    }
    let remarkLit = if (remark.isEmpty()) { "NULL" } else { sqlStr(remark) }
    return """UPDATE hr_training_record SET status = ${sqlStr(trainingResultRecordStatus(attended))},
       score = ${scoreLit}, credit = ${formatNum2(credit)}, remark = ${remarkLit}
WHERE training_id = ${trainingId} AND employee_id = ${empId} AND status <> 'CANCELLED'"""
}

/** 时间格式自校验：把同一个串喂给 TIMESTAMPDIFF，能算出 0 说明 MySQL 认它。 */
public func trainingTimeCheckSql(value: String): String {
    return "SELECT TIMESTAMPDIFF(MINUTE, ${sqlStr(value)}, ${sqlStr(value)})"
}

/** 起止顺序校验：负数或 0 都视为非法课程时长（0 分钟的培训没有业务意义）。 */
public func trainingTimeSpanSql(startAt: String, endAt: String): String {
    return "SELECT TIMESTAMPDIFF(MINUTE, ${sqlStr(startAt)}, ${sqlStr(endAt)})"
}

// ======================== 纯函数：行 -> JSON ========================

/** 培训计划行（15 列，见 trainingListSql）。 */
public func trainingPlanRowToJson(r: ArrayList<String>): String {
    if (r.size < 15) { return "" }
    return "{" +
        "\"id\":${r[0]}," +
        "\"title\":${jsonStr(r[1])}," +
        "\"category\":${jsonStr(r[2])}," +
        "\"categoryLabel\":${jsonStr(trainingCategoryLabel(r[2]))}," +
        "\"trainer\":${jsonStr(r[3])}," +
        "\"deptId\":${r[4]}," +
        "\"deptName\":${jsonStr(r[5])}," +
        "\"startTime\":${jsonStr(r[6])}," +
        "\"endTime\":${jsonStr(r[7])}," +
        "\"capacity\":${r[8]}," +
        "\"credit\":${r[9]}," +
        "\"location\":${jsonStr(r[10])}," +
        "\"description\":${jsonStr(r[11])}," +
        "\"status\":${jsonStr(r[12])}," +
        "\"statusLabel\":${jsonStr(trainingStatusLabel(r[12]))}," +
        "\"signedCount\":${r[13]}," +
        "\"attendedCount\":${r[14]}" +
        "}"
}

/** 员工视角课程行（17 列，见 trainingAvailableSql），带可操作标记。 */
public func trainingOfferRowToJson(r: ArrayList<String>): String {
    if (r.size < 17) { return "" }
    let capacity = Int64.tryParse(r[8]) ?? 0
    let signed = Int64.tryParse(r[15]) ?? 0
    let minToStart = Int64.tryParse(r[12]) ?? 0
    let minSinceEnd = Int64.tryParse(r[13]) ?? 0
    let myStatus = r[14]
    let left = trainingCapacityLeft(capacity, signed)
    let signupDeny = trainingSignupDenied(r[11], minToStart, left)
    let checkinDeny = trainingCheckinDenied(minToStart, minSinceEnd)
    let canSignup = (myStatus == "CANCELLED" || myStatus == "ABSENT" || myStatus.isEmpty()) && signupDeny.isEmpty()
    let canCheckin = myStatus == "REGISTERED" && checkinDeny.isEmpty()
    let canUnsignup = myStatus == "REGISTERED" && minToStart > 0
    // 说明：if/else 结果先落到局部变量再插值。仓颉允许 `if` 作为表达式，
    // 但把 if 表达式直接写进字符串插值 `${}` 里在本仓库基线中没有先例，
    // 无法静态论证可编译，故一律先取值。
    let myLabel = if (myStatus.isEmpty()) {
        "未报名"
    } else {
        trainingStatusLabel(myStatus)
    }
    let signupText = if (canSignup) { "true" } else { "false" }
    let checkinText = if (canCheckin) { "true" } else { "false" }
    let unsignupText = if (canUnsignup) { "true" } else { "false" }
    var blockReason = "你已缺席该培训"
    if (myStatus.isEmpty()) {
        blockReason = signupDeny
    }
    if (myStatus == "REGISTERED") {
        blockReason = "你已报名该培训"
    }
    if (myStatus == "ATTENDED") {
        blockReason = "你已签到该培训"
    }
    return "{" +
        "\"id\":${r[0]}," +
        "\"title\":${jsonStr(r[1])}," +
        "\"category\":${jsonStr(r[2])}," +
        "\"categoryLabel\":${jsonStr(trainingCategoryLabel(r[2]))}," +
        "\"trainer\":${jsonStr(r[3])}," +
        "\"deptName\":${jsonStr(r[5])}," +
        "\"startTime\":${jsonStr(r[6])}," +
        "\"endTime\":${jsonStr(r[7])}," +
        "\"capacity\":${r[8]}," +
        "\"credit\":${r[9]}," +
        "\"location\":${jsonStr(r[10])}," +
        "\"status\":${jsonStr(r[11])}," +
        "\"statusLabel\":${jsonStr(trainingStatusLabel(r[11]))}," +
        "\"minToStart\":${minToStart}," +
        "\"minSinceEnd\":${minSinceEnd}," +
        "\"myStatus\":${jsonStr(myStatus)}," +
        "\"myStatusLabel\":${jsonStr(myLabel)}," +
        "\"signedCount\":${signed}," +
        "\"capacityLeft\":${left}," +
        "\"canSignup\":${signupText}," +
        "\"canCheckin\":${checkinText}," +
        "\"canUnsignup\":${unsignupText}," +
        "\"blockReason\":${jsonStr(blockReason)}," +
        "\"checkinAt\":${jsonStr(r[16])}" +
        "}"
}

/** 我的记录行（13 列，见 trainingMyRecordsSql）。 */
public func trainingRecordRowToJson(r: ArrayList<String>): String {
    if (r.size < 13) { return "" }
    return "{" +
        "\"id\":${r[0]}," +
        "\"trainingId\":${r[1]}," +
        "\"title\":${jsonStr(r[2])}," +
        "\"category\":${jsonStr(r[3])}," +
        "\"categoryLabel\":${jsonStr(trainingCategoryLabel(r[3]))}," +
        "\"trainer\":${jsonStr(r[4])}," +
        "\"startTime\":${jsonStr(r[5])}," +
        "\"endTime\":${jsonStr(r[6])}," +
        "\"courseCredit\":${r[7]}," +
        "\"status\":${jsonStr(r[8])}," +
        "\"statusLabel\":${jsonStr(trainingStatusLabel(r[8]))}," +
        "\"checkinAt\":${jsonStr(r[9])}," +
        "\"score\":${r[10]}," +
        "\"credit\":${r[11]}," +
        "\"remark\":${jsonStr(r[12])}" +
        "}"
}

/** 名册行（11 列，见 trainingRosterSql）。userId 为 0 表示该员工没有登录账号。 */
public func trainingRosterRowToJson(r: ArrayList<String>): String {
    if (r.size < 11) { return "" }
    return "{" +
        "\"id\":${r[0]}," +
        "\"employeeId\":${r[1]}," +
        "\"name\":${jsonStr(r[2])}," +
        "\"empNo\":${jsonStr(r[3])}," +
        "\"deptName\":${jsonStr(r[4])}," +
        "\"status\":${jsonStr(r[5])}," +
        "\"statusLabel\":${jsonStr(trainingStatusLabel(r[5]))}," +
        "\"checkinAt\":${jsonStr(r[6])}," +
        "\"score\":${r[7]}," +
        "\"credit\":${r[8]}," +
        "\"remark\":${jsonStr(r[9])}," +
        "\"userId\":${r[10]}" +
        "}"
}

/**
 * 数组包裹。刻意不接受「行映射函数」作为参数：仓颉的函数类型形参在本仓库基线里
 * 没有任何先例，无法静态论证其可编译性（L-CJ-1），所以每个处理器自己写 3 行循环。
 */
public func trainingWrapArray(items: ArrayList<String>): String {
    if (items.size == 0) { return "[]" }
    return "[" + String.join(items.toArray(), delimiter: ",") + "]"
}

/** 排行榜行（4 列）：员工ID / 姓名 / 部门 / 学分。 */
public func trainingRankRowToJson(r: ArrayList<String>): String {
    if (r.size < 4) { return "" }
    return "{\"employeeId\":${r[0]},\"name\":${jsonStr(r[1])},\"deptName\":${jsonStr(r[2])},\"credit\":${r[3]}}"
}

/** 课程维度统计行（6 列）。 */
public func trainingStatRowToJson(r: ArrayList<String>): String {
    if (r.size < 6) { return "" }
    return "{\"trainingId\":${r[0]},\"title\":${jsonStr(r[1])},\"avgScore\":${r[2]},\"signedCount\":${r[3]},\"attendedCount\":${r[4]},\"creditTotal\":${r[5]}}"
}

// ======================== HTTP 处理器 ========================

/** GET /api/v1/trainings?status=&category=&keyword=&deptId= —— HR/主管视角 */
public func handleTrainingList(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR", "MANAGER"])) {
        case None => return
        case Some(u) =>
            // 数据范围：主管只看「本部门课 + 全员课」，HR/管理员看全部。
            // 这条必须写在服务端——前端把 deptId 改成别的部门就绕过去了。
            // 主管本人没有绑定员工（employeeId<=0 → deptId 取到 0）时，
            // trainingVisibleCond(0) 退化为「只看全员课」，是保守侧的失败。
            var scopeCond = trainingDeptCond(getQueryInt(ctx, "deptId", 0))
            if (u.role == "MANAGER") {
                scopeCond = trainingVisibleCond(getUserDeptId(u))
            }
            let sql = trainingListSql(
                trainingStatusCond(getQueryStr(ctx, "status", "").trimAscii()),
                trainingCategoryCond(getQueryStr(ctx, "category", "").trimAscii()),
                trainingKeywordCond(getQueryStr(ctx, "keyword", "")),
                scopeCond
            )
            let rows = queryRows(sql)
            let items = ArrayList<String>()
            for (r in rows) {
                let j = trainingPlanRowToJson(r)
                if (!j.isEmpty()) {
                    items.add(j)
                }
            }
            sendOk(ctx, trainingWrapArray(items))
    }
}

/** POST /api/v1/trainings —— 新建草稿（发布走 PUT，状态机只有一处入口） */
public func handleTrainingCreate(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let title = getJsonStr(obj, "title", "").trimAscii()
                    let categoryRaw = getJsonStr(obj, "category", "INTERNAL").trimAscii()
                    let trainer = getJsonStr(obj, "trainer", "").trimAscii()
                    let deptId = getJsonInt(obj, "deptId", 0)
                    let startAt = getJsonStr(obj, "startTime", "").trimAscii()
                    let endAt = getJsonStr(obj, "endTime", "").trimAscii()
                    let capacity = trainingClampCapacity(getJsonInt(obj, "capacity", 0))
                    let credit = trainingClampCredit(getJsonFloat(obj, "credit", 1.0))
                    let location = truncateUtf8(getJsonStr(obj, "location", "").trimAscii(), 120)
                    let description = truncateUtf8(getJsonStr(obj, "description", "").trimAscii(), 500)
                    let invalid = trainingValidateForm(title, trainer, startAt, endAt)
                    if (!invalid.isEmpty()) {
                        sendErr(ctx, 400, 400, invalid)
                        return
                    }
                    if (!trainingTimeOk(startAt, endAt)) {
                        sendErr(ctx, 400, 400, "开课/结课时间不是有效日期，或结课未晚于开课")
                        return
                    }
                    // 类别越界不报错而是回落 INTERNAL：它是纯展示维度，
                    // 且前端下拉框已经限定候选，真出现越界多半是旧客户端，落回默认比拒绝更新更温和。
                    let category = if (trainingIsValidCategory(categoryRaw)) {
                        categoryRaw
                    } else {
                        "INTERNAL"
                    }
                    let newId = insertAndGetId(trainingInsertSql(title, category, trainer, deptId, startAt, endAt, capacity, credit, location, description, u.userId))
                    if (newId <= 0) {
                        sendErr(ctx, 500, 500, "创建培训计划失败")
                        return
                    }
                    writeAuditLog(u, "培训与学分", "新建培训计划", "新建培训计划 #${newId}：${title}（草稿，${trainingClampCredit(credit)} 学分）")
                    sendOk(ctx, "{\"id\":${newId},\"status\":\"DRAFT\"}")
            }
    }
}

/** PUT /api/v1/trainings/:id —— 修改内容 + 推进状态机（发布/结课/取消） */
public func handleTrainingUpdate(ctx: HttpContext, trainingId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            if (trainingId <= 0) {
                sendErr(ctx, 400, 400, "培训计划ID不合法")
                return
            }
            let cur = queryRows(trainingOneSql(trainingId))
            if (cur.size == 0 || cur[0].size < 11) {
                sendErr(ctx, 404, 404, "培训计划不存在")
                return
            }
            let row = cur[0]
            let curStatus = trainingSafeCol(row, 5, "")
            let curTitle = trainingSafeCol(row, 1, "")
            let attended = Int64.tryParse(trainingNumCol(row, 9, "0")) ?? 0
            let locked = trainingEditDenied(curStatus)
            if (!locked.isEmpty()) {
                sendErr(ctx, 400, 400, locked)
                return
            }
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    // 编辑弹窗回填的是完整表单，这里按「整份内容覆盖」处理：
                    // location/description 传空串就是清空，不做「未传即不改」的猜测。
                    let title = getJsonStr(obj, "title", "").trimAscii()
                    let categoryRaw = getJsonStr(obj, "category", "INTERNAL").trimAscii()
                    let trainer = getJsonStr(obj, "trainer", "").trimAscii()
                    let deptId = getJsonInt(obj, "deptId", 0)
                    let startAt = getJsonStr(obj, "startTime", "").trimAscii()
                    let endAt = getJsonStr(obj, "endTime", "").trimAscii()
                    let capacity = trainingClampCapacity(getJsonInt(obj, "capacity", 0))
                    let credit = trainingClampCredit(getJsonFloat(obj, "credit", 1.0))
                    let location = truncateUtf8(getJsonStr(obj, "location", "").trimAscii(), 120)
                    let description = truncateUtf8(getJsonStr(obj, "description", "").trimAscii(), 500)
                    let category = if (trainingIsValidCategory(categoryRaw)) {
                        categoryRaw
                    } else {
                        "INTERNAL"
                    }
                    let invalid = trainingValidateForm(title, trainer, startAt, endAt)
                    if (!invalid.isEmpty()) {
                        sendErr(ctx, 400, 400, invalid)
                        return
                    }
                    if (!trainingTimeOk(startAt, endAt)) {
                        sendErr(ctx, 400, 400, "开课/结课时间不是有效日期，或结课未晚于开课")
                        return
                    }
                    // 已有出勤记录后再改学分，历史行的 credit 会与新规则脱节（账实不符），直接拒绝。
                    if (attended > 0 && querySingleInt(trainingCreditChangedSql(trainingId, credit), 0) == 1) {
                        sendErr(ctx, 400, 400, trainingCreditChangeDenied(attended))
                        return
                    }
                    // 已有人报名时把开课时间改到过去，会让学员被动错过课程，这一种改法必须设卡；
                    // 往后推是安全的（名册与通知都还在），不拦。
                    let signed = Int64.tryParse(trainingNumCol(row, 8, "0")) ?? 0
                    if (curStatus == "PUBLISHED" && signed > 0 && trainingStartPassedSql(startAt) == 1) {
                        sendErr(ctx, 400, 400, "已有学员报名，不能把开课时间改到过去")
                        return
                    }
                    let setSql = trainingUpdateSet(title, category, trainer, deptId, startAt, endAt, capacity, credit, location, description)
                    if (!setSql.isEmpty()) {
                        if (!executeSql("UPDATE hr_training SET ${setSql} WHERE id = ${trainingId}")) {
                            sendErr(ctx, 500, 500, "更新培训计划失败")
                            return
                        }
                    }
                    let nextStatus = getJsonStr(obj, "status", "").trimAscii()
                    var applied = curStatus
                    if (!nextStatus.isEmpty() && nextStatus != curStatus) {
                        if (!trainingIsValidStatus(nextStatus)) {
                            sendErr(ctx, 400, 400, "培训状态不合法")
                            return
                        }
                        if (!trainingStatusTransition(curStatus, nextStatus)) {
                            sendErr(ctx, 400, 400, trainingTransitionDenied(curStatus, nextStatus))
                            return
                        }
                        if (nextStatus == "PUBLISHED" && trainingStartPassedSql(startAt) == 1) {
                            sendErr(ctx, 400, 400, "开课时间已过，无法发布，请先调整时间")
                            return
                        }
                        if (!executeSql(trainingUpdateStatusSql(trainingId, nextStatus))) {
                            sendErr(ctx, 500, 500, "变更培训状态失败")
                            return
                        }
                        applied = nextStatus
                        if (nextStatus == "PUBLISHED") {
                            notifyTrainingPublished(trainingId, title, deptId, startAt, credit)
                        }
                        if (nextStatus == "DONE") {
                            // 结课自动结算：未签到的报名记为缺席，出勤但未考核的按全额学分入账。
                            executeSql(trainingSettleAbsentSql(trainingId))
                            executeSql(trainingSettleCreditSql(trainingId, trainingClampCredit(credit)))
                        }
                    }
                    writeAuditLog(u, "培训与学分", "修改培训计划", "修改培训计划 #${trainingId}：${curTitle} → ${title}（状态 ${applied}）")
                    sendOk(ctx, "{\"id\":${trainingId},\"status\":${jsonStr(applied)},\"statusLabel\":${jsonStr(trainingStatusLabel(applied))}}")
            }
    }
}

/** GET /api/v1/trainings/available —— 员工端可报名清单（含我的报名态与可操作标记） */
public func handleTrainingAvailable(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            if (u.employeeId <= 0) {
                sendErr(ctx, 403, 403, "当前账号未关联员工档案，无法查看培训")
                return
            }
            let deptId = getUserDeptId(u)
            let rows = queryRows(trainingAvailableSql(deptId, u.employeeId, trainingVisibleCond(deptId)))
            let items = ArrayList<String>()
            for (r in rows) {
                let j = trainingOfferRowToJson(r)
                if (!j.isEmpty()) {
                    items.add(j)
                }
            }
            let summary = queryRows(trainingMySummarySql(u.employeeId))
            let s = if (summary.size > 0) {
                summary[0]
            } else {
                ArrayList<String>()
            }
            let credit = Float64.tryParse(trainingNumCol(s, 0, "0")) ?? 0.0
            let hours = (Float64.tryParse(trainingNumCol(s, 3, "0")) ?? 0.0) / 60.0
            let enrolled = trainingNumCol(s, 1, "0")
            let attendedCnt = trainingNumCol(s, 2, "0")
            sendOk(ctx, "{\"list\":${trainingWrapArray(items)},\"summary\":{\"credit\":${formatNum2(credit)},\"enrolled\":${enrolled},\"attended\":${attendedCnt},\"hours\":${formatNum2(hours)}}}")
    }
}

/** GET /api/v1/trainings/my —— 我的报名/出勤/学分明细 */
public func handleTrainingMy(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            if (u.employeeId <= 0) {
                sendErr(ctx, 403, 403, "当前账号未关联员工档案，无法查看培训记录")
                return
            }
            let rows = queryRows(trainingMyRecordsSql(u.employeeId))
            let items = ArrayList<String>()
            for (r in rows) {
                let j = trainingRecordRowToJson(r)
                if (!j.isEmpty()) {
                    items.add(j)
                }
            }
            let summary = queryRows(trainingMySummarySql(u.employeeId))
            let s = if (summary.size > 0) {
                summary[0]
            } else {
                ArrayList<String>()
            }
            let credit = Float64.tryParse(trainingNumCol(s, 0, "0")) ?? 0.0
            let hours = (Float64.tryParse(trainingNumCol(s, 3, "0")) ?? 0.0) / 60.0
            let enrolled = trainingNumCol(s, 1, "0")
            let attendedCnt = trainingNumCol(s, 2, "0")
            sendOk(ctx, "{\"list\":${trainingWrapArray(items)},\"totalCredit\":${formatNum2(credit)},\"enrolledCount\":${enrolled},\"attendedCount\":${attendedCnt},\"totalHours\":${formatNum2(hours)}}")
    }
}

/** GET /api/v1/trainings/stats —— 管理视角总览 + 学分排行 + 课程维度统计 */
public func handleTrainingStats(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR", "MANAGER"])) {
        case None => return
        case Some(_) =>
            let ov = queryRows(trainingOverviewSql())
            let o = if (ov.size > 0) {
                ov[0]
            } else {
                ArrayList<String>()
            }
            let agg = queryRows(trainingAggregateSql())
            let a = if (agg.size > 0) {
                agg[0]
            } else {
                ArrayList<String>()
            }
            let avgScore = querySingleValue(trainingScoreAvgSql())
            let covered = querySingleInt(trainingCoveredEmpSql(), 0)
            // 浮点一律经 formatNum2 落字符串再插值：Cangjie 的 Float64 直接插值在
            // 极端值下可能输出 "Infinity"，那是非法 JSON，前端 JSON.parse 会整页白屏。
            let minutes = Float64.tryParse(trainingNumCol(a, 0, "0")) ?? 0.0
            let totalHours = formatNum2(minutes / 60.0)
            let avgScoreText = formatNum2(Float64.tryParse(trainingSafeNum(avgScore, "0")) ?? 0.0)
            let rankRows = queryRows(trainingCreditRankSql())
            let rank = ArrayList<String>()
            for (r in rankRows) {
                let j = trainingRankRowToJson(r)
                if (!j.isEmpty()) {
                    rank.add(j)
                }
            }
            let statRows = queryRows(trainingCourseStatsSql(10))
            let stats = ArrayList<String>()
            for (r in statRows) {
                let j = trainingStatRowToJson(r)
                if (!j.isEmpty()) {
                    stats.add(j)
                }
            }
            sendOk(ctx, "{\"overview\":{\"total\":${trainingNumCol(o, 0, "0")},\"published\":${trainingNumCol(o, 1, "0")},\"done\":${trainingNumCol(o, 2, "0")},\"draft\":${trainingNumCol(o, 3, "0")},\"cancelled\":${trainingNumCol(o, 4, "0")},\"totalHours\":${totalHours},\"avgScore\":${avgScoreText},\"coveredEmployees\":${covered}},\"creditRank\":${trainingWrapArray(rank)},\"courseStats\":${trainingWrapArray(stats)}}")
    }
}

/** GET /api/v1/trainings/:id/records —— 培训名册 */
public func handleTrainingRoster(ctx: HttpContext, trainingId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR", "MANAGER"])) {
        case None => return
        case Some(_) =>
            if (trainingId <= 0) {
                sendErr(ctx, 400, 400, "培训计划ID不合法")
                return
            }
            let plan = queryRows(trainingOneSql(trainingId))
            if (plan.size == 0) {
                sendErr(ctx, 404, 404, "培训计划不存在")
                return
            }
            let rows = queryRows(trainingRosterSql(trainingId))
            let items = ArrayList<String>()
            for (r in rows) {
                let j = trainingRosterRowToJson(r)
                if (!j.isEmpty()) {
                    items.add(j)
                }
            }
            sendOk(ctx, "{\"trainingId\":${trainingId},\"title\":${jsonStr(trainingSafeCol(plan[0], 1, \"\"))},\"status\":${jsonStr(trainingSafeCol(plan[0], 5, \"\"))},\"list\":${trainingWrapArray(items)}}")
    }
}

/** POST /api/v1/trainings/:id/signup —— 员工自助报名（名额 + 时窗 + 可见范围三重校验） */
public func handleTrainingSignup(ctx: HttpContext, trainingId: Int64): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            if (trainingId <= 0) {
                sendErr(ctx, 400, 400, "培训计划ID不合法")
                return
            }
            if (u.employeeId <= 0) {
                sendErr(ctx, 403, 403, "当前账号未关联员工档案，无法报名培训")
                return
            }
            let rows = queryRows(trainingActionCheckSql(trainingId, u.employeeId))
            if (rows.size == 0 || rows[0].size < 7) {
                sendErr(ctx, 404, 404, "培训计划不存在")
                return
            }
            let r = rows[0]
            let myStatus = r[6]
            if (myStatus == "REGISTERED") {
                sendErr(ctx, 409, 409, "你已报名该培训")
                return
            }
            if (myStatus == "ATTENDED") {
                sendErr(ctx, 409, 409, "你已签到该培训，无需重复报名")
                return
            }
            // 受众校验交给纯函数：规则只有一处定义，前端/单测/e2e 都围绕它。
            let audienceDeny = trainingAudienceDenied(Int64.tryParse(r[4]) ?? 0, getUserDeptId(u))
            if (!audienceDeny.isEmpty()) {
                sendErr(ctx, 403, 403, audienceDeny)
                return
            }
            let minToStart = Int64.tryParse(r[1]) ?? 0
            let signed = Int64.tryParse(r[2]) ?? 0
            let capacity = Int64.tryParse(r[3]) ?? 0
            let left = trainingCapacityLeft(capacity, signed)
            let deny = trainingSignupDenied(r[0], minToStart, left)
            if (!deny.isEmpty()) {
                sendErr(ctx, 400, 400, deny)
                return
            }
            // 取消过的行必须复用（UNIQUE(training_id, employee_id) 挡住二次 INSERT），
            // 直接插新行会让整个脚本中止，连带影响后续语句。
            let ok = if (myStatus == "CANCELLED") {
                executeSql(trainingSignupReactivateSql(trainingId, u.employeeId))
            } else {
                executeSql(trainingSignupInsertSql(trainingId, u.employeeId))
            }
            if (!ok) {
                sendErr(ctx, 500, 500, "报名失败，请稍后重试")
                return
            }
            writeAuditLog(u, "培训与学分", "报名培训", "报名培训计划 #${trainingId}（${r[0]}，剩余名额 ${trainingCapacityLeft(capacity, signed + 1)}）")
            let newLeft = trainingCapacityLeft(capacity, signed + 1)
            sendOk(ctx, "{\"trainingId\":${trainingId},\"status\":\"REGISTERED\",\"capacityLeft\":${newLeft}}")
    }
}

/** DELETE /api/v1/trainings/:id/signup —— 取消报名（仅未开课的 REGISTERED 行可自助取消） */
public func handleTrainingUnsignup(ctx: HttpContext, trainingId: Int64): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            if (trainingId <= 0) {
                sendErr(ctx, 400, 400, "培训计划ID不合法")
                return
            }
            if (u.employeeId <= 0) {
                sendErr(ctx, 403, 403, "当前账号未关联员工档案，无法取消报名")
                return
            }
            let rows = queryRows(trainingActionCheckSql(trainingId, u.employeeId))
            if (rows.size == 0 || rows[0].size < 7) {
                sendErr(ctx, 404, 404, "培训计划不存在")
                return
            }
            let minToStart = Int64.tryParse(rows[0][1]) ?? 0
            let deny = trainingUnsignupDenied(rows[0][6], minToStart)
            if (!deny.isEmpty()) {
                sendErr(ctx, 400, 400, deny)
                return
            }
            if (!executeSql(trainingCancelSignupSql(trainingId, u.employeeId))) {
                sendErr(ctx, 500, 500, "取消报名失败")
                return
            }
            writeAuditLog(u, "培训与学分", "取消报名", "取消培训计划 #${trainingId} 的报名")
            sendOk(ctx, "{\"trainingId\":${trainingId},\"status\":\"CANCELLED\"}")
    }
}

/** POST /api/v1/trainings/:id/checkin —— 开课时窗内自助签到 */
public func handleTrainingCheckin(ctx: HttpContext, trainingId: Int64): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            if (trainingId <= 0) {
                sendErr(ctx, 400, 400, "培训计划ID不合法")
                return
            }
            if (u.employeeId <= 0) {
                sendErr(ctx, 403, 403, "当前账号未关联员工档案，无法签到")
                return
            }
            let rows = queryRows(trainingActionCheckSql(trainingId, u.employeeId))
            if (rows.size == 0 || rows[0].size < 7) {
                sendErr(ctx, 404, 404, "培训计划不存在")
                return
            }
            let r = rows[0]
            if (r[6] == "ATTENDED") {
                sendErr(ctx, 409, 409, "你已签到该培训")
                return
            }
            if (r[6] != "REGISTERED") {
                sendErr(ctx, 400, 400, "未报名该培训，无法签到")
                return
            }
            let minToStart = Int64.tryParse(r[1]) ?? 0
            let minSinceEnd = Int64.tryParse(r[5]) ?? 0
            let deny = trainingCheckinDenied(minToStart, minSinceEnd)
            if (!deny.isEmpty()) {
                sendErr(ctx, 400, 400, deny)
                return
            }
            if (!executeSql(trainingCheckinSql(trainingId, u.employeeId))) {
                sendErr(ctx, 500, 500, "签到失败，请稍后重试")
                return
            }
            writeAuditLog(u, "培训与学分", "培训签到", "完成培训计划 #${trainingId} 签到")
            sendOk(ctx, "{\"trainingId\":${trainingId},\"status\":\"ATTENDED\"}")
    }
}

/** POST /api/v1/trainings/:id/records —— HR 录入出勤与考核分，系统折算学分 */
public func handleTrainingResult(ctx: HttpContext, trainingId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            if (trainingId <= 0) {
                sendErr(ctx, 400, 400, "培训计划ID不合法")
                return
            }
            let plan = queryRows(trainingOneSql(trainingId))
            if (plan.size == 0 || plan[0].size < 11) {
                sendErr(ctx, 404, 404, "培训计划不存在")
                return
            }
            let deny = trainingResultDenied(plan[0][5])
            if (!deny.isEmpty()) {
                sendErr(ctx, 400, 400, deny)
                return
            }
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let employeeId = getJsonInt(obj, "employeeId", 0)
                    if (employeeId <= 0) {
                        sendErr(ctx, 400, 400, "员工ID必填")
                        return
                    }
                    let attended = getJsonBool(obj, "attended", true)
                    let score = trainingClampScore(getJsonFloat(obj, "score", -1.0))
                    let remark = truncateUtf8(getJsonStr(obj, "remark", "").trimAscii(), 255)
                    let existed = querySingleValue(trainingRecordStatusSql(trainingId, employeeId))
                    if (existed.isEmpty()) {
                        sendErr(ctx, 404, 404, "该员工未报名此培训")
                        return
                    }
                    if (existed == "CANCELLED") {
                        sendErr(ctx, 400, 400, "该员工已取消报名，不能录入结果")
                        return
                    }
                    let courseCredit = Float64.tryParse(trainingSafeNum(plan[0][6], "0")) ?? 0.0
                    let gained = trainingCreditOf(courseCredit, attended, score)
                    if (!executeSql(trainingResultSql(trainingId, employeeId, attended, score, gained, remark))) {
                        sendErr(ctx, 500, 500, "录入培训结果失败")
                        return
                    }
                    let statusText = trainingResultRecordStatus(attended)
                    // 缺席行库里是 NULL，出 JSON 也必须是 null（前端据此显示「未考核」而不是「0 分」）；
                    // 有考核分才走 formatNum2，避免把哨兵 -1 直接抛给前端。
                    var scoreText = "null"
                    if (attended && score >= 0.0) {
                        scoreText = formatNum2(score)
                    }
                    writeAuditLog(u, "培训与学分", "录入培训结果", "培训计划 #${trainingId} 员工 #${employeeId}：${statusText}，得分 ${scoreText}，学分 ${formatNum2(gained)}")
                    sendOk(ctx, "{\"trainingId\":${trainingId},\"employeeId\":${employeeId},\"status\":${jsonStr(statusText)},\"score\":${scoreText},\"credit\":${formatNum2(gained)}}")
            }
    }
}

// ======================== 行取值与数值安全化 ========================

/**
 * 按下标安全取列：下标越界、列为空串（NULL 在 mysql_pool 层被还原成空串）
 * 一律回退 def。控制器里对外来行统一走这里，不裸写 r[n]。
 * 注意 def 传空串时等价于「保留 NULL 语义」，本模块确实有这种列
 * （我的报名态：空串 = 尚未报名，与 'CANCELLED' 是两种不同提示）。
 */
public func trainingSafeCol(row: ArrayList<String>, idx: Int64, def: String): String {
    if (idx < 0) { return def }
    if (row.size <= idx) { return def }
    let v = row[idx]
    if (v.isEmpty()) { return def }
    return v
}

/**
 * 数值文本安全化：先按下标安全取值，再逐字节确认它是合法的 JSON 数字字面量。
 * 与 attMonthSafeNum 同构——刻意不用 Float64.tryParse 当校验器，因为它会接受
 * 1e5 / NaN / Infinity 这些 JSON.parse 直接报错的写法，一个坏值就能让整页白屏。
 */
public func trainingSafeNum(raw: String, defaultText: String): String {
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

/** 安全取列 + 数值校验，一步到位（越界/空/非数字都回退 defaultText）。 */
public func trainingNumCol(row: ArrayList<String>, idx: Int64, defaultText: String): String {
    return trainingSafeNum(trainingSafeCol(row, idx, ""), defaultText)
}

// ======================== 纯函数：时间格式校验 ========================

/**
 * 严格的 'YYYY-MM-DD HH:MM:SS' 形状校验（19 字符 + 逐字节白名单 + 取值范围）。
 * 参照 attendance_controller 的 isValidYearMonth：校验通过后串里只可能剩下
 * 数字与 - : 空格，从根上封死「时间字段带 SQL」这条路。
 *
 * 这里只管「形状」不管「日期是否真实存在」：2 月 30 日形状合法，
 * 那部分交给 trainingTimeValid 让 MySQL 自己判——本机没有仓颉 SDK，
 * 自己实现一套闰年/大小月规则既无法验证也没有必要。
 */
public func trainingTimeFormatOk(s: String): Bool {
    let bytes = s.toArray()
    if (bytes.size != 19) {
        return false
    }
    let zero: UInt8 = 0x30
    let one: UInt8 = 0x31
    let two: UInt8 = 0x32
    let three: UInt8 = 0x33
    let five: UInt8 = 0x35
    let nine: UInt8 = 0x39
    let dash: UInt8 = 0x2D
    let colon: UInt8 = 0x3A
    let space: UInt8 = 0x20
    if (bytes[4] != dash || bytes[7] != dash) {
        return false
    }
    if (bytes[10] != space) {
        return false
    }
    if (bytes[13] != colon || bytes[16] != colon) {
        return false
    }
    // 年：固定 20xx（HR 系统不会出现 19xx/21xx 的开课时间）
    if (bytes[0] != two || bytes[1] != zero) {
        return false
    }
    let digitIdx = ArrayList<Int64>()
    digitIdx.add(2)
    digitIdx.add(3)
    digitIdx.add(5)
    digitIdx.add(6)
    digitIdx.add(8)
    digitIdx.add(9)
    digitIdx.add(11)
    digitIdx.add(12)
    digitIdx.add(14)
    digitIdx.add(15)
    digitIdx.add(17)
    digitIdx.add(18)
    for (i in digitIdx) {
        let b = bytes[i]
        if (b < zero || b > nine) {
            return false
        }
    }
    // 月 01-12
    if (bytes[5] == zero) {
        if (bytes[6] == zero) { return false }
    } else if (bytes[5] == one) {
        if (bytes[6] > two) { return false }
    } else {
        return false
    }
    // 日 01-31
    if (bytes[8] == zero) {
        if (bytes[9] == zero) { return false }
    } else if (bytes[8] == three) {
        if (bytes[9] > one) { return false }
    } else if (bytes[8] > two) {
        return false
    }
    // 时 00-23
    if (bytes[11] == two) {
        if (bytes[12] > three) { return false }
    } else if (bytes[11] > one) {
        return false
    }
    // 分/秒 00-59
    if (bytes[14] > five || bytes[17] > five) {
        return false
    }
    return true
}

/** 时间是否既是合法形状、又被 MySQL 认（后者能挡住 2 月 30 日）。 */
public func trainingTimeValid(value: String): Bool {
    if (!trainingTimeFormatOk(value)) { return false }
    // 非法日期 TIMESTAMPDIFF 返回 NULL，querySingleInt 取不到值回退 -1；
    // 合法日期的自差恒为 0。
    return querySingleInt(trainingTimeCheckSql(value), -1) == 0
}

/** 起止都合法且结课晚于开课（在库里比，避免仓颉侧解析日期）。 */
public func trainingTimeOk(startAt: String, endAt: String): Bool {
    if (!trainingTimeValid(startAt)) { return false }
    if (!trainingTimeValid(endAt)) { return false }
    return querySingleInt(trainingTimeSpanSql(startAt, endAt), -1) > 0
}

/**
 * 字符数（不是字节数）：MySQL 的 VARCHAR(n) 按字符计长，直接拿 String.size
 * 会把「王梓涵」这类 3 字姓名算成 9 而误杀（与 employee_controller.strRuneLen 同口径）。
 */
public func trainingRuneLen(s: String): Int64 {
    return s.toRuneArray().size
}

/**
 * 表单必填 / 长度 / 时间形状校验（纯函数，可单测）。返回空串 = 通过。
 * 长度上限逐条对齐建表 DDL：title VARCHAR(120)、trainer VARCHAR(64)。
 * 这里选择「拒绝并给文案」而不是「静默截断」——培训主题是给人看的，
 * 被系统悄悄砍掉一半比报错更难排查。
 */
public func trainingValidateForm(title: String, trainer: String, startAt: String, endAt: String): String {
    if (title.isEmpty()) { return "培训主题必填" }
    if (trainingRuneLen(title) > 120) { return "培训主题不超过 120 字" }
    if (trainer.isEmpty()) { return "讲师必填" }
    if (trainingRuneLen(trainer) > 64) { return "讲师姓名不超过 64 字" }
    if (startAt.isEmpty()) { return "开课时间必填" }
    if (endAt.isEmpty()) { return "结课时间必填" }
    if (!trainingTimeFormatOk(startAt)) { return "开课时间格式须为 YYYY-MM-DD HH:MM:SS" }
    if (!trainingTimeFormatOk(endAt)) { return "结课时间格式须为 YYYY-MM-DD HH:MM:SS" }
    return ""
}

// ======================== 处理器：发布通知 ========================

/**
 * 培训计划发布 -> 推站内通知给面向部门的在职员工。
 *
 * 复用 P3.2 的通知基础设施（notifInsertSql / notifJoinInserts）而不是逐条
 * pushNotification：面向全员的课一次要发几十条，逐条走 mysql.exe 子进程
 * 会让发布接口慢到不可用，拼成一条脚本一次执行是这里的正确量级。
 * notifInsertSql 自带 INSERT IGNORE + UNIQUE(user_id, type, ref_id)，
 * 重复发布同一个计划不会刷屏。
 * 通知失败不影响发布本身（培训计划已落库），只记日志。
 */
public func notifyTrainingPublished(trainingId: Int64, title: String, deptId: Int64, startAt: String, credit: Float64): Unit {
    if (trainingId <= 0) { return }
    let scope = if (deptId > 0) {
        "本部门"
    } else {
        "全员"
    }
    let ref = "${trainingId}"
    let digest = truncateUtf8(title, 60)
    let body = "《${digest}》已发布（面向${scope}），开课时间 ${startAt}，可获得 ${formatNum2(credit)} 学分，请及时报名。"
    let rows = queryRows(trainingAudienceSql(deptId))
    let parts = ArrayList<String>()
    for (r in rows) {
        if (r.size < 1) { continue }
        let uid = Int64.tryParse(trainingNumCol(r, 0, "0")) ?? 0
        if (uid <= 0) { continue }
        parts.add(notifInsertSql(uid, "TRAINING_PUBLISHED", "培训新课上线：《${digest}》", body, ref))
    }
    let script = notifJoinInserts(parts)
    if (script.isEmpty()) { return }
    executeSql(script)
}

