package hrms_backend.controller

import std.time.*
import std.convert.*
import std.collection.*
import hrms_backend.common.*
import hrms_backend.db.*
import hrms_backend.middleware.*
import hrms_backend.service.*

// ============================================================================
// P4.2 差旅与报销（hr_expense）
//
// 模块职责：员工自助填报销单（草稿）→ 提交 → 主管 / HR 审批（部门范围 + 金额档位 +
//           自审闸门）→ HR 按「报销月份 + 员工」批量发放 → 全程站内通知。
//
// 状态机（expenseNextStatus / expenseActionDenied 是唯一的裁决处，处理器不得自己判分支）：
//   DRAFT     --submit-->   SUBMITTED
//   SUBMITTED --approve-->  APPROVED
//   SUBMITTED --reject-->   REJECTED
//   SUBMITTED --withdraw--> DRAFT        （仅本人撤回）
//   REJECTED  --submit-->   SUBMITTED    （修改后重报）
//   APPROVED  --pay-->      PAID         （PAID 为终态）
//   其余跃迁一律非法，返回中文原因（业务码 400，不是 500）。
//
// 闸门清单（全部是不碰库的纯函数，返回原因串，空串 = 放行）：
//   expenseTitleDenied      标题非空、按 UTF-8 字节限长 120
//   expenseAmountDenied     amount > 0、按分钳位、上限 100000 防脏数据
//   expenseLimitDenied      类别单笔上限（未知类别直接拒绝）
//   expenseTravelDenied     TRAVEL 必须有 city 且 days ∈ [1,60]；非差旅忽略 city/days
//   expenseMonthDenied      pay_month 必须是合法 YYYY-MM 且等于 occur_date 所在月
//   expenseDateDenied       occur_date 必须是合法 YYYY-MM-DD（真实性再交给 MySQL 复核）
//   expenseReceiptDenied    票号字符集与长度（重复票号：先查 expenseReceiptDupSql，
//                           再由 UNIQUE KEY uk_expense_emp_month_receipt 兜底）
//   expenseEditDenied       只有 DRAFT / REJECTED 允许本人修改
//   expenseDeleteDenied     只有 DRAFT 允许删除
//   expenseStatusChangeDenied  PUT 不允许绕过状态机直接改 status
//   expenseApproverDenied   部门范围（MANAGER 限本部门）+ 金额档位（>5000 只能 ADMIN/HR）
//                           + 自审闸门（审批人 == 提交人一律拒绝）
//   expensePayDenied        只能对 APPROVED 发放，且批次月份必须等于该单的 pay_month
//
// 出参契约（前端与测试的唯一依据）：
//   列表行 / 详情行（expenseRowToJson）固定键，顺序即 SELECT 列顺序：
//     id, employeeId, empNo, empName, deptName, category, categoryLabel, title,
//     amount, occurDate, payMonth, city, days, receiptNo, status, statusLabel,
//     approverName, approveRemark, approvedAt, paidAt, submittedAt, createdAt, remark
//   1. amount 一律是「字符串 + 永远两位小数」（common.formatNum2 的算法，如 "1.50"），
//      不做裸 round 拼接，避免 1.5 / 1.50 两种形态同时出现。
//   2. 未发生的时间字段（submittedAt / approvedAt / paidAt）返回 JSON null，
//      不用空串冒充；哨兵语义与 training 模块一致。
//   3. 可空的文本列（receiptNo / approveRemark / remark）同样返回 null；
//      receiptNo = null 表示「无票」，city = "" 表示非差旅不适用。
//   4. xxxLabel 命名对齐 training 模块（categoryLabel / statusLabel）。
//   详情（GET /expenses/:id）额外返回 timeline：
//     [{"step","label","status","at","operatorName","remark"}]（at 允许 null）。
//
// 为什么报销款绝不写 hr_payroll：
//   本项目的薪资核算把 hr_payroll.bonus 计入 calculateTax 的应税所得，而实报实销的
//   报销款不是工资性收入；一旦并入，个税会算错，且既有「金额一致性」用例会被动摇。
//   所以发放只在本模块记录 paid_at / paid_by，是一条独立的发放通道。
//
// SQL 纪律（同 P4.1）：只使用 mysql_pool 的 5 个门面（queryRows / querySingleValue /
//   querySingleInt / executeSql / insertAndGetId）；所有 SQL 文本由本文件的纯函数生成，
//   筛选值走白名单或 sqlStr，禁止把用户输入裸拼进语句。
// ============================================================================

/** 主管可审批的金额档位上限（元）：超过它必须由 ADMIN / HR 审批。 */
public let EXPENSE_MANAGER_MAX_AMOUNT: Float64 = 5000.0

/** 单笔金额硬上限（元）：挡脏数据与前端误传（DECIMAL(10,2) 本身容得下更大值）。 */
public let EXPENSE_AMOUNT_MAX: Float64 = 100000.0

/** 差旅天数上限。 */
public let EXPENSE_DAYS_MAX: Int64 = 60

/** 标题字节上限，与建表 varchar(120) 对齐。 */
public let EXPENSE_TITLE_MAX: Int64 = 120

// ======================== 纯函数：字典与状态机 ========================

/** 报销类别白名单，与建表 COMMENT 逐字一致；未知类别直接拒绝，防止限额闸门被绕过。 */
public func expenseIsValidCategory(s: String): Bool {
    if (s == "TRAVEL") { return true }
    if (s == "TRANSPORT") { return true }
    if (s == "MEAL") { return true }
    if (s == "OFFICE") { return true }
    if (s == "OTHER") { return true }
    return false
}

/** 报销单状态白名单，与上面的状态机注释逐字一致。 */
public func expenseIsValidStatus(s: String): Bool {
    if (s == "DRAFT") { return true }
    if (s == "SUBMITTED") { return true }
    if (s == "APPROVED") { return true }
    if (s == "REJECTED") { return true }
    if (s == "PAID") { return true }
    return false
}

/** 状态流转动作白名单（approve 接口用 APPROVE / REJECT 两个动作）。 */
public func expenseIsValidAction(s: String): Bool {
    if (s == "SUBMIT") { return true }
    if (s == "WITHDRAW") { return true }
    if (s == "APPROVE") { return true }
    if (s == "REJECT") { return true }
    if (s == "PAY") { return true }
    return false
}

public func expenseCategoryLabel(s: String): String {
    if (s == "TRAVEL") { return "差旅" }
    if (s == "TRANSPORT") { return "交通" }
    if (s == "MEAL") { return "餐费" }
    if (s == "OFFICE") { return "办公" }
    if (s == "OTHER") { return "其他" }
    return "未知"
}

public func expenseStatusLabel(s: String): String {
    if (s == "DRAFT") { return "草稿" }
    if (s == "SUBMITTED") { return "待审批" }
    if (s == "APPROVED") { return "已批准" }
    if (s == "REJECTED") { return "已驳回" }
    if (s == "PAID") { return "已发放" }
    return "未知"
}

/**
 * 状态机唯一裁决处：合法跃迁返回目标状态，非法跃迁返回空串。
 * 同态（例如对 SUBMITTED 再次 submit）也算非法，由 expenseActionDenied 给出
 * 「已经是待审批」这类更准确的中文原因，而不是笼统的「状态不允许」。
 */
public func expenseNextStatus(from: String, action: String): String {
    if (!expenseIsValidStatus(from) || !expenseIsValidAction(action)) { return "" }
    if (action == "SUBMIT") {
        if (from == "DRAFT" || from == "REJECTED") { return "SUBMITTED" }
        return ""
    }
    if (action == "WITHDRAW") {
        if (from == "SUBMITTED") { return "DRAFT" }
        return ""
    }
    if (action == "APPROVE") {
        if (from == "SUBMITTED") { return "APPROVED" }
        return ""
    }
    if (action == "REJECT") {
        if (from == "SUBMITTED") { return "REJECTED" }
        return ""
    }
    if (action == "PAY") {
        if (from == "APPROVED") { return "PAID" }
        return ""
    }
    return ""
}

/**
 * 非法跃迁的中文原因。action 取 SUBMIT / WITHDRAW / APPROVE / REJECT / PAY，
 * 空串 = 允许。这里刻意把「为什么不行」和「下一步该做什么」一起说清楚，
 * 前端可以直接展示。
 */
public func expenseActionDenied(status: String, action: String): String {
    if (!expenseIsValidStatus(status)) {
        return "单据状态异常（${status}），请刷新后重试"
    }
    if (expenseNextStatus(status, action) != "") { return "" }
    if (action == "SUBMIT") {
        if (status == "SUBMITTED") { return "该报销单已提交，正在等待审批" }
        if (status == "APPROVED") { return "该报销单已批准，如需修改请先由 HR 撤回发放流程" }
        if (status == "PAID") { return "该报销单已发放，报销单已归档不可再操作" }
        return "只有草稿或被驳回的报销单可以提交"
    }
    if (action == "WITHDRAW") {
        if (status == "DRAFT") { return "草稿尚未提交，无需撤回" }
        if (status == "PAID") { return "报销款已发放，不能再撤回单据" }
        return "只有待审批的报销单可以撤回"
    }
    if (action == "APPROVE") {
        if (status == "APPROVED") { return "该报销单已批准，无需重复审批" }
        if (status == "PAID") { return "该报销单已发放，无需重复审批" }
        return "只有待审批的报销单可以批准"
    }
    if (action == "REJECT") {
        if (status == "REJECTED") { return "该报销单已驳回，无需重复操作" }
        return "只有待审批的报销单可以驳回"
    }
    if (action == "PAY") {
        if (status == "PAID") { return "该报销单已发放，请勿重复操作" }
        return "只有已批准的报销单可以发放"
    }
    return "不支持的操作：${action}"
}

/** 本人可改闸门：已提交的单据内容锁定，只能撤回后再改。空串 = 允许。 */
public func expenseEditDenied(status: String): String {
    if (status == "DRAFT" || status == "REJECTED") { return "" }
    if (status == "SUBMITTED") {
        return "报销单已提交，内容已锁定；请先撤回为草稿再修改"
    }
    if (status == "PAID") {
        return "报销款已发放，单据不可修改"
    }
    return "当前状态（${expenseStatusLabel(status)}）不允许修改"
}

/** 本人可删闸门：只有草稿可删。空串 = 允许。 */
public func expenseDeleteDenied(status: String): String {
    if (status == "DRAFT") { return "" }
    if (status == "SUBMITTED") { return "报销单正在审批中，请先撤回后再删除" }
    return "已${expenseStatusLabel(status)}的报销单不可删除"
}

/**
 * PUT 里的 status 字段闸门：状态只能由 submit / withdraw / approve / pay 四个接口驱动。
 * want 与当前状态相同视为「没改」，放行（前端整单回传是常见写法）。空串 = 允许。
 */
public func expenseStatusChangeDenied(current: String, want: String): String {
    if (!expenseIsValidStatus(want)) {
        return "status 取值非法：${want}"
    }
    if (want == current) { return "" }
    return "status 只能通过提交 / 撤回 / 审批 / 发放接口变更（当前 ${expenseStatusLabel(current)}，收到 ${expenseStatusLabel(want)}）"
}

/**
 * 审批权限闸门（部门范围 + 金额档位 + 自审闸门），空串 = 允许。
 * role        当前审批人的 sys_user.role
 * sameDept    审批人与报销人是否同部门（ADMIN / HR 不看这个）
 * amount      单据金额（已钳位）
 * selfSubmit  审批人 user_id 是否等于单据的 submit_user_id
 */
public func expenseApproverDenied(role: String, sameDept: Bool, amount: Float64, selfSubmit: Bool): String {
    if (role != "ADMIN" && role != "HR" && role != "MANAGER") {
        return "只有主管或 HR 可以审批报销单"
    }
    if (selfSubmit) {
        return "不能审批自己提交的报销单，请由其他主管或 HR 处理"
    }
    if (role == "MANAGER") {
        if (!sameDept) {
            return "只能审批本部门员工的报销单"
        }
        if (amount > EXPENSE_MANAGER_MAX_AMOUNT) {
            return "单笔 ${formatNum2(amount)} 元超过主管档位 ${formatNum2(EXPENSE_MANAGER_MAX_AMOUNT)} 元，请转 ADMIN / HR 审批"
        }
    }
    return ""
}

/** 发放闸门：状态 + 批次月份一致性。batchMonth 为空串表示前端没传，由处理器回填单据月份。 */
public func expensePayDenied(status: String, billMonth: String, batchMonth: String): String {
    if (status != "APPROVED") {
        return expenseActionDenied(status, "PAY")
    }
    if (!batchMonth.isEmpty() && batchMonth != billMonth) {
        return "发放批次月份 ${batchMonth} 与单据报销月份 ${billMonth} 不一致"
    }
    return ""
}

// ======================== 纯函数：字段校验 ========================

/** 类别单笔上限（元）；未知类别返回 -1，由 expenseLimitDenied 拒绝。 */
public func expenseCategoryLimit(category: String): Float64 {
    if (category == "TRAVEL") { return 20000.0 }
    if (category == "TRANSPORT") { return 5000.0 }
    if (category == "MEAL") { return 2000.0 }
    if (category == "OFFICE") { return 10000.0 }
    if (category == "OTHER") { return 1000.0 }
    return -1.0
}

/**
 * 金额按分钳位：复用 common.round2（Int64(绝对值 * 100 + 0.5) 再除回 100），
 * 保证入库值与展示值都是两位小数，不会出现 1.5 / 1.50 两种形态。
 */
public func expenseClampAmount(raw: Float64): Float64 {
    return round2(raw)
}

/** 金额合法性：> 0、不超硬上限。空串 = 允许（调用方必须先钳位）。 */
public func expenseAmountDenied(amount: Float64): String {
    if (amount <= 0.0) {
        return "报销金额必须大于 0"
    }
    if (amount > EXPENSE_AMOUNT_MAX) {
        return "单笔报销金额不能超过 ${formatNum2(EXPENSE_AMOUNT_MAX)} 元"
    }
    return ""
}

/** 类别限额闸门。未知类别在这里一并拒绝（限额表就是类别白名单的唯一真相来源）。 */
public func expenseLimitDenied(category: String, amount: Float64): String {
    let limit = expenseCategoryLimit(category)
    if (limit < 0.0) {
        return "报销类别非法：${category}，仅支持 TRAVEL / TRANSPORT / MEAL / OFFICE / OTHER"
    }
    if (amount > limit) {
        return "${expenseCategoryLabel(category)} 单笔上限为 ${formatNum2(limit)} 元，本笔 ${formatNum2(amount)} 元已超出单笔上限，请拆分或走专项审批"
    }
    return ""
}

/**
 * 日期闸门：严格校验 'YYYY-MM-DD' —— 长度 10、第 5/8 位是 '-'、数字位全为 0-9、
 * 月份 01-12、日 01-31。逐字节判定（不解析、不比较日期对象），因为本机没有仓颉 SDK，
 * 任何自造的时间解析都无法验证；真实存在性（如 2 月 30 日）交给 MySQL 复核，
 * 见 expenseDateExistsSql。空串 = 允许。
 */
public func expenseDateDenied(s: String): String {
    let bytes = s.toArray()
    let fmtErr = "费用发生日期格式必须为 YYYY-MM-DD"
    if (bytes.size != 10) { return fmtErr }
    let dash: UInt8 = 0x2D
    let zero: UInt8 = 0x30
    let one: UInt8 = 0x31
    let two: UInt8 = 0x32
    let three: UInt8 = 0x33
    let nine: UInt8 = 0x39
    if (bytes[4] != dash || bytes[7] != dash) { return fmtErr }
    let digitIdx = ArrayList<Int64>()
    digitIdx.add(0)
    digitIdx.add(1)
    digitIdx.add(2)
    digitIdx.add(3)
    digitIdx.add(5)
    digitIdx.add(6)
    digitIdx.add(8)
    digitIdx.add(9)
    for (i in digitIdx) {
        let b = bytes[i]
        if (b < zero || b > nine) { return fmtErr }
    }
    if (bytes[5] > one) { return "费用发生日期的月份必须是 01-12" }
    if (bytes[5] == one && bytes[6] > two) { return "费用发生日期的月份必须是 01-12" }
    if (bytes[5] == zero && bytes[6] == zero) { return "费用发生日期的月份必须是 01-12" }
    if (bytes[8] == zero) {
        if (bytes[9] == zero) { return "费用发生日期的日必须是 01-31" }
        return ""
    }
    if (bytes[8] == one || bytes[8] == two) { return "" }
    if (bytes[8] == three && bytes[9] == zero) { return "" }
    return "费用发生日期的日必须是 01-31"
}

/** 严格校验 'YYYY-MM'：长度 7、第 5 位是 '-'、数字位全为 0-9、月份 01-12。 */
public func expenseMonthOk(s: String): Bool {
    let bytes = s.toArray()
    if (bytes.size != 7) { return false }
    let dash: UInt8 = 0x2D
    let zero: UInt8 = 0x30
    let nine: UInt8 = 0x39
    let one: UInt8 = 0x31
    let two: UInt8 = 0x32
    if (bytes[4] != dash) { return false }
    let digitIdx = ArrayList<Int64>()
    digitIdx.add(0)
    digitIdx.add(1)
    digitIdx.add(2)
    digitIdx.add(3)
    digitIdx.add(5)
    digitIdx.add(6)
    for (i in digitIdx) {
        let b = bytes[i]
        if (b < zero || b > nine) { return false }
    }
    if (bytes[5] == zero) { return bytes[6] != zero }
    if (bytes[5] == one) { return bytes[6] >= zero && bytes[6] <= two }
    return false
}

/** 取 'YYYY-MM-DD' 的所属月份；入参必须已过 expenseDateOk，因此是纯 ASCII 切片。 */
public func expenseMonthOfDate(occurDate: String): String {
    if (occurDate.size < 7) { return "" }
    return occurDate[..7]
}

/** 月份一致性：格式合法 + 等于发生日期所在月。空串 = 允许。 */
public func expenseMonthDenied(occurDate: String, payMonth: String): String {
    if (!expenseMonthOk(payMonth)) {
        return "报销月份格式必须为 YYYY-MM，收到「${payMonth}」"
    }
    let expect = expenseMonthOfDate(occurDate)
    if (expect != payMonth) {
        return "报销月份 ${payMonth} 与费用发生日期 ${occurDate} 所在月 ${expect} 不一致"
    }
    return ""
}

/**
 * 差旅完整性闸门：category=TRAVEL 必须给 city 且 days ∈ [1,60]；
 * 非差旅类别忽略 city / days（处理器会把两者清零后入库，避免脏值留在库里）。
 * 空串 = 允许。
 */
public func expenseTravelDenied(category: String, city: String, days: Int64): String {
    if (category != "TRAVEL") { return "" }
    if (city.trimAscii().isEmpty()) {
        return "差旅报销必须填写出差城市"
    }
    if (city.trimAscii().size > 64) {
        return "出差城市长度不能超过 64 字节"
    }
    if (days < 1) {
        return "差旅报销必须填写出差天数（1-${EXPENSE_DAYS_MAX} 天）"
    }
    if (days > EXPENSE_DAYS_MAX) {
        return "出差天数不能超过 ${EXPENSE_DAYS_MAX} 天，超过请走专项审批"
    }
    return ""
}

/** 标题闸门：非空、按 UTF-8 字节限长（建表 varchar(120)）。空串 = 允许。 */
public func expenseTitleDenied(title: String): String {
    if (title.isEmpty()) {
        return "报销事由不能为空"
    }
    if (title.toArray().size > EXPENSE_TITLE_MAX) {
        return "报销事由过长（最多 ${EXPENSE_TITLE_MAX} 字节），请精简"
    }
    return ""
}

/**
 * 票号格式闸门：空串表示「无票」（入库为 NULL，不与 UNIQUE 冲突）；
 * 非空只允许数字 / 字母 / '-' / '_'，长度 3-64。
 * 白名单校验后可以确定不含引号，拼进 SQL 前仍统一走 sqlStr。
 */
public func expenseReceiptDenied(receiptNo: String): String {
    if (receiptNo.isEmpty()) { return "" }
    let bytes = receiptNo.toArray()
    if (bytes.size < 3) { return "发票号至少 3 位，如留空表示无票" }
    if (bytes.size > 64) { return "发票号长度不能超过 64 字节" }
    let zero: UInt8 = 0x30
    let nine: UInt8 = 0x39
    let upperA: UInt8 = 0x41
    let upperZ: UInt8 = 0x5A
    let lowerA: UInt8 = 0x61
    let lowerZ: UInt8 = 0x7A
    let dash: UInt8 = 0x2D
    let underline: UInt8 = 0x5F
    for (b in bytes) {
        let ok = (b >= zero && b <= nine) || (b >= upperA && b <= upperZ) || (b >= lowerA && b <= lowerZ) || b == dash || b == underline
        if (!ok) { return "发票号只能包含数字、字母、- 和 _" }
    }
    return ""
}

/** 表单组合闸门：按「类别 → 标题 → 金额 → 限额 → 日期 → 月份 → 差旅 → 票号」顺序返回首个原因。 */
public func expenseFormDenied(
    category: String,
    title: String,
    amount: Float64,
    occurDate: String,
    payMonth: String,
    city: String,
    days: Int64,
    receiptNo: String
): String {
    let d1 = expenseLimitDenied(category, amount)
    if (!d1.isEmpty()) { return d1 }
    let d2 = expenseTitleDenied(title)
    if (!d2.isEmpty()) { return d2 }
    let d3 = expenseAmountDenied(amount)
    if (!d3.isEmpty()) { return d3 }
    let d4 = expenseDateDenied(occurDate)
    if (!d4.isEmpty()) { return d4 }
    let d5 = expenseMonthDenied(occurDate, payMonth)
    if (!d5.isEmpty()) { return d5 }
    let d6 = expenseTravelDenied(category, city, days)
    if (!d6.isEmpty()) { return d6 }
    let d7 = expenseReceiptDenied(receiptNo)
    if (!d7.isEmpty()) { return d7 }
    return ""
}

/** 出差天数钳位：负数归零，非差旅由调用方强制归零。 */
public func expenseClampDays(days: Int64): Int64 {
    if (days < 0) { return 0 }
    return days
}

/** 主管档位是否可批（供 /expenses/pending 生成 SQL 条件和响应字段复用）。 */
public func expenseManagerAmountOk(amount: Float64): Bool {
    return amount <= EXPENSE_MANAGER_MAX_AMOUNT
}

// ======================== 纯函数：SQL 文本生成 ========================

/**
 * 列表 / 详情共用的 SELECT 列，顺序与 expenseRowToJson 的索引严格绑定（25 列）：
 *   0 id / 1 employee_id / 2 emp_no / 3 emp_name / 4 dept_name / 5 category / 6 title
 *   7 amount / 8 occur_date / 9 pay_month / 10 city / 11 days / 12 receipt_no
 *   13 status / 14 approver_name / 15 approve_remark / 16 approved_at / 17 paid_at
 *   18 submitted_at / 19 created_at / 20 remark / 21 approver_user_id / 22 submit_user_id
 *   23 dept_id / 24 paid_by_name
 * 金额用 CAST(... AS CHAR)（与 training 的 credit 排行同款写法），NULL 列在 SQL 侧
 * 归一成空串，仓颉侧再按「空串 = 无值」映射成 JSON null。
 */
public func expenseColsSql(): String {
    return """
SELECT ex.id, ex.employee_id, IFNULL(e.emp_no, ''), IFNULL(e.name, ''), IFNULL(d.dept_name, ''),
       ex.category, ex.title, CAST(ex.amount AS CHAR),
       DATE_FORMAT(ex.occur_date, '%Y-%m-%d'), ex.pay_month, ex.city, ex.days,
       IFNULL(ex.receipt_no, ''), ex.status, IFNULL(au.username, ''), IFNULL(ex.approve_remark, ''),
       IFNULL(DATE_FORMAT(ex.approved_at, '%Y-%m-%d %H:%i:%s'), ''),
       IFNULL(DATE_FORMAT(ex.paid_at, '%Y-%m-%d %H:%i:%s'), ''),
       IFNULL(DATE_FORMAT(ex.submitted_at, '%Y-%m-%d %H:%i:%s'), ''),
       DATE_FORMAT(ex.created_at, '%Y-%m-%d %H:%i:%s'), IFNULL(ex.remark, ''),
       ex.approver_user_id, ex.submit_user_id, IFNULL(e.dept_id, 0), IFNULL(pu.username, '')
"""
}

public func expenseFromSql(): String {
    return """
FROM hr_expense ex
LEFT JOIN hr_employee e ON ex.employee_id = e.id
LEFT JOIN hr_department d ON e.dept_id = d.id
LEFT JOIN sys_user au ON ex.approver_user_id = au.id
LEFT JOIN sys_user pu ON ex.paid_by = pu.id
"""
}

/** 多个筛选片段拼成 WHERE：无筛选时落到 1=1，永不产生空 WHERE。 */
public func expenseJoinConds(conds: ArrayList<String>): String {
    let parts = ArrayList<String>()
    for (c in conds) {
        if (!c.isEmpty()) {
            parts.add(c)
        }
    }
    if (parts.size == 0) {
        return "1=1"
    }
    return String.join(parts.toArray(), delimiter: " AND ")
}

/** 状态筛选：只接受白名单值，越界返回空串（= 不加该条件），杜绝把用户输入拼进 SQL。 */
public func expenseStatusCond(raw: String): String {
    if (expenseIsValidStatus(raw)) {
        return "ex.status = ${sqlStr(raw)}"
    }
    return ""
}

public func expenseCategoryCond(raw: String): String {
    if (expenseIsValidCategory(raw)) {
        return "ex.category = ${sqlStr(raw)}"
    }
    return ""
}

/** 报销月份筛选：必须是合法 YYYY-MM，否则忽略该筛选而不是拼进去。 */
public func expenseMonthCond(raw: String): String {
    if (expenseMonthOk(raw)) {
        return "ex.pay_month = ${sqlStr(raw)}"
    }
    return ""
}

/** 关键字筛选：事由 / 发票号 / 员工姓名 / 工号。先转义 LIKE 元字符，再整体走 sqlStr。 */
public func expenseKeywordCond(raw: String): String {
    let kw = raw.trimAscii()
    if (kw.isEmpty()) { return "" }
    var esc = kw.replace("\\", "\\\\")
    esc = esc.replace("%", "\\%")
    esc = esc.replace("_", "\\_")
    let lit = sqlStr("%" + esc + "%")
    return "(ex.title LIKE ${lit} OR ex.receipt_no LIKE ${lit} OR e.name LIKE ${lit} OR e.emp_no LIKE ${lit})"
}

/** 部门筛选（ADMIN / HR 才有意义）。 */
public func expenseDeptCond(raw: Int64): String {
    if (raw > 0) {
        return "e.dept_id = ${raw}"
    }
    return ""
}

/** MANAGER 的自动限权：只能看本部门员工（含未挂部门的单据直接排除）。 */
public func expenseManagerScopeCond(role: String, deptId: Int64): String {
    if (role == "MANAGER") {
        if (deptId > 0) {
            return "e.dept_id = ${deptId}"
        }
        return "1=0"
    }
    return ""
}

/** 只查某位员工的单据（/expenses/my）。 */
public func expenseOwnerCond(employeeId: Int64): String {
    return "ex.employee_id = ${employeeId}"
}

/** 待我审批：状态 + 主管档位 + 部门范围，三段都从纯函数来。 */
public func expensePendingCond(role: String, deptId: Int64): String {
    let scope = expenseManagerScopeCond(role, deptId)
    if (role == "MANAGER") {
        let amountCond = "ex.amount <= ${formatNum2(EXPENSE_MANAGER_MAX_AMOUNT)}"
        if (scope.isEmpty()) {
            return "ex.status = 'SUBMITTED' AND ${amountCond}"
        }
        return "ex.status = 'SUBMITTED' AND ${amountCond} AND ${scope}"
    }
    return "ex.status = 'SUBMITTED'"
}

public func expenseListSql(where: String, limit: Int64, offset: Int64): String {
    return "${expenseColsSql()} ${expenseFromSql()} WHERE ${where} ORDER BY ex.id DESC LIMIT ${limit} OFFSET ${offset}"
}

public func expenseCountSql(where: String): String {
    return "SELECT COUNT(*) FROM hr_expense ex LEFT JOIN hr_employee e ON ex.employee_id = e.id ${expenseDeptJoinSql()} WHERE ${where}"
}

/** 计数语句只需要员工 / 部门两张表（筛选条件只引用它们）。 */
public func expenseDeptJoinSql(): String {
    return "LEFT JOIN hr_department d ON e.dept_id = d.id"
}

/** 详情按主键取一行（含审批人 / 发放人姓名），权限在处理器里用 23 列 dept_id 判定。 */
public func expenseOneSql(id: Int64): String {
    return "${expenseColsSql()} ${expenseFromSql()} WHERE ex.id = ${id} LIMIT 1"
}

/** 状态回读（乐观跃迁后确认写入生效）与存在性判断共用。 */
public func expenseStatusReadSql(id: Int64): String {
    return "SELECT status FROM hr_expense WHERE id = ${id} LIMIT 1"
}

/**
 * 日期真实存在性交给 MySQL 复核（2 月 30 日这类值纯字符串校验挡不住）：
 * 非法日期经 TIMESTAMPDIFF 返回 NULL，querySingleInt 拿到默认值 -1，与合法日期的 0 区分开。
 * 这是 P4.1 已经验证过的做法（trainingTimeValid），不自造仓颉侧日期解析。
 */
public func expenseDateExistsSql(occurDate: String): String {
    let lit = sqlStr(occurDate)
    return "SELECT TIMESTAMPDIFF(DAY, ${lit}, ${lit})"
}

/** 同员工同月重复票号预检：命中就先给友好中文原因，不让数据库抛 1062 变成 500。 */
public func expenseReceiptDupSql(employeeId: Int64, payMonth: String, receiptNo: String, excludeId: Int64): String {
    return "SELECT id FROM hr_expense WHERE employee_id = ${employeeId} AND pay_month = ${sqlStr(payMonth)} AND receipt_no = ${sqlStr(receiptNo)} AND id <> ${excludeId} LIMIT 1"
}

/**
 * 新建单据。status=SUBMITTED（创建即提交）时才写提交人 / 提交时间，
 * 草稿保持 submit_user_id = 0，这样自审闸门只针对真实提交过的单据。
 */
public func expenseInsertSql(
    employeeId: Int64,
    category: String,
    title: String,
    amount: Float64,
    occurDate: String,
    payMonth: String,
    city: String,
    days: Int64,
    receiptNo: String,
    status: String,
    submitUserId: Int64,
    remark: String
): String {
    let submitCols = if (status == "SUBMITTED") { ", submit_user_id, submitted_at" } else { "" }
    let submitVals = if (status == "SUBMITTED") { ", ${submitUserId}, NOW()" } else { "" }
    return """
INSERT INTO hr_expense (employee_id, category, title, amount, occur_date, pay_month, city, days,
                        receipt_no, status, remark${submitCols})
VALUES (${employeeId}, ${sqlStr(category)}, ${sqlStr(title)}, ${formatNum2(amount)}, ${sqlStr(occurDate)},
        ${sqlStr(payMonth)}, ${sqlStr(city)}, ${days}, ${sqlNullableStr(receiptNo)}, ${sqlStr(status)},
        ${sqlNullableStr(remark)}${submitVals})
"""
}

/**
 * 局部更新的落库语句：处理器已经把「body 里没出现的字段」用库中原值回填，
 * 所以这里可以安全地整行覆写。status / 审批与发放字段不在 UPDATE 列里，
 * 状态只能由四个动作接口驱动（见 expenseStatusChangeDenied）。
 */
public func expenseUpdateSql(
    id: Int64,
    category: String,
    title: String,
    amount: Float64,
    occurDate: String,
    payMonth: String,
    city: String,
    days: Int64,
    receiptNo: String,
    remark: String
): String {
    return """
UPDATE hr_expense
SET category = ${sqlStr(category)}, title = ${sqlStr(title)}, amount = ${formatNum2(amount)},
    occur_date = ${sqlStr(occurDate)}, pay_month = ${sqlStr(payMonth)}, city = ${sqlStr(city)},
    days = ${days}, receipt_no = ${sqlNullableStr(receiptNo)}, remark = ${sqlNullableStr(remark)}
WHERE id = ${id}
"""
}

/**
 * 提交：带状态乐观条件，并发下重复提交只会成功一次（affected=0 由回读确认）。
 * REJECTED 重报时同时清掉上一轮的审批痕迹（approve_remark 保留会让前端误读成最新结论）。
 */
public func expenseSubmitSql(id: Int64, fromStatus: String, submitUserId: Int64): String {
    let clearRemark = if (fromStatus == "REJECTED") { ", approve_remark = NULL, approved_at = NULL, approver_user_id = 0" } else { "" }
    return """
UPDATE hr_expense
SET status = 'SUBMITTED', submit_user_id = ${submitUserId}, submitted_at = NOW()${clearRemark}
WHERE id = ${id} AND status = ${sqlStr(fromStatus)}
"""
}

/** 撤回：只有本人 + 待审批可撤回，同时清空提交痕迹，回到干净的草稿。 */
public func expenseWithdrawSql(id: Int64, employeeId: Int64): String {
    return """
UPDATE hr_expense
SET status = 'DRAFT', submit_user_id = 0, submitted_at = NULL
WHERE id = ${id} AND status = 'SUBMITTED' AND employee_id = ${employeeId}
"""
}

/** 审批（通过 / 驳回都走这里）：乐观条件 WHERE status='SUBMITTED'，防止双人同时审批。 */
public func expenseApproveSql(id: Int64, nextStatus: String, approverUserId: Int64, approveRemark: String): String {
    return """
UPDATE hr_expense
SET status = ${sqlStr(nextStatus)}, approver_user_id = ${approverUserId},
    approve_remark = ${sqlNullableStr(approveRemark)}, approved_at = NOW()
WHERE id = ${id} AND status = 'SUBMITTED'
"""
}

/** 发放：乐观条件 WHERE status='APPROVED'，独立于薪资发放通道。 */
public func expensePaySql(id: Int64, payUserId: Int64): String {
    return """
UPDATE hr_expense
SET status = 'PAID', paid_at = NOW(), paid_by = ${payUserId}
WHERE id = ${id} AND status = 'APPROVED'
"""
}

/** 删除：本人 + 仅草稿，条件全部写进 WHERE，不依赖先读后删。 */
public func expenseDeleteSql(id: Int64, employeeId: Int64): String {
    return "DELETE FROM hr_expense WHERE id = ${id} AND employee_id = ${employeeId} AND status = 'DRAFT'"
}

/** 本人单据的状态计数与合计（/expenses/my 的 summary）。 */
public func expenseCountsSql(employeeId: Int64): String {
    return """
SELECT status, COUNT(*), CAST(IFNULL(SUM(amount), 0) AS CHAR)
FROM hr_expense WHERE employee_id = ${employeeId}
GROUP BY status ORDER BY status ASC
"""
}

/** 按类别汇总（金额 + 单数）。 */
public func expenseStatCategorySql(where: String): String {
    return """
SELECT ex.category, COUNT(*), CAST(IFNULL(SUM(ex.amount), 0) AS CHAR)
${expenseFromSql()} WHERE ${where}
GROUP BY ex.category ORDER BY SUM(ex.amount) DESC, ex.category ASC
"""
}

/** 按报销月份汇总，只回最近 12 个月。 */
public func expenseStatMonthSql(where: String): String {
    return """
SELECT ex.pay_month, COUNT(*), CAST(IFNULL(SUM(ex.amount), 0) AS CHAR)
${expenseFromSql()} WHERE ${where}
GROUP BY ex.pay_month ORDER BY ex.pay_month DESC LIMIT 12
"""
}

/** 按部门汇总 TOP 10（key 用部门名，NULL 部门归入「未分配部门」）。 */
public func expenseStatDeptSql(where: String): String {
    return """
SELECT IFNULL(d.dept_name, '未分配部门'), COUNT(*), CAST(IFNULL(SUM(ex.amount), 0) AS CHAR)
${expenseFromSql()} WHERE ${where}
GROUP BY IFNULL(d.dept_name, '未分配部门') ORDER BY SUM(ex.amount) DESC, IFNULL(d.dept_name, '未分配部门') ASC LIMIT 10
"""
}

/** 按状态汇总（stats 顶部的概览卡片）。 */
public func expenseStatStatusSql(where: String): String {
    return """
SELECT ex.status, COUNT(*), CAST(IFNULL(SUM(ex.amount), 0) AS CHAR)
${expenseFromSql()} WHERE ${where}
GROUP BY ex.status ORDER BY ex.status ASC
"""
}

/**
 * 结算台账（独立发放通道）：按员工聚合该报销月份的「已批准未发放」笔数与金额，
 * 同时把仍在审批中的笔数带出来，供 HR 判断是否要先催办再发放。
 */
public func expenseSettlementSql(payMonth: String): String {
    return """
SELECT ex.employee_id, IFNULL(e.emp_no, ''), IFNULL(e.name, ''), IFNULL(d.dept_name, ''),
       COUNT(CASE WHEN ex.status = 'APPROVED' THEN 1 END),
       CAST(IFNULL(SUM(CASE WHEN ex.status = 'APPROVED' THEN ex.amount ELSE 0 END), 0) AS CHAR),
       COUNT(CASE WHEN ex.status = 'SUBMITTED' THEN 1 END),
       CAST(IFNULL(SUM(CASE WHEN ex.status = 'SUBMITTED' THEN ex.amount ELSE 0 END), 0) AS CHAR)
FROM hr_expense ex
LEFT JOIN hr_employee e ON ex.employee_id = e.id
LEFT JOIN hr_department d ON e.dept_id = d.id
WHERE ex.pay_month = ${sqlStr(payMonth)} AND ex.status IN ('APPROVED', 'SUBMITTED')
GROUP BY ex.employee_id, IFNULL(e.emp_no, ''), IFNULL(e.name, ''), IFNULL(d.dept_name, '')
ORDER BY SUM(CASE WHEN ex.status = 'APPROVED' THEN ex.amount ELSE 0 END) DESC, ex.employee_id ASC
"""
}

/**
 * 报销单提交后该通知谁：小额（<= 主管档位）通知本部门主管 + ADMIN/HR；
 * 大额只通知 ADMIN/HR，否则主管收到一条自己无权处理的待办。
 */
public func expenseApproverUserSql(amount: Float64, deptId: Int64): String {
    if (amount > EXPENSE_MANAGER_MAX_AMOUNT) {
        return "SELECT id FROM sys_user WHERE is_active = 1 AND role IN ('ADMIN', 'HR') ORDER BY id ASC"
    }
    if (deptId > 0) {
        return """
SELECT id FROM sys_user
WHERE is_active = 1 AND (role IN ('ADMIN', 'HR') OR (role = 'MANAGER' AND employee_id IN (
    SELECT id FROM hr_employee WHERE dept_id = ${deptId}
)))
ORDER BY id ASC
"""
    }
    return "SELECT id FROM sys_user WHERE is_active = 1 AND role IN ('ADMIN', 'HR') ORDER BY id ASC"
}

/** 某员工某月仍未决（SUBMITTED）的单据数，发放响应里的警告来源。 */
public func expensePendingCountSql(employeeId: Int64, payMonth: String): String {
    return "SELECT COUNT(*) FROM hr_expense WHERE employee_id = ${employeeId} AND pay_month = ${sqlStr(payMonth)} AND status = 'SUBMITTED'"
}

/** 单据归属员工的 sys_user 主键（审批结果 / 发放通知的收件人）。 */
public func expenseOwnerUserSql(employeeId: Int64): String {
    return "SELECT id FROM sys_user WHERE employee_id = ${employeeId} LIMIT 1"
}

// ======================== 纯函数：行 → JSON ========================

/** 单据行专用（一行 = 25 列）：列缺失、空串、字面量 NULL 一律回落到默认值。 */
public func expenseCol(row: ArrayList<String>, i: Int64, def: String): String {
    if (i < 0 || i >= row.size) { return def }
    let v = row[i]
    if (v == "NULL") { return def }
    if (v.isEmpty()) { return def }
    return v
}

public func expenseIntCol(row: ArrayList<String>, i: Int64): Int64 {
    let v = expenseCol(row, i, "0")
    return Int64.tryParse(v) ?? 0
}

public func expenseFloatCol(row: ArrayList<String>, i: Int64): Float64 {
    let v = expenseCol(row, i, "0")
    return Float64.tryParse(v) ?? 0.0
}

/** 时间列哨兵：库里没有值就输出 JSON null，绝不用空串冒充（与 training 一致）。 */
public func expenseTimeJson(v: String): String {
    if (v.isEmpty()) { return "null" }
    return jsonStr(v)
}

/** 可空文本列哨兵：空串 → JSON null。 */
public func expenseTextJson(v: String): String {
    if (v.isEmpty()) { return "null" }
    return jsonStr(v)
}

/**
 * 25 列 -> 单据 JSON，键名严格遵循文件头的出参契约。
 * 金额走 formatNum2（永远两位小数）后再 jsonStr 成字符串，避免前端拿到 1.5 少一位。
 */
public func expenseRowToJson(row: ArrayList<String>): String {
    let id = expenseIntCol(row, 0)
    let employeeId = expenseIntCol(row, 1)
    let empNo = expenseCol(row, 2, "")
    let empName = expenseCol(row, 3, "")
    let deptName = expenseCol(row, 4, "")
    let category = expenseCol(row, 5, "OTHER")
    let title = expenseCol(row, 6, "")
    let amount = expenseClampAmount(expenseFloatCol(row, 7))
    let occurDate = expenseCol(row, 8, "")
    let payMonth = expenseCol(row, 9, "")
    let city = expenseCol(row, 10, "")
    let days = expenseIntCol(row, 11)
    let receiptNo = expenseCol(row, 12, "")
    let status = expenseCol(row, 13, "DRAFT")
    let approverName = expenseCol(row, 14, "")
    let approveRemark = expenseCol(row, 15, "")
    let approvedAt = expenseCol(row, 16, "")
    let paidAt = expenseCol(row, 17, "")
    let submittedAt = expenseCol(row, 18, "")
    let createdAt = expenseCol(row, 19, "")
    let remark = expenseCol(row, 20, "")
    let amountStr = formatNum2(amount)
    return "{" +
        "\"id\":${id}," +
        "\"employeeId\":${employeeId}," +
        "\"empNo\":${jsonStr(empNo)}," +
        "\"empName\":${jsonStr(empName)}," +
        "\"deptName\":${jsonStr(deptName)}," +
        "\"category\":${jsonStr(category)}," +
        "\"categoryLabel\":${jsonStr(expenseCategoryLabel(category))}," +
        "\"title\":${jsonStr(title)}," +
        "\"amount\":${jsonStr(amountStr)}," +
        "\"occurDate\":${jsonStr(occurDate)}," +
        "\"payMonth\":${jsonStr(payMonth)}," +
        "\"city\":${jsonStr(city)}," +
        "\"days\":${days}," +
        "\"receiptNo\":${expenseTextJson(receiptNo)}," +
        "\"status\":${jsonStr(status)}," +
        "\"statusLabel\":${jsonStr(expenseStatusLabel(status))}," +
        "\"approverName\":${expenseTextJson(approverName)}," +
        "\"approveRemark\":${expenseTextJson(approveRemark)}," +
        "\"approvedAt\":${expenseTimeJson(approvedAt)}," +
        "\"paidAt\":${expenseTimeJson(paidAt)}," +
        "\"submittedAt\":${expenseTimeJson(submittedAt)}," +
        "\"createdAt\":${expenseTimeJson(createdAt)}," +
        "\"remark\":${expenseTextJson(remark)}" +
        "}"
}

/** 审批步骤的中文标签：驳回与通过共用 approved_at，靠 status 区分语义。 */
public func expenseApproveStepLabel(status: String): String {
    if (status == "REJECTED") { return "已驳回" }
    return "已批准"
}

/**
 * 审批轨迹：由单据上的 4 个时间戳拼出（创建 / 提交 / 审批 / 发放），
 * 未发生的时间字段保持 null；待审批单据额外追加一条 at=null 的进行中节点。
 */
public func expenseTimelineJson(row: ArrayList<String>): String {
    let empName = expenseCol(row, 3, "")
    let status = expenseCol(row, 13, "DRAFT")
    let approverName = expenseCol(row, 14, "")
    let approveRemark = expenseCol(row, 15, "")
    let approvedAt = expenseCol(row, 16, "")
    let paidAt = expenseCol(row, 17, "")
    let submittedAt = expenseCol(row, 18, "")
    let createdAt = expenseCol(row, 19, "")
    let paidByName = expenseCol(row, 24, "")
    let empNameJson = jsonStr(empName)
    let steps = ArrayList<String>()
    steps.add("{\"step\":\"CREATED\",\"label\":\"创建草稿\",\"status\":\"DRAFT\",\"at\":${expenseTimeJson(createdAt)},\"operatorName\":${empNameJson},\"remark\":null}")
    if (!submittedAt.isEmpty()) {
        steps.add("{\"step\":\"SUBMITTED\",\"label\":\"提交审批\",\"status\":\"SUBMITTED\",\"at\":${expenseTimeJson(submittedAt)},\"operatorName\":${empNameJson},\"remark\":null}")
    }
    if (!approvedAt.isEmpty()) {
        let label = expenseApproveStepLabel(status)
        let stepKey = if (status == "REJECTED") { "REJECTED" } else { "APPROVED" }
        let billStatus = if (status == "REJECTED") { "REJECTED" } else { "APPROVED" }
        steps.add("{\"step\":\"${stepKey}\",\"label\":\"${label}\",\"status\":\"${billStatus}\",\"at\":${expenseTimeJson(approvedAt)},\"operatorName\":${jsonStr(approverName)},\"remark\":${expenseTextJson(approveRemark)}}")
    }
    if (!paidAt.isEmpty()) {
        steps.add("{\"step\":\"PAID\",\"label\":\"报销款已发放\",\"status\":\"PAID\",\"at\":${expenseTimeJson(paidAt)},\"operatorName\":${jsonStr(paidByName)},\"remark\":null}")
    }
    if (status == "SUBMITTED") {
        steps.add("{\"step\":\"WAITING\",\"label\":\"等待审批\",\"status\":\"SUBMITTED\",\"at\":null,\"operatorName\":null,\"remark\":null}")
    }
    let joined = String.join(steps.toArray(), delimiter: ",")
    return "[${joined}]"
}

/** 聚合行（[key, count, amount]）的中文标签：类别 / 状态有字典，月份与部门原样。 */
public func expenseGroupKeyLabel(kind: String, key: String): String {
    if (kind == "category") { return expenseCategoryLabel(key) }
    if (kind == "status") { return expenseStatusLabel(key) }
    return key
}

public func expenseGroupRowToJson(groupRow: ArrayList<String>, kind: String): String {
    let key = expenseCol(groupRow, 0, "")
    let cnt = expenseIntCol(groupRow, 1)
    let total = expenseClampAmount(expenseFloatCol(groupRow, 2))
    let keyLabel = expenseGroupKeyLabel(kind, key)
    let amountStr = formatNum2(total)
    return "{\"key\":${jsonStr(key)},\"keyLabel\":${jsonStr(keyLabel)},\"count\":${cnt},\"amount\":${jsonStr(amountStr)}}"
}

/** 聚合行集 -> JSON 数组（按类别 / 月份 / 部门 / 状态共用）。 */
public func expenseGroupRowsToJson(rows: ArrayList<ArrayList<String>>, kind: String): String {
    let items = ArrayList<String>()
    for (row in rows) {
        items.add(expenseGroupRowToJson(row, kind))
    }
    let joined = String.join(items.toArray(), delimiter: ",")
    return "[${joined}]"
}

/** 状态计数行集里取某状态的单数（不存在返回 0）。 */
public func expenseCountByStatus(rows: ArrayList<ArrayList<String>>, status: String): Int64 {
    for (row in rows) {
        if (expenseCol(row, 0, "") == status) {
            return expenseIntCol(row, 1)
        }
    }
    return 0
}

/** 状态计数行集里取某状态的金额合计（不存在返回 0.0）。 */
public func expenseAmountByStatus(rows: ArrayList<ArrayList<String>>, status: String): Float64 {
    for (row in rows) {
        if (expenseCol(row, 0, "") == status) {
            return expenseClampAmount(expenseFloatCol(row, 2))
        }
    }
    return 0.0
}

/** 状态计数行集的总单数。 */
public func expenseCountTotal(rows: ArrayList<ArrayList<String>>): Int64 {
    var total: Int64 = 0
    for (row in rows) {
        total = total + expenseIntCol(row, 1)
    }
    return total
}

/** 状态计数行集的金额合计。 */
public func expenseAmountTotal(rows: ArrayList<ArrayList<String>>): Float64 {
    var total = 0.0
    for (row in rows) {
        total = total + expenseFloatCol(row, 2)
    }
    return expenseClampAmount(total)
}

/**
 * /expenses/my 的 summary：固定输出 5 个状态桶（缺项补 0）+ TOTAL，
 * 这样前端不用为「这个月没有草稿」写特判。
 */
public func expenseSummaryToJson(rows: ArrayList<ArrayList<String>>): String {
    let buckets = ArrayList<String>()
    let known = ArrayList<String>()
    known.add("DRAFT")
    known.add("SUBMITTED")
    known.add("APPROVED")
    known.add("REJECTED")
    known.add("PAID")
    for (s in known) {
        let cnt = expenseCountByStatus(rows, s)
        let amountStr = formatNum2(expenseAmountByStatus(rows, s))
        buckets.add("\"${s}\":{\"count\":${cnt},\"amount\":${jsonStr(amountStr)}}")
    }
    let totalCount = expenseCountTotal(rows)
    let totalAmount = formatNum2(expenseAmountTotal(rows))
    let pendingAmount = formatNum2(expenseAmountByStatus(rows, "SUBMITTED"))
    let approvedAmount = formatNum2(expenseAmountByStatus(rows, "APPROVED"))
    let joined = String.join(buckets.toArray(), delimiter: ",")
    return "{" +
        joined +
        ",\"TOTAL\":{\"count\":${totalCount},\"amount\":${jsonStr(totalAmount)}}" +
        ",\"pendingAmount\":${jsonStr(pendingAmount)}" +
        ",\"payableAmount\":${jsonStr(approvedAmount)}" +
        "}"
}

/** 结算行的未决警告：有 SUBMITTED 未决单据时给出提示串，但不阻断发放。空串 = 无需提示。 */
public func expenseSettlementWarning(payMonth: String, pendingCount: Int64, pendingAmount: Float64): String {
    if (pendingCount <= 0) { return "" }
    let amountStr = formatNum2(pendingAmount)
    return "${payMonth} 还有 ${pendingCount} 笔待审批（合计 ${amountStr} 元），本批次只发放已批准单据；如需一并处理请先催办审批"
}

/** 结算行（8 列，见 expenseSettlementSql 的列序）-> JSON。 */
public func expenseSettlementRowToJson(row: ArrayList<String>, payMonth: String): String {
    let employeeId = expenseIntCol(row, 0)
    let empNo = expenseCol(row, 1, "")
    let empName = expenseCol(row, 2, "")
    let deptName = expenseCol(row, 3, "")
    let payableCount = expenseIntCol(row, 4)
    let payable = expenseClampAmount(expenseFloatCol(row, 5))
    let pendingCount = expenseIntCol(row, 6)
    let pendingAmount = expenseClampAmount(expenseFloatCol(row, 7))
    let payableStr = formatNum2(payable)
    let pendingStr = formatNum2(pendingAmount)
    let warning = expenseSettlementWarning(payMonth, pendingCount, pendingAmount)
    return "{" +
        "\"employeeId\":${employeeId}," +
        "\"empNo\":${jsonStr(empNo)}," +
        "\"empName\":${jsonStr(empName)}," +
        "\"deptName\":${jsonStr(deptName)}," +
        "\"payMonth\":${jsonStr(payMonth)}," +
        "\"payableCount\":${payableCount}," +
        "\"payableAmount\":${jsonStr(payableStr)}," +
        "\"pendingCount\":${pendingCount}," +
        "\"pendingAmount\":${jsonStr(pendingStr)}," +
        "\"warning\":${expenseTextJson(warning)}" +
        "}"
}

/** 结算列表的金额合计（前端「本批应付总额」）。 */
public func expenseSettlementTotal(rows: ArrayList<ArrayList<String>>): Float64 {
    var total = 0.0
    for (row in rows) {
        total = total + expenseFloatCol(row, 5)
    }
    return expenseClampAmount(total)
}

// ======================== 通知（复用 notification 模块的 INSERT IGNORE + ref_id 幂等） ========================

/**
 * 提交后通知有权审批的人。
 * ref_id = "${expenseId}:SUBMITTED"：撤回再提交不会重复轰炸（与 P4.1 TRAINING_PUBLISHED 同策略）；
 * 收件人由 expenseApproverUserSql 按金额档位过滤，主管不会收到自己无权批的待办。
 */
public func notifyExpenseSubmitted(expenseId: Int64, empName: String, amount: Float64, deptId: Int64): Unit {
    if (expenseId <= 0) { return }
    let ids = notifUserIds(queryRows(expenseApproverUserSql(amount, deptId)))
    if (ids.size == 0) { return }
    let ref = "${expenseId}:SUBMITTED"
    let digest = truncateUtf8(empName, 40)
    let content = truncateUtf8("${digest} 提交了 ${formatNum2(amount)} 元报销单，请在 3 个工作日内处理。", 255)
    let parts = ArrayList<String>()
    for (uid in ids) {
        parts.add(notifInsertSql(uid, "EXPENSE_SUBMITTED", "报销单待审批", content, ref))
    }
    let script = notifJoinInserts(parts)
    if (script.isEmpty()) { return }
    executeSql(script)
}

/**
 * 审批结果 / 发放结果通知单据员工本人。
 * refIdSuffix 传状态名（APPROVED / REJECTED / PAID），保证「同一单据同一结论只发一次」，
 * 并发重复点击approve时 INSERT IGNORE 直接吞掉第二条。
 */
public func notifyExpenseResult(expenseId: Int64, employeeId: Int64, title: String, content: String, statusSuffix: String): Unit {
    if (expenseId <= 0 || employeeId <= 0) { return }
    let notifType = "EXPENSE_${statusSuffix}"
    if (!notifIsValidType(notifType)) { return }
    let userId = querySingleInt(expenseOwnerUserSql(employeeId), 0)
    if (userId <= 0) { return }
    executeSql(notifInsertSql(userId, notifType, truncateUtf8(title, 100), truncateUtf8(content, 255), "${expenseId}:${statusSuffix}"))
}

// ======================== 处理器复用的小工具（仍是纯文本 / 纯拼装） ========================

/** 布尔出成 JSON 字面量，前端 `v-if` 直接可用（与 notification 模块 readFlag 的写法同款）。 */
public func expenseBoolJson(b: Bool): String {
    return if (b) { "true" } else { "false" }
}

/** 单据行集 -> JSON 数组。空集合必须是 []，否则前端 .map 直接抛。 */
public func expenseBillRowsToJson(rows: ArrayList<ArrayList<String>>): String {
    let items = ArrayList<String>()
    for (r in rows) {
        items.add(expenseRowToJson(r))
    }
    return "[" + String.join(items.toArray(), delimiter: ",") + "]"
}

/** 当前月份（结算台账不传 payMonth 时的默认值）。日期口径只在 MySQL 侧判定，仓颉不自造解析。 */
public func expenseCurrentMonthSql(): String {
    return "SELECT DATE_FORMAT(CURDATE(), '%Y-%m')"
}

/** 某员工某月未决单据的合计金额（发放响应里的警告串用）。 */
public func expensePendingAmountSql(employeeId: Int64, payMonth: String): String {
    return "SELECT CAST(IFNULL(SUM(amount), 0) AS CHAR) FROM hr_expense WHERE employee_id = ${employeeId} AND pay_month = ${sqlStr(payMonth)} AND status = 'SUBMITTED'"
}

/**
 * 列表 / 统计共用的筛选 WHERE。每个片段都来自纯函数：非法值直接退化成空串（= 不加该条件），
 * 绝不把未校验的用户输入拼进 SQL；MANAGER 的部门限权在这里兜底，前端改 deptId 也绕不过去。
 */
public func expenseFilterWhere(ctx: HttpContext, role: String, deptId: Int64): String {
    let conds = ArrayList<String>()
    conds.add(expenseStatusCond(getQueryStr(ctx, "status", "").trimAscii()))
    conds.add(expenseCategoryCond(getQueryStr(ctx, "category", "").trimAscii()))
    conds.add(expenseMonthCond(getQueryStr(ctx, "payMonth", "").trimAscii()))
    conds.add(expenseKeywordCond(getQueryStr(ctx, "keyword", "")))
    conds.add(expenseDeptCond(getQueryInt(ctx, "deptId", 0)))
    conds.add(expenseManagerScopeCond(role, deptId))
    return expenseJoinConds(conds)
}

/**
 * 详情里的操作位（前端按钮显隐的唯一依据）。
 * 全部由闸门函数反着问一遍得出，不做任何「前端自己猜」的妥协：
 * 前端拿到的 canApprove=false 时，原因可以从对应的 denied 文案里读到。
 */
public func expenseActionFlagsJson(status: String, isOwner: Bool, role: String, sameDept: Bool, amount: Float64, selfSubmit: Bool): String {
    let canEdit = isOwner && expenseEditDenied(status).isEmpty()
    let canDelete = isOwner && expenseDeleteDenied(status).isEmpty()
    let canSubmit = isOwner && expenseActionDenied(status, "SUBMIT").isEmpty()
    let canWithdraw = isOwner && expenseActionDenied(status, "WITHDRAW").isEmpty()
    let canApprove = expenseActionDenied(status, "APPROVE").isEmpty() && expenseApproverDenied(role, sameDept, amount, selfSubmit).isEmpty()
    var canPay = false
    if (role == "ADMIN" || role == "HR") {
        canPay = expensePayDenied(status, "", "").isEmpty()
    }
    return "\"isOwner\":${expenseBoolJson(isOwner)}," +
        "\"canEdit\":${expenseBoolJson(canEdit)}," +
        "\"canDelete\":${expenseBoolJson(canDelete)}," +
        "\"canSubmit\":${expenseBoolJson(canSubmit)}," +
        "\"canWithdraw\":${expenseBoolJson(canWithdraw)}," +
        "\"canApprove\":${expenseBoolJson(canApprove)}," +
        "\"canPay\":${expenseBoolJson(canPay)}"
}

// ======================== HTTP 处理器 ========================

/**
 * GET /api/v1/expenses?status=&category=&payMonth=&keyword=&deptId=&page=&pageSize=
 * 管理视角列表（ADMIN / HR 全量，MANAGER 自动限本部门）。
 * 出参：sendPage 的 {list,total,page,pageSize}，list 行键名见文件头契约。
 */
public func handleExpenseList(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR", "MANAGER"])) {
        case None => return
        case Some(u) =>
            let whereSql = expenseFilterWhere(ctx, u.role, getUserDeptId(u))
            var page = getQueryInt(ctx, "page", 1)
            var pageSize = getQueryInt(ctx, "pageSize", 10)
            if (page < 1) { page = 1 }
            if (pageSize < 1 || pageSize > 100) { pageSize = 10 }
            let total = querySingleInt(expenseCountSql(whereSql), 0)
            let rows = queryRows(expenseListSql(whereSql, pageSize, (page - 1) * pageSize))
            sendPage(ctx, expenseBillRowsToJson(rows), total, page, pageSize)
    }
}

/**
 * POST /api/v1/expenses —— 登录用户新建报销单。
 * submitNow=true 直接进 SUBMITTED（创建即提交），否则落 DRAFT。
 *
 * 单据永远挂在当前账号的员工档案上，不接受 body 里的 employeeId：
 * 否则任何人都能给别人造一张单子，审批链形同虚设。
 * 出参：新建后的完整单据（与列表行同一套键名，时间戳由数据库生成后回读）。
 */
public func handleExpenseCreate(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            if (u.employeeId <= 0) {
                sendErr(ctx, 403, 403, "当前账号未关联员工档案，无法提交报销")
                return
            }
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let category = getJsonStr(obj, "category", "OTHER").trimAscii()
                    let title = getJsonStr(obj, "title", "").trimAscii()
                    let amount = expenseClampAmount(getJsonFloat(obj, "amount", 0.0))
                    let occurDate = getJsonStr(obj, "occurDate", "").trimAscii()
                    let monthRaw = getJsonStr(obj, "payMonth", "").trimAscii()
                    // 报销月份可以由发生日期反推：少一个「前端算错月份」的坑，
                    // 显式传了则必须与发生日期同月（expenseMonthDenied 负责拒绝）。
                    let payMonth = if (monthRaw.isEmpty()) { expenseMonthOfDate(occurDate) } else { monthRaw }
                    let travel = category == "TRAVEL"
                    let city = if (travel) { truncateUtf8(getJsonStr(obj, "city", "").trimAscii(), 64) } else { "" }
                    let days = if (travel) { expenseClampDays(getJsonInt(obj, "days", 0)) } else { 0 }
                    let receiptNo = getJsonStr(obj, "receiptNo", "").trimAscii()
                    let remark = truncateUtf8(getJsonStr(obj, "remark", "").trimAscii(), 255)
                    let submitNow = getJsonBool(obj, "submitNow", false)
                    let status = if (submitNow) { "SUBMITTED" } else { "DRAFT" }
                    let invalid = expenseFormDenied(category, title, amount, occurDate, payMonth, city, days, receiptNo)
                    if (!invalid.isEmpty()) {
                        sendErr(ctx, 400, 400, invalid)
                        return
                    }
                    // 形似 YYYY-MM-DD 但实际不存在的日期（2 月 30 日）交给 MySQL 复核
                    if (querySingleInt(expenseDateExistsSql(occurDate), -1) != 0) {
                        sendErr(ctx, 400, 400, "费用发生日期不存在，请核对：${occurDate}")
                        return
                    }
                    if (!receiptNo.isEmpty() && querySingleInt(expenseReceiptDupSql(u.employeeId, payMonth, receiptNo, 0), 0) > 0) {
                        sendErr(ctx, 400, 400, "${payMonth} 已有发票号 ${receiptNo}，同一员工同一月份不能重复报销同一张发票")
                        return
                    }
                    let newId = insertAndGetId(expenseInsertSql(u.employeeId, category, title, amount, occurDate, payMonth, city, days, receiptNo, status, u.userId, remark))
                    if (newId <= 0) {
                        sendErr(ctx, 500, 500, "创建报销单失败")
                        return
                    }
                    let after = queryRows(expenseOneSql(newId))
                    var empName = u.username
                    var billDeptId = getUserDeptId(u)
                    var billJson = "{\"id\":${newId},\"status\":${jsonStr(status)},\"statusLabel\":${jsonStr(expenseStatusLabel(status))}}"
                    if (after.size > 0) {
                        empName = expenseCol(after[0], 3, u.username)
                        billDeptId = expenseIntCol(after[0], 23)
                        billJson = expenseRowToJson(after[0])
                    }
                    if (status == "SUBMITTED") {
                        notifyExpenseSubmitted(newId, empName, amount, billDeptId)
                    }
                    writeAuditLog(u, "差旅与报销", "新建报销单", "新建报销单 #${newId}：${title} ${formatNum2(amount)} 元（${expenseStatusLabel(status)}）")
                    sendOk(ctx, billJson)
            }
    }
}

/**
 * PUT /api/v1/expenses/:id —— 本人修改，**局部更新**。
 *
 * ⚠️ 这是 P4.1 留下的已知坑（FOLLOWUP_PLAN 12.17 ④）的修法：
 * body 里没出现的字段一律沿用库里的原值——做法就是把当前值作为 getJsonXxx 的默认值传进去。
 * 因此只传 {remark} 或只传 {status} 绝不会报「报销事由不能为空」，
 * 表单校验（expenseFormDenied）也只在合成后的完整值上跑一次。
 * payMonth 是唯一例外：未显式传时按最终的 occurDate 反推，
 * 避免「改了发生日期没改月份」把月份一致性闸门绕过去。
 * 出参：修改后的完整单据。
 */
public func handleExpenseUpdate(ctx: HttpContext, expenseId: Int64): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            if (expenseId <= 0) {
                sendErr(ctx, 400, 400, "报销单ID不合法")
                return
            }
            let cur = queryRows(expenseOneSql(expenseId))
            if (cur.size == 0) {
                sendErr(ctx, 404, 404, "报销单不存在")
                return
            }
            let row = cur[0]
            if (expenseIntCol(row, 1) != u.employeeId) {
                sendErr(ctx, 403, 403, "只能修改本人的报销单")
                return
            }
            let curStatus = expenseCol(row, 13, "DRAFT")
            let oldTitle = expenseCol(row, 6, "")
            let locked = expenseEditDenied(curStatus)
            if (!locked.isEmpty()) {
                sendErr(ctx, 400, 400, locked)
                return
            }
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    // status 允许整单回传（值与原状态相同 = 没改），只拦住真正的越权改状态
                    let statusDenied = expenseStatusChangeDenied(curStatus, getJsonStr(obj, "status", curStatus).trimAscii())
                    if (!statusDenied.isEmpty()) {
                        sendErr(ctx, 400, 400, statusDenied)
                        return
                    }
                    let category = getJsonStr(obj, "category", expenseCol(row, 5, "OTHER")).trimAscii()
                    let title = getJsonStr(obj, "title", oldTitle).trimAscii()
                    let amount = expenseClampAmount(getJsonFloat(obj, "amount", expenseFloatCol(row, 7)))
                    let occurDate = getJsonStr(obj, "occurDate", expenseCol(row, 8, "")).trimAscii()
                    let monthRaw = getJsonStr(obj, "payMonth", "").trimAscii()
                    let payMonth = if (monthRaw.isEmpty()) { expenseMonthOfDate(occurDate) } else { monthRaw }
                    let travel = category == "TRAVEL"
                    let city = if (travel) { truncateUtf8(getJsonStr(obj, "city", expenseCol(row, 10, "")).trimAscii(), 64) } else { "" }
                    let days = if (travel) { expenseClampDays(getJsonInt(obj, "days", expenseIntCol(row, 11))) } else { 0 }
                    let receiptNo = getJsonStr(obj, "receiptNo", expenseCol(row, 12, "")).trimAscii()
                    let remark = truncateUtf8(getJsonStr(obj, "remark", expenseCol(row, 20, "")).trimAscii(), 255)
                    let invalid = expenseFormDenied(category, title, amount, occurDate, payMonth, city, days, receiptNo)
                    if (!invalid.isEmpty()) {
                        sendErr(ctx, 400, 400, invalid)
                        return
                    }
                    if (querySingleInt(expenseDateExistsSql(occurDate), -1) != 0) {
                        sendErr(ctx, 400, 400, "费用发生日期不存在，请核对：${occurDate}")
                        return
                    }
                    if (!receiptNo.isEmpty() && querySingleInt(expenseReceiptDupSql(u.employeeId, payMonth, receiptNo, expenseId), 0) > 0) {
                        sendErr(ctx, 400, 400, "${payMonth} 已有发票号 ${receiptNo}，同一员工同一月份不能重复报销同一张发票")
                        return
                    }
                    if (!executeSql(expenseUpdateSql(expenseId, category, title, amount, occurDate, payMonth, city, days, receiptNo, remark))) {
                        sendErr(ctx, 500, 500, "更新报销单失败")
                        return
                    }
                    let after = queryRows(expenseOneSql(expenseId))
                    var billJson = "{\"id\":${expenseId},\"status\":${jsonStr(curStatus)}}"
                    if (after.size > 0) {
                        billJson = expenseRowToJson(after[0])
                    }
                    writeAuditLog(u, "差旅与报销", "修改报销单", "修改报销单 #${expenseId}：${oldTitle} → ${title} ${formatNum2(amount)} 元")
                    sendOk(ctx, billJson)
            }
    }
}

/** DELETE /api/v1/expenses/:id —— 本人删除，仅草稿。 */
public func handleExpenseDelete(ctx: HttpContext, expenseId: Int64): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            if (expenseId <= 0) {
                sendErr(ctx, 400, 400, "报销单ID不合法")
                return
            }
            let cur = queryRows(expenseOneSql(expenseId))
            if (cur.size == 0) {
                sendErr(ctx, 404, 404, "报销单不存在")
                return
            }
            let row = cur[0]
            if (expenseIntCol(row, 1) != u.employeeId) {
                sendErr(ctx, 403, 403, "只能删除本人的报销单")
                return
            }
            let curStatus = expenseCol(row, 13, "DRAFT")
            let billTitle = expenseCol(row, 6, "")
            let denied = expenseDeleteDenied(curStatus)
            if (!denied.isEmpty()) {
                sendErr(ctx, 400, 400, denied)
                return
            }
            if (!executeSql(expenseDeleteSql(expenseId, u.employeeId))) {
                sendErr(ctx, 500, 500, "删除报销单失败")
                return
            }
            // 删除条件里带了 status='DRAFT'，回读仍有行说明中途被人改过状态（乐观冲突）
            if (queryRows(expenseOneSql(expenseId)).size > 0) {
                sendErr(ctx, 400, 400, "该报销单已被审批流程处理，请刷新后重试")
                return
            }
            writeAuditLog(u, "差旅与报销", "删除报销单", "删除报销单 #${expenseId}：${billTitle}（草稿）")
            sendOkMsg(ctx, "报销单已删除", "{\"id\":${expenseId}}")
    }
}

/**
 * GET /api/v1/expenses/my?status=&payMonth= —— 本人单据 + 各状态计数 + 合计。
 *
 * list 受筛选影响；summary / total 永远是该员工的全量口径（角标不因筛选跳数）。
 * 个人流水取最近 200 条，再往前的历史走管理端列表；不启分页是因为「我的报销」
 * 页面本身是滚动列表，分页反而让合计失去意义。
 */
public func handleExpenseMy(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            if (u.employeeId <= 0) {
                sendErr(ctx, 403, 403, "当前账号未关联员工档案，无法查看报销单")
                return
            }
            let conds = ArrayList<String>()
            conds.add(expenseOwnerCond(u.employeeId))
            conds.add(expenseStatusCond(getQueryStr(ctx, "status", "").trimAscii()))
            conds.add(expenseCategoryCond(getQueryStr(ctx, "category", "").trimAscii()))
            conds.add(expenseMonthCond(getQueryStr(ctx, "payMonth", "").trimAscii()))
            conds.add(expenseKeywordCond(getQueryStr(ctx, "keyword", "")))
            let whereSql = expenseJoinConds(conds)
            let rows = queryRows(expenseListSql(whereSql, 200, 0))
            let countRows = queryRows(expenseCountsSql(u.employeeId))
            let totalCount = expenseCountTotal(countRows)
            let data = "{\"list\":${expenseBillRowsToJson(rows)},\"total\":${totalCount},\"summary\":${expenseSummaryToJson(countRows)}}"
            sendOk(ctx, data)
    }
}

/**
 * GET /api/v1/expenses/pending —— 「待我审批」。
 *
 * 筛选口径 = expensePendingCond：状态 SUBMITTED + 按角色档位过滤金额
 * （MANAGER 只看本部门 ≤5000 的单据）。也就是说这条列表里出现的每一单，
 * 当前账号都**真的有权限**点通过/驳回；不做「看得见但按不动」的 UI 陷阱。
 * 出参形状与 sendPage 一致（list/total/page/pageSize），额外补两个字段：
 * pendingAmount（当前筛选下的待批合计）与 managerCap（主管额度上限，供前端提示）。
 */
public func handleExpensePending(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR", "MANAGER"])) {
        case None => return
        case Some(u) =>
            let conds = ArrayList<String>()
            conds.add(expensePendingCond(u.role, getUserDeptId(u)))
            conds.add(expenseCategoryCond(getQueryStr(ctx, "category", "").trimAscii()))
            conds.add(expenseMonthCond(getQueryStr(ctx, "payMonth", "").trimAscii()))
            conds.add(expenseKeywordCond(getQueryStr(ctx, "keyword", "")))
            // 主管额外指定部门只会把结果并成空集（AND），不能扩大他的审批范围
            conds.add(expenseDeptCond(getQueryInt(ctx, "deptId", 0)))
            let whereSql = expenseJoinConds(conds)
            var page = getQueryInt(ctx, "page", 1)
            var pageSize = getQueryInt(ctx, "pageSize", 10)
            if (page < 1) { page = 1 }
            if (pageSize < 1 || pageSize > 100) { pageSize = 10 }
            let total = querySingleInt(expenseCountSql(whereSql), 0)
            let rows = queryRows(expenseListSql(whereSql, pageSize, (page - 1) * pageSize))
            let statRows = queryRows(expenseStatStatusSql(whereSql))
            let pendingAmount = formatNum2(expenseClampAmount(expenseAmountByStatus(statRows, "SUBMITTED")))
            let capText = formatNum2(EXPENSE_MANAGER_MAX_AMOUNT)
            let data = "{\"list\":${expenseBillRowsToJson(rows)},\"total\":${total},\"page\":${page},\"pageSize\":${pageSize}," +
                "\"pendingAmount\":${jsonStr(pendingAmount)},\"managerCap\":${jsonStr(capText)}}"
            sendOk(ctx, data)
    }
}

/**
 * GET /api/v1/expenses/stats —— 按类别 / 按月份 / 按部门 TOP / 按状态汇总。
 * 四个口径共用同一份 WHERE（含 MANAGER 部门限权），所以数字之间可以互相核对。
 */
public func handleExpenseStats(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR", "MANAGER"])) {
        case None => return
        case Some(u) =>
            let whereSql = expenseFilterWhere(ctx, u.role, getUserDeptId(u))
            let statusRows = queryRows(expenseStatStatusSql(whereSql))
            let totalCount = expenseCountTotal(statusRows)
            let totalAmount = formatNum2(expenseClampAmount(expenseAmountTotal(statusRows)))
            let pendingCount = expenseCountByStatus(statusRows, "SUBMITTED")
            let pendingAmount = formatNum2(expenseClampAmount(expenseAmountByStatus(statusRows, "SUBMITTED")))
            let payableCount = expenseCountByStatus(statusRows, "APPROVED")
            let payableAmount = formatNum2(expenseClampAmount(expenseAmountByStatus(statusRows, "APPROVED")))
            let paidCount = expenseCountByStatus(statusRows, "PAID")
            let paidAmount = formatNum2(expenseClampAmount(expenseAmountByStatus(statusRows, "PAID")))
            let categoryJson = expenseGroupRowsToJson(queryRows(expenseStatCategorySql(whereSql)), "category")
            let monthJson = expenseGroupRowsToJson(queryRows(expenseStatMonthSql(whereSql)), "month")
            let deptJson = expenseGroupRowsToJson(queryRows(expenseStatDeptSql(whereSql)), "dept")
            let statusJson = expenseGroupRowsToJson(statusRows, "status")
            let overview = "{\"totalCount\":${totalCount},\"totalAmount\":${jsonStr(totalAmount)}," +
                "\"pendingCount\":${pendingCount},\"pendingAmount\":${jsonStr(pendingAmount)}," +
                "\"payableCount\":${payableCount},\"payableAmount\":${jsonStr(payableAmount)}," +
                "\"paidCount\":${paidCount},\"paidAmount\":${jsonStr(paidAmount)}}"
            let data = "{\"overview\":${overview},\"byCategory\":${categoryJson},\"byMonth\":${monthJson},\"byDept\":${deptJson},\"byStatus\":${statusJson}}"
            sendOk(ctx, data)
    }
}

// ============================================================================
// 结算台账 / 独立发放通道
//
// ⚠️ 硬约束：报销金额一律不得写入 hr_payroll。理由（不是洁癖，是真的会算错钱）：
//   1. hr_payroll.bonus 会进入 calculateTax 的应税所得基数。实报实销的报销款是
//      「员工垫付、公司原额归还」，不是所得；并进 bonus 会凭空抬高个税，
//      员工到手金额与报销单金额对不上，还会让人以为报销要交税。
//   2. 本项目的薪资金额一致性用例（应发 = 基本 + 绩效 + 奖金，实发 = 应发 - 社保 - 个税）
//      依赖 bonus 只来自绩效模块。把报销塞进去会动摇这批既有用例的断言。
//   3. 报销有自己完整的状态机与凭证（发票号、审批人、paid_at/paid_by），
//      写进薪资行就丢掉了这张单的审计轨迹，事后无法复核是谁批的、按的哪张发票。
// 因此本 handler **只读 hr_expense**，发放也只走 POST /api/v1/expenses/:id/pay
// 记 paid_at / paid_by，与薪资发放是两条互不写对方表的通道。
// ============================================================================

/**
 * GET /api/v1/expenses/settlement?payMonth=YYYY-MM —— 按员工聚合「已通过待发放」台账。
 *
 * 口径：只统计 status='APPROVED' 的单据；同月该员工的 SUBMITTED 未决单据不进合计，
 * 但会以 pendingCount / pendingAmount / warning 的形式一并返回，由 HR 自己决定
 * 是先补审还是先发放（不阻断发放，这是流程事实：审核和发放本来就是两个人、两个时点）。
 * payMonth 省略时取当前月份（由 MySQL 的 DATE_FORMAT 给出，仓颉不自造日期解析）。
 */
public func handleExpenseSettlement(ctx: HttpContext): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(_) =>
            let rawMonth = getQueryStr(ctx, "payMonth", "").trimAscii()
            var payMonth = rawMonth
            if (payMonth.isEmpty()) {
                payMonth = querySingleValue(expenseCurrentMonthSql()).trimAscii()
            }
            if (!expenseMonthOk(payMonth)) {
                sendErr(ctx, 400, 400, "报销月份格式必须为 YYYY-MM，收到：${rawMonth}")
                return
            }
            let rows = queryRows(expenseSettlementSql(payMonth))
            let items = ArrayList<String>()
            var pendingTotalCount: Int64 = 0
            var pendingTotalAmount = 0.0
            for (r in rows) {
                items.add(expenseSettlementRowToJson(r, payMonth))
                pendingTotalCount = pendingTotalCount + expenseIntCol(r, 6)
                pendingTotalAmount = pendingTotalAmount + expenseFloatCol(r, 7)
            }
            let payableAmount = formatNum2(expenseSettlementTotal(rows))
            let pendingAmount = formatNum2(expenseClampAmount(pendingTotalAmount))
            let warning = expenseSettlementWarning(payMonth, pendingTotalCount, expenseClampAmount(pendingTotalAmount))
            let data = "{\"payMonth\":${jsonStr(payMonth)},\"employeeCount\":${rows.size},\"list\":[" + String.join(items.toArray(), delimiter: ",") + "]" +
                ",\"payableAmount\":${jsonStr(payableAmount)},\"pendingCount\":${pendingTotalCount}" +
                ",\"pendingAmount\":${jsonStr(pendingAmount)},\"warning\":${expenseTextJson(warning)}}"
            sendOk(ctx, data)
    }
}

/**
 * GET /api/v1/expenses/:id —— 单据详情 + 审批轨迹 + 当前账号的操作位。
 * 可见范围：本人 / ADMIN / HR 全量，MANAGER 限本部门（大额单他能看见，
 * 但 canApprove 会被档位闸门拒——看得见不等于批得动，档位是审批时再判一次）。
 */
public func handleExpenseDetail(ctx: HttpContext, expenseId: Int64): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            if (expenseId <= 0) {
                sendErr(ctx, 400, 400, "报销单ID不合法")
                return
            }
            let cur = queryRows(expenseOneSql(expenseId))
            if (cur.size == 0) {
                sendErr(ctx, 404, 404, "报销单不存在")
                return
            }
            let row = cur[0]
            let isOwner = expenseIntCol(row, 1) == u.employeeId
            let billDeptId = expenseIntCol(row, 23)
            let approverDeptId = getUserDeptId(u)
            let sameDept = (approverDeptId > 0) && (approverDeptId == billDeptId)
            var visible = isOwner
            if (u.role == "ADMIN" || u.role == "HR") {
                visible = true
            }
            if (!visible && u.role == "MANAGER" && sameDept) {
                visible = true
            }
            if (!visible) {
                sendErr(ctx, 403, 403, "无权查看该报销单")
                return
            }
            let curStatus = expenseCol(row, 13, "DRAFT")
            let amount = expenseClampAmount(expenseFloatCol(row, 7))
            let submitUserId = expenseIntCol(row, 22)
            let selfSubmit = (submitUserId > 0) && (submitUserId == u.userId)
            let flags = expenseActionFlagsJson(curStatus, isOwner, u.role, sameDept, amount, selfSubmit)
            let expenseJson = expenseRowToJson(row)
            let timelineJson = expenseTimelineJson(row)
            let data = "{\"expense\":${expenseJson},\"timeline\":${timelineJson},${flags}}"
            sendOk(ctx, data)
    }
}

/**
 * POST /api/v1/expenses/:id/submit —— 提交 / 驳回后重报（本人）。
 *
 * 提交是审批的入口，所以这里把整张单据重新校验一遍（草稿允许只填一半，
 * 提交时不允许）：类别限额、差旅完整性、月份一致性、日期真实存在、票号不重复。
 * UPDATE 带 `WHERE status IN ('DRAFT','REJECTED')`，写完回读确认，
 * 拿不到 SUBMITTED 就是被人抢先处理了（mysql_pool 不暴露 affected rows）。
 */
public func handleExpenseSubmit(ctx: HttpContext, expenseId: Int64): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            if (expenseId <= 0) {
                sendErr(ctx, 400, 400, "报销单ID不合法")
                return
            }
            let cur = queryRows(expenseOneSql(expenseId))
            if (cur.size == 0) {
                sendErr(ctx, 404, 404, "报销单不存在")
                return
            }
            let row = cur[0]
            let employeeId = expenseIntCol(row, 1)
            if (employeeId != u.employeeId) {
                sendErr(ctx, 403, 403, "只能提交本人的报销单")
                return
            }
            let curStatus = expenseCol(row, 13, "DRAFT")
            let denied = expenseActionDenied(curStatus, "SUBMIT")
            if (!denied.isEmpty()) {
                sendErr(ctx, 400, 400, denied)
                return
            }
            let category = expenseCol(row, 5, "OTHER")
            let billTitle = expenseCol(row, 6, "")
            let amount = expenseClampAmount(expenseFloatCol(row, 7))
            let occurDate = expenseCol(row, 8, "")
            let payMonth = expenseCol(row, 9, "")
            let city = expenseCol(row, 10, "")
            let days = expenseIntCol(row, 11)
            let receiptNo = expenseCol(row, 12, "")
            let invalid = expenseFormDenied(category, billTitle, amount, occurDate, payMonth, city, days, receiptNo)
            if (!invalid.isEmpty()) {
                sendErr(ctx, 400, 400, "报销单内容不完整，无法提交：${invalid}")
                return
            }
            if (querySingleInt(expenseDateExistsSql(occurDate), -1) != 0) {
                sendErr(ctx, 400, 400, "费用发生日期不存在，请核对：${occurDate}")
                return
            }
            if (!receiptNo.isEmpty() && querySingleInt(expenseReceiptDupSql(employeeId, payMonth, receiptNo, expenseId), 0) > 0) {
                sendErr(ctx, 400, 400, "${payMonth} 已有发票号 ${receiptNo}，同一员工同一月份不能重复报销同一张发票")
                return
            }
            if (!executeSql(expenseSubmitSql(expenseId, curStatus, u.userId))) {
                sendErr(ctx, 500, 500, "提交报销单失败")
                return
            }
            let after = queryRows(expenseOneSql(expenseId))
            if (after.size == 0) {
                sendErr(ctx, 500, 500, "提交后回读报销单失败")
                return
            }
            let nowStatus = expenseCol(after[0], 13, "")
            if (nowStatus != "SUBMITTED") {
                sendErr(ctx, 400, 400, "该单据已被他人处理（当前「${expenseStatusLabel(nowStatus)}」），请刷新后重试")
                return
            }
            notifyExpenseSubmitted(expenseId, expenseCol(after[0], 3, u.username), amount, expenseIntCol(after[0], 23))
            writeAuditLog(u, "差旅与报销", "提交报销单", "提交报销单 #${expenseId}：${billTitle} ${formatNum2(amount)} 元（${expenseStatusLabel(curStatus)} → 已提交）")
            sendOk(ctx, expenseRowToJson(after[0]))
    }
}

/** POST /api/v1/expenses/:id/withdraw —— 本人撤回：SUBMITTED → DRAFT。 */
public func handleExpenseWithdraw(ctx: HttpContext, expenseId: Int64): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            if (expenseId <= 0) {
                sendErr(ctx, 400, 400, "报销单ID不合法")
                return
            }
            let cur = queryRows(expenseOneSql(expenseId))
            if (cur.size == 0) {
                sendErr(ctx, 404, 404, "报销单不存在")
                return
            }
            let row = cur[0]
            if (expenseIntCol(row, 1) != u.employeeId) {
                sendErr(ctx, 403, 403, "只能撤回本人的报销单")
                return
            }
            let curStatus = expenseCol(row, 13, "DRAFT")
            let denied = expenseActionDenied(curStatus, "WITHDRAW")
            if (!denied.isEmpty()) {
                sendErr(ctx, 400, 400, denied)
                return
            }
            let billTitle = expenseCol(row, 6, "")
            // 撤回条件里同时锁了 employee_id 与 status，别人在这窗口审批过就会走到下面的冲突分支
            if (!executeSql(expenseWithdrawSql(expenseId, u.employeeId))) {
                sendErr(ctx, 500, 500, "撤回报销单失败")
                return
            }
            let after = queryRows(expenseOneSql(expenseId))
            if (after.size == 0) {
                sendErr(ctx, 500, 500, "撤回后回读报销单失败")
                return
            }
            let nowStatus = expenseCol(after[0], 13, "")
            if (nowStatus != "DRAFT") {
                sendErr(ctx, 400, 400, "该单据已被他人处理（当前「${expenseStatusLabel(nowStatus)}」），请刷新后重试")
                return
            }
            writeAuditLog(u, "差旅与报销", "撤回报销单", "撤回报销单 #${expenseId}：${billTitle}（已提交 → 草稿）")
            sendOk(ctx, expenseRowToJson(after[0]))
    }
}

/**
 * POST /api/v1/expenses/:id/approve —— 审批（body：action=APPROVE|REJECT、approveRemark）。
 *
 * 三段闸门（全部来自 expenseApproverDenied，可单测）：
 *   1. 部门范围：MANAGER 只能审本部门员工的单据；ADMIN / HR 不限部门。
 *   2. 金额档位：>${EXPENSE_MANAGER_MAX_AMOUNT} 必须由 ADMIN / HR 审批，主管只能批小额。
 *   3. 自审：提交人就是当前账号时一律拒绝（用 submit_user_id 比对，不是「大概是自己」）。
 * 通过后写 approved_at / approver_user_id，并给单据员工发 EXPENSE_APPROVED / EXPENSE_REJECTED。
 */
public func handleExpenseApprove(ctx: HttpContext, expenseId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR", "MANAGER"])) {
        case None => return
        case Some(u) =>
            if (expenseId <= 0) {
                sendErr(ctx, 400, 400, "报销单ID不合法")
                return
            }
            let cur = queryRows(expenseOneSql(expenseId))
            if (cur.size == 0) {
                sendErr(ctx, 404, 404, "报销单不存在")
                return
            }
            let row = cur[0]
            let curStatus = expenseCol(row, 13, "DRAFT")
            match (parseJsonObject(readRequestBody(ctx))) {
                case None =>
                    sendErr(ctx, 400, 400, "请求体 JSON 格式错误")
                    return
                case Some(obj) =>
                    let action = getJsonStr(obj, "action", "APPROVE").trimAscii()
                    if (action != "APPROVE" && action != "REJECT") {
                        sendErr(ctx, 400, 400, "审批动作只支持 APPROVE / REJECT，收到：${action}")
                        return
                    }
                    let denied = expenseActionDenied(curStatus, action)
                    if (!denied.isEmpty()) {
                        sendErr(ctx, 400, 400, denied)
                        return
                    }
                    let employeeId = expenseIntCol(row, 1)
                    let billTitle = expenseCol(row, 6, "")
                    let amount = expenseClampAmount(expenseFloatCol(row, 7))
                    let billDeptId = expenseIntCol(row, 23)
                    let approverDeptId = getUserDeptId(u)
                    let sameDept = (approverDeptId > 0) && (approverDeptId == billDeptId)
                    let submitUserId = expenseIntCol(row, 22)
                    let selfSubmit = (submitUserId > 0) && (submitUserId == u.userId)
                    let gate = expenseApproverDenied(u.role, sameDept, amount, selfSubmit)
                    if (!gate.isEmpty()) {
                        sendErr(ctx, 403, 403, gate)
                        return
                    }
                    let approveRemark = truncateUtf8(getJsonStr(obj, "approveRemark", "").trimAscii(), 255)
                    let nextStatus = expenseNextStatus(curStatus, action)
                    if (!executeSql(expenseApproveSql(expenseId, nextStatus, u.userId, approveRemark))) {
                        sendErr(ctx, 500, 500, "审批写入失败")
                        return
                    }
                    let after = queryRows(expenseOneSql(expenseId))
                    if (after.size == 0) {
                        sendErr(ctx, 500, 500, "审批后回读报销单失败")
                        return
                    }
                    let nowStatus = expenseCol(after[0], 13, "")
                    if (nowStatus != nextStatus) {
                        sendErr(ctx, 400, 400, "该单据已被他人处理（当前「${expenseStatusLabel(nowStatus)}」），请刷新后重试")
                        return
                    }
                    let digest = truncateUtf8(billTitle, 40)
                    let amountText = formatNum2(amount)
                    if (nextStatus == "APPROVED") {
                        notifyExpenseResult(expenseId, employeeId, "报销单已通过", "你的 ${amountText} 元报销单「${digest}」已通过审批，等待 HR 发放报销款。", "APPROVED")
                    }
                    if (nextStatus == "REJECTED") {
                        let reasonText = if (approveRemark.isEmpty()) { "未填写原因，请与审批人确认" } else { approveRemark }
                        notifyExpenseResult(expenseId, employeeId, "报销单已驳回", "你的 ${amountText} 元报销单「${digest}」未通过审批：${reasonText}。修改后可重新提交。", "REJECTED")
                    }
                    let actionLabel = if (nextStatus == "APPROVED") { "审批通过报销单" } else { "驳回报销单" }
                    let remarkPart = if (approveRemark.isEmpty()) { "" } else { "，意见：${approveRemark}" }
                    writeAuditLog(u, "差旅与报销", actionLabel, "${actionLabel} #${expenseId}：${billTitle} ${amountText} 元${remarkPart}")
                    sendOk(ctx, expenseRowToJson(after[0]))
            }
    }
}

/**
 * POST /api/v1/expenses/:id/pay —— 发放报销款（ADMIN / HR）。
 *
 * 只写 paid_at / paid_by，**绝不写 hr_payroll**（理由见结算台账一段的注释）。
 * 可选 ?payMonth=YYYY-MM 让 HR 在整批发放时核对批次月份；同一员工同一月份若还有
 * SUBMITTED 未决单据，只在响应的 warning 里提示，不阻断发放（审核与发放本就是两个时点）。
 */
public func handleExpensePay(ctx: HttpContext, expenseId: Int64): Unit {
    match (requireRoles(ctx, ["ADMIN", "HR"])) {
        case None => return
        case Some(u) =>
            if (expenseId <= 0) {
                sendErr(ctx, 400, 400, "报销单ID不合法")
                return
            }
            let cur = queryRows(expenseOneSql(expenseId))
            if (cur.size == 0) {
                sendErr(ctx, 404, 404, "报销单不存在")
                return
            }
            let row = cur[0]
            let curStatus = expenseCol(row, 13, "DRAFT")
            let billMonth = expenseCol(row, 9, "")
            let batchMonth = getQueryStr(ctx, "payMonth", "").trimAscii()
            let denied = expensePayDenied(curStatus, billMonth, batchMonth)
            if (!denied.isEmpty()) {
                sendErr(ctx, 400, 400, denied)
                return
            }
            let employeeId = expenseIntCol(row, 1)
            let billTitle = expenseCol(row, 6, "")
            let amount = expenseClampAmount(expenseFloatCol(row, 7))
            if (!executeSql(expensePaySql(expenseId, u.userId))) {
                sendErr(ctx, 500, 500, "发放报销款失败")
                return
            }
            let after = queryRows(expenseOneSql(expenseId))
            if (after.size == 0) {
                sendErr(ctx, 500, 500, "发放后回读报销单失败")
                return
            }
            let nowStatus = expenseCol(after[0], 13, "")
            if (nowStatus != "PAID") {
                sendErr(ctx, 400, 400, "该单据已被他人处理（当前「${expenseStatusLabel(nowStatus)}」），请刷新后重试")
                return
            }
            let paidAt = expenseCol(after[0], 17, "")
            let digest = truncateUtf8(billTitle, 40)
            let amountText = formatNum2(amount)
            notifyExpenseResult(expenseId, employeeId, "报销款已发放", "你的 ${amountText} 元报销单「${digest}」已于 ${paidAt} 发放，请核对到账金额。", "PAID")
            let pendingCount = querySingleInt(expensePendingCountSql(employeeId, billMonth), 0)
            let pendingRaw = querySingleValue(expensePendingAmountSql(employeeId, billMonth))
            let pendingAmount = expenseClampAmount(Float64.tryParse(pendingRaw) ?? 0.0)
            let warning = expenseSettlementWarning(billMonth, pendingCount, pendingAmount)
            writeAuditLog(u, "差旅与报销", "发放报销款", "发放报销款 #${expenseId}：${billTitle} ${amountText} 元（${billMonth}）")
            let expenseJson = expenseRowToJson(after[0])
            let data = "{\"expense\":${expenseJson},\"payMonth\":${jsonStr(billMonth)},\"warning\":${expenseTextJson(warning)}}"
            sendOk(ctx, data)
    }
}


