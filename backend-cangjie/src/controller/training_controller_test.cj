package hrms_backend.controller

import std.collection.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*

// P4.1 培训与学分（training_controller.cj）纯函数单元测试。
//
// 覆盖与数据库无关的全部判定逻辑：状态/类别/记录态三套白名单、状态机、
// 钳位与学分折算、名额、受众/报名/签到/取消/录分五道闸门、筛选条件、
// 所有 SQL 生成函数、时间形状校验、数值文本安全化、表单校验。
//
// 为什么整串 pin SQL：本机没有仓颉 SDK（L-CJ-1），.cj 永远不会被编译，
// 「列名拼错 / 漏掉 status <> CANCELLED / 忘了 INSERT IGNORE」这类问题只会在真实
// MySQL 上以「统计偏大」「静默丢通知」的形式暴露。整串 pin + node 镜像复算期望值，
// 是目前唯一能把这类漂移钉死的手段（String.contains 还会把 IN (1) 误判成 IN (12,13)）。
//
// 不碰库的函数一律不出现在这里：trainingTimeValid / trainingTimeOk /
// notifyTrainingPublished / 11 个 handleTraining* —— 它们依赖 mysql.exe，属于真库实测范围。
//
// 纪律（与 request/attendance/payroll/notification 测试一致）：
//   不用数组字面量（[..]）→ ArrayList + add；不用 String.contains；每个 @test 类 ≤3 个 @TestCase。

// ============================ 测试辅助 ============================

func trRow2(a: String, b: String): ArrayList<String> {
    let r = ArrayList<String>()
    r.add(a)
    r.add(b)
    return r
}

func trRepeat(unit: String, n: Int64): String {
    var s = ""
    var i: Int64 = 0
    while (i < n) {
        s += unit
        i += 1
    }
    return s
}

func trWrapNone(): ArrayList<String> {
    return ArrayList<String>()
}

func trWrapTwo(): ArrayList<String> {
    let a = ArrayList<String>()
    a.add("{\"a\":1}")
    a.add("{\"b\":2}")
    return a
}

func trRow1(): ArrayList<String> {
    let r = ArrayList<String>()
    r.add("3")
    r.add("安全生产责任制")
    r.add("COMPLIANCE")
    r.add("李工")
    r.add("2")
    r.add("研发中心")
    r.add("2026-12-01 09:00:00")
    r.add("2026-12-01 17:00:00")
    r.add("30")
    r.add("2.0")
    r.add("301")
    r.add("含\"引号\"与'单引'")
    r.add("PUBLISHED")
    r.add("5")
    r.add("3")
    return r
}

func trRow2(): ArrayList<String> {
    let r = ArrayList<String>()
    r.add("3")
    r.add("安全生产责任制")
    r.add("COMPLIANCE")
    r.add("李工")
    r.add("2")
    r.add("研发中心")
    r.add("2026-12-01 09:00:00")
    r.add("2026-12-01 17:00:00")
    r.add("30")
    r.add("2.0")
    r.add("301")
    r.add("x")
    r.add("PUBLISHED")
    r.add("5")
    return r
}

func trRow3(): ArrayList<String> {
    let r = ArrayList<String>()
    r.add("7")
    r.add("新员工融入")
    r.add("INTERNAL")
    r.add("张三")
    r.add("5")
    r.add("人事部")
    r.add("2026-12-05 09:00:00")
    r.add("2026-12-05 12:00:00")
    r.add("30")
    r.add("1.5")
    r.add("线上直播")
    r.add("PUBLISHED")
    r.add("120")
    r.add("-600")
    r.add("")
    r.add("4")
    r.add("")
    return r
}

func trRow4(): ArrayList<String> {
    let r = ArrayList<String>()
    r.add("7")
    r.add("新员工融入")
    r.add("INTERNAL")
    r.add("张三")
    r.add("5")
    r.add("人事部")
    r.add("2026-12-05 09:00:00")
    r.add("2026-12-05 12:00:00")
    r.add("30")
    r.add("1.5")
    r.add("线上直播")
    r.add("PUBLISHED")
    r.add("-30")
    r.add("-600")
    r.add("REGISTERED")
    r.add("30")
    r.add("")
    return r
}

func trRow5(): ArrayList<String> {
    let r = ArrayList<String>()
    r.add("7")
    r.add("新员工融入")
    r.add("INTERNAL")
    r.add("张三")
    r.add("5")
    r.add("人事部")
    r.add("2026-12-05 09:00:00")
    r.add("2026-12-05 12:00:00")
    r.add("0")
    r.add("1.5")
    r.add("线上直播")
    r.add("DONE")
    r.add("-600")
    r.add("-200")
    r.add("ABSENT")
    r.add("12")
    r.add("")
    return r
}

func trRow6(): ArrayList<String> {
    let r = ArrayList<String>()
    r.add("11")
    r.add("3")
    r.add("安全生产责任制")
    r.add("COMPLIANCE")
    r.add("李工")
    r.add("2026-11-10 09:00:00")
    r.add("2026-11-10 17:00:00")
    r.add("1.5")
    r.add("ATTENDED")
    r.add("2026-11-10 08:55:00")
    r.add("88.0")
    r.add("1.5")
    r.add("表现良好")
    return r
}

func trRow7(): ArrayList<String> {
    let r = ArrayList<String>()
    r.add("12")
    r.add("4")
    r.add("在线课程")
    r.add("ONLINE")
    r.add("王五")
    r.add("2026-12-20 09:00:00")
    r.add("2026-12-20 12:00:00")
    r.add("1.0")
    r.add("REGISTERED")
    r.add("")
    r.add("null")
    r.add("0.0")
    r.add("")
    return r
}

func trRow8(): ArrayList<String> {
    let r = ArrayList<String>()
    r.add("21")
    r.add("4")
    r.add("李四")
    r.add("EMP0004")
    r.add("研发中心")
    r.add("ATTENDED")
    r.add("2026-11-10 08:58:00")
    r.add("55.0")
    r.add("0.0")
    r.add("迟到")
    r.add("8")
    return r
}

func trRow9(): ArrayList<String> {
    let r = ArrayList<String>()
    r.add("4")
    r.add("李四")
    r.add("研发中心")
    r.add("3.5")
    return r
}

func trRow10(): ArrayList<String> {
    let r = ArrayList<String>()
    r.add("3")
    r.add("安全生产责任制")
    r.add("71.50000")
    r.add("3")
    r.add("2")
    r.add("3.0")
    return r
}

// ============================ TrainingRoundDec1Test ============================

@test class TrainingRoundDec1Test {
    @TestCase
    func testHalfRoundsUp(): Unit {
        @Assert(actual: roundDec1(0.75), expected: 0.8)
        @Assert(actual: roundDec1(2.34), expected: 2.3)
        @Assert(actual: roundDec1(2.35), expected: 2.4)
        @Assert(actual: roundDec1(1.0), expected: 1.0)
    }

    @TestCase
    func testNegativeAndZero(): Unit {
        @Assert(actual: roundDec1(0.0), expected: 0.0)
        @Assert(actual: roundDec1(-0.25), expected: -0.3)
        @Assert(actual: roundDec1(-2.36), expected: -2.4)
    }

    @TestCase
    func testLargeValuesKeepOneDecimal(): Unit {
        @Assert(actual: roundDec1(99.94), expected: 99.9)
        @Assert(actual: roundDec1(99.95), expected: 100.0)
        @Assert(actual: roundDec1(100.0), expected: 100.0)
    }

}

// ============================ TrainingClampTest ============================

@test class TrainingClampTest {
    @TestCase
    func testCapacityClamp(): Unit {
        // capacity<=0 归一为 0（= 不限），上限 500。
        @Assert(actual: trainingClampCapacity(30), expected: 30)
        @Assert(actual: trainingClampCapacity(0), expected: 0)
        @Assert(actual: trainingClampCapacity(-9), expected: 0)
        @Assert(actual: trainingClampCapacity(501), expected: 500)
        @Assert(actual: trainingClampCapacity(500), expected: 500)
    }

    @TestCase
    func testCreditClamp(): Unit {
        // 0 学分合法（宣讲类课程不给分），>10 钳到 10。
        @Assert(actual: trainingClampCredit(2.0), expected: 2.0)
        @Assert(actual: trainingClampCredit(0.0), expected: 0.0)
        @Assert(actual: trainingClampCredit(-1.0), expected: 0.0)
        @Assert(actual: trainingClampCredit(10.5), expected: 10.0)
        @Assert(actual: trainingClampCredit(2.34), expected: 2.3)
    }

    @TestCase
    func testScoreSentinel(): Unit {
        // -1.0 是“无考核”哨兵，与真实的 0 分严格区分。
        @Assert(actual: trainingClampScore(88.0), expected: 88.0)
        @Assert(actual: trainingClampScore(0.0), expected: 0.0)
        @Assert(actual: trainingClampScore(-1.0), expected: -1.0)
        @Assert(actual: trainingClampScore(120.0), expected: 100.0)
        @Assert(actual: trainingClampScore(88.26), expected: 88.3)
    }

}

// ============================ TrainingCreditOfTest ============================

@test class TrainingCreditOfTest {
    @TestCase
    func testAttendanceGate(): Unit {
        @Assert(actual: trainingCreditOf(2.0, false, 88.0), expected: 0.0)
        @Assert(actual: trainingCreditOf(2.0, true, 88.0), expected: 2.0)
        @Assert(actual: trainingCreditOf(2.0, true, -1.0), expected: 2.0)
    }

    @TestCase
    func testScoreBands(): Unit {
        // 60 与 80 是闭区间下界，59.9 归零、79.9 半额。
        @Assert(actual: trainingCreditOf(2.0, true, 80.0), expected: 2.0)
        @Assert(actual: trainingCreditOf(2.0, true, 79.9), expected: 1.0)
        @Assert(actual: trainingCreditOf(2.0, true, 60.0), expected: 1.0)
        @Assert(actual: trainingCreditOf(2.0, true, 59.9), expected: 0.0)
        @Assert(actual: trainingCreditOf(2.0, true, 0.0), expected: 0.0)
    }

    @TestCase
    func testHalfCreditRoundingAndZeroCourse(): Unit {
        @Assert(actual: trainingCreditOf(1.5, true, 65.0), expected: 0.8)
        @Assert(actual: trainingCreditOf(1.0, true, 70.0), expected: 0.5)
        @Assert(actual: trainingCreditOf(0.0, true, 90.0), expected: 0.0)
        @Assert(actual: trainingCreditOf(12.0, true, 90.0), expected: 10.0)
    }

}

// ============================ TrainingCapacityLeftTest ============================

@test class TrainingCapacityLeftTest {
    @TestCase
    func testUnlimitedAndNormal(): Unit {
        @Assert(actual: trainingCapacityLeft(0, 5), expected: -1)
        @Assert(actual: trainingCapacityLeft(0, 0), expected: -1)
        @Assert(actual: trainingCapacityLeft(30, 29), expected: 1)
    }

    @TestCase
    func testFullAndOverSold(): Unit {
        @Assert(actual: trainingCapacityLeft(30, 30), expected: 0)
        @Assert(actual: trainingCapacityLeft(30, 31), expected: 0)
        @Assert(actual: trainingCapacityLeft(30, 0), expected: 30)
    }

}

// ============================ TrainingAudienceDeniedTest ============================

@test class TrainingAudienceDeniedTest {
    @TestCase
    func testPublicCourseHasNoBlock(): Unit {
        // dept_id=0 = 全员课，任何部门都能报。
        @Assert(actual: trainingAudienceDenied(0, 0), expected: "")
        @Assert(actual: trainingAudienceDenied(0, 3), expected: "")
        @Assert(actual: trainingAudienceDenied(-1, 3), expected: "")
    }

    @TestCase
    func testEmployeeWithoutDept(): Unit {
        // 未绑定在职员工（empDeptId<=0）必须先补档案，不能默认放行。
        @Assert(actual: trainingAudienceDenied(2, 0), expected: "该培训面向指定部门，请先在员工档案中完善部门信息")
        @Assert(actual: trainingAudienceDenied(2, -1), expected: "该培训面向指定部门，请先在员工档案中完善部门信息")
    }

    @TestCase
    func testCrossDepartment(): Unit {
        @Assert(actual: trainingAudienceDenied(2, 3), expected: "该培训仅面向其它部门开放，你无法报名")
        @Assert(actual: trainingAudienceDenied(2, 2), expected: "")
    }

}

// ============================ TrainingSignupDeniedTest ============================

@test class TrainingSignupDeniedTest {
    @TestCase
    func testStateFirst(): Unit {
        @Assert(actual: trainingSignupDenied("DRAFT", 100, 5), expected: "该培训计划为「草稿」，暂不可报名")
        @Assert(actual: trainingSignupDenied("DONE", 100, 5), expected: "该培训计划为「已结课」，暂不可报名")
        @Assert(actual: trainingSignupDenied("CANCELLED", 100, 0), expected: "该培训计划为「已取消」，暂不可报名")
    }

    @TestCase
    func testTimeThenQuota(): Unit {
        // minToStart<=0 表示已开课；left==0 才是满员，left==-1 是不限。
        @Assert(actual: trainingSignupDenied("PUBLISHED", 0, 5), expected: "该培训已开课或已结束，无法报名")
        @Assert(actual: trainingSignupDenied("PUBLISHED", -10, 5), expected: "该培训已开课或已结束，无法报名")
        @Assert(actual: trainingSignupDenied("PUBLISHED", 120, 0), expected: "该培训名额已满，如需加位请联系 HR")
        @Assert(actual: trainingSignupDenied("PUBLISHED", 120, -1), expected: "")
        @Assert(actual: trainingSignupDenied("PUBLISHED", 120, 3), expected: "")
    }

}

// ============================ TrainingCheckinDeniedTest ============================

@test class TrainingCheckinDeniedTest {
    @TestCase
    func testTooEarly(): Unit {
        @Assert(actual: trainingCheckinDenied(30, -300), expected: "签到将在开课前 15 分钟开放")
        @Assert(actual: trainingCheckinDenied(16, -600), expected: "签到将在开课前 15 分钟开放")
        @Assert(actual: trainingCheckinDenied(15, -600), expected: "")
    }

    @TestCase
    func testTooLateAndWindow(): Unit {
        @Assert(actual: trainingCheckinDenied(-200, 61), expected: "该培训结束已超过 1 小时，签到通道已关闭")
        @Assert(actual: trainingCheckinDenied(-200, 60), expected: "")
        @Assert(actual: trainingCheckinDenied(-200, -121), expected: "")
        @Assert(actual: trainingCheckinDenied(10, -600), expected: "")
        @Assert(actual: trainingCheckinDenied(-30, 30), expected: "")
    }

}

// ============================ TrainingUnsignupDeniedTest ============================

@test class TrainingUnsignupDeniedTest {
    @TestCase
    func testMissingAndCancelled(): Unit {
        @Assert(actual: trainingUnsignupDenied("", 100), expected: "你尚未报名该培训")
        @Assert(actual: trainingUnsignupDenied("CANCELLED", 100), expected: "该报名已取消")
    }

    @TestCase
    func testCheckedInMustGoThroughHr(): Unit {
        @Assert(actual: trainingUnsignupDenied("ATTENDED", 100), expected: "已签到的记录不能自助取消，请联系 HR 调整")
        @Assert(actual: trainingUnsignupDenied("ABSENT", 100), expected: "已签到的记录不能自助取消，请联系 HR 调整")
    }

    @TestCase
    func testStartedAndOpen(): Unit {
        @Assert(actual: trainingUnsignupDenied("REGISTERED", 0), expected: "培训已开始，取消报名请联系 HR")
        @Assert(actual: trainingUnsignupDenied("REGISTERED", -5), expected: "培训已开始，取消报名请联系 HR")
        @Assert(actual: trainingUnsignupDenied("REGISTERED", 5), expected: "")
    }

}

// ============================ TrainingFilterCondTest ============================

@test class TrainingFilterCondTest {
    @TestCase
    func testStatusCondOnlyAcceptsWhitelist(): Unit {
        @Assert(actual: trainingStatusCond("PUBLISHED"), expected: "AND t.status = 'PUBLISHED'")
        @Assert(actual: trainingStatusCond("DONE"), expected: "AND t.status = 'DONE'")
        @Assert(actual: trainingStatusCond("published"), expected: "")
        @Assert(actual: trainingStatusCond(""), expected: "")
        @Assert(actual: trainingStatusCond("PUBLISHED; DROP TABLE hr_training"), expected: "")
    }

    @TestCase
    func testCategoryCondOnlyAcceptsWhitelist(): Unit {
        @Assert(actual: trainingCategoryCond("INTERNAL"), expected: "AND t.category = 'INTERNAL'")
        @Assert(actual: trainingCategoryCond("COMPLIANCE"), expected: "AND t.category = 'COMPLIANCE'")
        @Assert(actual: trainingCategoryCond("offline"), expected: "")
        @Assert(actual: trainingCategoryCond("1=1"), expected: "")
    }

    @TestCase
    func testDeptCondAndVisibleCond(): Unit {
        // deptId 走 Int64.tryParse，非数字已经在处理器落为 0，这里只验证正数才产生条件。
        @Assert(actual: trainingDeptCond(7), expected: "AND t.dept_id = 7")
        @Assert(actual: trainingDeptCond(0), expected: "")
        @Assert(actual: trainingDeptCond(-5), expected: "")
        @Assert(actual: trainingVisibleCond(3), expected: "AND (t.dept_id = 0 OR t.dept_id = 3)")
        @Assert(actual: trainingVisibleCond(0), expected: "AND (t.dept_id = 0 OR t.dept_id = 0)")
    }

}

// ============================ TrainingKeywordCondTest ============================

@test class TrainingKeywordCondTest {
    @TestCase
    func testBlankKeywordProducesNoCondition(): Unit {
        @Assert(actual: trainingKeywordCond(""), expected: "")
        @Assert(actual: trainingKeywordCond("   "), expected: "")
    }

    @TestCase
    func testWildcardsAreEscaped(): Unit {
        // 先转义反斜杠再转义 % _，顺序错了会产生双重转义。
        @Assert(actual: trainingKeywordCond("50%"), expected: "AND (t.title LIKE '%50\\\\%%' OR t.trainer LIKE '%50\\\\%%' OR t.location LIKE '%50\\\\%%')")
        @Assert(actual: trainingKeywordCond("a_b"), expected: "AND (t.title LIKE '%a\\\\_b%' OR t.trainer LIKE '%a\\\\_b%' OR t.location LIKE '%a\\\\_b%')")
        @Assert(actual: trainingKeywordCond("\\"), expected: "AND (t.title LIKE '%\\\\\\\\%' OR t.trainer LIKE '%\\\\\\\\%' OR t.location LIKE '%\\\\\\\\%')")
        @Assert(actual: trainingKeywordCond("%_%"), expected: "AND (t.title LIKE '%\\\\%\\\\_\\\\%%' OR t.trainer LIKE '%\\\\%\\\\_\\\\%%' OR t.location LIKE '%\\\\%\\\\_\\\\%%')")
    }

    @TestCase
    func testQuoteInsideKeywordIsSqlEscaped(): Unit {
        @Assert(actual: trainingKeywordCond("a'b"), expected: "AND (t.title LIKE '%a\\'b%' OR t.trainer LIKE '%a\\'b%' OR t.location LIKE '%a\\'b%')")
        @Assert(actual: trainingKeywordCond("'; DROP TABLE hr_training; --"), expected: "AND (t.title LIKE '%\\'; DROP TABLE hr\\\\_training; --%' OR t.trainer LIKE '%\\'; DROP TABLE hr\\\\_training; --%' OR t.location LIKE '%\\'; DROP TABLE hr\\\\_training; --%')")
        @Assert(actual: trainingLikeLit("  培_训  "), expected: "培\\_训")
    }

}

// ============================ TrainingListSqlTest ============================

@test class TrainingListSqlTest {
    @TestCase
    func testFourFiltersCompose(): Unit {
        @Assert(actual: trainingListSql(trainingStatusCond("PUBLISHED"), trainingCategoryCond("COMPLIANCE"), trainingKeywordCond("安"), trainingDeptCond(2)), expected: "SELECT t.id, t.title, t.category, t.trainer, t.dept_id, IFNULL(d.dept_name, '全员'),\n       t.start_time, t.end_time, t.capacity, CAST(t.credit AS CHAR), IFNULL(t.location, ''),\n       IFNULL(t.description, ''), t.status,\n       (SELECT COUNT(*) FROM hr_training_record r WHERE r.training_id = t.id AND r.status <> 'CANCELLED'),\n       (SELECT COUNT(*) FROM hr_training_record r WHERE r.training_id = t.id AND r.status = 'ATTENDED')\nFROM hr_training t LEFT JOIN hr_department d ON t.dept_id = d.id\nWHERE 1 = 1 AND t.status = 'PUBLISHED' AND t.category = 'COMPLIANCE' AND (t.title LIKE '%安%' OR t.trainer LIKE '%安%' OR t.location LIKE '%安%') AND t.dept_id = 2\nORDER BY t.start_time DESC, t.id DESC")
    }

    @TestCase
    func testManagerScopeKeepsEmptyCondersAsSpaces(): Unit {
        // 三个非法筛选全部落空，WHERE 只剩主管可见范围。
        @Assert(actual: trainingListSql(trainingStatusCond("ALL"), trainingCategoryCond("all"), trainingKeywordCond("   "), trainingVisibleCond(3)), expected: "SELECT t.id, t.title, t.category, t.trainer, t.dept_id, IFNULL(d.dept_name, '全员'),\n       t.start_time, t.end_time, t.capacity, CAST(t.credit AS CHAR), IFNULL(t.location, ''),\n       IFNULL(t.description, ''), t.status,\n       (SELECT COUNT(*) FROM hr_training_record r WHERE r.training_id = t.id AND r.status <> 'CANCELLED'),\n       (SELECT COUNT(*) FROM hr_training_record r WHERE r.training_id = t.id AND r.status = 'ATTENDED')\nFROM hr_training t LEFT JOIN hr_department d ON t.dept_id = d.id\nWHERE 1 = 1    AND (t.dept_id = 0 OR t.dept_id = 3)\nORDER BY t.start_time DESC, t.id DESC")
    }

}

// ============================ TrainingAvailableSqlTest ============================

@test class TrainingAvailableSqlTest {
    @TestCase
    func testScopedToOwnDept(): Unit {
        @Assert(actual: trainingAvailableSql(2, 7, trainingVisibleCond(2)), expected: "SELECT t.id, t.title, t.category, t.trainer, t.dept_id, IFNULL(d.dept_name, '全员'),\n       t.start_time, t.end_time, t.capacity, CAST(t.credit AS CHAR), IFNULL(t.location, ''), t.status,\n       TIMESTAMPDIFF(MINUTE, NOW(), t.start_time), TIMESTAMPDIFF(MINUTE, t.end_time, NOW()),\n       IFNULL(r.status, ''),\n       (SELECT COUNT(*) FROM hr_training_record r2 WHERE r2.training_id = t.id AND r2.status <> 'CANCELLED'),\n       IFNULL(CAST(r.checkin_at AS CHAR), '')\nFROM hr_training t\nLEFT JOIN hr_department d ON t.dept_id = d.id\nLEFT JOIN hr_training_record r ON r.training_id = t.id AND r.employee_id = 2\nWHERE t.status = 'PUBLISHED' AND (t.dept_id = 0 OR t.dept_id = 7)\nORDER BY t.start_time ASC, t.id ASC")
    }

    @TestCase
    func testNoScopeForAdminLeavesTrailingSpace(): Unit {
        // visibleCond 传空串时模板留一个尾随空格，语法合法且是注入防线生效的证据。
        @Assert(actual: trainingAvailableSql(0, 7, ""), expected: "SELECT t.id, t.title, t.category, t.trainer, t.dept_id, IFNULL(d.dept_name, '全员'),\n       t.start_time, t.end_time, t.capacity, CAST(t.credit AS CHAR), IFNULL(t.location, ''), t.status,\n       TIMESTAMPDIFF(MINUTE, NOW(), t.start_time), TIMESTAMPDIFF(MINUTE, t.end_time, NOW()),\n       IFNULL(r.status, ''),\n       (SELECT COUNT(*) FROM hr_training_record r2 WHERE r2.training_id = t.id AND r2.status <> 'CANCELLED'),\n       IFNULL(CAST(r.checkin_at AS CHAR), '')\nFROM hr_training t\nLEFT JOIN hr_department d ON t.dept_id = d.id\nLEFT JOIN hr_training_record r ON r.training_id = t.id AND r.employee_id = 0\nWHERE t.status = 'PUBLISHED' AND (t.dept_id = 0 OR t.dept_id = 7)\nORDER BY t.start_time ASC, t.id ASC")
    }

}

// ============================ TrainingMySqlTest ============================

@test class TrainingMySqlTest {
    @TestCase
    func testRecordsScopedByEmployee(): Unit {
        @Assert(actual: trainingMyRecordsSql(7), expected: "SELECT r.id, r.training_id, t.title, t.category, t.trainer, t.start_time, t.end_time,\n       CAST(t.credit AS CHAR), r.status, IFNULL(CAST(r.checkin_at AS CHAR), ''),\n       IFNULL(CAST(r.score AS CHAR), 'null'), CAST(r.credit AS CHAR), IFNULL(r.remark, '')\nFROM hr_training_record r JOIN hr_training t ON r.training_id = t.id\nWHERE r.employee_id = 7\nORDER BY t.start_time DESC, r.id DESC")
        @Assert(actual: trainingMyRecordsSql(990001), expected: "SELECT r.id, r.training_id, t.title, t.category, t.trainer, t.start_time, t.end_time,\n       CAST(t.credit AS CHAR), r.status, IFNULL(CAST(r.checkin_at AS CHAR), ''),\n       IFNULL(CAST(r.score AS CHAR), 'null'), CAST(r.credit AS CHAR), IFNULL(r.remark, '')\nFROM hr_training_record r JOIN hr_training t ON r.training_id = t.id\nWHERE r.employee_id = 990001\nORDER BY t.start_time DESC, r.id DESC")
    }

    @TestCase
    func testSummaryIsAggregate(): Unit {
        @Assert(actual: trainingMySummarySql(7), expected: "SELECT IFNULL(SUM(r.credit), 0), COUNT(*),\n       IFNULL(SUM(r.status = 'ATTENDED'), 0),\n       IFNULL(SUM(CASE WHEN r.status = 'ATTENDED' THEN TIMESTAMPDIFF(MINUTE, t.start_time, t.end_time) ELSE 0 END), 0)\nFROM hr_training_record r JOIN hr_training t ON r.training_id = t.id\nWHERE r.employee_id = 7 AND r.status <> 'CANCELLED'")
    }

}

// ============================ TrainingRosterSqlTest ============================

@test class TrainingRosterSqlTest {
    @TestCase
    func testRosterPinsJoinAndOrder(): Unit {
        @Assert(actual: trainingRosterSql(3), expected: "SELECT r.id, r.employee_id, e.name, e.emp_no, IFNULL(d.dept_name, ''), r.status,\n       IFNULL(CAST(r.checkin_at AS CHAR), ''), IFNULL(CAST(r.score AS CHAR), 'null'),\n       CAST(r.credit AS CHAR), IFNULL(r.remark, ''), IFNULL(u.id, 0)\nFROM hr_training_record r\nJOIN hr_employee e ON r.employee_id = e.id\nLEFT JOIN hr_department d ON e.dept_id = d.id\nLEFT JOIN sys_user u ON u.employee_id = e.id\nWHERE r.training_id = 3\nORDER BY FIELD(r.status, 'REGISTERED', 'ATTENDED', 'ABSENT', 'CANCELLED'), r.id ASC")
    }

}

// ============================ TrainingStatsSqlTest ============================

@test class TrainingStatsSqlTest {
    @TestCase
    func testOverviewAndAggregate(): Unit {
        @Assert(actual: trainingOverviewSql(), expected: "SELECT COUNT(*), IFNULL(SUM(status = 'PUBLISHED'), 0), IFNULL(SUM(status = 'DONE'), 0),\n       IFNULL(SUM(status = 'DRAFT'), 0), IFNULL(SUM(status = 'CANCELLED'), 0)\nFROM hr_training")
        @Assert(actual: trainingAggregateSql(), expected: "SELECT IFNULL(SUM(TIMESTAMPDIFF(MINUTE, start_time, end_time)), 0)\nFROM hr_training WHERE status IN ('PUBLISHED', 'DONE')")
    }

    @TestCase
    func testAvgAndCovered(): Unit {
        // AVG(score) 只算非 NULL 行，0 分必须计入均分。
        @Assert(actual: trainingScoreAvgSql(), expected: "SELECT IFNULL(CAST(AVG(score) AS CHAR), '0') FROM hr_training_record WHERE score IS NOT NULL")
        @Assert(actual: trainingCoveredEmpSql(), expected: "SELECT COUNT(DISTINCT employee_id) FROM hr_training_record WHERE status IN ('ATTENDED', 'REGISTERED')")
    }

    @TestCase
    func testRankAndCourseStats(): Unit {
        // 排行固定 TOP10；课程维度受钳位后的 limit 控制。
        @Assert(actual: trainingCreditRankSql(), expected: "SELECT e.id, e.name, IFNULL(d.dept_name, ''), CAST(SUM(r.credit) AS CHAR)\nFROM hr_training_record r\nJOIN hr_employee e ON r.employee_id = e.id\nLEFT JOIN hr_department d ON e.dept_id = d.id\nWHERE r.status <> 'CANCELLED'\nGROUP BY e.id, e.name, d.dept_name\nORDER BY SUM(r.credit) DESC, e.id ASC\nLIMIT 10")
        @Assert(actual: trainingCourseStatsSql(10), expected: "SELECT t.id, t.title, IFNULL(CAST(AVG(r.score) AS CHAR), 'null'),\n       (SELECT COUNT(*) FROM hr_training_record x WHERE x.training_id = t.id AND x.status <> 'CANCELLED'),\n       (SELECT COUNT(*) FROM hr_training_record x WHERE x.training_id = t.id AND x.status = 'ATTENDED'),\n       CAST(SUM(r.credit) AS CHAR)\nFROM hr_training t JOIN hr_training_record r ON r.training_id = t.id\nGROUP BY t.id, t.title\nORDER BY SUM(r.credit) DESC, t.id ASC\nLIMIT 10")
    }

}

// ============================ TrainingInsertSqlTest ============================

@test class TrainingInsertSqlTest {
    @TestCase
    func testQuotesAndBackslashAreEscaped(): Unit {
        // 讲师名带反斜杠、主题带单引号，是最容易把 SQL 拼断的组合。
        @Assert(actual: trainingInsertSql("O'Brien 安全", "COMPLIANCE", "李\\老师", 2, "2026-12-01 09:00:00", "2026-12-01 17:00:00", 30, 2.0, "301", "x", 2), expected: "INSERT INTO hr_training (title, category, trainer, dept_id, start_time, end_time,\n       capacity, credit, location, description, status, creator_id)\nVALUES ('O\\'Brien 安全', 'COMPLIANCE', '李\\\\老师', 2, '2026-12-01 09:00:00', '2026-12-01 17:00:00',\n       30, 2.00, '301', 'x', 'DRAFT', 2)")
    }

    @TestCase
    func testEmptyLocationAndDescription(): Unit {
        // location/description 为空串时的写法必须与建表默认值一致。
        @Assert(actual: trainingInsertSql("新主题", "ONLINE", "王五", 0, "2026-12-02 10:00:00", "2026-12-02 12:00:00", 0, 1.5, "", "", 7), expected: "INSERT INTO hr_training (title, category, trainer, dept_id, start_time, end_time,\n       capacity, credit, location, description, status, creator_id)\nVALUES ('新主题', 'ONLINE', '王五', 0, '2026-12-02 10:00:00', '2026-12-02 12:00:00',\n       0, 1.50, '', '', 'DRAFT', 7)")
    }

}

// ============================ TrainingUpdateSetTest ============================

@test class TrainingUpdateSetTest {
    @TestCase
    func testSetFragmentPinsAllColumns(): Unit {
        @Assert(actual: trainingUpdateSet("新主题", "ONLINE", "王五", 0, "2026-12-02 10:00:00", "2026-12-02 12:00:00", 0, 1.5, "", ""), expected: "title = '新主题', category = 'ONLINE', trainer = '王五',\n       dept_id = 0, start_time = '2026-12-02 10:00:00', end_time = '2026-12-02 12:00:00',\n       capacity = 0, credit = 1.50, location = '',\n       description = ''")
    }

    @TestCase
    func testSetFragmentEscapes(): Unit {
        @Assert(actual: trainingUpdateSet("O'Brien 安全", "COMPLIANCE", "李\\老师", 2, "2026-12-01 09:00:00", "2026-12-01 17:00:00", 30, 0.5, "301", "x"), expected: "title = 'O\\'Brien 安全', category = 'COMPLIANCE', trainer = '李\\\\老师',\n       dept_id = 2, start_time = '2026-12-01 09:00:00', end_time = '2026-12-01 17:00:00',\n       capacity = 30, credit = 0.50, location = '301',\n       description = 'x'")
    }

}

// ============================ TrainingSettleSqlTest ============================

@test class TrainingSettleSqlTest {
    @TestCase
    func testCreditChangedProbe(): Unit {
        @Assert(actual: trainingCreditChangedSql(3, 2.0), expected: "SELECT SUM(credit <> 2.00) FROM hr_training_record WHERE training_id = 3 AND status = 'ATTENDED'")
    }

    @TestCase
    func testSettleStatements(): Unit {
        @Assert(actual: trainingSettleAbsentSql(3), expected: "UPDATE hr_training_record SET status = 'ABSENT', remark = '结课时未签到'\nWHERE training_id = 3 AND status = 'REGISTERED'")
        @Assert(actual: trainingSettleCreditSql(3, 2.0), expected: "UPDATE hr_training_record SET credit = 2.00\nWHERE training_id = 3 AND status = 'ATTENDED' AND score IS NULL")
    }

    @TestCase
    func testStartPassedProbe(): Unit {
        // 时间比较交给 MySQL，返回 Int64 由 querySingleInt 兜底。
        @Assert(actual: trainingStartPassedSql("2026-12-01 09:00:00"), expected: "SELECT TIMESTAMPDIFF(MINUTE, NOW(), '2026-12-01 09:00:00') < 0")
    }

}

// ============================ TrainingActionSqlTest ============================

@test class TrainingActionSqlTest {
    @TestCase
    func testActionCheckAndRecordStatus(): Unit {
        @Assert(actual: trainingActionCheckSql(1, 7), expected: "SELECT t.status, TIMESTAMPDIFF(MINUTE, NOW(), t.start_time),\n       (SELECT COUNT(*) FROM hr_training_record x WHERE x.training_id = t.id AND x.status <> 'CANCELLED'),\n       t.capacity, t.dept_id, TIMESTAMPDIFF(MINUTE, t.end_time, NOW()), IFNULL(r.status, '')\nFROM hr_training t LEFT JOIN hr_training_record r ON r.training_id = t.id AND r.employee_id = 7\nWHERE t.id = 1")
        @Assert(actual: trainingRecordStatusSql(3, 7), expected: "SELECT status FROM hr_training_record WHERE training_id = 3 AND employee_id = 7 LIMIT 1")
    }

    @TestCase
    func testUpdateStatusEscapesValue(): Unit {
        @Assert(actual: trainingUpdateStatusSql(4, "PUBLISHED"), expected: "UPDATE hr_training SET status = 'PUBLISHED' WHERE id = 4")
    }

}

// ============================ TrainingSignupSqlTest ============================

@test class TrainingSignupSqlTest {
    @TestCase
    func testInsertIsIgnore(): Unit {
        // 重复报名必须 INSERT IGNORE，否则唯一键冲突会中止整批。
        @Assert(actual: trainingSignupInsertSql(1, 7), expected: "INSERT INTO hr_training_record (training_id, employee_id, status, credit)\nVALUES (1, 7, 'REGISTERED', 0.0)")
    }

    @TestCase
    func testReactivate(): Unit {
        // 取消后再报名走 UPDATE 复活原行，不产生第二条记录。
        @Assert(actual: trainingSignupReactivateSql(1, 7), expected: "UPDATE hr_training_record SET status = 'REGISTERED', credit = 0.0, checkin_at = NULL,\n       score = NULL, remark = NULL\nWHERE training_id = 1 AND employee_id = 7 AND status = 'CANCELLED'")
    }

    @TestCase
    func testCancel(): Unit {
        @Assert(actual: trainingCancelSignupSql(1, 7), expected: "UPDATE hr_training_record SET status = 'CANCELLED' WHERE training_id = 1 AND employee_id = 7 AND status = 'REGISTERED'")
    }

}

// ============================ TrainingCheckinSqlTest ============================

@test class TrainingCheckinSqlTest {
    @TestCase
    func testCheckinStamp(): Unit {
        @Assert(actual: trainingCheckinSql(1, 7), expected: "UPDATE hr_training_record SET status = 'ATTENDED', checkin_at = NOW()\nWHERE training_id = 1 AND employee_id = 7 AND status = 'REGISTERED'")
    }

    @TestCase
    func testResultAttendedWithScore(): Unit {
        // 出勤 + 有考核：score 落 formatNum2 后的字面量。
        @Assert(actual: trainingResultSql(3, 4, true, 88.0, 2.0, "认真"), expected: "UPDATE hr_training_record SET status = 'ATTENDED',\n       score = 88.00, credit = 2.00, remark = '认真'\nWHERE training_id = 3 AND employee_id = 4 AND status <> 'CANCELLED'")
    }

    @TestCase
    func testResultAbsentAndZeroScore(): Unit {
        // 缺席行 score 必须是 NULL；0 分必须保留（0 分 ≠ 未考核）。
        @Assert(actual: trainingResultSql(3, 5, false, -1.0, 0.0, ""), expected: "UPDATE hr_training_record SET status = 'ABSENT',\n       score = NULL, credit = 0.00, remark = NULL\nWHERE training_id = 3 AND employee_id = 5 AND status <> 'CANCELLED'")
        @Assert(actual: trainingResultSql(3, 6, true, 0.0, 0.0, ""), expected: "UPDATE hr_training_record SET status = 'ATTENDED',\n       score = 0.00, credit = 0.00, remark = NULL\nWHERE training_id = 3 AND employee_id = 6 AND status <> 'CANCELLED'")
    }

}

// ============================ TrainingTimeSqlTest ============================

@test class TrainingTimeSqlTest {
    @TestCase
    func testInvalidDateReturnsNullProbe(): Unit {
        // 2026-02-30 这类假日期在 MySQL 里返回 NULL，querySingleInt 兜底成 -1。
        @Assert(actual: trainingTimeCheckSql("2026-11-30 09:00:00"), expected: "SELECT TIMESTAMPDIFF(MINUTE, '2026-11-30 09:00:00', '2026-11-30 09:00:00')")
        @Assert(actual: trainingTimeCheckSql("2026-02-30 09:00:00"), expected: "SELECT TIMESTAMPDIFF(MINUTE, '2026-02-30 09:00:00', '2026-02-30 09:00:00')")
    }

    @TestCase
    func testSpanProbeEscapesInput(): Unit {
        @Assert(actual: trainingTimeSpanSql("2026-11-30 09:00:00", "2026-11-30 17:00:00"), expected: "SELECT TIMESTAMPDIFF(MINUTE, '2026-11-30 09:00:00', '2026-11-30 17:00:00')")
        @Assert(actual: trainingTimeSpanSql("2026-11-30 17:00:00", "x'y"), expected: "SELECT TIMESTAMPDIFF(MINUTE, '2026-11-30 17:00:00', 'x\\'y')")
    }

}

// ============================ TrainingTimeFormatOkTest ============================

@test class TrainingTimeFormatOkTest {
    @TestCase
    func testAcceptCanonicalForm(): Unit {
        @Assert(actual: trainingTimeFormatOk("2026-11-30 09:00:00"), expected: true)
        @Assert(actual: trainingTimeFormatOk("2026-01-01 00:00:00"), expected: true)
        @Assert(actual: trainingTimeFormatOk("2099-12-31 23:59:59"), expected: true)
    }

    @TestCase
    func testRejectWrongShape(): Unit {
        @Assert(actual: trainingTimeFormatOk("2026-11-30"), expected: false)
        @Assert(actual: trainingTimeFormatOk("2026-11-30T09:00:00"), expected: false)
        @Assert(actual: trainingTimeFormatOk("2026-11-30 09:00:0"), expected: false)
        @Assert(actual: trainingTimeFormatOk(""), expected: false)
        @Assert(actual: trainingTimeFormatOk("2026-11-30 09:00:00 "), expected: false)
    }

    @TestCase
    func testRejectOutOfRangeFields(): Unit {
        // 月/日/时/分秒的十位上限，把 13 月、32 日、24 时挡在拼 SQL 之前。
        @Assert(actual: trainingTimeFormatOk("2026-00-30 09:00:00"), expected: false)
        @Assert(actual: trainingTimeFormatOk("2026-13-30 09:00:00"), expected: false)
        @Assert(actual: trainingTimeFormatOk("2026-11-00 09:00:00"), expected: false)
        @Assert(actual: trainingTimeFormatOk("2026-11-32 09:00:00"), expected: false)
        @Assert(actual: trainingTimeFormatOk("2026-11-30 24:00:00"), expected: false)
        @Assert(actual: trainingTimeFormatOk("2026-11-30 09:60:00"), expected: false)
        @Assert(actual: trainingTimeFormatOk("1999-11-30 09:00:00"), expected: false)
    }

}

// ============================ TrainingSafeNumTest ============================

@test class TrainingSafeNumTest {
    @TestCase
    func testAcceptNumericText(): Unit {
        @Assert(actual: trainingSafeNum("88.5", "DEF"), expected: "88.5")
        @Assert(actual: trainingSafeNum("-3", "DEF"), expected: "-3")
        @Assert(actual: trainingSafeNum(" 71.5 ", "DEF"), expected: "71.5")
        @Assert(actual: trainingSafeNum("0", "DEF"), expected: "0")
    }

    @TestCase
    func testRejectAnythingElse(): Unit {
        @Assert(actual: trainingSafeNum("", "DEF"), expected: "DEF")
        @Assert(actual: trainingSafeNum("NULL", "DEF"), expected: "DEF")
        @Assert(actual: trainingSafeNum("88abc", "DEF"), expected: "DEF")
        @Assert(actual: trainingSafeNum("1.2.3", "DEF"), expected: "DEF")
        @Assert(actual: trainingSafeNum("-", "DEF"), expected: "DEF")
        @Assert(actual: trainingSafeNum("1e5", "DEF"), expected: "DEF")
    }

    @TestCase
    func testColumnHelpers(): Unit {
        // 列缺失/越界/负下标都必须回落，不能让 JSON 拼出 undefined。
        @Assert(actual: trainingSafeCol(trRow2("ATTENDED", ""), 0, "X"), expected: "ATTENDED")
        @Assert(actual: trainingSafeCol(trRow2("ATTENDED", ""), 1, "X"), expected: "X")
        @Assert(actual: trainingSafeCol(trRow2("ATTENDED", ""), 5, "X"), expected: "X")
        @Assert(actual: trainingSafeCol(trRow2("ATTENDED", ""), -1, "X"), expected: "X")
        @Assert(actual: trainingNumCol(trRow2("71.50000", "abc"), 0, "0.0"), expected: "71.50000")
        @Assert(actual: trainingNumCol(trRow2("71.50000", "abc"), 1, "0.0"), expected: "0.0")
        @Assert(actual: trainingNumCol(trRow2("71.50000", "abc"), 9, "0.0"), expected: "0.0")
    }

}

// ============================ TrainingValidateFormTest ============================

@test class TrainingValidateFormTest {
    @TestCase
    func testValidFormPasses(): Unit {
        @Assert(actual: trainingValidateForm("安全生产", "李工", "2026-11-30 09:00:00", "2026-11-30 17:00:00"), expected: "")
        @Assert(actual: trainingRuneLen("安全生产培训"), expected: 6)
        @Assert(actual: trainingRuneLen(""), expected: 0)
    }

    @TestCase
    func testRequiredFields(): Unit {
        @Assert(actual: trainingValidateForm("", "李工", "2026-11-30 09:00:00", "2026-11-30 17:00:00"), expected: "培训主题必填")
        @Assert(actual: trainingValidateForm("安全生产", "", "2026-11-30 09:00:00", "2026-11-30 17:00:00"), expected: "讲师必填")
        @Assert(actual: trainingValidateForm("安全生产", "李工", "", "2026-11-30 17:00:00"), expected: "开课时间必填")
        @Assert(actual: trainingValidateForm("安全生产", "李工", "2026-11-30 09:00:00", ""), expected: "结课时间必填")
    }

    @TestCase
    func testLengthBoundaryAndTimeShape(): Unit {
        // 120 字通过、121 字拒绝；64 字讲师通过、65 字拒绝。
        @Assert(actual: trainingValidateForm(trRepeat("长", 120), "李工", "2026-11-30 09:00:00", "2026-11-30 17:00:00"), expected: "")
        @Assert(actual: trainingValidateForm(trRepeat("长", 121), "李工", "2026-11-30 09:00:00", "2026-11-30 17:00:00"), expected: "培训主题不超过 120 字")
        @Assert(actual: trainingValidateForm("安全生产", trRepeat("师", 65), "2026-11-30 09:00:00", "2026-11-30 17:00:00"), expected: "讲师姓名不超过 64 字")
        @Assert(actual: trainingValidateForm("安全生产", "李工", "2026-11-30", "2026-11-30 17:00:00"), expected: "开课时间格式须为 YYYY-MM-DD HH:MM:SS")
        @Assert(actual: trainingValidateForm("安全生产", "李工", "2026-11-30 09:00:00", "bad"), expected: "结课时间格式须为 YYYY-MM-DD HH:MM:SS")
    }

}

// ============================ TrainingOneSqlTest ============================

@test class TrainingOneSqlTest {
    @TestCase
    func testOneCarriesCreditCapacityAndStatus(): Unit {
        @Assert(actual: trainingOneSql(3), expected: "SELECT t.id, t.title, t.category, t.trainer, t.dept_id, t.status,\n       CAST(t.credit AS CHAR), t.capacity,\n       (SELECT COUNT(*) FROM hr_training_record r WHERE r.training_id = t.id AND r.status <> 'CANCELLED'),\n       (SELECT COUNT(*) FROM hr_training_record r WHERE r.training_id = t.id AND r.status = 'ATTENDED'),\n       TIMESTAMPDIFF(MINUTE, NOW(), t.start_time)\nFROM hr_training t WHERE t.id = 3")
    }

    @TestCase
    func testAudienceTwoForms(): Unit {
        // dept_id=0 走全员分支，不产生部门限制。
        @Assert(actual: trainingAudienceSql(2), expected: "SELECT u.id FROM sys_user u JOIN hr_employee e ON u.employee_id = e.id\nWHERE u.is_active = 1 AND e.status = 'ACTIVE' AND e.dept_id = 2")
        @Assert(actual: trainingAudienceSql(0), expected: "SELECT u.id FROM sys_user u JOIN hr_employee e ON u.employee_id = e.id\nWHERE u.is_active = 1 AND e.status = 'ACTIVE'")
    }

}

// ============================ TrainingEditGuardTest ============================

@test class TrainingEditGuardTest {
    @TestCase
    func testResultDenied(): Unit {
        // 已结课还能追加录分会造成账实不符。
        @Assert(actual: trainingResultDenied("DRAFT"), expected: "培训计划尚未发布，无需录入结果")
        @Assert(actual: trainingResultDenied("CANCELLED"), expected: "该培训已取消，不再录入结果")
        @Assert(actual: trainingResultDenied("DONE"), expected: "")
        @Assert(actual: trainingResultDenied("PUBLISHED"), expected: "")
    }

    @TestCase
    func testEditDeniedAndCreditChange(): Unit {
        @Assert(actual: trainingEditDenied("DONE"), expected: "「已结课」的培训内容已锁定，不能再修改")
        @Assert(actual: trainingEditDenied("CANCELLED"), expected: "「已取消」的培训内容已锁定，不能再修改")
        @Assert(actual: trainingEditDenied("PUBLISHED"), expected: "")
        @Assert(actual: trainingCreditChangeDenied(1), expected: "该培训已有出勤记录，学分不能再修改（避免与已发放学分离谱）")
        @Assert(actual: trainingCreditChangeDenied(0), expected: "")
    }

    @TestCase
    func testRecordStatusLiteral(): Unit {
        @Assert(actual: trainingResultRecordStatus(true), expected: "ATTENDED")
        @Assert(actual: trainingResultRecordStatus(false), expected: "ABSENT")
    }

}

// ============================ TrainingStatusWhitelistTest ============================

@test class TrainingStatusWhitelistTest {
    @TestCase
    func testFourPlanStatusesAreAccepted(): Unit {
        @Assert(actual: trainingIsValidStatus("DRAFT"), expected: true)
        @Assert(actual: trainingIsValidStatus("PUBLISHED"), expected: true)
        @Assert(actual: trainingIsValidStatus("DONE"), expected: true)
        @Assert(actual: trainingIsValidStatus("CANCELLED"), expected: true)
    }

    @TestCase
    func testRecordOnlyStatusIsRejected(): Unit {
        // 记录态 REGISTERED 不是计划态，混用会让状态机形同虚设。
        @Assert(actual: trainingIsValidStatus("REGISTERED"), expected: false)
        @Assert(actual: trainingIsValidStatus("ATTENDED"), expected: false)
        @Assert(actual: trainingIsValidStatus("published"), expected: false)
        @Assert(actual: trainingIsValidStatus(""), expected: false)
        @Assert(actual: trainingIsValidStatus("DRAFT; DROP TABLE hr_training"), expected: false)
    }

    @TestCase
    func testRecordStatusWhitelistIsADifferentSet(): Unit {
        @Assert(actual: trainingIsValidRecordStatus("REGISTERED"), expected: true)
        @Assert(actual: trainingIsValidRecordStatus("ATTENDED"), expected: true)
        @Assert(actual: trainingIsValidRecordStatus("ABSENT"), expected: true)
        @Assert(actual: trainingIsValidRecordStatus("CANCELLED"), expected: true)
        @Assert(actual: trainingIsValidRecordStatus("PUBLISHED"), expected: false)
    }

}

// ============================ TrainingLabelTest ============================

@test class TrainingLabelTest {
    @TestCase
    func testPlanLabels(): Unit {
        @Assert(actual: trainingStatusLabel("DRAFT"), expected: "草稿")
        @Assert(actual: trainingStatusLabel("PUBLISHED"), expected: "已发布")
        @Assert(actual: trainingStatusLabel("DONE"), expected: "已结课")
        @Assert(actual: trainingStatusLabel("CANCELLED"), expected: "已取消")
    }

    @TestCase
    func testRecordLabelsAndUnknownFallback(): Unit {
        // 回落值必须是“未知”，空串会让表格出现无文案行。
        @Assert(actual: trainingStatusLabel("REGISTERED"), expected: "已报名")
        @Assert(actual: trainingStatusLabel("ATTENDED"), expected: "已出勤")
        @Assert(actual: trainingStatusLabel("ABSENT"), expected: "缺席")
        @Assert(actual: trainingStatusLabel("WHATEVER"), expected: "未知")
        @Assert(actual: trainingStatusLabel(""), expected: "未知")
    }

    @TestCase
    func testCategoryLabels(): Unit {
        @Assert(actual: trainingCategoryLabel("INTERNAL"), expected: "内部培训")
        @Assert(actual: trainingCategoryLabel("ONLINE"), expected: "在线课程")
        @Assert(actual: trainingCategoryLabel("EXTERNAL"), expected: "外部课程")
        @Assert(actual: trainingCategoryLabel("COMPLIANCE"), expected: "合规必修")
        @Assert(actual: trainingCategoryLabel(""), expected: "其它")
    }

}

// ============================ TrainingStatusTransitionTest ============================

@test class TrainingStatusTransitionTest {
    @TestCase
    func testLegalEdges(): Unit {
        @Assert(actual: trainingStatusTransition("DRAFT", "PUBLISHED"), expected: true)
        @Assert(actual: trainingStatusTransition("DRAFT", "CANCELLED"), expected: true)
        @Assert(actual: trainingStatusTransition("PUBLISHED", "DONE"), expected: true)
        @Assert(actual: trainingStatusTransition("PUBLISHED", "CANCELLED"), expected: true)
    }

    @TestCase
    func testTerminalStatesAreLocked(): Unit {
        // 终态不能回流，否则已发放学分的课会被重新开放报名。
        @Assert(actual: trainingStatusTransition("DONE", "PUBLISHED"), expected: false)
        @Assert(actual: trainingStatusTransition("CANCELLED", "DRAFT"), expected: false)
        @Assert(actual: trainingStatusTransition("DONE", "CANCELLED"), expected: false)
    }

    @TestCase
    func testSkipAndIllegalEdges(): Unit {
        @Assert(actual: trainingStatusTransition("DRAFT", "DONE"), expected: false)
        @Assert(actual: trainingStatusTransition("PUBLISHED", "DRAFT"), expected: false)
        @Assert(actual: trainingStatusTransition("PUBLISHED", "PUBLISHED"), expected: false)
        @Assert(actual: trainingStatusTransition("GARBAGE", "DONE"), expected: false)
    }

}

// ============================ TrainingTransitionDeniedTest ============================

@test class TrainingTransitionDeniedTest {
    @TestCase
    func testSameStateIsFriendlyNotError(): Unit {
        @Assert(actual: trainingTransitionDenied("PUBLISHED", "PUBLISHED"), expected: "该培训计划已是「已发布」状态")
        @Assert(actual: trainingTransitionDenied("DRAFT", "DRAFT"), expected: "该培训计划已是「草稿」状态")
    }

    @TestCase
    func testTerminalStateWording(): Unit {
        @Assert(actual: trainingTransitionDenied("DONE", "PUBLISHED"), expected: "「已结课」为终态，不能再变更")
        @Assert(actual: trainingTransitionDenied("CANCELLED", "DRAFT"), expected: "「已取消」为终态，不能再变更")
    }

    @TestCase
    func testUnsupportedEdgeListsBothLabels(): Unit {
        @Assert(actual: trainingTransitionDenied("DRAFT", "DONE"), expected: "不支持的状态流转：草稿 → 已结课")
        @Assert(actual: trainingTransitionDenied("PUBLISHED", "DRAFT"), expected: "不支持的状态流转：已发布 → 草稿")
    }

}

// ============================ TrainingCategoryWhitelistTest ============================

@test class TrainingCategoryWhitelistTest {
    @TestCase
    func testFourCategories(): Unit {
        @Assert(actual: trainingIsValidCategory("INTERNAL"), expected: true)
        @Assert(actual: trainingIsValidCategory("ONLINE"), expected: true)
        @Assert(actual: trainingIsValidCategory("EXTERNAL"), expected: true)
        @Assert(actual: trainingIsValidCategory("COMPLIANCE"), expected: true)
    }

    @TestCase
    func testRejectCaseAndInjection(): Unit {
        @Assert(actual: trainingIsValidCategory("internal"), expected: false)
        @Assert(actual: trainingIsValidCategory(""), expected: false)
        @Assert(actual: trainingIsValidCategory("INTERNAL OR 1=1"), expected: false)
    }

}

// ============================ TrainingPlanRowToJsonTest ============================

@test class TrainingPlanRowToJsonTest {
    @TestCase
    func testFullRowPinsWholeObject(): Unit {
        @Assert(actual: trainingPlanRowToJson(trRow1()), expected: "{\"id\":3,\"title\":\"安全生产责任制\",\"category\":\"COMPLIANCE\",\"categoryLabel\":\"合规必修\",\"trainer\":\"李工\",\"deptId\":2,\"deptName\":\"研发中心\",\"startTime\":\"2026-12-01 09:00:00\",\"endTime\":\"2026-12-01 17:00:00\",\"capacity\":30,\"credit\":2.0,\"location\":\"301\",\"description\":\"含\\\"引号\\\"与'单引'\",\"status\":\"PUBLISHED\",\"statusLabel\":\"已发布\",\"signedCount\":5,\"attendedCount\":3}")
    }

    @TestCase
    func testShortRowIsDroppedNotGuessed(): Unit {
        // 少一列必须整行丢弃（返回空串由处理器过滤），不能拿上一列顶替。
        @Assert(actual: trainingPlanRowToJson(trRow2()), expected: "")
    }

}

// ============================ TrainingOfferRowToJsonTest ============================

@test class TrainingOfferRowToJsonTest {
    @TestCase
    func testNotSignedOpenCourse(): Unit {
        @Assert(actual: trainingOfferRowToJson(trRow3()), expected: "{\"id\":7,\"title\":\"新员工融入\",\"category\":\"INTERNAL\",\"categoryLabel\":\"内部培训\",\"trainer\":\"张三\",\"deptName\":\"人事部\",\"startTime\":\"2026-12-05 09:00:00\",\"endTime\":\"2026-12-05 12:00:00\",\"capacity\":30,\"credit\":1.5,\"location\":\"线上直播\",\"status\":\"PUBLISHED\",\"statusLabel\":\"已发布\",\"minToStart\":120,\"minSinceEnd\":-600,\"myStatus\":\"\",\"myStatusLabel\":\"未报名\",\"signedCount\":4,\"capacityLeft\":26,\"canSignup\":true,\"canCheckin\":false,\"canUnsignup\":false,\"blockReason\":\"\",\"checkinAt\":\"\"}")
    }

    @TestCase
    func testRegisteredAndStarted(): Unit {
        // 已开课：可签到、不可取消、不可重复报名，capacityLeft 归 0。
        @Assert(actual: trainingOfferRowToJson(trRow4()), expected: "{\"id\":7,\"title\":\"新员工融入\",\"category\":\"INTERNAL\",\"categoryLabel\":\"内部培训\",\"trainer\":\"张三\",\"deptName\":\"人事部\",\"startTime\":\"2026-12-05 09:00:00\",\"endTime\":\"2026-12-05 12:00:00\",\"capacity\":30,\"credit\":1.5,\"location\":\"线上直播\",\"status\":\"PUBLISHED\",\"statusLabel\":\"已发布\",\"minToStart\":-30,\"minSinceEnd\":-600,\"myStatus\":\"REGISTERED\",\"myStatusLabel\":\"已报名\",\"signedCount\":30,\"capacityLeft\":0,\"canSignup\":false,\"canCheckin\":true,\"canUnsignup\":false,\"blockReason\":\"你已报名该培训\",\"checkinAt\":\"\"}")
    }

    @TestCase
    func testClosedCourseAbsent(): Unit {
        // 已结课 + 缺席：blockReason 保留“已缺席”，canSignup 仍为 false（课程不可报名）。
        @Assert(actual: trainingOfferRowToJson(trRow5()), expected: "{\"id\":7,\"title\":\"新员工融入\",\"category\":\"INTERNAL\",\"categoryLabel\":\"内部培训\",\"trainer\":\"张三\",\"deptName\":\"人事部\",\"startTime\":\"2026-12-05 09:00:00\",\"endTime\":\"2026-12-05 12:00:00\",\"capacity\":0,\"credit\":1.5,\"location\":\"线上直播\",\"status\":\"DONE\",\"statusLabel\":\"已结课\",\"minToStart\":-600,\"minSinceEnd\":-200,\"myStatus\":\"ABSENT\",\"myStatusLabel\":\"缺席\",\"signedCount\":12,\"capacityLeft\":-1,\"canSignup\":false,\"canCheckin\":false,\"canUnsignup\":false,\"blockReason\":\"你已缺席该培训\",\"checkinAt\":\"\"}")
    }

}

// ============================ TrainingRecordRowToJsonTest ============================

@test class TrainingRecordRowToJsonTest {
    @TestCase
    func testAttendedRow(): Unit {
        @Assert(actual: trainingRecordRowToJson(trRow6()), expected: "{\"id\":11,\"trainingId\":3,\"title\":\"安全生产责任制\",\"category\":\"COMPLIANCE\",\"categoryLabel\":\"合规必修\",\"trainer\":\"李工\",\"startTime\":\"2026-11-10 09:00:00\",\"endTime\":\"2026-11-10 17:00:00\",\"courseCredit\":1.5,\"status\":\"ATTENDED\",\"statusLabel\":\"已出勤\",\"checkinAt\":\"2026-11-10 08:55:00\",\"score\":88.0,\"credit\":1.5,\"remark\":\"表现良好\"}")
    }

    @TestCase
    func testUnscoredRowKeepsJsonNull(): Unit {
        @Assert(actual: trainingRecordRowToJson(trRow7()), expected: "{\"id\":12,\"trainingId\":4,\"title\":\"在线课程\",\"category\":\"ONLINE\",\"categoryLabel\":\"在线课程\",\"trainer\":\"王五\",\"startTime\":\"2026-12-20 09:00:00\",\"endTime\":\"2026-12-20 12:00:00\",\"courseCredit\":1.0,\"status\":\"REGISTERED\",\"statusLabel\":\"已报名\",\"checkinAt\":\"\",\"score\":null,\"credit\":0.0,\"remark\":\"\"}")
    }

    @TestCase
    func testShortRowIsDropped(): Unit {
        @Assert(actual: trainingRecordRowToJson(trRow9()), expected: "")
    }

}

// ============================ TrainingRosterRowToJsonTest ============================

@test class TrainingRosterRowToJsonTest {
    @TestCase
    func testRosterRow(): Unit {
        // userId=0 表示该员工没有登录账号，前端据此隐藏通知入口。
        @Assert(actual: trainingRosterRowToJson(trRow8()), expected: "{\"id\":21,\"employeeId\":4,\"name\":\"李四\",\"empNo\":\"EMP0004\",\"deptName\":\"研发中心\",\"status\":\"ATTENDED\",\"statusLabel\":\"已出勤\",\"checkinAt\":\"2026-11-10 08:58:00\",\"score\":55.0,\"credit\":0.0,\"remark\":\"迟到\",\"userId\":8}")
    }

    @TestCase
    func testRankAndStatRows(): Unit {
        @Assert(actual: trainingRankRowToJson(trRow9()), expected: "{\"employeeId\":4,\"name\":\"李四\",\"deptName\":\"研发中心\",\"credit\":3.5}")
        @Assert(actual: trainingStatRowToJson(trRow10()), expected: "{\"trainingId\":3,\"title\":\"安全生产责任制\",\"avgScore\":71.50000,\"signedCount\":3,\"attendedCount\":2,\"creditTotal\":3.0}")
    }

    @TestCase
    func testWrapArray(): Unit {
        @Assert(actual: trainingWrapArray(trWrapNone()), expected: "[]")
        @Assert(actual: trainingWrapArray(trWrapTwo()), expected: "[{\"a\":1},{\"b\":2}]")
    }

}
