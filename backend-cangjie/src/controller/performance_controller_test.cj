package hrms_backend.controller

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

// =============================================================================
// performance_controller.cj 单元测试（P1.1）
//
// 覆盖两个可脱离 HTTP / 数据库运行的纯函数：
//   public func mapPerformanceGrade(score: Float64): (String, Float64)
//   func          perfRowToJson(r: ArrayList<String>): String   （包内可见）
//
// -----------------------------------------------------------------------------
// 【断言纪律：为什么本文件可以放心使用严格相等】
// 与 payroll_controller_test.cj 相反，这里没有一处经过 round2 / formatNum2：
//   (1) mapPerformanceGrade 直接 `return ("S", 1.20)` —— 系数是源码字面量，
//       测试里写的 1.20 与源码里的 1.20 被同一套字面量解析规则折叠成同一
//       IEEE-754 位模式，因此严格相等是可证的，不需要 delta。
//   (2) 档位判定是纯 Float64 比较（score >= 90.0 ...），不涉及任何舍入，
//       所以边界（含 89.99 / 89.999 这类「离边界 >= 1e-3」的采样点）可以精确 pin。
//   (3) perfRowToJson 只做字符串拼接与 jsonEscape，输出完全确定，
//       因此这里额外放了一条「整段 JSON 逐字符相等」的 golden 断言。
// 唯一仍然只用「性质」而不用「精确值」的，是跨档系数差（0.80-0.50 在二进制下
// 不等于 0.30），这类一律改用大小比较表达。
//
// 【语法纪律】本文件只用基线 src 中已出现、或已确证的构造：
//   ArrayList<String>() + .add() + 下标访问 + .isEmpty() + .replace() + .size；
//   元组只在顶层 let (a, b) = ... 处解构（见 mysql_pool.cj:322）；
//   不使用数组字面量 [a,b,c]、不使用 ._0 / .0、不使用 String.contains、
//   不使用 HashMap、不使用双侧切片 s[0..1]。
//   转义符统一由 perfDq()/perfBs() 拼接，避免手抄反斜杠数错个数。
//
// 未覆盖（交由 P1.2 冒烟脚本 + 数据库集成）：handlePerformanceInitCycle /
// handlePerformanceList / handlePerformanceSelfEval / handlePerformanceReview，
// 均依赖 HttpContext 与 queryRows/queryExecute。
// =============================================================================

// ---- 测试辅助（perf 前缀，避免与同包其它 *_test.cj 顶层符号冲突）----

// 一个双引号字符
func perfDq(): String {
    return "\""
}

// 一个反斜杠字符
func perfBs(): String {
    return "\\"
}

// 真实换行 / 制表符也走函数，用例里读起来更明确
func perfLf(): String {
    return "\n"
}

func perfTab(): String {
    return "\t"
}

// "s"
func perfQ(s: String): String {
    return perfDq() + s + perfDq()
}

// "key":
func perfK(key: String): String {
    return perfDq() + key + perfDq() + ":"
}

// 基线中没有任何 String.contains 的用法，其可用性未证实；
// 这里用「replace 后长度是否变短」等价实现。
func perfHas(s: String, sub: String): Bool {
    if (sub.isEmpty()) {
        return true
    }
    return s.replace(sub, "").size != s.size
}

// 同理，用长度差统计子串出现次数。
func perfCountOf(s: String, needle: String): Int64 {
    if (needle.isEmpty()) {
        return 0
    }
    return (s.size - s.replace(needle, "").size) / needle.size
}

// mapPerformanceGrade 返回元组；元组下标 ._0 在基线里无先例，
// 所以统一在顶层 let 解构后降级成标量。
func perfGradeOf(score: Float64): String {
    let (g, _) = mapPerformanceGrade(score)
    return g
}

func perfRatioOf(score: Float64): Float64 {
    let (_, r) = mapPerformanceGrade(score)
    return r
}

// 15 个字段，长度不足一律补 "x"，保证「传错行数不会静默通过」
func perfRow(nos: ArrayList<String>): ArrayList<String> {
    let r = ArrayList<String>()
    var i: Int64 = 0
    while (i < 15) {
        if (i < nos.size) {
            r.add(nos[i])
        } else {
            r.add("x")
        }
        i = i + 1
    }
    return r
}

// 全空串行（perfRow 的补齐符是 "x"，不能拿来当空串行用）
func perfEmptyRow(): ArrayList<String> {
    let r = ArrayList<String>()
    var i: Int64 = 0
    while (i < 15) {
        r.add("")
        i = i + 1
    }
    return r
}

// 一行完整已评审记录：S 档、奖金系数 1.20
func perfCleanRow(): ArrayList<String> {
    let src = ArrayList<String>()
    src.add("1") // r[0]  id
    src.add("2026-Q4") // r[1]  cycleName
    src.add("7") // r[2]  employeeId
    src.add("E001") // r[3]  empNo
    src.add("Zhang San") // r[4]  empName
    src.add("Tech") // r[5]  deptName
    src.add("Engineer") // r[6]  positionName
    src.add("Delivered P1") // r[7]  selfSummary
    src.add("88.00") // r[8]  selfScore
    src.add("92.50") // r[9]  finalScore
    src.add("S") // r[10] grade
    src.add("1.20") // r[11] bonusRatio
    src.add("Strong delivery") // r[12] reviewerComment
    src.add("REVIEWED") // r[13] status
    src.add("2026-11-05 10:00:00") // r[14] updatedAt
    return perfRow(src)
}

// 一行「自评 / 终评都还没填」的记录：r[8]、r[9] 必须输出裸 null
func perfUnreviewedRow(): ArrayList<String> {
    let src = ArrayList<String>()
    src.add("2")
    src.add("2026-Q4")
    src.add("8")
    src.add("E002")
    src.add("Li Si")
    src.add("HR")
    src.add("Manager")
    src.add("")
    src.add("") // selfScore 空 -> null
    src.add("") // finalScore 空 -> null
    src.add("")
    src.add("1.00")
    src.add("")
    src.add("PENDING")
    src.add("")
    return perfRow(src)
}

// 全 "NULL" 源行（15 个），单独放函数里，避免用例体里堆 15 行 add。
func perfNullSrc(): ArrayList<String> {
    let r = ArrayList<String>()
    var i: Int64 = 0
    while (i < 15) {
        r.add("NULL")
        i = i + 1
    }
    return r
}

// 与 formatNum2 输出口径一致的两位小数文本；这里只需要覆盖 1.20/1.10/1.00/
// 0.80/0.50 五个固定值，直接用档位映射表返回字面量，避免依赖未编译验证的格式化。
func perfRatioText(score: Float64): String {
    let (_, ratio) = mapPerformanceGrade(score)
    if (ratio == 1.20) {
        return "1.20"
    } else if (ratio == 1.10) {
        return "1.10"
    } else if (ratio == 1.00) {
        return "1.00"
    } else if (ratio == 0.80) {
        return "0.80"
    }
    return "0.50"
}

@Test
class PerformancePureFunctionTests {
    // ---- 0. 辅助函数自检：先证明「尺子」本身是准的 ----

    @TestCase
    func testHelperSelfCheck(): Unit {
        @Assert(perfDq().size, 1)
        @Assert(perfBs().size, 1)
        @Assert(perfLf().size, 1)
        @Assert(perfTab().size, 1)
        @Assert((perfBs() + "n").size, 2)
        @Assert((perfDq() + "S" + perfDq()).size, 3)
        @Assert(perfCountOf("a,b,,c", ","), 3)
        @Assert(perfCountOf("abc", ","), 0)
        @Assert(perfCountOf("", ","), 0)
        @Assert(perfCountOf("banana", "na"), 2)
        @Assert(perfCountOf("nullnull", "null"), 2)
        @Assert(perfHas("hello", "ell"))
        @Assert(!perfHas("hello", "xyz"))
        @Assert(perfHas("hello", ""))
        @Assert(perfK("id"), perfDq() + "id" + perfDq() + ":")
        // 行数守卫：补齐到 15，越界不会被静默吞掉
        @Assert(perfRow(ArrayList<String>()).size, 15)
        @Assert(perfRow(ArrayList<String>())[14], "x")
        @Assert(perfCleanRow().size, 15)
        @Assert(perfUnreviewedRow().size, 15)
        @Assert(perfEmptyRow().size, 15)
        @Assert(perfCleanRow()[8], "88.00")
        @Assert(perfUnreviewedRow()[9].size, 0)
    }

    // ---- 1. mapPerformanceGrade：五档边界 ----

    @TestCase
    func testGradeAtHundredIsS(): Unit {
        let (g, r) = mapPerformanceGrade(100.0)
        @Assert(g, "S")
        @Assert(r, 1.20, delta: 0.0)
    }

    @TestCase
    func testGradeBoundaryS(): Unit {
        // 90 分是 S 的下界（score >= 90.0）
        @Assert(perfGradeOf(90.0), "S")
        @Assert(perfRatioOf(90.0), 1.20, delta: 0.0)
        // 89.99 离边界 1e-2，二进制下不可能越过 90.0，可以精确 pin
        @Assert(perfGradeOf(89.99), "A")
        @Assert(perfRatioOf(89.99), 1.10, delta: 0.0)
    }

    @TestCase
    func testGradeBoundaryA(): Unit {
        @Assert(perfGradeOf(80.0), "A")
        @Assert(perfRatioOf(80.0), 1.10, delta: 0.0)
        @Assert(perfGradeOf(79.99), "B")
        @Assert(perfRatioOf(79.99), 1.00, delta: 0.0)
    }

    @TestCase
    func testGradeBoundaryB(): Unit {
        @Assert(perfGradeOf(70.0), "B")
        @Assert(perfRatioOf(70.0), 1.00, delta: 0.0)
        @Assert(perfGradeOf(69.99), "C")
        @Assert(perfRatioOf(69.99), 0.80, delta: 0.0)
    }

    @TestCase
    func testGradeBoundaryC(): Unit {
        @Assert(perfGradeOf(60.0), "C")
        @Assert(perfRatioOf(60.0), 0.80, delta: 0.0)
        @Assert(perfGradeOf(59.99), "D")
        @Assert(perfRatioOf(59.99), 0.50, delta: 0.0)
    }

    @TestCase
    func testGradeBoundaryDeeperThanOneCent(): Unit {
        // 89.999 / 90.001 距边界仍有 1e-3，远大于 Float64 在 90 附近的 ulp
        // （约 1.4e-14），因此归属仍然完全确定。
        @Assert(perfGradeOf(89.999), "A")
        @Assert(perfGradeOf(90.001), "S")
        @Assert(perfGradeOf(59.999), "D")
        @Assert(perfGradeOf(60.001), "C")
        @Assert(perfGradeOf(69.999), "C")
        @Assert(perfGradeOf(70.001), "B")
    }

    @TestCase
    func testGradeInteriorPoints(): Unit {
        @Assert(perfGradeOf(95.0), "S")
        @Assert(perfGradeOf(92.5), "S")
        @Assert(perfGradeOf(85.0), "A")
        @Assert(perfGradeOf(75.0), "B")
        @Assert(perfGradeOf(65.0), "C")
        @Assert(perfGradeOf(55.0), "D")
        @Assert(perfRatioOf(85.0), 1.10, delta: 0.0)
        @Assert(perfRatioOf(75.0), 1.00, delta: 0.0)
        @Assert(perfRatioOf(65.0), 0.80, delta: 0.0)
        @Assert(perfRatioOf(55.0), 0.50, delta: 0.0)
    }

    @TestCase
    func testGradeOutsideNormalRange(): Unit {
        // 分数没做入库校验：> 100 与 < 0 都必须仍然落到某一档，不能掉进
        // 「无档位」的空分支。
        @Assert(perfGradeOf(120.0), "S")
        @Assert(perfGradeOf(1000.0), "S")
        @Assert(perfGradeOf(0.0), "D")
        @Assert(perfGradeOf(-5.0), "D")
        @Assert(perfGradeOf(-100.0), "D")
        @Assert(perfRatioOf(120.0), 1.20, delta: 0.0)
        @Assert(perfRatioOf(-100.0), 0.50, delta: 0.0)
    }

    @TestCase
    func testGradeAllFiveCoefficients(): Unit {
        // 五个系数都是源码字面量原样返回，逐个钉死。
        @Assert(perfRatioOf(90.0), 1.20, delta: 0.0)
        @Assert(perfRatioOf(80.0), 1.10, delta: 0.0)
        @Assert(perfRatioOf(70.0), 1.00, delta: 0.0)
        @Assert(perfRatioOf(60.0), 0.80, delta: 0.0)
        @Assert(perfRatioOf(59.0), 0.50, delta: 0.0)
    }

    @TestCase
    func testGradeCoefficientsStrictlyOrdered(): Unit {
        // 档位越高系数越大；用大小比较而不是「差值等于某个十进制数」，
        // 因为 0.80 - 0.50 在二进制下并不精确等于 0.30。
        @Assert(perfRatioOf(90.0) > perfRatioOf(80.0))
        @Assert(perfRatioOf(80.0) > perfRatioOf(70.0))
        @Assert(perfRatioOf(70.0) > perfRatioOf(60.0))
        @Assert(perfRatioOf(60.0) > perfRatioOf(50.0))
        // B 档必须是 1.00（不加成也不扣减）
        @Assert(perfRatioOf(75.0) == 1.00)
    }

    @TestCase
    func testGradeIsNonDecreasingInScore(): Unit {
        @Assert(perfRatioOf(60.0) >= perfRatioOf(59.99))
        @Assert(perfRatioOf(70.0) >= perfRatioOf(69.99))
        @Assert(perfRatioOf(80.0) >= perfRatioOf(79.99))
        @Assert(perfRatioOf(90.0) >= perfRatioOf(89.99))
        @Assert(perfRatioOf(100.0) >= perfRatioOf(0.0))
        @Assert(perfGradeOf(85.0) != perfGradeOf(75.0))
        @Assert(perfGradeOf(65.0) != perfGradeOf(55.0))
    }

    @TestCase
    func testGradeAlwaysSingleChar(): Unit {
        // 任何输入都必须产出一个且仅一个字母档位，绝不能是空串或 "None"。
        @Assert(perfGradeOf(0.0).size, 1)
        @Assert(perfGradeOf(59.99).size, 1)
        @Assert(perfGradeOf(60.0).size, 1)
        @Assert(perfGradeOf(100.0).size, 1)
        @Assert(perfGradeOf(-7.5).size, 1)
        @Assert(perfGradeOf(33.33).size, 1)
    }

    @TestCase
    func testRatioAlwaysWithinContractRange(): Unit {
        // 契约：系数 ∈ [0.50, 1.20]。纯比较，与舍入无关。
        @Assert(perfRatioOf(0.0) >= 0.50)
        @Assert(perfRatioOf(60.0) >= 0.50)
        @Assert(perfRatioOf(100.0) <= 1.20)
        @Assert(perfRatioOf(999.0) <= 1.20)
        @Assert(perfRatioOf(75.0) <= 1.20)
        @Assert(perfRatioOf(-50.0) >= 0.50)
    }

    @TestCase
    func testWrongBracketWouldBeCaught(): Unit {
        // 反向保护：如果哪天把 80 的分界写成 85、或把 B 档条件丢了，
        // 下面这几条会立刻失败。
        @Assert(perfGradeOf(82.0), "A")
        @Assert(perfGradeOf(78.0), "B")
        @Assert(perfGradeOf(63.0), "C")
        @Assert(perfGradeOf(58.0), "D")
        @Assert(perfGradeOf(91.0), "S")
        @Assert(perfRatioOf(72.0), 1.00, delta: 0.0)
    }

    @TestCase
    func testGradeIsDeterministic(): Unit {
        @Assert(perfGradeOf(92.5), perfGradeOf(92.5))
        @Assert(perfRatioOf(92.5), perfRatioOf(92.5), delta: 0.0)
        @Assert(perfGradeOf(60.0), perfGradeOf(60.0))
        @Assert(perfRatioOf(60.0), perfRatioOf(60.0), delta: 0.0)
    }

    // ---- 2. perfRowToJson：15 字段 -> 恰好 14 个逗号 ----

    @TestCase
    func testRowToJsonGoldenOutput(): Unit {
        // 逐字符钉死整段 JSON —— 纯拼接 + jsonEscape，输出完全确定。
        let expect = "{" +
            perfK("id") + "1" + "," +
            perfK("cycleName") + perfQ("2026-Q4") + "," +
            perfK("employeeId") + "7" + "," +
            perfK("empNo") + perfQ("E001") + "," +
            perfK("empName") + perfQ("Zhang San") + "," +
            perfK("deptName") + perfQ("Tech") + "," +
            perfK("positionName") + perfQ("Engineer") + "," +
            perfK("selfSummary") + perfQ("Delivered P1") + "," +
            perfK("selfScore") + "88.00" + "," +
            perfK("finalScore") + "92.50" + "," +
            perfK("grade") + perfQ("S") + "," +
            perfK("bonusRatio") + "1.20" + "," +
            perfK("reviewerComment") + perfQ("Strong delivery") + "," +
            perfK("status") + perfQ("REVIEWED") + "," +
            perfK("updatedAt") + perfQ("2026-11-05 10:00:00") +
            "}"
        @Assert(perfRowToJson(perfCleanRow()), expect)
    }

    @TestCase
    func testRowToJsonStructureCounts(): Unit {
        let out = perfRowToJson(perfCleanRow())
        @Assert(perfCountOf(out, ","), 14)
        @Assert(perfCountOf(out, "{"), 1)
        @Assert(perfCountOf(out, "}"), 1)
        // 15 个 key 各 2 个引号 = 30；10 个走 jsonStr 的字段各 2 个 = 20
        @Assert(perfCountOf(out, perfDq()), 50)
        // 冒号必须数「引号紧跟冒号」：updatedAt 的值自带 2 个时刻冒号。
        @Assert(perfCountOf(out, perfDq() + ":"), 15)
        @Assert(out.size > 100)
    }

    @TestCase
    func testRowToJsonHasAllKeys(): Unit {
        let out = perfRowToJson(perfCleanRow())
        @Assert(perfHas(out, perfK("id")))
        @Assert(perfHas(out, perfK("cycleName")))
        @Assert(perfHas(out, perfK("employeeId")))
        @Assert(perfHas(out, perfK("empNo")))
        @Assert(perfHas(out, perfK("empName")))
        @Assert(perfHas(out, perfK("deptName")))
        @Assert(perfHas(out, perfK("positionName")))
        @Assert(perfHas(out, perfK("selfSummary")))
        @Assert(perfHas(out, perfK("selfScore")))
        @Assert(perfHas(out, perfK("finalScore")))
        @Assert(perfHas(out, perfK("grade")))
        @Assert(perfHas(out, perfK("bonusRatio")))
        @Assert(perfHas(out, perfK("reviewerComment")))
        @Assert(perfHas(out, perfK("status")))
        @Assert(perfHas(out, perfK("updatedAt")))
    }

    @TestCase
    func testRowToJsonNumericFieldsAreBare(): Unit {
        // r[0] id / r[2] employeeId / r[11] bonusRatio 恒为裸插值；
        // r[8] selfScore / r[9] finalScore 非空时也是裸插值。
        let out = perfRowToJson(perfCleanRow())
        @Assert(perfHas(out, perfK("id") + "1" + ","))
        @Assert(perfHas(out, perfK("employeeId") + "7" + ","))
        @Assert(perfHas(out, perfK("bonusRatio") + "1.20" + ","))
        @Assert(perfHas(out, perfK("selfScore") + "88.00" + ","))
        @Assert(perfHas(out, perfK("finalScore") + "92.50" + ","))
        // 裸字段绝不能被加引号
        @Assert(!perfHas(out, perfK("id") + perfDq()))
        @Assert(!perfHas(out, perfK("employeeId") + perfDq()))
        @Assert(!perfHas(out, perfK("bonusRatio") + perfDq()))
        @Assert(!perfHas(out, perfK("selfScore") + perfDq()))
        @Assert(!perfHas(out, perfK("finalScore") + perfDq()))
    }

    @TestCase
    func testRowToJsonStringFieldsAreQuoted(): Unit {
        let out = perfRowToJson(perfCleanRow())
        @Assert(perfHas(out, perfK("cycleName") + perfQ("2026-Q4") + ","))
        @Assert(perfHas(out, perfK("empNo") + perfQ("E001") + ","))
        @Assert(perfHas(out, perfK("empName") + perfQ("Zhang San") + ","))
        @Assert(perfHas(out, perfK("deptName") + perfQ("Tech") + ","))
        @Assert(perfHas(out, perfK("positionName") + perfQ("Engineer") + ","))
        @Assert(perfHas(out, perfK("selfSummary") + perfQ("Delivered P1") + ","))
        @Assert(perfHas(out, perfK("grade") + perfQ("S") + ","))
        @Assert(perfHas(out, perfK("reviewerComment") + perfQ("Strong delivery") + ","))
        @Assert(perfHas(out, perfK("status") + perfQ("REVIEWED") + ","))
        // updatedAt 是最后一个字段：值后紧跟 '}' 而不是 ','
        @Assert(perfHas(out, perfK("updatedAt") + perfQ("2026-11-05 10:00:00") + "}"))
    }

    @TestCase
    func testRowToJsonEmptyScoresBecomeBareNull(): Unit {
        let out = perfRowToJson(perfUnreviewedRow())
        @Assert(perfHas(out, perfK("selfScore") + "null" + ","))
        @Assert(perfHas(out, perfK("finalScore") + "null" + ","))
        @Assert(perfCountOf(out, "null"), 2)
        // null 绝不能被写成字符串 "null"——前端会拿到字符串而不是 number
        @Assert(!perfHas(out, perfK("selfScore") + perfDq()))
        @Assert(!perfHas(out, perfK("finalScore") + perfDq()))
        @Assert(!perfHas(out, perfDq() + "null" + perfDq()))
    }

    @TestCase
    func testRowToJsonEmptyScoresKeepStructure(): Unit {
        // 少两个「值引号」不可能发生（score 走裸插值），所以引号总数不变；
        // 逗号与 key 数必须与完整行完全一致。
        let a = perfRowToJson(perfCleanRow())
        let b = perfRowToJson(perfUnreviewedRow())
        @Assert(perfCountOf(b, perfDq()), 50)
        @Assert(perfCountOf(b, ","), perfCountOf(a, ","))
        @Assert(perfCountOf(b, ","), 14)
        @Assert(perfCountOf(b, perfDq() + ":"), perfCountOf(a, perfDq() + ":"))
        @Assert(perfCountOf(b, perfDq() + ":"), 15)
        @Assert(perfCountOf(b, "{"), 1)
        @Assert(perfCountOf(b, "}"), 1)
    }

    @TestCase
    func testRowToJsonEmptyStringFieldsStillProduceValidShape(): Unit {
        let out = perfRowToJson(perfEmptyRow())
        @Assert(perfCountOf(out, ","), 14)
        @Assert(perfCountOf(out, perfDq()), 50)
        @Assert(perfCountOf(out, perfDq() + ":"), 15)
        @Assert(perfCountOf(out, "null"), 2)
        @Assert(perfHas(out, perfK("cycleName") + perfDq() + perfDq() + ","))
        @Assert(perfHas(out, perfK("updatedAt") + perfDq() + perfDq() + "}"))
        // 数字列空串时裸插值会产出非法 JSON（`"id":,`）——这是已知契约：
        // 数字列在 MySQL 侧是 NOT NULL，永远不会为空。这里钉住行为，
        // 防止有人顺手把它改成 jsonNullableStr 而丢掉裸数值语义。
        @Assert(perfHas(out, perfK("id") + ","))
    }

    @TestCase
    func testRowToJsonEscapesQuoteAndControlChars(): Unit {
        let src = ArrayList<String>()
        src.add("3")
        src.add("2026-Q1")
        src.add("9")
        src.add("E009")
        src.add("O" + perfDq() + "Brien")
        src.add("R&D")
        src.add("Eng")
        src.add("a" + perfLf() + "b")
        src.add("70.00")
        src.add("75.50")
        src.add("B")
        src.add("1.00")
        src.add("ok")
        src.add("REVIEWED")
        src.add("a" + perfBs() + "b")
        let out = perfRowToJson(perfRow(src))
        // 真实控制符绝不允许出现在 JSON 文本里，必须两字符转义
        @Assert(perfCountOf(out, perfLf()), 0)
        @Assert(perfCountOf(out, perfTab()), 0)
        @Assert(perfHas(out, perfDq() + "O" + perfBs() + perfDq() + "Brien" + perfDq()))
        @Assert(perfHas(out, perfDq() + "a" + perfBs() + "nb" + perfDq()))
        @Assert(perfHas(out, perfDq() + "a" + perfBs() + perfBs() + "b" + perfDq()))
        @Assert(perfHas(out, perfQ("R&D")))
        @Assert(perfCountOf(out, ","), 14)
        // 引号：30(key) + 20(jsonStr) + 1(字段内被转义的引号) = 51
        @Assert(perfCountOf(out, perfDq()), 51)
        // 反斜杠：O"Brien 用 1 个，a<LF>b 用 1 个，a\b 的 1 个变 2 个 -> 共 4
        @Assert(perfCountOf(out, perfBs()), 4)
    }

    @TestCase
    func testRowToJsonPassesMysqlNullLiteralThrough(): Unit {
        // mysql --batch -N 下 NULL 列输出字符串 "NULL"。
        // 裸插值 -> `"id":NULL`（前端 JSON.parse 会报错），
        // jsonStr -> `"empName":"NULL"`（前端拿到字符串 "NULL"）。
        // 这里钉住两种行为，防止误改其中一侧。
        let out = perfRowToJson(perfRow(perfNullSrc()))
        @Assert(perfHas(out, perfK("id") + "NULL" + ","))
        @Assert(perfHas(out, perfK("employeeId") + "NULL" + ","))
        @Assert(perfHas(out, perfK("bonusRatio") + "NULL" + ","))
        @Assert(perfHas(out, perfK("selfScore") + "NULL" + ","))
        @Assert(perfHas(out, perfK("finalScore") + "NULL" + ","))
        @Assert(perfHas(out, perfK("empName") + perfQ("NULL") + ","))
        @Assert(perfHas(out, perfK("updatedAt") + perfQ("NULL") + "}"))
        @Assert(perfCountOf(out, ","), 14)
        @Assert(perfCountOf(out, perfDq()), 50)
        // "NULL" 不是 "null"：空分值分支只判 isEmpty，不该把 NULL 也变 null
        @Assert(perfCountOf(out, "null"), 0)
        @Assert(perfCountOf(out, "NULL"), 15)
    }

    @TestCase
    func testRowToJsonIsDeterministicAndDistinct(): Unit {
        @Assert(perfRowToJson(perfCleanRow()), perfRowToJson(perfCleanRow()))
        @Assert(perfRowToJson(perfUnreviewedRow()), perfRowToJson(perfUnreviewedRow()))
        @Assert(perfRowToJson(perfRow(ArrayList<String>())).size > 0)
        @Assert(perfRowToJson(perfCleanRow()) != perfRowToJson(perfUnreviewedRow()))
        @Assert(perfRowToJson(perfCleanRow()) != perfRowToJson(perfEmptyRow()))
        @Assert(perfRowToJson(perfUnreviewedRow()) != perfRowToJson(perfEmptyRow()))
    }

    @TestCase
    func testRowToJsonUnicodePassesThrough(): Unit {
        // 中文不做 \uXXXX 转义，原样输出。
        let src = ArrayList<String>()
        src.add("5")
        src.add("2026-Q4")
        src.add("12")
        src.add("E012")
        src.add("张三")
        src.add("研发部")
        src.add("工程师")
        src.add("完成三个模块")
        src.add("90.00")
        src.add("95.00")
        src.add("S")
        src.add("1.20")
        src.add("优秀")
        src.add("REVIEWED")
        src.add("2026-11-30 18:00:00")
        let out = perfRowToJson(perfRow(src))
        @Assert(perfHas(out, perfQ("张三")))
        @Assert(perfHas(out, perfQ("研发部")))
        @Assert(perfHas(out, perfQ("工程师")))
        @Assert(perfHas(out, perfQ("完成三个模块")))
        @Assert(perfHas(out, perfQ("优秀")))
        @Assert(!perfHas(out, "u5f20"))
        @Assert(perfCountOf(out, ","), 14)
        @Assert(perfCountOf(out, perfDq()), 50)
    }

    @TestCase
    func testRowToJsonOnlyOneScoreMissing(): Unit {
        // selfScore 已填、finalScore 未填：一个是数字、一个是 null，
        // 两个分支必须各自独立生效（防止误写成同一个 r[8] 判两次）。
        let src = ArrayList<String>()
        src.add("6")
        src.add("2026-Q4")
        src.add("13")
        src.add("E013")
        src.add("Wang Wu")
        src.add("Ops")
        src.add("Analyst")
        src.add("done")
        src.add("85.00")
        src.add("")
        src.add("")
        src.add("1.00")
        src.add("")
        src.add("SELF_DONE")
        src.add("")
        let out = perfRowToJson(perfRow(src))
        @Assert(perfHas(out, perfK("selfScore") + "85.00" + ","))
        @Assert(perfHas(out, perfK("finalScore") + "null" + ","))
        @Assert(perfCountOf(out, "null"), 1)
        @Assert(perfCountOf(out, ","), 14)
    }

    @TestCase
    func testGradeMatchesCoefficientStoredInRow(): Unit {
        // 行里的 grade / bonusRatio 必须与 mapPerformanceGrade(finalScore)
        // 一致 —— 钉住「写入侧」与「读取侧」用的是同一套映射。
        let finalScore = 92.50
        @Assert(perfCleanRow()[10], perfGradeOf(finalScore))
        @Assert(perfCleanRow()[11], perfRatioText(finalScore))
        @Assert(perfUnreviewedRow()[11], "1.00")
    }
}
