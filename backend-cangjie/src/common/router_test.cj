package hrms_backend.common

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

// =============================================================================
// router.cj 单元测试（P1.1）
//
// 覆盖 public func parsePathSegments / parseIntId —— 这两个函数是 main.cj
// 手写 if 链路由的全部输入解析入口，属于纯函数，可以在单测中完整覆盖。
//
// 未覆盖（原因记录，避免误以为已覆盖）：
//   readRequestBody(ctx) / getQueryStr(ctx, ...) / getQueryInt(ctx, ...)
//   依赖 stdx.net.http.HttpContext（内部含 request.body 流与 url.queryForm），
//   其构造方式在 1.0.5 文档中并非面向单测开放，故交由 P1.2 冒烟脚本覆盖。
// =============================================================================

// ---- 测试辅助（rt 前缀，避免与同包其它 *_test.cj 顶层符号冲突）----
func rtCount(path: String): Int64 {
    return parsePathSegments(path).size
}

func rtSegAt(path: String, idx: Int64): String {
    let segs = parsePathSegments(path)
    if (idx < 0 || idx >= segs.size) {
        return ""
    }
    return segs[idx]
}

// 用固定分隔符把段拼回来，便于一次断言「段数 + 段内容」
func rtJoin(path: String, sep: String): String {
    var out = ""
    var first = true
    for (s in parsePathSegments(path)) {
        if (!first) {
            out = out + sep
        }
        out = out + s
        first = false
    }
    return out
}

@Test
class RouterTests {
    // ------------------------------------------------------------------
    // 0. 字面量自检
    // ------------------------------------------------------------------
    @TestCase
    func testLiteralSelfCheck(): Unit {
        @Assert("".size, 0)
        @Assert("/".size, 1)
        @Assert("//".size, 2)
        @Assert("/api/employees".size, 14)
        @Assert("9223372036854775807".size, 19)
        @Assert("9223372036854775808".size, 19)
    }

    // ------------------------------------------------------------------
    // 1. parsePathSegments：空段必须全部过滤掉
    // ------------------------------------------------------------------
    @TestCase
    func testParsePathSegmentsEmptyAndSlashes(): Unit {
        @Assert(rtCount(""), 0)
        @Assert(rtCount("/"), 0)
        @Assert(rtCount("//"), 0)
        @Assert(rtCount("///"), 0)
        @Assert(rtJoin("", "|"), "")
    }

    @TestCase
    func testParsePathSegmentsNormalPath(): Unit {
        @Assert(rtCount("/api/employees"), 2)
        @Assert(rtSegAt("/api/employees", 0), "api")
        @Assert(rtSegAt("/api/employees", 1), "employees")
        @Assert(rtJoin("/api/employees", "|"), "api|employees")
        // 越界访问在辅助函数里约定返回空串
        @Assert(rtSegAt("/api/employees", 2), "")
        @Assert(rtSegAt("/api/employees", -1), "")
    }

    @TestCase
    func testParsePathSegmentsIgnoresTrailingSlash(): Unit {
        @Assert(rtCount("/api/employees/"), 2)
        @Assert(rtJoin("/api/employees/", "|"), "api|employees")
        @Assert(rtCount("/api/employees//"), 2)
    }

    @TestCase
    func testParsePathSegmentsWithoutLeadingSlash(): Unit {
        @Assert(rtCount("api/dept"), 2)
        @Assert(rtJoin("api/dept", "|"), "api|dept")
    }

    @TestCase
    func testParsePathSegmentsSqueezesRepeatedSlashes(): Unit {
        @Assert(rtCount("/a//b///c"), 3)
        @Assert(rtJoin("/a//b///c", "|"), "a|b|c")
        @Assert(rtSegAt("/a//b///c", 0), "a")
        @Assert(rtSegAt("/a//b///c", 1), "b")
        @Assert(rtSegAt("/a//b///c", 2), "c")
    }

    @TestCase
    func testParsePathSegmentsKeepsNonNumericAndUnicode(): Unit {
        @Assert(rtJoin("/sys-dept/2024_q1", "|"), "sys-dept|2024_q1")
        @Assert(rtJoin("/a/b/c/d/e", "|"), "a|b|c|d|e")
        // 中文段：只做等值断言，不断言 .size（String.size 语义未经证实）
        @Assert(rtSegAt("/部门/12", 0), "部门")
        @Assert(rtSegAt("/部门/12", 1), "12")
        @Assert(rtCount("/部门/12"), 2)
    }

    @TestCase
    func testParsePathSegmentsDoesNotTrimOrDecode(): Unit {
        // 路由段中的空格与 %xx 编码都不做处理，原样保留
        @Assert(rtCount("/a b/c"), 2)
        @Assert(rtSegAt("/a b/c", 0), "a b")
        @Assert(rtSegAt("/p%65ed", 0), "p%65ed")
        @Assert(rtSegAt("/x/", 5), "")
    }

    // ------------------------------------------------------------------
    // 2. parseIntId：解析失败一律返回 0（0 同时是「非法 id」的哨兵值）
    // ------------------------------------------------------------------
    @TestCase
    func testParseIntIdValid(): Unit {
        @Assert(parseIntId("1"), 1)
        @Assert(parseIntId("42"), 42)
        @Assert(parseIntId("0"), 0)
        @Assert(parseIntId("1000000"), 1000000)
        @Assert(parseIntId("9223372036854775807"), 9223372036854775807)
    }

    @TestCase
    func testParseIntIdTrimsSpaces(): Unit {
        @Assert(parseIntId(" 42 "), 42)
        @Assert(parseIntId("   "), 0)
        @Assert(parseIntId(""), 0)
    }

    @TestCase
    func testParseIntIdNegative(): Unit {
        @Assert(parseIntId("-7"), -7)
        @Assert(parseIntId("-0"), 0)
    }

    @TestCase
    func testParseIntIdRejectsNonIntegers(): Unit {
        @Assert(parseIntId("abc"), 0)
        @Assert(parseIntId("1.5"), 0)
        @Assert(parseIntId("1e3"), 0)
        @Assert(parseIntId("12x"), 0)
        @Assert(parseIntId("x12"), 0)
        @Assert(parseIntId("9223372036854775808"), 0) // 溢出 -> None -> 0
        @Assert(parseIntId("-9223372036854775809"), 0)
    }

    // 0 既是合法 id 也是失败哨兵：这一性质被 main.cj 依赖，钉死它
    @TestCase
    func testParseIntIdZeroIsAmbiguousSentinel(): Unit {
        @Assert(parseIntId("0"), parseIntId("bad"))
        @Assert(parseIntId("0"), parseIntId(""))
        @Assert(parseIntId("0"), parseIntId("abc"))
        @Assert(parseIntId("1") > parseIntId("0"), true)
    }
}
