package hrms_backend.common

import std.unittest.*
import std.unittest.testmacro.*
import stdx.encoding.json.*

// =============================================================================
// response.cj 单元测试（P1.1）
//
// 与被测源码同目录、同 package；response.cj 中的纯函数全部为 public。
//
// 覆盖范围说明：
//   sendJson / sendOk / sendOkMsg / sendErr / sendPage / sendJsonWithToken /
//   addCorsHeaders / readRequestBody / getQueryStr / getQueryInt
//   依赖 stdx.net.http.HttpContext（单测无法构造，且其构造方式未经证实），
//   故不在本文件覆盖，改由 P1.2 接口冒烟脚本覆盖。
//
// ★ 浮点断言纪律（重要，勿凭记忆放宽）★
//   formatNum2 / round2 都使用 `Int64(abs * 100.0 + 0.5)`，
//   而仓颉 Float64 -> Int64 的转换语义（向零截断 vs 四舍六入五成双）
//   在本次接管环境中「未经官方文档证实」，且无 SDK 可实机验证。
//   令 y = |v| * 100：仅当 frac(y) ∈ [0.5, 1.0)，或 frac(y) == 0 且 y 为偶数时，
//   两种语义结果一致，才可以精确断言；其余取值一律只断言误差界。
//   安全取值表见 FOLLOWUP_PLAN.md 第 12.5 节。
// =============================================================================

// ---- 转义相关字面量：用拼接函数生成，避免手抄反斜杠数错字符 ----
func respBs(): String {
    return "\\"
}

func respDq(): String {
    return "\""
}

func respQ(s: String): String {
    return respDq() + s + respDq()
}

let RESP_BS = respBs() // 1 字符
let RESP_DQ = respDq() // 1 字符

// 待转义输入（全部纯 ASCII，可安全使用 .size）
let RESP_IN_BS = "a" + respBs() + "b" // 3
let RESP_IN_DQ = "a" + respDq() + "b" // 3
let RESP_IN_BOTH = "a" + respBs() + respDq() + "b" // 4
let RESP_IN_NL = "a\nb" // 3
let RESP_IN_TAB = "a\tb" // 3
let RESP_IN_CR = "a\rb" // 3

// 期望输出
let RESP_OUT_BS = "a" + respBs() + respBs() + "b" // 4
let RESP_OUT_DQ = "a" + respBs() + respDq() + "b" // 4
let RESP_OUT_BOTH = "a" + respBs() + respBs() + respBs() + respDq() + "b" // 6
let RESP_OUT_NL = "a" + respBs() + "nb" // 4
let RESP_OUT_TAB = "a" + respBs() + "tb" // 4
let RESP_OUT_CR = "a" + respBs() + "rb" // 4

let RESP_PLAIN = "hello world 123"
let RESP_DEF_STR = "<<D>>"
let RESP_DEF_I: Int64 = -99
let RESP_DEF_F: Float64 = -99.5
let RESP_DEF_B = true

// ---- JSON 对象体（覆盖 getJson* 的全部分支）----
func respKV(key: String, value: String): String {
    return respQ(key) + ":" + value
}

func respObjBody(): String {
    var out = "{"
    out = out + respKV("i", "7")
    out = out + "," + respKV("f", "2.5")
    out = out + "," + respKV("nf", "-2.5")
    out = out + "," + respKV("half", "1.5")
    out = out + "," + respKV("s", respQ("42"))
    out = out + "," + respKV("neg", respQ("-13"))
    out = out + "," + respKV("empty", respQ(""))
    out = out + "," + respKV("sp", respQ(" 42 "))
    out = out + "," + respKV("b", "true")
    out = out + "," + respKV("fb", "false")
    out = out + "," + respKV("n", "null")
    out = out + "," + respKV("a", "[1,2]")
    out = out + "," + respKV("o", "{" + respKV("k", respQ("v")) + "}")
    out = out + "," + respKV("z", "0")
    out = out + "," + respKV("t1", respQ("1"))
    out = out + "," + respKV("t0", respQ("0"))
    out = out + "," + respKV("tTrue", respQ("TRUE"))
    out = out + "," + respKV("tFalse", respQ("False"))
    out = out + "," + respKV("tYes", respQ("yes"))
    out = out + "}"
    return out
}

// ---- 通用测试辅助（名字带 resp 前缀，避免与同包其它 *_test.cj 顶层符号冲突）----

// Option<JsonObject> 降级：None 时给一个空对象，便于「取到默认值即说明 None」的断言
func respObjOrEmpty(body: String): JsonObject {
    match (parseJsonObject(body)) {
        case Some(o) => return o
        case None => return JsonValue.fromStr("{}").asObject()
    }
}

func respParseCode(body: String): Int64 {
    match (parseJsonObject(body)) {
        case Some(_) => return 1
        case None => return 0
    }
}

// 不依赖未经证实的 String.contains：出现次数 = 长度差 / needle 长度
func respCountOf(s: String, needle: String): Int64 {
    if (needle.isEmpty()) {
        return 0
    }
    return (s.size - s.replace(needle, "").size) / needle.size
}

func respAfterDot(s: String): String {
    let parts = s.split(".")
    if (parts.size != 2) {
        return ""
    }
    return parts[1]
}

// 自带绝对值，避免引入未经使用的 std.math
func respAbs(v: Float64): Float64 {
    return if (v < 0.0) {
        -v
    } else {
        v
    }
}

@Test
class ResponseTests {
    // ------------------------------------------------------------------
    // 0. 字面量自检：这里红了，说明下面所有用例的输入都不成立
    // ------------------------------------------------------------------
    @TestCase
    func testLiteralSelfCheck(): Unit {
        @Assert(RESP_BS.size, 1)
        @Assert(RESP_DQ.size, 1)
        @Assert(RESP_IN_BS.size, 3)
        @Assert(RESP_IN_DQ.size, 3)
        @Assert(RESP_IN_BOTH.size, 4)
        @Assert(RESP_IN_NL.size, 3)
        @Assert(RESP_IN_TAB.size, 3)
        @Assert(RESP_IN_CR.size, 3)
        @Assert(RESP_OUT_BS.size, 4)
        @Assert(RESP_OUT_DQ.size, 4)
        @Assert(RESP_OUT_BOTH.size, 6)
        @Assert(RESP_OUT_NL.size, 4)
        @Assert(RESP_OUT_TAB.size, 4)
        @Assert(RESP_OUT_CR.size, 4)
        @Assert(RESP_PLAIN.size, 15)
    }

    // ------------------------------------------------------------------
    // 1. jsonEscape：反斜杠 / 引号 / 控制符
    // ------------------------------------------------------------------
    @TestCase
    func testJsonEscapeBackslash(): Unit {
        @Assert(jsonEscape(RESP_BS), RESP_BS + RESP_BS)
        @Assert(jsonEscape(RESP_IN_BS), RESP_OUT_BS)
        @Assert(jsonEscape(RESP_BS + RESP_BS), RESP_BS + RESP_BS + RESP_BS + RESP_BS)
    }

    @TestCase
    func testJsonEscapeQuote(): Unit {
        @Assert(jsonEscape(RESP_DQ), RESP_BS + RESP_DQ)
        @Assert(jsonEscape(RESP_IN_DQ), RESP_OUT_DQ)
        @Assert(respCountOf(jsonEscape(RESP_DQ + RESP_DQ), RESP_BS + RESP_DQ), 2)
    }

    // 顺序敏感：必须先转义反斜杠，再转义引号，否则引号产生的反斜杠会被二次转义
    @TestCase
    func testJsonEscapeBackslashThenQuote(): Unit {
        @Assert(jsonEscape(RESP_IN_BOTH), RESP_OUT_BOTH)
        @Assert(jsonEscape(RESP_BS + RESP_DQ), RESP_BS + RESP_BS + RESP_BS + RESP_DQ)
        @Assert(jsonEscape(RESP_OUT_BS), "a" + RESP_BS + RESP_BS + RESP_BS + RESP_BS + "b")
    }

    @TestCase
    func testJsonEscapeControlCharacters(): Unit {
        @Assert(jsonEscape(RESP_IN_NL), RESP_OUT_NL)
        @Assert(jsonEscape(RESP_IN_TAB), RESP_OUT_TAB)
        @Assert(jsonEscape(RESP_IN_CR), RESP_OUT_CR)
        // 反向：转义后不应再残留裸控制符
        @Assert(respCountOf(jsonEscape(RESP_IN_NL), "\n"), 0)
        @Assert(respCountOf(jsonEscape(RESP_IN_TAB), "\t"), 0)
        @Assert(respCountOf(jsonEscape(RESP_IN_CR), "\r"), 0)
    }

    @TestCase
    func testJsonEscapePlainAsciiUnchanged(): Unit {
        @Assert(jsonEscape(RESP_PLAIN), RESP_PLAIN)
        @Assert(jsonEscape(""), "")
        @Assert(jsonEscape("{}[]:,"), "{}[]:,")
    }

    // 语义无关的长度性质：转义只会变长或等长
    @TestCase
    func testJsonEscapeNeverShrinks(): Unit {
        @Assert(jsonEscape(RESP_IN_BS).size >= RESP_IN_BS.size, true)
        @Assert(jsonEscape(RESP_IN_DQ).size >= RESP_IN_DQ.size, true)
        @Assert(jsonEscape(RESP_IN_BOTH).size >= RESP_IN_BOTH.size, true)
        @Assert(jsonEscape(RESP_PLAIN).size, RESP_PLAIN.size)
    }

    // ------------------------------------------------------------------
    // 2. jsonStr / jsonNullableStr
    // ------------------------------------------------------------------
    @TestCase
    func testJsonStrWrapsQuotes(): Unit {
        @Assert(jsonStr(RESP_PLAIN), RESP_DQ + RESP_PLAIN + RESP_DQ)
        @Assert(jsonStr(RESP_IN_DQ), RESP_DQ + RESP_OUT_DQ + RESP_DQ)
        @Assert(jsonStr(""), RESP_DQ + RESP_DQ)
        @Assert(jsonStr(RESP_IN_DQ).size, 6)
    }

    @TestCase
    func testJsonNullableStr(): Unit {
        @Assert(jsonNullableStr(""), "null")
        @Assert(jsonNullableStr(RESP_PLAIN), RESP_DQ + RESP_PLAIN + RESP_DQ)
        @Assert(jsonNullableStr("null"), RESP_DQ + "null" + RESP_DQ)
        // 空串走 null 分支，绝不能带引号
        @Assert(respCountOf(jsonNullableStr(""), RESP_DQ), 0)
    }

    // ------------------------------------------------------------------
    // 3. parseJsonObject
    // ------------------------------------------------------------------
    @TestCase
    func testParseJsonObjectAcceptsObject(): Unit {
        @Assert(respParseCode(respObjBody()), 1)
        @Assert(respParseCode("{" + respKV("k", "1") + "}"), 1)
        // trimAscii 后再解析：首尾空白不影响结果
        @Assert(respParseCode("  " + respObjBody() + "\r\n"), 1)
        let obj = respObjOrEmpty(respObjBody())
        @Assert(getJsonInt(obj, "i", RESP_DEF_I), 7)
    }

    @TestCase
    func testParseJsonObjectRejectsNonObjects(): Unit {
        @Assert(respParseCode(""), 0)
        @Assert(respParseCode("   "), 0)
        @Assert(respParseCode("\t\n "), 0)
        @Assert(respParseCode("[1,2]"), 0)
        @Assert(respParseCode("123"), 0)
        @Assert(respParseCode("true"), 0)
        @Assert(respParseCode("\"str\""), 0)
        @Assert(respParseCode("not json"), 0)
        @Assert(respParseCode("{"), 0)
        @Assert(respParseCode("{\"k\":"), 0)
    }

    // None 与「空对象」的区分：空对象取任何键都得默认值
    @TestCase
    func testParseJsonObjectNoneIsNotEmptyObject(): Unit {
        let empty = respObjOrEmpty("[1,2]")
        @Assert(getJsonStr(empty, "i", RESP_DEF_STR), RESP_DEF_STR)
        @Assert(getJsonInt(empty, "i", RESP_DEF_I), RESP_DEF_I)
        let real = respObjOrEmpty(respObjBody())
        @Assert(getJsonStr(real, "i", RESP_DEF_STR), "7")
    }

    // ------------------------------------------------------------------
    // 4. getJsonStr
    // ------------------------------------------------------------------
    @TestCase
    func testGetJsonStrBranches(): Unit {
        let o = respObjOrEmpty(respObjBody())
        @Assert(getJsonStr(o, "s", RESP_DEF_STR), "42")
        @Assert(getJsonStr(o, "empty", RESP_DEF_STR), "")
        @Assert(getJsonStr(o, "sp", RESP_DEF_STR), " 42 ")
        @Assert(getJsonStr(o, "i", RESP_DEF_STR), "7")
        // JsFloat / JsBool 走字符串插值，其格式未经证实 -> 只断言「不是默认值且非空」
        @Assert(getJsonStr(o, "f", RESP_DEF_STR) != RESP_DEF_STR, true)
        @Assert(getJsonStr(o, "f", RESP_DEF_STR).size > 0, true)
        @Assert(getJsonStr(o, "b", RESP_DEF_STR) != RESP_DEF_STR, true)
        // JsNull / JsArray / JsObject -> case _ -> def
        @Assert(getJsonStr(o, "n", RESP_DEF_STR), RESP_DEF_STR)
        @Assert(getJsonStr(o, "a", RESP_DEF_STR), RESP_DEF_STR)
        @Assert(getJsonStr(o, "o", RESP_DEF_STR), RESP_DEF_STR)
        @Assert(getJsonStr(o, "missing", RESP_DEF_STR), RESP_DEF_STR)
    }

    // ------------------------------------------------------------------
    // 5. getJsonInt（含 Int64(Float64) 语义风险，仅用安全取值 2.5 / -2.5）
    // ------------------------------------------------------------------
    @TestCase
    func testGetJsonIntBranches(): Unit {
        let o = respObjOrEmpty(respObjBody())
        @Assert(getJsonInt(o, "i", RESP_DEF_I), 7)
        @Assert(getJsonInt(o, "z", RESP_DEF_I), 0)
        // 2.5 是「.5 平局」：截断与四舍六入五成双同为 2
        @Assert(getJsonInt(o, "f", RESP_DEF_I), 2)
        @Assert(getJsonInt(o, "nf", RESP_DEF_I), -2)
        @Assert(getJsonInt(o, "s", RESP_DEF_I), 42)
        @Assert(getJsonInt(o, "neg", RESP_DEF_I), -13)
        @Assert(getJsonInt(o, "sp", RESP_DEF_I), 42)
        @Assert(getJsonInt(o, "empty", RESP_DEF_I), RESP_DEF_I)
        @Assert(getJsonInt(o, "tYes", RESP_DEF_I), RESP_DEF_I)
        @Assert(getJsonInt(o, "b", RESP_DEF_I), 1)
        @Assert(getJsonInt(o, "fb", RESP_DEF_I), 0)
        @Assert(getJsonInt(o, "n", RESP_DEF_I), RESP_DEF_I)
        @Assert(getJsonInt(o, "a", RESP_DEF_I), RESP_DEF_I)
        @Assert(getJsonInt(o, "o", RESP_DEF_I), RESP_DEF_I)
        @Assert(getJsonInt(o, "missing", RESP_DEF_I), RESP_DEF_I)
    }

    // ------------------------------------------------------------------
    // 6. getJsonFloat
    // ------------------------------------------------------------------
    @TestCase
    func testGetJsonFloatBranches(): Unit {
        let o = respObjOrEmpty(respObjBody())
        @Assert(getJsonFloat(o, "f", RESP_DEF_F), 2.5, delta: 0.0001)
        @Assert(getJsonFloat(o, "nf", RESP_DEF_F), -2.5, delta: 0.0001)
        @Assert(getJsonFloat(o, "half", RESP_DEF_F), 1.5, delta: 0.0001)
        @Assert(getJsonFloat(o, "i", RESP_DEF_F), 7.0, delta: 0.0001)
        @Assert(getJsonFloat(o, "z", RESP_DEF_F), 0.0, delta: 0.0001)
        @Assert(getJsonFloat(o, "s", RESP_DEF_F), 42.0, delta: 0.0001)
        @Assert(getJsonFloat(o, "neg", RESP_DEF_F), -13.0, delta: 0.0001)
        @Assert(getJsonFloat(o, "sp", RESP_DEF_F), 42.0, delta: 0.0001)
        @Assert(getJsonFloat(o, "empty", RESP_DEF_F), RESP_DEF_F, delta: 0.0001)
        @Assert(getJsonFloat(o, "b", RESP_DEF_F), RESP_DEF_F, delta: 0.0001)
        @Assert(getJsonFloat(o, "n", RESP_DEF_F), RESP_DEF_F, delta: 0.0001)
        @Assert(getJsonFloat(o, "a", RESP_DEF_F), RESP_DEF_F, delta: 0.0001)
        @Assert(getJsonFloat(o, "missing", RESP_DEF_F), RESP_DEF_F, delta: 0.0001)
    }

    // ------------------------------------------------------------------
    // 7. getJsonBool
    // ------------------------------------------------------------------
    @TestCase
    func testGetJsonBoolBranches(): Unit {
        let o = respObjOrEmpty(respObjBody())
        @Assert(getJsonBool(o, "b", !RESP_DEF_B), true)
        @Assert(getJsonBool(o, "fb", RESP_DEF_B), false)
        @Assert(getJsonBool(o, "i", false), true)
        @Assert(getJsonBool(o, "z", true), false)
        @Assert(getJsonBool(o, "t1", false), true)
        @Assert(getJsonBool(o, "t0", true), false)
        @Assert(getJsonBool(o, "tTrue", false), true)
        @Assert(getJsonBool(o, "tFalse", true), false)
        @Assert(getJsonBool(o, "tYes", RESP_DEF_B), RESP_DEF_B)
        @Assert(getJsonBool(o, "empty", RESP_DEF_B), RESP_DEF_B)
        @Assert(getJsonBool(o, "s", RESP_DEF_B), RESP_DEF_B)
        @Assert(getJsonBool(o, "n", RESP_DEF_B), RESP_DEF_B)
        @Assert(getJsonBool(o, "a", RESP_DEF_B), RESP_DEF_B)
        @Assert(getJsonBool(o, "o", RESP_DEF_B), RESP_DEF_B)
        @Assert(getJsonBool(o, "missing", RESP_DEF_B), RESP_DEF_B)
    }

    // ------------------------------------------------------------------
    // 8. formatNum2 —— 精确断言只用「两种舍入语义同解」的安全取值
    //    （下表中每个取值都用 IEEE-754 实算核验过 frac(|v|*100) 的落点，
    //      注意 8.745 之类「看似 .5 平局」的十进制数在二进制里其实是
    //      874.4999999999999，属于不安全取值，已剔除）
    // ------------------------------------------------------------------
    @TestCase
    func testFormatNum2SafeValues(): Unit {
        @Assert(formatNum2(0.0), "0.00")
        @Assert(formatNum2(0.5), "0.50")
        @Assert(formatNum2(1.5), "1.50")
        @Assert(formatNum2(1.9), "1.90")
        @Assert(formatNum2(2.5), "2.50")
        @Assert(formatNum2(7.0), "7.00")
        @Assert(formatNum2(20.0), "20.00")
        @Assert(formatNum2(45.6), "45.60")
        @Assert(formatNum2(12.5), "12.50")
        @Assert(formatNum2(100.0), "100.00")
        @Assert(formatNum2(-100.0), "-100.00")
        @Assert(formatNum2(0.125), "0.13")
        @Assert(formatNum2(0.135), "0.14")
        @Assert(formatNum2(0.505), "0.51")
        @Assert(formatNum2(0.615), "0.62")
        @Assert(formatNum2(2.675), "2.68")
        @Assert(formatNum2(8.355), "8.36")
        @Assert(formatNum2(-8.355), "-8.36")
        @Assert(formatNum2(1.236), "1.24")
        @Assert(formatNum2(3.146), "3.15")
        @Assert(formatNum2(1234.5678), "1234.57")
        @Assert(formatNum2(0.006), "0.01")
        @Assert(formatNum2(-0.006), "-0.01")
        @Assert(formatNum2(99.999), "100.00")
        @Assert(formatNum2(999999.996), "1000000.00")
    }

    // cents == 0 时不加负号（源码 prefix 条件为 neg && cents > 0）
    @TestCase
    func testFormatNum2ZeroSignDropped(): Unit {
        @Assert(formatNum2(-0.0), "0.00")
        @Assert(formatNum2(0.0), "0.00")
        // -0.0 参与比较时 -0.0 < 0.0 为假，因此不会带上负号
        @Assert(respCountOf(formatNum2(-0.0), "-"), 0)
        // 真正落到非零 cents 的负数必须带负号
        @Assert(respCountOf(formatNum2(-0.006), "-"), 1)
        @Assert(respCountOf(formatNum2(-100.0), "-"), 1)
        // 0.004 是不安全取值（frac(y)=0.4）：只断言两种语义下的可能集合
        @Assert(formatNum2(0.004) == "0.00" || formatNum2(0.004) == "0.01", true)
    }

    // 结构性质：与舍入语义无关，恰好一个小数点、点后恰好两位
    @TestCase
    func testFormatNum2Structure(): Unit {
        let samples = [0.0, 1.0, 0.5, 1.234, 3.14159, -2.675, 0.004, 99.999, 1234.5678]
        for (v in samples) {
            let s = formatNum2(v)
            @Assert(respCountOf(s, "."), 1)
            @Assert(respAfterDot(s).size, 2)
            @Assert(s.size >= 4, true)
        }
    }

    // ------------------------------------------------------------------
    // 9. round2
    // ------------------------------------------------------------------
    @TestCase
    func testRound2SafeValues(): Unit {
        @Assert(round2(0.0), 0.0, delta: 0.0001)
        @Assert(round2(0.5), 0.5, delta: 0.0001)
        @Assert(round2(1.5), 1.5, delta: 0.0001)
        @Assert(round2(100.0), 100.0, delta: 0.0001)
        @Assert(round2(0.125), 0.13, delta: 0.0001)
        @Assert(round2(8.355), 8.36, delta: 0.0001)
        @Assert(round2(-8.355), -8.36, delta: 0.0001)
        @Assert(round2(2.675), 2.68, delta: 0.0001)
        @Assert(round2(1.236), 1.24, delta: 0.0001)
        @Assert(round2(1234.5678), 1234.57, delta: 0.0001)
        @Assert(round2(999999.996), 1000000.0, delta: 0.0001)
    }

    // 语义无关的兜底：任意输入都落在「两位小数」的误差界内
    @TestCase
    func testRound2ErrorBound(): Unit {
        let d1 = respAbs(round2(1.234) - 1.234)
        let d2 = respAbs(round2(3.14159) - 3.14159)
        let d3 = respAbs(round2(0.004) - 0.004)
        let d4 = respAbs(round2(2.675) - 2.675)
        @Assert(d1, 0.0, delta: 0.011)
        @Assert(d2, 0.0, delta: 0.011)
        @Assert(d3, 0.0, delta: 0.011)
        @Assert(d4, 0.0, delta: 0.011)
    }

    // 源码对负数取 abs 后再舍入，故 ±v 必然严格对称（与舍入语义无关）
    @TestCase
    func testRound2NegationSymmetry(): Unit {
        let samples = [1.234, 0.125, 8.745, 1234.5678, 0.004, 99.999]
        for (v in samples) {
            let sum = respAbs(round2(-v) + round2(v))
            @Assert(sum, 0.0, delta: 0.0001)
        }
    }

    // 说明：刻意不写 formatNum2(x) == formatNum2(round2(x)) 这类「幂等」用例。
    // round2 的返回值再进 formatNum2 时，y = cents/100*100 的落点会随舍入语义变化
    // （例如四舍六入五成双语义下 round2(0.125)=0.13 再格式化会得到 0.14），
    // 因此该性质在本环境里不是语义无关的，不能作为断言。

    // ------------------------------------------------------------------
    // 10. truncateUtf8
    // ------------------------------------------------------------------
    @TestCase
    func testTruncateUtf8AsciiOnly(): Unit {
        @Assert(truncateUtf8("hello world", 5), "hello")
        @Assert(truncateUtf8("hello", 10), "hello")
        @Assert(truncateUtf8("hello", 5), "hello")
        @Assert(truncateUtf8("hello", 1), "h")
        @Assert(truncateUtf8("", 5), "")
    }

    @TestCase
    func testTruncateUtf8MultiByteBoundary(): Unit {
        // "中文" = 6 字节，每个汉字 3 字节
        @Assert(truncateUtf8("中文", 6), "中文")
        @Assert(truncateUtf8("中文", 7), "中文")
        @Assert(truncateUtf8("中文", 3), "中")
        @Assert(truncateUtf8("中文", 4), "中") // 切在第 2 个汉字中间 -> 回退
        @Assert(truncateUtf8("中文", 5), "中")
        @Assert(truncateUtf8("中文", 2), "")
        @Assert(truncateUtf8("中文", 1), "")
        // 混合：ASCII 头 + 多字节
        @Assert(truncateUtf8("a中", 1), "a")
        @Assert(truncateUtf8("a中", 2), "a")
        @Assert(truncateUtf8("a中", 4), "a中")
    }

    @TestCase
    func testTruncateUtf8NonPositiveLimit(): Unit {
        @Assert(truncateUtf8("hello", 0), "")
        @Assert(truncateUtf8("hello", -1), "")
        @Assert(truncateUtf8("中文", -5), "")
    }

    // 截断结果必须仍是原文的前缀，且不超过字节上限
    @TestCase
    func testTruncateUtf8StaysPrefixAndWithinLimit(): Unit {
        let s = "人力资源管理系统"
        let cuts = [1, 2, 3, 4, 5, 6, 9, 12, 24]
        for (n in cuts) {
            let t = truncateUtf8(s, n)
            @Assert(s.size >= t.size, true)
            @Assert(t.toArray().size <= n, true)
            // 前缀性：截断结果必须能整除 3（每个汉字 3 字节），即没切半个字
            @Assert(t.toArray().size % 3, 0)
        }
        @Assert(truncateUtf8(s, 24), s)
    }
}
