package hrms_backend.controller

import std.collection.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*

// P2.4 考勤月度汇总纯函数单元测试。
//
// 覆盖 attendance_controller.cj 中与数据库无关的 6 个函数：
//   func attMonthIsLate(lateMinutes: Int64, status: String): Bool
//   func attMonthIsEarly(earlyMinutes: Int64, status: String): Bool
//   func attendanceRatePercent(attendDays: Int64, shouldDays: Int64): Float64
//   func attMonthSafeNum(raw: String, defaultText: String): String
//   func isValidYearMonth(s: String): Bool
//   func attMonthlyRowToJson(r: ArrayList<String>): String
//   func attMonthlyTotalsJson(rows: ArrayList<ArrayList<String>>): String
// 以及包级常量 attShouldAttendDays。
//
// 为什么值得单独测：验收项「导出报表与页面数字一致」完全依赖这几个函数——
// 前端 CSV 是直接由本接口返回的 list/summary 拼出来的，只要这里算错，
// 页面和导出会一起错，E2E 反而看不出来，所以必须在纯函数层钉死。
//
// 纪律（与 payroll/employee_import 测试一致）：本文件刻意不使用
//   - 数组字面量（[..]）——全部用 ArrayList<String>() + add()
//   - 元组下标（._0 / tuple indexing）——本模块没有返回元组的函数
//   - String.contains——避免 SDK 版本差异；结构断言一律整串 pin

// ============================ 测试辅助函数 ============================

func attmDq(): String {
    return "\""
}

// 本文件的浮点断言一律用 delta: 0.0——因为被测值都经过 round2，
// 结果是 Float64(Int64 cents) / 100.0，对 0.00 / 25.00 / 50.00 / 75.00 / 100.00
// 这类能被二进制精确表示的值可以精确 pin；非整除值才放宽到 0.011。
func attmAbs(v: Float64): Float64 {
    if (v < 0.0) {
        return -v
    }
    return v
}

// v 元换算成「分」之后，到最近整数分的距离。恒有 0 <= 返回值 <= 0.5。
func attmCentDistance(v: Float64): Float64 {
    let cents = v * 100.0
    var n: Int64 = Int64(cents)
    let down: Float64 = Float64(n)
    if (attmAbs(cents - down) > 0.5) {
        if (cents < 0.0) {
            n = n - 1
        } else {
            n = n + 1
        }
    }
    return attmAbs(cents - Float64(n))
}

// 11 列：empId, empNo, empName, deptName, attendDays, lateCount, earlyCount,
//        lateMinutes, earlyMinutes, leaveDays, overtimeHours
// 长度不足一律补 "x"（非空串），保证 SQL 与仓颉的列序一旦错位会立刻炸出来。
func attmRow(vals: ArrayList<String>): ArrayList<String> {
    let r = ArrayList<String>()
    var i: Int64 = 0
    while (i < 11) {
        if (i < vals.size) {
            r.add(vals[i])
        } else {
            r.add("x")
        }
        i = i + 1
    }
    return r
}

func attmCleanRow(): ArrayList<String> {
    let src = ArrayList<String>()
    src.add("7")
    src.add("E007")
    src.add("Chen Siyuan")
    src.add("Tech")
    src.add("22")
    src.add("2")
    src.add("1")
    src.add("35")
    src.add("10")
    src.add("1.50")
    src.add("3.00")
    return attmRow(src)
}

// 半勤同事：11/22 = 50.00%，是一个能被精确 pin 的比率
func attmHalfRow(): ArrayList<String> {
    let src = ArrayList<String>()
    src.add("8")
    src.add("E008")
    src.add("Li Wen")
    src.add("HR")
    src.add("11")
    src.add("0")
    src.add("0")
    src.add("0")
    src.add("0")
    src.add("0.50")
    src.add("2.00")
    return attmRow(src)
}

func attmEmptyRow(): ArrayList<String> {
    let r = ArrayList<String>()
    var i: Int64 = 0
    while (i < 11) {
        r.add("")
        i = i + 1
    }
    return r
}

func attmRowsOf(a: ArrayList<String>, b: ArrayList<String>): ArrayList<ArrayList<String>> {
    let rows = ArrayList<ArrayList<String>>()
    rows.add(a)
    rows.add(b)
    return rows
}

// 期望的单人 JSON（整串 pin，用来锁字段顺序与数字格式）
func attmExpect(empId: String, empNo: String, empName: String, deptName: String, attendDays: String, lateCount: String, earlyCount: String, lateMinutes: String, earlyMinutes: String, leaveDays: String, overtimeHours: String, rate: String): String {
    let q = attmDq()
    return "{" +
        "${q}employeeId${q}:${empId}," +
        "${q}empNo${q}:${q}${empNo}${q}," +
        "${q}empName${q}:${q}${empName}${q}," +
        "${q}deptName${q}:${q}${deptName}${q}," +
        "${q}attendDays${q}:${attendDays}," +
        "${q}lateCount${q}:${lateCount}," +
        "${q}earlyCount${q}:${earlyCount}," +
        "${q}lateMinutes${q}:${lateMinutes}," +
        "${q}earlyMinutes${q}:${earlyMinutes}," +
        "${q}leaveDays${q}:${leaveDays}," +
        "${q}overtimeHours${q}:${overtimeHours}," +
        "${q}attendanceRate${q}:${rate}" +
    "}"
}

@Test
class AttendanceMonthlySummaryTests {
    // ---- 0. 尺子自检 ----

    @TestCase
    func testHelperSelfCheck(): Unit {
        @Assert(attmDq().size, 1)
        @Assert(("a" + attmDq() + "b").size, 3)
        @Assert(attmAbs(0.0), 0.0)
        @Assert(attmAbs(-2.5), 2.5, delta: 0.0)
        @Assert(attmRow(ArrayList<String>()).size, 11)
        @Assert(attmCleanRow().size, 11)
        @Assert(attmHalfRow().size, 11)
        @Assert(attmRow(ArrayList<String>())[10], "x")
        @Assert(attmCleanRow()[0], "7")
        @Assert(attmCleanRow()[10], "3.00")
        @Assert(attmEmptyRow().size, 11)
        @Assert(attmEmptyRow()[0].size, 0)
        @Assert(attmRowsOf(attmCleanRow(), attmHalfRow()).size, 2)
        @Assert(attmRowsOf(attmCleanRow(), attmHalfRow())[0].size, 11)
        // 分位尺：1.50 元 = 150 分，距离 0；1.234 元 = 123.4 分，距离 0.4
        @Assert(attmCentDistance(1.5) <= 0.01)
        @Assert(attmCentDistance(1.234) > 0.05)
        @Assert(attmCentDistance(-0.25) <= 0.01)
    }

    // ---- 1. 迟到 / 早退判定：必须与 handleAttendanceMy 的口径逐字对应 ----

    @TestCase
    func testLatePredicate(): Unit {
        @Assert(!attMonthIsLate(0, "NORMAL"))
        @Assert(attMonthIsLate(1, "NORMAL"))
        @Assert(attMonthIsLate(120, "NORMAL"))
        @Assert(attMonthIsLate(0, "LATE"))
        @Assert(attMonthIsLate(0, "LATE_AND_EARLY"))
        @Assert(!attMonthIsLate(0, "EARLY_LEAVE"))
        @Assert(!attMonthIsLate(0, "ABSENT"))
        // 分钟数优先于状态：HR 手工把状态改成 NORMAL 但没清分钟数时仍算迟到
        @Assert(attMonthIsLate(5, "NORMAL"))
        @Assert(attMonthIsLate(5, "ABSENT"))
        @Assert(!attMonthIsLate(0, ""))
        @Assert(!attMonthIsLate(-1, "NORMAL"))
        // 未知状态只有分钟数说话
        @Assert(!attMonthIsLate(0, "FUTURE_STATUS"))
        @Assert(attMonthIsLate(1, "FUTURE_STATUS"))
    }

    @TestCase
    func testEarlyPredicate(): Unit {
        @Assert(!attMonthIsEarly(0, "NORMAL"))
        @Assert(attMonthIsEarly(1, "NORMAL"))
        @Assert(attMonthIsEarly(0, "EARLY_LEAVE"))
        @Assert(attMonthIsEarly(0, "LATE_AND_EARLY"))
        @Assert(!attMonthIsEarly(0, "LATE"))
        @Assert(!attMonthIsEarly(0, "ABSENT"))
        @Assert(attMonthIsEarly(9, "ABSENT"))
        @Assert(!attMonthIsEarly(0, ""))
        @Assert(!attMonthIsEarly(-30, "NORMAL"))
        @Assert(!attMonthIsEarly(0, "FUTURE_STATUS"))
        @Assert(attMonthIsEarly(1, "FUTURE_STATUS"))
    }

    @TestCase
    func testLateAndEarlyCountsInBothSides(): Unit {
        // LATE_AND_EARLY 必须同时计入迟到次数与早退次数，否则月度汇总的两列之和会漏掉这类记录
        @Assert(attMonthIsLate(0, "LATE_AND_EARLY"))
        @Assert(attMonthIsEarly(0, "LATE_AND_EARLY"))
        // 但一条记录只会各计 1 次：两个谓词返回 Bool，调用方按记录 +1，不会翻倍
        var lateCnt: Int64 = 0
        var earlyCnt: Int64 = 0
        let st = ArrayList<String>()
        st.add("LATE_AND_EARLY")
        st.add("LATE_AND_EARLY")
        st.add("LATE")
        st.add("EARLY_LEAVE")
        st.add("NORMAL")
        for (s in st) {
            if (attMonthIsLate(0, s)) { lateCnt += 1 }
            if (attMonthIsEarly(0, s)) { earlyCnt += 1 }
        }
        @Assert(lateCnt, 3)
        @Assert(earlyCnt, 3)
    }

    // ---- 2. 出勤率 ----

    @TestCase
    func testAttendanceRateExactValues(): Unit {
        @Assert(attendanceRatePercent(0, 22), 0.0, delta: 0.0)
        @Assert(attendanceRatePercent(22, 22), 100.0, delta: 0.0)
        @Assert(attendanceRatePercent(11, 22), 50.0, delta: 0.0)
        @Assert(attendanceRatePercent(44, 44), 100.0, delta: 0.0)
        // 除数为 0 / 负数一律给 0，不允许抛异常拖垮整张报表
        @Assert(attendanceRatePercent(5, 0), 0.0, delta: 0.0)
        @Assert(attendanceRatePercent(5, -1), 0.0, delta: 0.0)
        @Assert(attendanceRatePercent(0, 0), 0.0, delta: 0.0)
        @Assert(attendanceRatePercent(0, 22), 0.0, delta: 0.0)
        // 负实际天数（理论不可能，防御性）也必须落在 0
        @Assert(attendanceRatePercent(-1, 22), 0.0, delta: 0.0)
        @Assert(attendanceRatePercent(-100, 22), 0.0, delta: 0.0)
        // 超过应出勤（周末补打卡）封顶 100
        @Assert(attendanceRatePercent(23, 22), 100.0, delta: 0.0)
        @Assert(attendanceRatePercent(999, 22), 100.0, delta: 0.0)
    }

    @TestCase
    func testAttendanceRateRoundingAndBounds(): Unit {
        // 20/22 = 90.9090... -> 90.91
        @Assert(attendanceRatePercent(20, 22), 90.91, delta: 0.011)
        // 19/22 = 86.3636... -> 86.36
        @Assert(attendanceRatePercent(19, 22), 86.36, delta: 0.011)
        // 1/22 = 4.5454... -> 4.55（round2 是 half-up，不是截断）
        @Assert(attendanceRatePercent(1, 22), 4.55, delta: 0.011)
        // 输出必须已经落在分上（前端直接展示，不能再出现 90.9090909090909）
        @Assert(attmCentDistance(attendanceRatePercent(20, 22)) <= 0.01)
        @Assert(attmCentDistance(attendanceRatePercent(1, 22)) <= 0.01)
        // 单调不减 + 恒在 [0,100]：扫一遍 -5..60 天
        var badRange: Int64 = 0
        var badMono: Int64 = 0
        var prev = attendanceRatePercent(-5, 22)
        var d: Int64 = -5
        while (d <= 60) {
            let cur = attendanceRatePercent(d, 22)
            if (cur < 0.0 || cur > 100.0) { badRange += 1 }
            if (cur < prev) { badMono += 1 }
            prev = cur
            d = d + 1
        }
        @Assert(badRange, 0)
        @Assert(badMono, 0)
    }

    // ---- 3. 数值文本安全化 ----

    @TestCase
    func testSafeNumberAcceptsPlainNumbers(): Unit {
        @Assert(attMonthSafeNum("0", "X"), "0")
        @Assert(attMonthSafeNum("22", "X"), "22")
        @Assert(attMonthSafeNum("1.50", "X"), "1.50")
        @Assert(attMonthSafeNum("  12.50  ", "X"), "12.50")
        @Assert(attMonthSafeNum("-1.5", "X"), "-1.5")
        @Assert(attMonthSafeNum(".5", "X"), ".5")
        @Assert(attMonthSafeNum("0.0000", "X"), "0.0000")
        @Assert(attMonthSafeNum("9007199254740992", "X"), "9007199254740992")
    }

    @TestCase
    func testSafeNumberRejectsNonJsonNumbers(): Unit {
        // 空串（NULL 的常见形态）必须回退，否则响应体直接非法 JSON
        @Assert(attMonthSafeNum("", "X"), "X")
        @Assert(attMonthSafeNum("   ", "X"), "X")
        @Assert(attMonthSafeNum("\t", "X"), "X")
        // Float64.tryParse 会接受、但 JSON.parse 会报错的写法必须拒绝
        @Assert(attMonthSafeNum("1e5", "X"), "X")
        @Assert(attMonthSafeNum("1E5", "X"), "X")
        @Assert(attMonthSafeNum("NaN", "X"), "X")
        @Assert(attMonthSafeNum("Infinity", "X"), "X")
        @Assert(attMonthSafeNum("-Infinity", "X"), "X")
        // 结构非法
        @Assert(attMonthSafeNum("-", "X"), "X")
        @Assert(attMonthSafeNum("--1", "X"), "X")
        @Assert(attMonthSafeNum("1.2.3", "X"), "X")
        @Assert(attMonthSafeNum(".", "X"), "X")
        @Assert(attMonthSafeNum("12,345", "X"), "X")
        @Assert(attMonthSafeNum("NULL", "X"), "X")
        @Assert(attMonthSafeNum("null", "X"), "X")
        @Assert(attMonthSafeNum("abc", "X"), "X")
        @Assert(attMonthSafeNum("12abc", "X"), "X")
        @Assert(attMonthSafeNum("+5", "X"), "X")
        @Assert(attMonthSafeNum("1 2", "X"), "X")
    }

    // ---- 4. 月份参数校验 ----

    @TestCase
    func testValidYearMonth(): Unit {
        @Assert(isValidYearMonth("2026-11"))
        @Assert(isValidYearMonth("2026-01"))
        @Assert(isValidYearMonth("2026-12"))
        @Assert(isValidYearMonth("2026-09"))
        @Assert(isValidYearMonth("2000-01"))
        @Assert(isValidYearMonth("2999-12"))
    }

    @TestCase
    func testInvalidYearMonth(): Unit {
        @Assert(!isValidYearMonth(""))
        @Assert(!isValidYearMonth("2026-1"))
        @Assert(!isValidYearMonth("2026-0"))
        @Assert(!isValidYearMonth("2026-00"))
        @Assert(!isValidYearMonth("2026-13"))
        @Assert(!isValidYearMonth("2026-19"))
        @Assert(!isValidYearMonth("2026-20"))
        @Assert(!isValidYearMonth("2026-99"))
        @Assert(!isValidYearMonth("2026-11-01"))
        @Assert(!isValidYearMonth("2026/11"))
        @Assert(!isValidYearMonth("2026_11"))
        @Assert(!isValidYearMonth("2026 11"))
        @Assert(!isValidYearMonth(" 2026-11"))
        @Assert(!isValidYearMonth("2026-11 "))
        @Assert(!isValidYearMonth("1026-11"))
        @Assert(!isValidYearMonth("3026-11"))
        @Assert(!isValidYearMonth("202a-11"))
        @Assert(!isValidYearMonth("2026-1b"))
        @Assert(!isValidYearMonth("202-11"))
        @Assert(!isValidYearMonth("2026-111"))
        @Assert(!isValidYearMonth("20261-1"))
        // 注入串：校验不通过 -> 调用方回退到当前月，不会进入 SQL
        @Assert(!isValidYearMonth("2026-11' OR '1'='1"))
        @Assert(!isValidYearMonth("2026-11; DROP TABLE hr_attendance"))
        @Assert(!isValidYearMonth("'2026-11"))
        @Assert(!isValidYearMonth("2026-11--"))
    }

    // ---- 5. 单人月度 JSON ----

    @TestCase
    func testMonthlyRowJsonClean(): Unit {
        let expect = attmExpect("7", "E007", "Chen Siyuan", "Tech", "22", "2", "1", "35", "10", "1.50", "3.00", "100.00")
        @Assert(attMonthlyRowToJson(attmCleanRow()), expect)
        let half = attmExpect("8", "E008", "Li Wen", "HR", "11", "0", "0", "0", "0", "0.50", "2.00", "50.00")
        @Assert(attMonthlyRowToJson(attmHalfRow()), half)
    }

    @TestCase
    func testMonthlyRowJsonEmptyAndGarbage(): Unit {
        // 全空行必须仍然是合法 JSON：数值位全部退化为 0，字符串位退化为 ""
        @Assert(attMonthlyRowToJson(attmEmptyRow()), attmExpect("0", "", "", "", "0", "0", "0", "0", "0", "0.00", "0.00", "0.00"))
        // NULL 文本同样退化，且不影响其它列
        let src = ArrayList<String>()
        src.add("9")
        src.add("E009")
        src.add("Wang")
        src.add("Fin")
        src.add("NULL")
        src.add("")
        src.add("x")
        src.add("1.5")
        src.add("3.00")
        src.add("2")
        // r[4]="NULL" -> 0 天；r[5]="" -> 0；r[6]="x" -> 0；
        // r[7]="1.5" / r[8]="3.00" 是小数文本，Int64.tryParse 失败 -> 0（分钟列必须是整数）；
        // r[9]="2" -> 2.00 天；r[10] 由 attmRow 补成 "x" -> 0.00
        @Assert(attMonthlyRowToJson(attmRow(src)), attmExpect("9", "E009", "Wang", "Fin", "0", "0", "0", "0", "0", "2.00", "0.00", "0.00"))
    }

    @TestCase
    func testMonthlyRowJsonRateMatchesSharedFunction(): Unit {
        // 行内出勤率必须由 attendanceRatePercent 计算，杜绝「两套算法」。
        // 这里用 20/22 这种非整除值，直接和函数结果对齐格式。
        let src = ArrayList<String>()
        src.add("10")
        src.add("E010")
        src.add("Zhao")
        src.add("Tech")
        src.add("20")
        src.add("3")
        src.add("0")
        src.add("45")
        src.add("0")
        src.add("0.00")
        src.add("0.00")
        let rateText = formatNum2(attendanceRatePercent(20, 22))
        @Assert(attMonthlyRowToJson(attmRow(src)), attmExpect("10", "E010", "Zhao", "Tech", "20", "3", "0", "45", "0", "0.00", "0.00", rateText))
        // 20/22 格式化后必须是两位小数的 90.91，而不是 90.9090909090909
        @Assert(rateText, "90.91")
    }

    @TestCase
    func testMonthlyRowJsonQuotingIsSafe(): Unit {
        // 姓名里带双引号/反斜杠时由 jsonStr 负责转义，整串长度会比原文多
        let src = ArrayList<String>()
        src.add("11")
        src.add("E011")
        src.add("A\"B")
        src.add("D")
        src.add("22")
        src.add("0")
        src.add("0")
        src.add("0")
        src.add("0")
        src.add("0.00")
        src.add("0.00")
        let out = attMonthlyRowToJson(attmRow(src))
        // 12 个字段 => 12 个冒号，且转义后不会出现裸的 `,"empName":` 断链
        @Assert(attJsonCountOf(out, ":"), 12)
        @Assert(attJsonCountOf(out, ","), 11)
        @Assert(out.size > 60)
    }

    // ---- 6. 合计行 ----

    @TestCase
    func testMonthlyTotalsEmpty(): Unit {
        let rows = ArrayList<ArrayList<String>>()
        @Assert(attMonthlyTotalsJson(rows), "{\"headcount\":0,\"shouldAttendDays\":22,\"actualAttendDays\":0,\"lateCount\":0,\"earlyCount\":0,\"lateMinutes\":0,\"earlyMinutes\":0,\"leaveDays\":0.00,\"overtimeHours\":0.00,\"attendanceRate\":0.00}")
    }

    @TestCase
    func testMonthlyTotalsSumEqualsDetail(): Unit {
        // 22 + 11 = 33；整体出勤率按 2 人 × 22 天 = 44 计，33/44 = 75.00
        let rows = attmRowsOf(attmCleanRow(), attmHalfRow())
        @Assert(attMonthlyTotalsJson(rows), "{\"headcount\":2,\"shouldAttendDays\":22,\"actualAttendDays\":33,\"lateCount\":2,\"earlyCount\":1,\"lateMinutes\":35,\"earlyMinutes\":10,\"leaveDays\":2.00,\"overtimeHours\":5.00,\"attendanceRate\":75.00}")
    }

    @TestCase
    func testMonthlyTotalsIgnoreGarbageColumns(): Unit {
        // 空行 + 全空行：人数要计入 headcount（这是「在职未打卡」的同事），数字全部按 0 累加
        let rows = attmRowsOf(attmHalfRow(), attmEmptyRow())
        @Assert(attMonthlyTotalsJson(rows), "{\"headcount\":2,\"shouldAttendDays\":22,\"actualAttendDays\":11,\"lateCount\":0,\"earlyCount\":0,\"lateMinutes\":0,\"earlyMinutes\":0,\"leaveDays\":0.50,\"overtimeHours\":2.00,\"attendanceRate\":25.00}")
        // 单行的出勤率与合计口径一致：11/(1*22) = 50.00
        let one = ArrayList<ArrayList<String>>()
        one.add(attmHalfRow())
        @Assert(attMonthlyTotalsJson(one), "{\"headcount\":1,\"shouldAttendDays\":22,\"actualAttendDays\":11,\"lateCount\":0,\"earlyCount\":0,\"lateMinutes\":0,\"earlyMinutes\":0,\"leaveDays\":0.50,\"overtimeHours\":2.00,\"attendanceRate\":50.00}")
    }

    @TestCase
    func testMonthlyTotalsClampAndDecimalAccumulation(): Unit {
        // 两人都超勤（23、22）=> 合计 45/44 => 封顶 100.00
        let a = ArrayList<String>()
        a.add("1")
        a.add("E1")
        a.add("A")
        a.add("D")
        a.add("23")
        a.add("0")
        a.add("0")
        a.add("0")
        a.add("0")
        a.add("0.33")
        a.add("0.67")
        let b = ArrayList<String>()
        b.add("2")
        b.add("E2")
        b.add("B")
        b.add("D")
        b.add("22")
        b.add("0")
        b.add("0")
        b.add("0")
        b.add("0")
        b.add("0.17")
        b.add("0.33")
        @Assert(attMonthlyTotalsJson(attmRowsOf(a, b)), "{\"headcount\":2,\"shouldAttendDays\":22,\"actualAttendDays\":45,\"lateCount\":0,\"earlyCount\":0,\"lateMinutes\":0,\"earlyMinutes\":0,\"leaveDays\":0.50,\"overtimeHours\":1.00,\"attendanceRate\":100.00}")
    }

    // ---- 7. 页面与导出一致性（验收项的直接护栏）----

    @TestCase
    func testTotalsConsistentWithRows(): Unit {
        // 合计的 attendDays 必须等于各行 attendDays 之和：
        // 前端 CSV 先逐行写明细、再写合计行，两边不同源就会在验收时对不上账。
        let rows = attmRowsOf(attmCleanRow(), attmHalfRow())
        var sum: Int64 = 0
        for (r in rows) {
            sum += Int64.tryParse(attMonthSafeNum(r[4], "0")) ?? 0
        }
        let totals = attMonthlyTotalsJson(rows)
        @Assert(sum, 33)
        // 合计行的键数必须与前端读取的字段一一对应：10 个键 => 10 个冒号
        @Assert(attJsonCountOf(totals, ":"), 10)
        @Assert(attJsonCountOf(totals, ","), 9)
        @Assert(attJsonCountOf(totals, ":22"), 1)
        // 合计里的 shouldAttendDays 恒等于 attShouldAttendDays
        @Assert(attShouldAttendDays, 22)
        @Assert(sum, attShouldAttendDays + 11)
    }
}

// 数子串出现次数（不用 String.contains，逐字符比较）
func attJsonCountOf(s: String, needle: String): Int64 {
    if (needle.size == 0 || s.size < needle.size) {
        return 0
    }
    let sb = s.toArray()
    let nb = needle.toArray()
    var cnt: Int64 = 0
    var i: Int64 = 0
    while (i + nb.size <= sb.size) {
        var j: Int64 = 0
        var hit = true
        while (j < nb.size) {
            if (sb[i + j] != nb[j]) {
                hit = false
            }
            j = j + 1
        }
        if (hit) {
            cnt += 1
        }
        i = i + 1
    }
    return cnt
}
