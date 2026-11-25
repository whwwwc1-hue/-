package hrms_backend.controller

import std.collection.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*

// P3.2 站内通知中心纯函数单元测试。
//
// 覆盖 notification_controller.cj 中与数据库无关的 28 个函数：
//   白名单/文案：notifIsValidType notifTypeLabel notifCategoryLabel notifDurationText
//   查询参数防线：notifReadCond notifClampLimit
//   SQL 生成：notifUnreadSql notifListSql notifReadSql notifReadCountSql notifIsReadSql
//             notifReadAllSql notifExistsSql notifInsertSql notifUserByEmpSql
//             notifManagerUserSql notifHrUserSql notifSeenRefsSql notifSeenStrRefsSql notifUserMapSql
//   集合拼接：notifNumList notifStrList notifJoinInserts notifUserIds notifSeen notifMapUser
//   响应 JSON：notifRowToJson notifRowsToJsonArray
//
// 为什么整串 pin 而不是查子串：本模块 3 个触发点（审批终态 / 批量发薪 / 合同到期）
// 全部在 SQL 字符串上「拼装即执行」，本机没有仓颉 SDK（L-CJ-1），
// 一旦拼错列名/漏掉 user_id/忘了 IGNORE，问题只会在真实库里以「通知静默丢失」暴露。
// 整串 pin 是唯一能把这类漂移钉死的手段（String.contains 还容易把
// `IN (1)` 误判成命中 `IN (12,13)`，基线里已吃过这类教训）。
//
// 纪律（与 request/attendance/payroll 测试一致）：本文件不使用
//   - 数组字面量（[..]）——一律 ArrayList<String>() + add()
//   - String.contains——结构断言全部整串 pin
//   - 元组下标
// 期望值来源：TEMP/notif_expect.mjs 独立镜像复算，
// 且镜像里的两段三引号模板已与本模块源文件做过字节级核对（含 DATE_FORMAT 前的 7 个空格）。
// 不碰库的函数才会出现在这里：pushNotification / notifResolveUser / 3 个 notify* 触发点 /
// 4 个 handleNotification* 一律不测——它们依赖 mysql.exe，属于 L-NOTIF-1 的验证范围。

// ============================ 测试辅助函数 ============================

// 构造一条 7 列的通知行（顺序与 notifListSql 的 SELECT 严格一致）。
func notpRow(id: String, type: String, title: String, content: String, refId: String, readFlag: String, createdAt: String): ArrayList<String> {
    let r = ArrayList<String>()
    r.add(id)
    r.add(type)
    r.add(title)
    r.add(content)
    r.add(refId)
    r.add(readFlag)
    r.add(createdAt)
    return r
}

// 只有一列的行，用于验证「列数不足必须被丢弃」。
func notpShortRow(id: String): ArrayList<String> {
    let r = ArrayList<String>()
    r.add(id)
    return r
}

func notpIdList(values: ArrayList<Int64>): ArrayList<Int64> {
    return values
}

// [id, employee_id] 两列映射行集（与 notifUserMapSql 的 SELECT 一致）。
func notpUserRow(userId: String, empId: String): ArrayList<String> {
    let r = ArrayList<String>()
    r.add(userId)
    r.add(empId)
    return r
}

func notpUserRows(): ArrayList<ArrayList<String>> {
    let rows = ArrayList<ArrayList<String>>()
    rows.add(notpUserRow("7", "5"))
    rows.add(notpUserRow("8", "6"))
    return rows
}

// ============================ 类型白名单 ============================

@test class NotifValidTypeTest {
    @TestCase
    func testAllFiveWhitelistedTypesAreAccepted(): Unit {
        // 这 5 个值与前端铃铛的跳转映射一一对应，少一个就有人点不开通知
        @Assert(actual: notifIsValidType("CONTRACT_EXPIRING"), expected: true)
        @Assert(actual: notifIsValidType("LEAVE_APPROVED"), expected: true)
        @Assert(actual: notifIsValidType("LEAVE_REJECTED"), expected: true)
        @Assert(actual: notifIsValidType("LEAVE_NEXT_LEVEL"), expected: true)
        @Assert(actual: notifIsValidType("PAYROLL_PAID"), expected: true)
    }

    @TestCase
    func testEverythingElseIsRejected(): Unit {
        // 小写：MySQL 列是 utf8mb4_unicode_ci，大小写不敏感，但前端映射敏感 => 必须拒
        @Assert(actual: notifIsValidType("payroll_paid"), expected: false)
        @Assert(actual: notifIsValidType(""), expected: false)
        @Assert(actual: notifIsValidType("PAYROLL_PAID "), expected: false)
        @Assert(actual: notifIsValidType("PAYROLL_PAID;DROP TABLE sys_notification"), expected: false)
        @Assert(actual: notifIsValidType("SYSTEM"), expected: false)
    }
}

// ============================ 类型 -> 中文标签 ============================

@test class NotifTypeLabelTest {
    @TestCase
    func testFiveKnownTypesHaveDistinctChineseLabels(): Unit {
        @Assert(actual: notifTypeLabel("CONTRACT_EXPIRING"), expected: "合同到期提醒")
        @Assert(actual: notifTypeLabel("LEAVE_APPROVED"), expected: "审批已通过")
        @Assert(actual: notifTypeLabel("LEAVE_REJECTED"), expected: "审批已驳回")
        @Assert(actual: notifTypeLabel("LEAVE_NEXT_LEVEL"), expected: "待你复核")
        @Assert(actual: notifTypeLabel("PAYROLL_PAID"), expected: "工资条已发放")
    }

    @TestCase
    func testUnknownTypeFallsBackToSystemNotice(): Unit {
        // 回落值绝不能是空串：抽屉里会渲染出一个没有标题分类的空行
        @Assert(actual: notifTypeLabel("UNKNOWN"), expected: "系统通知")
        @Assert(actual: notifTypeLabel(""), expected: "系统通知")
        @Assert(actual: notifTypeLabel("leave_approved"), expected: "系统通知")
    }
}

// ============================ readFlag 注入面（本模块唯一） ============================

@test class NotifReadCondTest {
    @TestCase
    func testOnlyZeroAndOneProduceCondition(): Unit {
        @Assert(actual: notifReadCond("0"), expected: "AND read_flag = 0")
        @Assert(actual: notifReadCond("1"), expected: "AND read_flag = 1")
    }

    @TestCase
    func testAnyOtherInputFallsBackToEmptyString(): Unit {
        @Assert(actual: notifReadCond(""), expected: "")
        @Assert(actual: notifReadCond("2"), expected: "")
        @Assert(actual: notifReadCond("-1"), expected: "")
        @Assert(actual: notifReadCond("1 OR 1=1"), expected: "")
        @Assert(actual: notifReadCond("0;DROP TABLE sys_notification"), expected: "")
        // 带空格的 " 0 " 也必须回落：宁可查全部，不可拼注入
        @Assert(actual: notifReadCond(" 0 "), expected: "")
    }
}

@test class NotifClampLimitTest {
    @TestCase
    func testNormalRangePassesThrough(): Unit {
        @Assert(actual: notifClampLimit(1), expected: 1)
        @Assert(actual: notifClampLimit(20), expected: 20)
        @Assert(actual: notifClampLimit(50), expected: 50)
    }

    @TestCase
    func testOver50IsClampedAndNonPositiveUsesDefault(): Unit {
        // 上限 50：抽屉滚动加载，不该一次拖全表
        @Assert(actual: notifClampLimit(51), expected: 50)
        @Assert(actual: notifClampLimit(9999), expected: 50)
        // <=0 一律回默认 20，绝不能拼出 LIMIT 0（铃铛会显示「暂无通知」）
        @Assert(actual: notifClampLimit(0), expected: 20)
        @Assert(actual: notifClampLimit(-1), expected: 20)
        @Assert(actual: notifClampLimit(-7), expected: 20)
    }
}

// ============================ 读取侧 SQL ============================

@test class NotifUnreadSqlTest {
    @TestCase
    func testUnreadCountIsSingleColumnAndScopedToUser(): Unit {
        @Assert(actual: notifUnreadSql(7), expected: "SELECT COUNT(*) FROM sys_notification WHERE user_id = 7 AND read_flag = 0")
        @Assert(actual: notifUnreadSql(990001), expected: "SELECT COUNT(*) FROM sys_notification WHERE user_id = 990001 AND read_flag = 0")
    }
}

@test class NotifListSqlTest {
    @TestCase
    func testUnreadOnlyPinsWholeSql(): Unit {
        @Assert(actual: notifListSql(7, "0", 20), expected: "SELECT id, type, title, IFNULL(content, ''), IFNULL(ref_id, ''), read_flag,\n       DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s')\nFROM sys_notification\nWHERE user_id = 7 AND read_flag = 0\nORDER BY created_at DESC, id DESC\nLIMIT 20")
    }

    @TestCase
    func testReadOnlyWithClampedLimitPinsWholeSql(): Unit {
        @Assert(actual: notifListSql(7, "1", 50), expected: "SELECT id, type, title, IFNULL(content, ''), IFNULL(ref_id, ''), read_flag,\n       DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s')\nFROM sys_notification\nWHERE user_id = 7 AND read_flag = 1\nORDER BY created_at DESC, id DESC\nLIMIT 50")
    }

    @TestCase
    func testInjectionReadFlagLeavesTrailingSpaceNotCondition(): Unit {
        // 期望串里 "user_id = 7 \n" 的那个空格是**证据**：
        // 说明 notifReadCond 返回了空串，而不是把外部输入拼进了 WHERE。
        @Assert(actual: notifListSql(7, "1 OR 1=1", 20), expected: "SELECT id, type, title, IFNULL(content, ''), IFNULL(ref_id, ''), read_flag,\n       DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s')\nFROM sys_notification\nWHERE user_id = 7 \nORDER BY created_at DESC, id DESC\nLIMIT 20")
    }
}

@test class NotifMarkReadSqlTest {
    @TestCase
    func testMarkReadAlwaysConstrainsBothIdAndUser(): Unit {
        // 越权改他人通知必须命中 0 行，所以 user_id 必须在 UPDATE 的 WHERE 里
        @Assert(actual: notifReadSql(9, 7), expected: "UPDATE sys_notification SET read_flag = 1 WHERE id = 9 AND user_id = 7 AND read_flag = 0")
        @Assert(actual: notifReadSql(9, 990001), expected: "UPDATE sys_notification SET read_flag = 1 WHERE id = 9 AND user_id = 990001 AND read_flag = 0")
    }

    @TestCase
    func testExistenceAndStateProbesAreSeparateQueries(): Unit {
        // COUNT 用来区分「不存在/不属于你」，read_flag 用来区分「已是已读」
        @Assert(actual: notifReadCountSql(9, 7), expected: "SELECT COUNT(*) FROM sys_notification WHERE id = 9 AND user_id = 7")
        @Assert(actual: notifIsReadSql(9, 7), expected: "SELECT read_flag FROM sys_notification WHERE id = 9 AND user_id = 7 LIMIT 1")
        @Assert(actual: notifReadAllSql(7), expected: "UPDATE sys_notification SET read_flag = 1 WHERE user_id = 7 AND read_flag = 0")
    }
}

@test class NotifExistsSqlTest {
    @TestCase
    func testDedupeProbeUsesTheUniqueKeyPrefix(): Unit {
        @Assert(actual: notifExistsSql(7, "PAYROLL_PAID", "123"), expected: "SELECT COUNT(*) FROM sys_notification WHERE user_id = 7 AND type = 'PAYROLL_PAID' AND ref_id = '123'")
    }

    @TestCase
    func testQuotesInsideTypeAndRefAreEscaped(): Unit {
        @Assert(actual: notifExistsSql(7, "a'b", "c'd"), expected: "SELECT COUNT(*) FROM sys_notification WHERE user_id = 7 AND type = 'a\\'b' AND ref_id = 'c\\'d'")
    }
}

// ============================ 写入侧 SQL（INSERT IGNORE 是实测换来的） ============================

@test class NotifInsertSqlTest {
    @TestCase
    func testInsertMustCarryIgnoreKeyword(): Unit {
        // mysql.exe 跑脚本没有 --force：一条 duplicate-key 会中止同脚本后续全部语句。
        // 这条断言是回归防线——谁把它改回普通 INSERT，批量发薪就会只剩第一个人的通知。
        @Assert(actual: notifInsertSql(7, "PAYROLL_PAID", "t", "c", "42"), expected: "INSERT IGNORE INTO sys_notification (user_id, type, title, content, ref_id, read_flag)\nVALUES (7, 'PAYROLL_PAID', 't', 'c', '42', 0)")
    }

    @TestCase
    func testSingleQuoteInsideContentIsEscaped(): Unit {
        // 拆成两个用例而不是一条混着 ' 和 \ 的串：混写时很容易把「已转义的形」当成输入，
        // 断言会因此永远为假，反而掩盖真实漂移。
        @Assert(actual: notifInsertSql(7, "PAYROLL_PAID", "含'单引号", "A'B", "42"), expected: "INSERT IGNORE INTO sys_notification (user_id, type, title, content, ref_id, read_flag)\nVALUES (7, 'PAYROLL_PAID', '含\\'单引号', 'A\\'B', '42', 0)")
    }

    @TestCase
    func testBackslashInsideContentIsDoubled(): Unit {
        // Windows 路径是最容易带反斜杠的真实文案（员工姓名一般不会，但 remark 会）
        @Assert(actual: notifInsertSql(7, "PAYROLL_PAID", "t", "路径C:\\temp 工资条", "42"), expected: "INSERT IGNORE INTO sys_notification (user_id, type, title, content, ref_id, read_flag)\nVALUES (7, 'PAYROLL_PAID', 't', '路径C:\\\\temp 工资条', '42', 0)")
    }

    @TestCase
    func testReadFlagIsAlwaysWrittenAsZero(): Unit {
        // 新通知必须落库为未读，否则红点数永远对不上
        @Assert(actual: notifInsertSql(1, "LEAVE_APPROVED", "a", "b", "1"), expected: "INSERT IGNORE INTO sys_notification (user_id, type, title, content, ref_id, read_flag)\nVALUES (1, 'LEAVE_APPROVED', 'a', 'b', '1', 0)")
        @Assert(actual: notifInsertSql(0, "LEAVE_REJECTED", "a", "b", ""), expected: "INSERT IGNORE INTO sys_notification (user_id, type, title, content, ref_id, read_flag)\nVALUES (0, 'LEAVE_REJECTED', 'a', 'b', '', 0)")
    }
}

// ============================ sys_user 反查与收件人集合 ============================

@test class NotifUserLookupSqlTest {
    @TestCase
    func testResolveUserByEmployeeId(): Unit {
        @Assert(actual: notifUserByEmpSql(5), expected: "SELECT id FROM sys_user WHERE employee_id = 5 LIMIT 1")
        @Assert(actual: notifUserByEmpSql(0), expected: "SELECT id FROM sys_user WHERE employee_id = 0 LIMIT 1")
    }

    @TestCase
    func testManagerAndHrScopesOnlyActiveAccounts(): Unit {
        // is_active = 1 是硬要求：停用账号（离职）不该再收到合同到期提醒
        @Assert(actual: notifManagerUserSql(), expected: "SELECT id FROM sys_user WHERE role IN ('ADMIN', 'HR') AND is_active = 1")
        @Assert(actual: notifHrUserSql(), expected: "SELECT id FROM sys_user WHERE role = 'HR' AND is_active = 1")
    }
}

@test class NotifUserIdsTest {
    @TestCase
    func testNonNumericAndNonPositiveIdsAreSkipped(): Unit {
        let rows = ArrayList<ArrayList<String>>()
        rows.add(notpUserRow("3", "5"))
        rows.add(notpShortRow("7"))
        rows.add(notpUserRow("0", "5"))
        rows.add(notpUserRow("-1", "5"))
        rows.add(notpUserRow("x", "5"))
        rows.add(notpUserRow(" 5", "5"))
        rows.add(ArrayList<String>())
        let ids = notifUserIds(rows)
        // 只剩 3 和 7：0 / 负数 / 非数字 / 带空格 / 空行全部丢弃
        @Assert(actual: ids.size, expected: 2)
        @Assert(actual: ids[0], expected: 3)
        @Assert(actual: ids[1], expected: 7)
    }

    @TestCase
    func testEmptyRowSetYieldsEmptyList(): Unit {
        // 空集合 => 调用方 for 一遍就是 no-op，不该往库里写任何东西
        @Assert(actual: notifUserIds(ArrayList<ArrayList<String>>()).size, expected: 0)
    }
}

// ============================ IN (...) 拼接：空集合必须是合法 SQL ============================

@test class NotifNumListTest {
    @TestCase
    func testEmptyListYieldsZeroSoInNeverSyntaxErrors(): Unit {
        // `IN ()` 是语法错误；`IN (0)` 命中 0 行且不影响其它语句
        @Assert(actual: notifNumList(notpIdList(ArrayList<Int64>())), expected: "0")
    }

    @TestCase
    func testJoinHasNoSpaces(): Unit {
        let one = ArrayList<Int64>()
        one.add(7)
        let three = ArrayList<Int64>()
        three.add(1)
        three.add(2)
        three.add(3)
        @Assert(actual: notifNumList(one), expected: "7")
        @Assert(actual: notifNumList(three), expected: "1,2,3")
    }
}

@test class NotifStrListTest {
    @TestCase
    func testEmptyListYieldsTwoQuotes(): Unit {
        @Assert(actual: notifStrList(ArrayList<String>()), expected: "''")
    }

    @TestCase
    func testEveryElementIsQuotedAndEscaped(): Unit {
        let one = ArrayList<String>()
        one.add("x")
        let two = ArrayList<String>()
        two.add("a")
        two.add("b'c")
        @Assert(actual: notifStrList(one), expected: "'x'")
        @Assert(actual: notifStrList(two), expected: "'a','b\\'c'")
    }
}

@test class NotifSeenRefsSqlTest {
    @TestCase
    func testNumericRefsAreWrappedInInList(): Unit {
        let refs = ArrayList<Int64>()
        refs.add(12)
        refs.add(13)
        refs.add(14)
        @Assert(actual: notifSeenRefsSql("PAYROLL_PAID", refs), expected: "SELECT ref_id FROM sys_notification WHERE type = 'PAYROLL_PAID' AND ref_id IN (12,13,14)")
        @Assert(actual: notifSeenRefsSql("PAYROLL_PAID", ArrayList<Int64>()), expected: "SELECT ref_id FROM sys_notification WHERE type = 'PAYROLL_PAID' AND ref_id IN (0)")
    }

    @TestCase
    func testStringRefsAreQuotedInList(): Unit {
        let refs = ArrayList<String>()
        refs.add("5:2026-12-31")
        refs.add("6:2027-01-05")
        @Assert(actual: notifSeenStrRefsSql("CONTRACT_EXPIRING", refs), expected: "SELECT ref_id FROM sys_notification WHERE type = 'CONTRACT_EXPIRING' AND ref_id IN ('5:2026-12-31','6:2027-01-05')")
        @Assert(actual: notifSeenStrRefsSql("CONTRACT_EXPIRING", ArrayList<String>()), expected: "SELECT ref_id FROM sys_notification WHERE type = 'CONTRACT_EXPIRING' AND ref_id IN ('')")
    }

    @TestCase
    func testUserMapSqlCoversEmptyAndTwoEmployees(): Unit {
        let empIds = ArrayList<Int64>()
        empIds.add(10)
        empIds.add(11)
        @Assert(actual: notifUserMapSql(empIds), expected: "SELECT id, employee_id FROM sys_user WHERE employee_id IN (10,11) AND employee_id IS NOT NULL")
        @Assert(actual: notifUserMapSql(ArrayList<Int64>()), expected: "SELECT id, employee_id FROM sys_user WHERE employee_id IN (0) AND employee_id IS NOT NULL")
    }
}

// ============================ 命中判断：绝不能用子串包含 ============================

@test class NotifSeenTest {
    @TestCase
    func testExactMatchOnlyNotSubstring(): Unit {
        let seen = ArrayList<String>()
        seen.add("12")
        seen.add("34")
        // "1" 不是已通知："12" 里含 "1"，用 contains 会误判成重复 => 第二张工资条静默丢失
        @Assert(actual: notifSeen(seen, "1"), expected: false)
        @Assert(actual: notifSeen(seen, "2"), expected: false)
        @Assert(actual: notifSeen(seen, "12"), expected: true)
        @Assert(actual: notifSeen(seen, "34"), expected: true)
    }

    @TestCase
    func testEmptySeenNeverMatches(): Unit {
        let none = ArrayList<String>()
        @Assert(actual: notifSeen(none, "1"), expected: false)
        @Assert(actual: notifSeen(none, ""), expected: false)
    }
}

@test class NotifMapUserTest {
    @TestCase
    func testHitReturnsUserIdAndMissReturnsZero(): Unit {
        let rows = notpUserRows()
        @Assert(actual: notifMapUser(rows, "6"), expected: 8)
        @Assert(actual: notifMapUser(rows, "5"), expected: 7)
        @Assert(actual: notifMapUser(rows, "99"), expected: 0)
    }

    @TestCase
    func testUnusableRowsReturnZeroInsteadOfThrowing(): Unit {
        let empty = ArrayList<ArrayList<String>>()
        @Assert(actual: notifMapUser(empty, "5"), expected: 0)
        // 只有一列的行（employee_id 缺失）不能越界访问
        let oneCol = ArrayList<ArrayList<String>>()
        oneCol.add(notpShortRow("7"))
        @Assert(actual: notifMapUser(oneCol, "7"), expected: 0)
        // user_id 不是数字时回落 0，调用方据此跳过该员工
        let dirty = ArrayList<ArrayList<String>>()
        dirty.add(notpUserRow("x", "5"))
        @Assert(actual: notifMapUser(dirty, "5"), expected: 0)
    }
}

// ============================ 批量脚本拼接 ============================

@test class NotifJoinInsertsTest {
    @TestCase
    func testEmptyPartsYieldEmptyScript(): Unit {
        // 空脚本 => 调用方直接 return，一个 mysql.exe 都不起
        @Assert(actual: notifJoinInserts(ArrayList<String>()), expected: "")
    }

    @TestCase
    func testEachStatementIsTerminatedAndFollowedByNewline(): Unit {
        let parts = ArrayList<String>()
        parts.add(notifInsertSql(7, "PAYROLL_PAID", "t1", "c1", "41"))
        parts.add(notifInsertSql(8, "PAYROLL_PAID", "t2", "c2", "42"))
        @Assert(actual: notifJoinInserts(parts), expected: "INSERT IGNORE INTO sys_notification (user_id, type, title, content, ref_id, read_flag)\nVALUES (7, 'PAYROLL_PAID', 't1', 'c1', '41', 0);\nINSERT IGNORE INTO sys_notification (user_id, type, title, content, ref_id, read_flag)\nVALUES (8, 'PAYROLL_PAID', 't2', 'c2', '42', 0);\n")
    }

    @TestCase
    func testSinglePartStillEndsWithSemicolon(): Unit {
        let parts = ArrayList<String>()
        parts.add("SELECT 1")
        @Assert(actual: notifJoinInserts(parts), expected: "SELECT 1;\n")
    }
}

// ============================ 文案函数（单位错了就是 bug） ============================

@test class NotifCategoryLabelTest {
    @TestCase
    func testKnownCategoriesAndFallback(): Unit {
        @Assert(actual: notifCategoryLabel("LEAVE"), expected: "请假")
        @Assert(actual: notifCategoryLabel("OVERTIME"), expected: "加班")
        @Assert(actual: notifCategoryLabel("EXPENSE"), expected: "假勤")
        @Assert(actual: notifCategoryLabel(""), expected: "假勤")
    }
}

@test class NotifDurationTextTest {
    @TestCase
    func testLeaveUsesDayUnit(): Unit {
        @Assert(actual: notifDurationText("LEAVE", 4.0), expected: "4.00 天")
        @Assert(actual: notifDurationText("LEAVE", 0.5), expected: "0.50 天")
        @Assert(actual: notifDurationText("LEAVE", 0.0), expected: "0.00 天")
        @Assert(actual: notifDurationText("EXPENSE", 3.0), expected: "3.00 天")
    }

    @TestCase
    func testOvertimeUsesHourUnit(): Unit {
        @Assert(actual: notifDurationText("OVERTIME", 2.5), expected: "2.50 小时")
        @Assert(actual: notifDurationText("OVERTIME", 8.0), expected: "8.00 小时")
        // 两位小数向上进位（formatNum2 是 +0.5 截断，不是四舍五入到偶数）
        @Assert(actual: notifDurationText("LEAVE", 3.333), expected: "3.33 天")
    }
}

// ============================ 响应 JSON 契约（前端直接消费） ============================

@test class NotifRowToJsonTest {
    @TestCase
    func testUnreadPayrollRowPinsWholeJson(): Unit {
        @Assert(actual: notifRowToJson(notpRow("9", "PAYROLL_PAID", "2026-10 工资条已发放", "正文", "42", "0", "2026-11-24 10:00:00")), expected: "{\"id\":9,\"type\":\"PAYROLL_PAID\",\"typeLabel\":\"工资条已发放\",\"title\":\"2026-10 工资条已发放\",\"content\":\"正文\",\"refId\":\"42\",\"isRead\":false,\"createdAt\":\"2026-11-24 10:00:00\"}")
    }

    @TestCase
    func testQuotesBackslashAndNewlineStayStructural(): Unit {
        // title 里的双引号、content 里的反斜杠与换行都必须被转义，
        // 否则一条脏通知能把整个抽屉的 JSON 打炸（前端 .map 之前就先 parse 失败）。
        @Assert(actual: notifRowToJson(notpRow("9", "LEAVE_NEXT_LEVEL", "有\"长假\"待你复核", "含\\反斜杠\n换行", "7", "1", "2026-11-24 10:00:00")), expected: "{\"id\":9,\"type\":\"LEAVE_NEXT_LEVEL\",\"typeLabel\":\"待你复核\",\"title\":\"有\\\"长假\\\"待你复核\",\"content\":\"含\\\\反斜杠\\n换行\",\"refId\":\"7\",\"isRead\":true,\"createdAt\":\"2026-11-24 10:00:00\"}")
    }

    @TestCase
    func testReadFlagIsJsonBooleanNotString(): Unit {
        // 前端写的是 v-if="n.isRead"，出成 "0"/"1" 字符串会让已读通知一直显示红点
        @Assert(actual: notifRowToJson(notpRow("9", "LEAVE_APPROVED", "t", "c", "7", "1", "2026-11-24 10:00:00")), expected: "{\"id\":9,\"type\":\"LEAVE_APPROVED\",\"typeLabel\":\"审批已通过\",\"title\":\"t\",\"content\":\"c\",\"refId\":\"7\",\"isRead\":true,\"createdAt\":\"2026-11-24 10:00:00\"}")
        @Assert(actual: notifRowToJson(notpRow("9", "LEAVE_APPROVED", "t", "c", "7", "", "2026-11-24 10:00:00")), expected: "{\"id\":9,\"type\":\"LEAVE_APPROVED\",\"typeLabel\":\"审批已通过\",\"title\":\"t\",\"content\":\"c\",\"refId\":\"7\",\"isRead\":false,\"createdAt\":\"2026-11-24 10:00:00\"}")
        @Assert(actual: notifRowToJson(notpRow("9", "LEAVE_APPROVED", "t", "c", "7", "2", "2026-11-24 10:00:00")), expected: "{\"id\":9,\"type\":\"LEAVE_APPROVED\",\"typeLabel\":\"审批已通过\",\"title\":\"t\",\"content\":\"c\",\"refId\":\"7\",\"isRead\":false,\"createdAt\":\"2026-11-24 10:00:00\"}")
    }

    @TestCase
    func testShortRowYieldsEmptyString(): Unit {
        // 列数不足（MySQL 返回被截断的脏行）必须整条丢弃，而不是拼出半截 JSON
        @Assert(actual: notifRowToJson(notpShortRow("9")), expected: "")
        let six = ArrayList<String>()
        six.add("9")
        six.add("PAYROLL_PAID")
        six.add("t")
        six.add("c")
        six.add("42")
        six.add("0")
        @Assert(actual: notifRowToJson(six), expected: "")
    }
}

@test class NotifRowsToJsonArrayTest {
    @TestCase
    func testEmptyRowsYieldEmptyArrayLiteral(): Unit {
        // 必须是 []，空串会让前端 res.data.list.map 直接抛
        @Assert(actual: notifRowsToJsonArray(ArrayList<ArrayList<String>>()), expected: "[]")
    }

    @TestCase
    func testAllShortRowsAlsoYieldEmptyArrayLiteral(): Unit {
        let rows = ArrayList<ArrayList<String>>()
        rows.add(notpShortRow("1"))
        rows.add(notpShortRow("2"))
        @Assert(actual: notifRowsToJsonArray(rows), expected: "[]")
    }

    @TestCase
    func testValidRowsAreCommaJoinedAndShortRowsDropped(): Unit {
        let rows = ArrayList<ArrayList<String>>()
        rows.add(notpRow("1", "CONTRACT_EXPIRING", "合同即将到期", "张三 的劳动合同将于 2026-12-31 到期（剩余 37 天），请及时办理续签。", "3:2026-12-31", "0", "2026-11-24 10:00:00"))
        rows.add(notpRow("2", "LEAVE_APPROVED", "请假申请已通过", "你发起的请假（4.00 天）已通过审批。", "7", "1", "2026-11-24 09:00:00"))
        rows.add(notpShortRow("3"))
        @Assert(actual: notifRowsToJsonArray(rows), expected: "[{\"id\":1,\"type\":\"CONTRACT_EXPIRING\",\"typeLabel\":\"合同到期提醒\",\"title\":\"合同即将到期\",\"content\":\"张三 的劳动合同将于 2026-12-31 到期（剩余 37 天），请及时办理续签。\",\"refId\":\"3:2026-12-31\",\"isRead\":false,\"createdAt\":\"2026-11-24 10:00:00\"},{\"id\":2,\"type\":\"LEAVE_APPROVED\",\"typeLabel\":\"审批已通过\",\"title\":\"请假申请已通过\",\"content\":\"你发起的请假（4.00 天）已通过审批。\",\"refId\":\"7\",\"isRead\":true,\"createdAt\":\"2026-11-24 09:00:00\"}]")
    }

    @TestCase
    func testSingleRowHasNoTrailingComma(): Unit {
        let rows = ArrayList<ArrayList<String>>()
        rows.add(notpRow("5", "LEAVE_REJECTED", "请假申请被驳回", "c", "8", "0", "2026-11-24 08:00:00"))
        @Assert(actual: notifRowsToJsonArray(rows), expected: "[{\"id\":5,\"type\":\"LEAVE_REJECTED\",\"typeLabel\":\"审批已驳回\",\"title\":\"请假申请被驳回\",\"content\":\"c\",\"refId\":\"8\",\"isRead\":false,\"createdAt\":\"2026-11-24 08:00:00\"}]")
    }

    @TestCase
    func testTypeLabelIsDerivedInsideEveryRow(): Unit {
        // 抽屉里分类徽标直接读 typeLabel，5 种 type 各钉一条，
        // 谁改了 notifTypeLabel 的映射就会在这里立刻炸出 5 条失败。
        @Assert(actual: notifRowToJson(notpRow("9", "CONTRACT_EXPIRING", "t", "c", "7", "0", "2026-11-24 10:00:00")), expected: "{\"id\":9,\"type\":\"CONTRACT_EXPIRING\",\"typeLabel\":\"合同到期提醒\",\"title\":\"t\",\"content\":\"c\",\"refId\":\"7\",\"isRead\":false,\"createdAt\":\"2026-11-24 10:00:00\"}")
        @Assert(actual: notifRowToJson(notpRow("9", "LEAVE_APPROVED", "t", "c", "7", "0", "2026-11-24 10:00:00")), expected: "{\"id\":9,\"type\":\"LEAVE_APPROVED\",\"typeLabel\":\"审批已通过\",\"title\":\"t\",\"content\":\"c\",\"refId\":\"7\",\"isRead\":false,\"createdAt\":\"2026-11-24 10:00:00\"}")
        @Assert(actual: notifRowToJson(notpRow("9", "LEAVE_REJECTED", "t", "c", "7", "0", "2026-11-24 10:00:00")), expected: "{\"id\":9,\"type\":\"LEAVE_REJECTED\",\"typeLabel\":\"审批已驳回\",\"title\":\"t\",\"content\":\"c\",\"refId\":\"7\",\"isRead\":false,\"createdAt\":\"2026-11-24 10:00:00\"}")
        @Assert(actual: notifRowToJson(notpRow("9", "LEAVE_NEXT_LEVEL", "t", "c", "7", "0", "2026-11-24 10:00:00")), expected: "{\"id\":9,\"type\":\"LEAVE_NEXT_LEVEL\",\"typeLabel\":\"待你复核\",\"title\":\"t\",\"content\":\"c\",\"refId\":\"7\",\"isRead\":false,\"createdAt\":\"2026-11-24 10:00:00\"}")
        @Assert(actual: notifRowToJson(notpRow("9", "PAYROLL_PAID", "t", "c", "7", "0", "2026-11-24 10:00:00")), expected: "{\"id\":9,\"type\":\"PAYROLL_PAID\",\"typeLabel\":\"工资条已发放\",\"title\":\"t\",\"content\":\"c\",\"refId\":\"7\",\"isRead\":false,\"createdAt\":\"2026-11-24 10:00:00\"}")
    }

    @TestCase
    func testMixedRowsIncludingUnknownType(): Unit {
        // 库里出现脏 type（历史数据 / 手工插入）时，整批响应仍必须合法：
        // 该行回落「系统通知」，而不是把整个数组打成空串。
        let three = ArrayList<ArrayList<String>>()
        three.add(notpRow("10", "PAYROLL_PAID", "2026-10 工资条已发放", "2026-10 的工资已发放，点击查看详情。", "88", "0", "2026-11-24 10:00:00"))
        three.add(notpRow("11", "LEAVE_NEXT_LEVEL", "有长假待你复核", "张三 的请假申请已超过 3 天，部门主管已通过一级，请复核。", "7", "0", "2026-11-24 09:30:00"))
        three.add(notpRow("12", "UNKNOWN", "系统维护", "", "", "1", "2026-11-23 22:00:00"))
        @Assert(actual: notifRowsToJsonArray(three), expected: "[{\"id\":10,\"type\":\"PAYROLL_PAID\",\"typeLabel\":\"工资条已发放\",\"title\":\"2026-10 工资条已发放\",\"content\":\"2026-10 的工资已发放，点击查看详情。\",\"refId\":\"88\",\"isRead\":false,\"createdAt\":\"2026-11-24 10:00:00\"},{\"id\":11,\"type\":\"LEAVE_NEXT_LEVEL\",\"typeLabel\":\"待你复核\",\"title\":\"有长假待你复核\",\"content\":\"张三 的请假申请已超过 3 天，部门主管已通过一级，请复核。\",\"refId\":\"7\",\"isRead\":false,\"createdAt\":\"2026-11-24 09:30:00\"},{\"id\":12,\"type\":\"UNKNOWN\",\"typeLabel\":\"系统通知\",\"title\":\"系统维护\",\"content\":\"\",\"refId\":\"\",\"isRead\":true,\"createdAt\":\"2026-11-23 22:00:00\"}]")
    }
}

// ============================ 第二批：参数边界与真实文案 ============================

@test class NotifPagingBoundaryTest {
    @TestCase
    func testLimitBoundariesAround50(): Unit {
        // 49/50 原样透传，100 钳到 50；配合上一节的 0/-1 默认值，边界就闭合了
        @Assert(actual: notifClampLimit(49), expected: 49)
        @Assert(actual: notifClampLimit(2), expected: 2)
        @Assert(actual: notifClampLimit(100), expected: 50)
    }

    @TestCase
    func testListSqlForOtherUserAndLimitOne(): Unit {
        // limit=1 是抽屉「只看最新一条」的用法；大 user_id 不能被拼成科学计数法
        @Assert(actual: notifListSql(990001, "", 1), expected: "SELECT id, type, title, IFNULL(content, ''), IFNULL(ref_id, ''), read_flag,\n       DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s')\nFROM sys_notification\nWHERE user_id = 990001 \nORDER BY created_at DESC, id DESC\nLIMIT 1")
        @Assert(actual: notifListSql(1, "0", 50), expected: "SELECT id, type, title, IFNULL(content, ''), IFNULL(ref_id, ''), read_flag,\n       DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s')\nFROM sys_notification\nWHERE user_id = 1 AND read_flag = 0\nORDER BY created_at DESC, id DESC\nLIMIT 50")
    }
}

@test class NotifValidTypeExtraTest {
    @TestCase
    func testNearMissesAreRejected(): Unit {
        // 差一个字母 / 多一个空格 / 大小写不同 都不能算合法 type
        @Assert(actual: notifIsValidType("contract_expiring"), expected: false)
        @Assert(actual: notifIsValidType("LEAVE_APPROVE"), expected: false)
        @Assert(actual: notifIsValidType("LEAVE_NEXT_LEVE"), expected: false)
        @Assert(actual: notifIsValidType(" PAYROLL_PAID"), expected: false)
        @Assert(actual: notifIsValidType("PAYROLL_PAI D"), expected: false)
        @Assert(actual: notifIsValidType("é"), expected: false)
    }
}

@test class NotifTypeLabelExtraTest {
    @TestCase
    func testNearMissesFallBackToo(): Unit {
        // 白名单与标签表必须同一份真相：合法集之外的值一律「系统通知」
        @Assert(actual: notifTypeLabel("contract_expiring"), expected: "系统通知")
        @Assert(actual: notifTypeLabel("LEAVE_NEXT_LEVEL "), expected: "系统通知")
        @Assert(actual: notifTypeLabel("PAYROLL"), expected: "系统通知")
        @Assert(actual: notifTypeLabel("UNKNOWN_TYPE"), expected: "系统通知")
    }
}

@test class NotifWordingExtraTest {
    @TestCase
    func testDurationRoundingAndUnits(): Unit {
        // 0.004 -> 0.00（不会因为浮点噪声变成 0.01）；7.375 -> 7.38（+0.5 截断）
        @Assert(actual: notifDurationText("LEAVE", 0.004), expected: "0.00 天")
        @Assert(actual: notifDurationText("OVERTIME", 0.5), expected: "0.50 小时")
        @Assert(actual: notifDurationText("OVERTIME", 0.0), expected: "0.00 小时")
        @Assert(actual: notifDurationText("LEAVE", 10.0), expected: "10.00 天")
        @Assert(actual: notifDurationText("overtime", 1.0), expected: "1.00 天")
        @Assert(actual: notifDurationText("LEAVE", 7.375), expected: "7.38 天")
    }

    @TestCase
    func testCategoryIsCaseSensitive(): Unit {
        @Assert(actual: notifCategoryLabel("leave"), expected: "假勤")
        @Assert(actual: notifCategoryLabel("OVERTIME "), expected: "假勤")
        @Assert(actual: notifCategoryLabel("TRAVEL"), expected: "假勤")
    }
}

@test class NotifInListExtraTest {
    @TestCase
    func testNumListHandlesBigIds(): Unit {
        let big = ArrayList<Int64>()
        big.add(900001)
        big.add(900002)
        let one = ArrayList<Int64>()
        one.add(42)
        @Assert(actual: notifNumList(ArrayList<Int64>()), expected: "0")
        @Assert(actual: notifNumList(big), expected: "900001,900002")
        @Assert(actual: notifNumList(one), expected: "42")
    }

    @TestCase
    func testStrListQuotesEveryElement(): Unit {
        let three = ArrayList<String>()
        three.add("a")
        three.add("b")
        three.add("c")
        let blank = ArrayList<String>()
        blank.add("")
        let quoted = ArrayList<String>()
        quoted.add("他说\"好\"")
        quoted.add("it's")
        // 空串元素也要留出一对引号，否则 IN (,) 语法错误
        @Assert(actual: notifStrList(three), expected: "'a','b','c'")
        @Assert(actual: notifStrList(blank), expected: "''")
        @Assert(actual: notifStrList(quoted), expected: "'他说\"好\"','it\\'s'")
    }
}

@test class NotifSeenPositionTest {
    @TestCase
    func testEveryPositionMatchesAndLookalikesDoNot(): Unit {
        let seen = ArrayList<String>()
        seen.add("11")
        seen.add("22")
        seen.add("33")
        seen.add("44")
        @Assert(actual: notifSeen(seen, "11"), expected: true)
        @Assert(actual: notifSeen(seen, "22"), expected: true)
        @Assert(actual: notifSeen(seen, "33"), expected: true)
        @Assert(actual: notifSeen(seen, "44"), expected: true)
        @Assert(actual: notifSeen(seen, "1"), expected: false)
        @Assert(actual: notifSeen(seen, "112"), expected: false)
    }
}

@test class NotifMapUserExtraTest {
    @TestCase
    func testFirstMatchingRowWins(): Unit {
        // 同一 employee_id 挂了两个账号（脏数据）时取第一条，行为必须确定
        let dup = ArrayList<ArrayList<String>>()
        dup.add(notpUserRow("7", "5"))
        dup.add(notpUserRow("9", "5"))
        @Assert(actual: notifMapUser(dup, "5"), expected: 7)
        @Assert(actual: notifMapUser(dup, "6"), expected: 0)
        let rows2 = notpUserRows()
        @Assert(actual: notifMapUser(rows2, "6"), expected: 8)
        // employee_id 列本身不是数字时匹配不上，返回 0 而不是抛
        let secondColDirty = ArrayList<ArrayList<String>>()
        secondColDirty.add(notpUserRow("7", "x"))
        @Assert(actual: notifMapUser(secondColDirty, "5"), expected: 0)
    }
}

@test class NotifUserIdsExtraTest {
    @TestCase
    func testSingleAllDirtyAndMixedSets(): Unit {
        let single = ArrayList<ArrayList<String>>()
        single.add(notpUserRow("4", "1"))
        @Assert(actual: notifUserIds(single).size, expected: 1)
        @Assert(actual: notifUserIds(single)[0], expected: 4)
        let allDirty = ArrayList<ArrayList<String>>()
        allDirty.add(notpUserRow("a", "1"))
        allDirty.add(notpUserRow("", "1"))
        allDirty.add(notpUserRow("-2", "1"))
        @Assert(actual: notifUserIds(allDirty).size, expected: 0)
        let mixed = ArrayList<ArrayList<String>>()
        mixed.add(notpUserRow("1", "1"))
        mixed.add(notpUserRow("zz", "1"))
        mixed.add(notpUserRow("2", "1"))
        mixed.add(notpUserRow("3", "1"))
        @Assert(actual: notifUserIds(mixed).size, expected: 3)
        @Assert(actual: notifUserIds(mixed)[2], expected: 3)
    }
}

@test class NotifRealWordingsTest {
    @TestCase
    func testThreeTriggerSitesPinTheirOwnSql(): Unit {
        // 这三条就是「审批终态 / 长假复核 / 合同到期」实际落到 mysql.exe 的语句，
        // 逐字 pin 住列顺序与文案，改文案时单测会提醒同步改前端抽屉的展示。
        @Assert(actual: notifExistsSql(7, "CONTRACT_EXPIRING", "3:2026-12-31"), expected: "SELECT COUNT(*) FROM sys_notification WHERE user_id = 7 AND type = 'CONTRACT_EXPIRING' AND ref_id = '3:2026-12-31'")
        @Assert(actual: notifExistsSql(7, "LEAVE_APPROVED", ""), expected: "SELECT COUNT(*) FROM sys_notification WHERE user_id = 7 AND type = 'LEAVE_APPROVED' AND ref_id = ''")
        @Assert(actual: notifInsertSql(7, "CONTRACT_EXPIRING", "合同即将到期", "张三 的劳动合同将于 2026-12-31 到期（剩余 37 天），请及时办理续签。", "3:2026-12-31"), expected: "INSERT IGNORE INTO sys_notification (user_id, type, title, content, ref_id, read_flag)\nVALUES (7, 'CONTRACT_EXPIRING', '合同即将到期', '张三 的劳动合同将于 2026-12-31 到期（剩余 37 天），请及时办理续签。', '3:2026-12-31', 0)")
        @Assert(actual: notifInsertSql(8, "LEAVE_NEXT_LEVEL", "有长假待你复核", "张三 的请假申请已超过 3 天，部门主管已通过一级，请复核。", "7"), expected: "INSERT IGNORE INTO sys_notification (user_id, type, title, content, ref_id, read_flag)\nVALUES (8, 'LEAVE_NEXT_LEVEL', '有长假待你复核', '张三 的请假申请已超过 3 天，部门主管已通过一级，请复核。', '7', 0)")
    }

    @TestCase
    func testBatchScriptCarriesThreeStatements(): Unit {
        // 一次 mysql.exe 提交 N 条：每条都要自带分号 + 换行，最后一条也不能漏
        let three = ArrayList<String>()
        three.add(notifInsertSql(1, "LEAVE_APPROVED", "a1", "b1", "r1"))
        three.add(notifInsertSql(2, "LEAVE_REJECTED", "a2", "b2", "r2"))
        three.add(notifInsertSql(3, "PAYROLL_PAID", "a3", "b3", "r3"))
        @Assert(actual: notifJoinInserts(three), expected: "INSERT IGNORE INTO sys_notification (user_id, type, title, content, ref_id, read_flag)\nVALUES (1, 'LEAVE_APPROVED', 'a1', 'b1', 'r1', 0);\nINSERT IGNORE INTO sys_notification (user_id, type, title, content, ref_id, read_flag)\nVALUES (2, 'LEAVE_REJECTED', 'a2', 'b2', 'r2', 0);\nINSERT IGNORE INTO sys_notification (user_id, type, title, content, ref_id, read_flag)\nVALUES (3, 'PAYROLL_PAID', 'a3', 'b3', 'r3', 0);\n")
    }
}
