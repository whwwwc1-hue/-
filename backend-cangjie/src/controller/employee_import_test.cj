package hrms_backend.controller

// =============================================================================
// P2.1 员工批量导入的纯函数单测
//
// 覆盖对象全部是**无数据库依赖**的函数：CSV 解析、表头映射、单元格取值、
// 格式校验、错误 JSON 组装。validateImportRow 把需要查库的两件事
// （已存在工号集合、部门名集合）设计成入参，因此整条校验链可脱库断言 ——
// 这不是测试妥协，而是刻意把「查库」与「判定」解耦，让判定可证伪。
//
// 语法约束（遵循 FOLLOWUP_PLAN 第十一节考证纪律，只用基线 6e79923 已编译通过的写法）：
//   · 不用数组字面量构造 ArrayList（基线零先例）—— 改用 impSplit / 逐个 add；
//   · 不用单引号字符串 —— 仓颉单引号是 Rune，基线里的 'LEAVE' 全在 SQL 字符串内部；
//   · 构造特殊字节用 String.fromUtf8(ArrayList<UInt8>.toArray())，
//     与 crypto_util.cj:43 / router.cj:22 同构；
//   · 不依赖 Float64 -> Int64 取整语义，长度类断言全部用整数。
//
// 诚实声明：本机无仓颉 SDK（FOLLOWUP_PLAN 第十节 L-CJ-1），本文件从未被
// cjpm test 真正执行过；长度类期望值由 impDigitRun 自证而非手数字符串。
// =============================================================================

import std.collection.*
import stdx.unittest.decore
import stdx.unittest.testcase

let IMP_BOM_A: UInt8 = 0xEF
let IMP_BOM_B: UInt8 = 0xBB
let IMP_BOM_C: UInt8 = 0xBF
let IMP_DIGIT_1: UInt8 = 0x31
// 全角数字「１」的 UTF-8 编码 = EF BC 91
let IMP_FW_A: UInt8 = 0xEF
let IMP_FW_B: UInt8 = 0xBC
let IMP_FW_C: UInt8 = 0x91

// ---- 构造辅助 ----

// 以竖线分隔造列表：比逐个 add 紧凑，又不依赖被测的 CSV 解析器，避免循环论证。
// 这里**手写扫描**而不是用 String.split：基线只在「分段必然非空」的输入上用过
// split（JWT 三段、密码四段、按行切分），「空分段是否保留」没有先例；
// 而本文件的尺子必须能造出 "A||C" 这种中间空字段的行，语义不能悬而未决。
func impSplit(s: String): ArrayList<String> {
    let r = ArrayList<String>()
    let runes = s.toRuneArray()
    var cur = ""
    var i: Int64 = 0
    while (i < runes.size) {
        if (runes[i].toString() == "|") {
            r.add(cur)
            cur = ""
        } else {
            cur = cur + runes[i].toString()
        }
        i = i + 1
    }
    r.add(cur)
    return r
}

func impEmpty(): ArrayList<String> {
    return ArrayList<String>()
}

func impBytes(bs: ArrayList<UInt8>): String {
    return String.fromUtf8(bs.toArray())
}

func impByteRun(byte: UInt8, n: Int64): String {
    let bs = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < n) {
        bs.add(byte)
        i = i + 1
    }
    return impBytes(bs)
}

// UTF-8 BOM 前缀
func impBom(): String {
    let bs = ArrayList<UInt8>()
    bs.add(IMP_BOM_A)
    bs.add(IMP_BOM_B)
    bs.add(IMP_BOM_C)
    return impBytes(bs)
}

// 恰好 n 个 ASCII '1' 的串：长度类边界不靠手数引号里的字符串
func impDigits(n: Int64): String {
    return impByteRun(IMP_DIGIT_1, n)
}

func impFullWidthOne(): String {
    let bs = ArrayList<UInt8>()
    bs.add(IMP_FW_A)
    bs.add(IMP_FW_B)
    bs.add(IMP_FW_C)
    return impBytes(bs)
}

// 补齐到 13 列，缺位填 ""。逐位补齐而不是变参，是为了让「列错位」这类 bug
// 在断言里就暴露，而不是静默退化成空串。
func impRow(vals: ArrayList<String>): ArrayList<String> {
    let r = ArrayList<String>()
    var i: Int64 = 0
    while (i < 13) {
        if (i < vals.size) {
            r.add(vals[i])
        } else {
            r.add("")
        }
        i = i + 1
    }
    return r
}

// 一条完整合法行的骨架，只暴露 4 个最常改动的字段，其余取合法默认值。
// 逐个 add 而不是「先造再按下标改写」：基线里 ArrayList 从未出现过下标赋值
// （只有 crypto_util.cj 对 Array<UInt8> 用过），其可用性未经证实，不作依赖。
func impRowOf(empNo: String, name: String, dept: String, hireDate: String): ArrayList<String> {
    let r = ArrayList<String>()
    r.add(empNo)
    r.add(name)
    r.add("男")
    r.add("13800000001")
    r.add("a@b.com")
    r.add("110101199001011234")
    r.add(dept)
    r.add("工程师")
    r.add("8000")
    r.add("5")
    r.add(hireDate)
    r.add("2029-01-04")
    r.add("ACTIVE")
    return r
}

func impCols(): ArrayList<Int64> {
    let missing = ArrayList<String>()
    return empImportCols(empImportHeader(), missing)
}

func impParse(text: String): ArrayList<ArrayList<String>> {
    let fields = ArrayList<String>()
    let counts = ArrayList<Int64>()
    let lines = ArrayList<Int64>()
    parseCsvInto(text, fields, counts, lines)
    return csvSplitRows(fields, counts)
}

func impParseCounts(text: String): ArrayList<Int64> {
    let fields = ArrayList<String>()
    let counts = ArrayList<Int64>()
    let lines = ArrayList<Int64>()
    parseCsvInto(text, fields, counts, lines)
    return counts
}

func impParseLines(text: String): ArrayList<Int64> {
    let fields = ArrayList<String>()
    let counts = ArrayList<Int64>()
    let lines = ArrayList<Int64>()
    parseCsvInto(text, fields, counts, lines)
    return lines
}

// empImportCols 同时产出 cols 与 missing；测试只关心 missing，
// 但必须真实调用一次并核对 cols 形状，否则实现漂移不会被发现。
func impMissing(header: ArrayList<String>): ArrayList<String> {
    let missing = ArrayList<String>()
    let cols = empImportCols(header, missing)
    if (cols.size != 13) {
        missing.add("__cols_size_drift__")
    }
    return missing
}

func impValidate(row: ArrayList<String>, existing: ArrayList<String>, inFile: ArrayList<String>, depts: ArrayList<String>, out: ArrayList<String>): Bool {
    return validateImportRow(row, 2, impCols(), existing, inFile, depts, out)
}

func impDepts(): ArrayList<String> {
    return impSplit("技术部|人事部")
}

@Test
class EmployeeImportTests {
    // ---- 0. 尺子自检 ----

    @TestCase
    func testHelperSelfCheck(): Unit {
        @Assert(impSplit("A|B|C").size, 3)
        @Assert(impSplit("A|B|C")[1], "B")
        @Assert(impSplit("A||C").size, 3)
        @Assert(impSplit("A||C")[1], "")
        @Assert(impSplit("A").size, 1)
        @Assert(impSplit("A")[0], "A")
        @Assert(impEmpty().size, 0)
        @Assert(impRow(impEmpty()).size, 13)
        @Assert(impRow(impSplit("A|B"))[1], "B")
        @Assert(impRow(impSplit("A|B"))[12], "")
        @Assert(impRow(impSplit("A|B|C|D|E|F|G|H|I|J|K|L|M")).size, 13)
        @Assert(impCols().size, 13)
        @Assert(impCols()[0], 0)
        @Assert(impCols()[12], 12)
        @Assert(impDepts().size, 2)
        @Assert(strRuneLen(impDigits(32)), 32)
        @Assert(strRuneLen(impDigits(33)), 33)
        @Assert(isAllDigits(impDigits(5)))
        // 构造器自检：BOM / 全角１ 都必须是 3 个 UTF-8 字节。
        // 一律用 toArray().size（Array<UInt8> 的元素数 = 字节数，无歧义），
        // 不用 String.size —— 它对非 ASCII 的口径基线无可佐证样本，不拿来当尺子。
        @Assert(impBom().toArray().size, 3)
        @Assert(impFullWidthOne().toArray().size, 3)
        @Assert(strRuneLen(impBom()), 1)
    }

    // ---- 1. CSV 解析：最小闭环 ----

    @TestCase
    func testParseBasic(): Unit {
        let rows = impParse("工号,姓名\r\nA1,张三\r\nA2,李四\r\n")
        @Assert(rows.size, 3)
        @Assert(rows[0].size, 2)
        @Assert(rows[0][0], "工号")
        @Assert(rows[0][1], "姓名")
        @Assert(rows[1][0], "A1")
        @Assert(rows[1][1], "张三")
        @Assert(rows[2][0], "A2")
        @Assert(rows[2][1], "李四")
    }

    @TestCase
    func testParseLineNumbers(): Unit {
        let lines = impParseLines("h1,h2\r\na,b\r\nc,d\r\n")
        @Assert(lines.size, 3)
        @Assert(lines[0], 1)
        @Assert(lines[1], 2)
        @Assert(lines[2], 3)
        @Assert(impParseCounts("h1,h2\r\na,b\r\nc,d\r\n")[0], 2)
        @Assert(impParseCounts("h1,h2\r\na,b\r\nc,d\r\n")[2], 2)
    }

    @TestCase
    func testParseNoTrailingNewline(): Unit {
        // 手工编辑的 CSV 极少以换行结尾，漏掉末行是导入功能最典型的 bug
        let rows = impParse("h1,h2\r\na,b")
        @Assert(rows.size, 2)
        @Assert(rows[1][0], "a")
        @Assert(rows[1][1], "b")
        let lines = impParseLines("h1,h2\r\na,b")
        @Assert(lines.size, 2)
        @Assert(lines[1], 2)
    }

    @TestCase
    func testParseLfOnlyAndCrOnly(): Unit {
        @Assert(impParse("h\na\nb\n").size, 3)
        @Assert(impParse("h\ra\rb\r").size, 3)
        @Assert(impParse("h\na\nb\n")[1][0], "a")
        @Assert(impParse("h\ra\rb\r")[2][0], "b")
        @Assert(impParseLines("h\na\nb\n")[2], 3)
        @Assert(impParseLines("h\ra\rb\r")[2], 3)
    }

    // ---- 2. CSV 解析：引号语义 ----

    @TestCase
    func testParseQuotedComma(): Unit {
        let rows = impParse("h1,h2\r\n\"技术,研发部\",x\r\n")
        @Assert(rows.size, 2)
        @Assert(rows[1].size, 2)
        @Assert(rows[1][0], "技术,研发部")
        @Assert(rows[1][1], "x")
        // 引号外的逗号才是分隔符
        @Assert(impParse("a,\"b,c\",d\r\n")[0].size, 3)
        @Assert(impParse("a,\"b,c\",d\r\n")[0][1], "b,c")
    }

    @TestCase
    func testParseEscapedQuote(): Unit {
        // "He said ""hi""" 应解出 He said "hi"
        let rows = impParse("h\r\n\"He said \"\"hi\"\"\"\r\n")
        @Assert(rows.size, 2)
        @Assert(rows[1].size, 1)
        @Assert(rows[1][0], "He said \"hi\"")
        // He + 空格 + said + 空格 + " + hi + " = 2+1+4+1+1+2+1 = 12 个字符
        @Assert(strRuneLen(rows[1][0]), 12)
    }

    @TestCase
    func testParseQuotedNewlineKeepsOneRow(): Unit {
        // 引号内的换行不产生新行 —— 这正是必须单独收集行号的根本原因
        let rows = impParse("h1,h2\r\n\"line1\nline2\",tail\r\nend,x\r\n")
        @Assert(rows.size, 3)
        @Assert(rows[1].size, 2)
        @Assert(rows[1][0], "line1\nline2")
        @Assert(rows[1][1], "tail")
        @Assert(rows[2][0], "end")
        @Assert(rows[2][1], "x")
    }

    @TestCase
    func testParseQuotedNewlineRowNumbers(): Unit {
        // 第 2 条数据物理占 2 行，因此第 3 行的行号必须是 4 而不是 2。
        // 若实现按下标 +1 报行号，用户会被引导到错误的行去改数据。
        let lines = impParseLines("h1,h2\r\n\"a\nb\",c\r\nd,e\r\n")
        @Assert(lines.size, 3)
        @Assert(lines[0], 1)
        @Assert(lines[1], 2)
        @Assert(lines[2], 4)
        @Assert(impParseCounts("h1,h2\r\n\"a\nb\",c\r\nd,e\r\n")[1], 2)
        @Assert(impParseCounts("h1,h2\r\n\"a\nb\",c\r\nd,e\r\n").size, 3)
    }

    @TestCase
    func testParseBom(): Unit {
        // 不剥 BOM 的话第一列表头会变成 "<BOM>工号"，表头匹配全盘失败，
        // 表现为「官方模板也导不进去」，属于最难定位的一类故障。
        let withBom = impBom() + "工号,姓名\r\nA1,B\r\n"
        @Assert(impParse(withBom).size, 2)
        @Assert(impParse(withBom)[0][0], "工号")
        @Assert(csvColIndex(impParse(withBom)[0], "工号"), 0)
        @Assert(csvColIndex(impParse(withBom)[0], "姓名"), 1)
        // 无 BOM 时同一入口也必须成立
        @Assert(csvColIndex(impParse("工号,姓名\r\n")[0], "工号"), 0)
        @Assert(csvStripBom("abc"), "abc")
        @Assert(csvStripBom(impBom() + "abc"), "abc")
        @Assert(csvStripBom(impBom() + "abc").toArray().size, 3)
        // BOM 不在开头就不是 BOM，必须原样保留（4 字节 = 1 + 3），
        // 否则会静默吃掉用户数据里的第一个字符
        @Assert(csvStripBom("a" + impBom()).toArray().size, 4)
    }

    @TestCase
    func testParseEmptyAndEdgeShapes(): Unit {
        @Assert(impParse("").size, 0)
        // RFC4180：一个空行本身就是一条记录（1 个空字段）。
        // 解析器**不**做「空行过滤」，过滤是 doEmployeeImport 用 csvRowIsBlank 做的 ——
        // 尺子必须忠实于语义，把策略留在调用方，否则引号内空行会被误删。
        @Assert(impParse("\r\n").size, 1)
        @Assert(impParse("\r\n")[0].size, 1)
        @Assert(impParse("\r\n")[0][0], "")
        @Assert(impParse("only\r\n").size, 1)
        @Assert(impParse("only\r\n")[0].size, 1)
        @Assert(impParse("only")[0].size, 1)
        // 尾随逗号必须产生一个空字段，否则列数会静默错位
        @Assert(impParse("a,b,\r\n")[0].size, 3)
        @Assert(impParse("a,b,\r\n")[0][2], "")
        @Assert(impParse(",,\r\n")[0].size, 3)
        @Assert(impParse("a\r\n\r\nb\r\n").size, 3)
        @Assert(impParseLines("a\r\n\r\nb\r\n")[1], 2)
        @Assert(impParseLines("a\r\n\r\nb\r\n")[2], 3)
    }

    @TestCase
    func testCsvRowIsBlank(): Unit {
        // 这是导入流程「忽略空行」的唯一判据，必须与解析器的语义配对断言
        @Assert(csvRowIsBlank(impParse("\r\n")[0]))
        @Assert(csvRowIsBlank(impParse(" , ,\r\n")[0]))
        @Assert(!csvRowIsBlank(impParse("a\r\n")[0]))
        @Assert(!csvRowIsBlank(impParse(",a\r\n")[0]))
        @Assert(!csvRowIsBlank(impParse("only\r\n")[0]))
        // 空行不改变解析器给出的行号，剔除后第 3 行仍报 3
        @Assert(impParse("h\r\n\r\nd\r\n")[2][0], "d")
    }

    // ---- 3. 表头 / 单元格 ----

    @TestCase
    func testCsvColIndex(): Unit {
        let header = impSplit("工号| 姓名 |部门")
        @Assert(header.size, 3)
        @Assert(csvColIndex(header, "工号"), 0)
        @Assert(csvColIndex(header, "姓名"), 1)
        @Assert(csvColIndex(header, "部门"), 2)
        @Assert(csvColIndex(header, "不存在"), -1)
        @Assert(csvColIndex(impEmpty(), "工号"), -1)
        @Assert(csvColIndex(empImportHeader(), "状态"), 12)
        @Assert(csvColIndex(empImportHeader(), "岗位"), 7)
        // csvColIndex 只对**表头单元格**做 trim（title 来自 empImportHeader 的固定值，
        // 本身不可能带空格）；Excel 另存为常在每个表头后加空格，这里必须能匹配上
        @Assert(csvColIndex(impSplit("工号 | 姓名|部门 "), "部门"), 2)
        @Assert(csvColIndex(impSplit("工号 | 姓名|部门 "), "工号"), 0)
        // title 两侧的空格不会被 trim，属于「不按 title 容错」的既定契约
        @Assert(csvColIndex(empImportHeader(), " 岗位 "), -1)
    }

    @TestCase
    func testCsvCell(): Unit {
        let row = impSplit(" A1 | |C")
        @Assert(row.size, 3)
        @Assert(csvCell(row, 0), "A1")
        @Assert(csvCell(row, 1), "")
        @Assert(csvCell(row, 2), "C")
        // 越界与 -1 都返回空串，由「必填」校验负责报错，而不是让下标越界炸掉整个请求
        @Assert(csvCell(row, 3), "")
        @Assert(csvCell(row, -1), "")
        @Assert(csvCell(row, -2), "")
        @Assert(csvCell(impEmpty(), 0), "")
    }

    @TestCase
    func testEmpImportColsMissing(): Unit {
        @Assert(impMissing(empImportHeader()).size, 0)
        let onlyTwo = impSplit("工号|姓名")
        // 13 个必需列里只出现了 2 个 → 缺 11 列
        @Assert(impMissing(onlyTwo).size, 11)
        @Assert(impMissing(onlyTwo)[0], "性别")
        @Assert(impMissing(impSplit("a|b")).size, 13)
        @Assert(impMissing(impEmpty()).size, 13)
        // 顺序打乱但列齐全 → 不缺列，且下标各自指向正确位置
        let shuffled = impSplit("状态|合同到期日期|入职日期|年假余额|基本薪资|岗位|部门|身份证号|邮箱|手机号|性别|姓名|工号")
        @Assert(impMissing(shuffled).size, 0)
        @Assert(csvColIndex(shuffled, "工号"), 12)
        @Assert(csvColIndex(shuffled, "状态"), 0)
        @Assert(csvColIndex(shuffled, "入职日期"), 2)
    }

    // ---- 4. 基础判定 ----

    @TestCase
    func testListIndexOf(): Unit {
        let l = impSplit("A|B|C")
        @Assert(listIndexOf(l, "A"), 0)
        @Assert(listIndexOf(l, "C"), 2)
        @Assert(listIndexOf(l, "B"), 1)
        @Assert(listIndexOf(l, "D"), -1)
        @Assert(listIndexOf(l, ""), -1)
        @Assert(listIndexOf(impEmpty(), "A"), -1)
        // 重复元素返回第一个下标，不能被后者覆盖
        @Assert(listIndexOf(impSplit("A|A|A"), "A"), 0)
    }

    @TestCase
    func testIsAllDigits(): Unit {
        @Assert(isAllDigits("0"))
        @Assert(isAllDigits("13800000001"))
        @Assert(!isAllDigits(""))
        @Assert(!isAllDigits("1380000000a"))
        @Assert(!isAllDigits("1380000000 "))
        @Assert(!isAllDigits("138-0000"))
        @Assert(!isAllDigits("+8613800000001"))
        // 全角数字不是 ASCII 数字，必须拒 —— 否则 MySQL 会静默截成 0
        @Assert(!isAllDigits(impFullWidthOne()))
        @Assert(isAllDigits(impDigits(33)))
    }

    @TestCase
    func testIsValidYmd(): Unit {
        @Assert(isValidYmd("2026-01-05"))
        @Assert(isValidYmd("2026-12-31"))
        @Assert(isValidYmd("1900-01-01"))
        @Assert(!isValidYmd(""))
        @Assert(!isValidYmd("2026-1-5"))
        @Assert(!isValidYmd("26-01-05"))
        @Assert(!isValidYmd("20260105"))
        @Assert(!isValidYmd("2026/01/05"))
        @Assert(!isValidYmd("2026-01-05 "))
        @Assert(!isValidYmd(" 2026-01-05"))
        @Assert(!isValidYmd("2026-00-10"))
        @Assert(!isValidYmd("2026-13-10"))
        @Assert(!isValidYmd("2026-01-00"))
        @Assert(!isValidYmd("2026-01-32"))
        @Assert(!isValidYmd("202a-01-05"))
        @Assert(!isValidYmd("2026-01-05-01"))
        @Assert(!isValidYmd("202/01-05"))
        // 2 月 30 日这类日历合法性交给 MySQL 的 DATE 列拒绝，
        // 本函数只保证字面量形状与分量范围，不重造公历闰年判断
        @Assert(isValidYmd("2026-02-30"))
        @Assert(isValidYmd("2026-04-31"))
    }

    @TestCase
    func testStrRuneLen(): Unit {
        // MySQL VARCHAR(n) 按**字符**计长；若实现误用「字节」口径（例如直接拿
        // text.toArray().size 当长度），64 的上限会让中文姓名只允许 21 个字。
        // strRuneLen 走 toRuneArray()，与 VARCHAR 的口径一致。
        @Assert(strRuneLen(""), 0)
        @Assert(strRuneLen("ABC"), 3)
        @Assert(strRuneLen("张三"), 2)
        @Assert(strRuneLen("张三P"), 3)
        @Assert(strRuneLen("王梓涵"), 3)
        @Assert(strRuneLen(impFullWidthOne()), 1)
        // 反证：同一姓名按 UTF-8 字节算是 6。这里刻意用 toArray().size 而不是
        // String.size —— String.toArray() 返回 Array<UInt8> 是基线 truncateUtf8
        // 已确证的事实，而 String.size 对非 ASCII 到底是字节还是字符，基线里
        // 没有任何一处非 ASCII 用法可以佐证，不作断言依据。
        // 结论不变：长度校验必须走 toRuneArray()，否则「姓名上限 64」会缩水成 21 字。
        @Assert("张三".toArray().size, 6)
    }

    @TestCase
    func testStrHas(): Unit {
        // 邮箱校验的唯一判据；用 replace 长度差实现，必须与出现位置无关
        @Assert(strHas("a@b.com", "@"))
        @Assert(strHas("@x", "@"))
        @Assert(strHas("x@", "@"))
        @Assert(!strHas("abc", "@"))
        @Assert(strHas("张三丰", "三"))
        @Assert(!strHas("张三丰", "李"))
        @Assert(strHas("", ""))
        @Assert(!strHas("", "a"))
        // 多次出现同样只判「有没有」
        @Assert(strHas("a@a@a", "@"))
    }

    @TestCase
    func testEmpImportGender(): Unit {
        @Assert(empImportGender("1"), 1)
        @Assert(empImportGender("男"), 1)
        @Assert(empImportGender("M"), 1)
        @Assert(empImportGender("male"), 1)
        @Assert(empImportGender("2"), 2)
        @Assert(empImportGender("女"), 2)
        @Assert(empImportGender("F"), 2)
        @Assert(empImportGender("female"), 2)
        @Assert(empImportGender(""), 0)
        @Assert(empImportGender("3"), 0)
        @Assert(empImportGender("未知"), 0)
        @Assert(empImportGender("0"), 0)
    }

    @TestCase
    func testEmpImportStatus(): Unit {
        @Assert(empImportStatus("ACTIVE"), "ACTIVE")
        @Assert(empImportStatus("active"), "ACTIVE")
        @Assert(empImportStatus("PROBATION"), "PROBATION")
        @Assert(empImportStatus("RESIGNED"), "RESIGNED")
        @Assert(empImportStatus("在职"), "ACTIVE")
        @Assert(empImportStatus("正式"), "ACTIVE")
        @Assert(empImportStatus("试用期"), "PROBATION")
        @Assert(empImportStatus("离职"), "RESIGNED")
        @Assert(empImportStatus(""), "")
        @Assert(empImportStatus("FIRED"), "")
        @Assert(empImportStatus("在职x"), "")
    }

    // ---- 5. 单行校验（脱库） ----

    @TestCase
    func testValidateGoodRow(): Unit {
        let out = ArrayList<String>()
        @Assert(impValidate(impRowOf("EMP900", "测试甲", "技术部", "2026-01-05"), impEmpty(), impEmpty(), impDepts(), out))
        @Assert(out.size, 0)
        let out2 = ArrayList<String>()
        @Assert(impValidate(impRowOf("EMP901", "测试乙", "人事部", "2026-02-01"), impEmpty(), impEmpty(), impDepts(), out2))
        @Assert(out2.size, 0)
        // 长中文姓名不能被字节长度上限误杀（strRuneLen 的意义所在）
        let out3 = ArrayList<String>()
        @Assert(impValidate(impRowOf("EMP902", "欧阳测试姓名很长很长的中文姓名确实很长很长", "技术部", "2026-03-01"), impEmpty(), impEmpty(), impDepts(), out3))
        @Assert(out3.size, 0)
        // 部门名两侧空格不应被误判成「部门不存在」
        let out4 = ArrayList<String>()
        @Assert(impValidate(impRowOf("EMP903", "测试丙", " 技术部 ", "2026-04-01"), impEmpty(), impEmpty(), impDepts(), out4))
        @Assert(out4.size, 0)
    }

    @TestCase
    func testValidateEmptyEmpNo(): Unit {
        let out = ArrayList<String>()
        @Assert(!impValidate(impRowOf("", "测试甲", "技术部", "2026-01-05"), impEmpty(), impEmpty(), impDepts(), out))
        @Assert(out.size, 1)
        @Assert(out[0], "{\"row\":2,\"field\":\"工号\",\"reason\":\"不能为空\"}")
    }

    @TestCase
    func testValidateEmpNoDuplicateInDb(): Unit {
        let existing = impSplit("EMP001|EMP002")
        let out = ArrayList<String>()
        @Assert(!impValidate(impRowOf("EMP001", "测试甲", "技术部", "2026-01-05"), existing, impEmpty(), impDepts(), out))
        @Assert(out.size, 1)
        @Assert(out[0], "{\"row\":2,\"field\":\"工号\",\"reason\":\"工号 EMP001 已存在于系统，导入不覆盖已有档案\"}")
        // 库里没有的工号必须放行，否则导入功能形同虚设
        @Assert(impValidate(impRowOf("EMP900", "测试甲", "技术部", "2026-01-05"), existing, impEmpty(), impDepts(), ArrayList<String>()))
    }

    @TestCase
    func testValidateEmpNoDuplicateInFile(): Unit {
        // 文件内部重号必须在**写入前**抓住：第二条会撞唯一索引、整批事务回滚，
        // 而用户看到的报错只是「Duplicate entry」，完全不知道该改哪一行。
        let inFile = impSplit("EMP900")
        let out = ArrayList<String>()
        @Assert(!impValidate(impRowOf("EMP900", "测试甲", "技术部", "2026-01-05"), impEmpty(), inFile, impDepts(), out))
        @Assert(out.size, 1)
        @Assert(out[0], "{\"row\":2,\"field\":\"工号\",\"reason\":\"工号 EMP900 在本次文件内重复\"}")
        @Assert(impValidate(impRowOf("EMP901", "测试甲", "技术部", "2026-01-05"), impEmpty(), inFile, impDepts(), ArrayList<String>()))
    }

    @TestCase
    func testValidateEmpNoTooLong(): Unit {
        let out = ArrayList<String>()
        @Assert(!impValidate(impRowOf(impDigits(33), "测试甲", "技术部", "2026-01-05"), impEmpty(), impEmpty(), impDepts(), out))
        @Assert(out.size, 1)
        @Assert(out[0], "{\"row\":2,\"field\":\"工号\",\"reason\":\"长度超过 32 字符\"}")
        // 恰好 32 字符必须放行，边界不能写成 >=
        @Assert(impValidate(impRowOf(impDigits(32), "测试甲", "技术部", "2026-01-05"), impEmpty(), impEmpty(), impDepts(), ArrayList<String>()))
    }

    @TestCase
    func testValidateNameAndDeptAndPosition(): Unit {
        let blankName = ArrayList<String>()
        @Assert(!impValidate(impRowOf("EMP900", "", "技术部", "2026-01-05"), impEmpty(), impEmpty(), impDepts(), blankName))
        @Assert(blankName.size, 1)
        @Assert(blankName[0], "{\"row\":2,\"field\":\"姓名\",\"reason\":\"不能为空\"}")

        let badDept = ArrayList<String>()
        @Assert(!impValidate(impRowOf("EMP900", "测试甲", "不存在部", "2026-01-05"), impEmpty(), impEmpty(), impDepts(), badDept))
        @Assert(badDept.size, 1)
        @Assert(badDept[0], "{\"row\":2,\"field\":\"部门\",\"reason\":\"部门「不存在部」不存在，请先在组织架构中创建\"}")

        let noDept = ArrayList<String>()
        @Assert(!impValidate(impRowOf("EMP900", "测试甲", "", "2026-01-05"), impEmpty(), impEmpty(), impDepts(), noDept))
        @Assert(noDept[0], "{\"row\":2,\"field\":\"部门\",\"reason\":\"不能为空\"}")

        let noPos = ArrayList<String>()
        let posRow = impSplit("EMP900|测试甲|男|13800000001|a@b.com|110101199001011234|技术部||8000|5|2026-01-05|2029-01-04|ACTIVE")
        @Assert(posRow.size, 13)
        @Assert(!impValidate(posRow, impEmpty(), impEmpty(), impDepts(), noPos))
        @Assert(noPos[0], "{\"row\":2,\"field\":\"岗位\",\"reason\":\"不能为空\"}")
        @Assert(noPos.size, 1)
    }

    @TestCase
    func testValidateHireDate(): Unit {
        let emptyDate = ArrayList<String>()
        @Assert(!impValidate(impRowOf("EMP900", "测试甲", "技术部", ""), impEmpty(), impEmpty(), impDepts(), emptyDate))
        @Assert(emptyDate[0], "{\"row\":2,\"field\":\"入职日期\",\"reason\":\"不能为空\"}")
        @Assert(emptyDate.size, 1)

        let badDate = ArrayList<String>()
        @Assert(!impValidate(impRowOf("EMP900", "测试甲", "技术部", "2026-1-5"), impEmpty(), impEmpty(), impDepts(), badDate))
        @Assert(badDate.size, 1)
        @Assert(badDate[0], "{\"row\":2,\"field\":\"入职日期\",\"reason\":\"日期格式应为 YYYY-MM-DD，实际为「2026-1-5」\"}")
    }

    @TestCase
    func testValidateOptionalFields(): Unit {
        // 邮箱 / 薪资 / 性别 / 合同日期 / 身份证 / 状态 都是「填了才校验」
        @Assert(impValidate(impSplit("EMP900|测试甲|男|13800000001|a@b.com|110101199001011234|技术部|工程师|8000|5|2026-01-05|2029-01-04|ACTIVE"), impEmpty(), impEmpty(), impDepts(), ArrayList<String>()))

        let e1 = ArrayList<String>()
        @Assert(!impValidate(impSplit("EMP900|测试甲|男|13800000001|abc|110101199001011234|技术部|工程师|8000|5|2026-01-05|2029-01-04|ACTIVE"), impEmpty(), impEmpty(), impDepts(), e1))
        @Assert(e1[0], "{\"row\":2,\"field\":\"邮箱\",\"reason\":\"缺少 @ 符号\"}")
        @Assert(e1.size, 1)

        @Assert(impValidate(impSplit("EMP900|测试甲|男|13800000001||110101199001011234|技术部|工程师|8000|5|2026-01-05|2029-01-04|ACTIVE"), impEmpty(), impEmpty(), impDepts(), ArrayList<String>()))

        let s1 = ArrayList<String>()
        @Assert(!impValidate(impSplit("EMP900|测试甲|男|13800000001|||技术部|工程师|8,000|5|2026-01-05||ACTIVE"), impEmpty(), impEmpty(), impDepts(), s1))
        @Assert(s1[0], "{\"row\":2,\"field\":\"基本薪资\",\"reason\":\"不是合法数字\"}")

        @Assert(!impValidate(impSplit("EMP900|测试甲|男|13800000001|||技术部|工程师|-1|5|2026-01-05||ACTIVE"), impEmpty(), impEmpty(), impDepts(), ArrayList<String>()))
        // 0 薪资是合法值（实习/义务岗），不能和负数一起被拒
        @Assert(impValidate(impSplit("EMP900|测试甲|男|13800000001|||技术部|工程师|0|5|2026-01-05||ACTIVE"), impEmpty(), impEmpty(), impDepts(), ArrayList<String>()))

        @Assert(!impValidate(impSplit("EMP900|测试甲|不详|13800000001|||技术部|工程师|8000|5|2026-01-05||ACTIVE"), impEmpty(), impEmpty(), impDepts(), ArrayList<String>()))
        @Assert(!impValidate(impSplit("EMP900|测试甲|男|13800000001|||技术部|工程师|8000|5|2026-01-05||FIRED"), impEmpty(), impEmpty(), impDepts(), ArrayList<String>()))
        @Assert(!impValidate(impSplit("EMP900|测试甲|男|13800000001||110101|技术部|工程师|8000|5|2026-01-05||ACTIVE"), impEmpty(), impEmpty(), impDepts(), ArrayList<String>()))
        @Assert(impValidate(impSplit("EMP900|测试甲|男|13800000001||110101900101123|技术部|工程师|8000|5|2026-01-05||ACTIVE"), impEmpty(), impEmpty(), impDepts(), ArrayList<String>()))
        @Assert(!impValidate(impSplit("EMP900|测试甲|男|13800000001|||技术部|工程师|8000|5|2026-01-05|2029/01/04x|ACTIVE"), impEmpty(), impEmpty(), impDepts(), ArrayList<String>()))
        @Assert(!impValidate(impSplit("EMP900|测试甲|男|1380000000a|||技术部|工程师|8000|5|2026-01-05||ACTIVE"), impEmpty(), impEmpty(), impDepts(), ArrayList<String>()))

        // 手机号为空是必填项缺失
        let p1 = ArrayList<String>()
        @Assert(!impValidate(impSplit("EMP900|测试甲|男||||技术部|工程师|8000|5|2026-01-05||ACTIVE"), impEmpty(), impEmpty(), impDepts(), p1))
        @Assert(p1[0], "{\"row\":2,\"field\":\"手机号\",\"reason\":\"不能为空\"}")
        @Assert(p1.size, 1)
    }

    @TestCase
    func testValidateMissingColumnDegradesToRequiredError(): Unit {
        // 表头缺列时 cols[i] = -1，csvCell 返回 ""；
        // 必须由「必填」报错，绝不能静默当成合法空值写进库。
        let header = impSplit("工号|姓名|性别|手机号|邮箱|身份证号|部门|岗位|基本薪资|年假余额|合同到期日期|状态")
        @Assert(header.size, 12)
        let missing = ArrayList<String>()
        let cols = empImportCols(header, missing)
        @Assert(cols.size, 13)
        @Assert(missing.size, 1)
        @Assert(missing[0], "入职日期")
        @Assert(cols[10], -1)
        @Assert(cols[11], 10)
        @Assert(cols[12], 11)
        let row = impSplit("EMP900|测试甲|男|13800000001|a@b.com|110101199001011234|技术部|工程师|8000|5|2029-01-04|ACTIVE")
        @Assert(row.size, 12)
        let out = ArrayList<String>()
        @Assert(!validateImportRow(row, 2, cols, impEmpty(), impEmpty(), impDepts(), out))
        @Assert(out.size, 1)
        @Assert(out[0], "{\"row\":2,\"field\":\"入职日期\",\"reason\":\"不能为空\"}")
    }

    @TestCase
    func testValidateCollectsAllErrorsInOnePass(): Unit {
        // 全空行：工号 / 姓名 / 手机号 / 部门 / 岗位 / 入职日期 共 6 处必填。
        // 一次报全，否则用户要反复上传 6 轮才能导进去。
        let out = ArrayList<String>()
        @Assert(!impValidate(impRow(impEmpty()), impEmpty(), impEmpty(), impDepts(), out))
        @Assert(out.size, 6)
        @Assert(out[0], "{\"row\":2,\"field\":\"工号\",\"reason\":\"不能为空\"}")
        @Assert(out[1], "{\"row\":2,\"field\":\"姓名\",\"reason\":\"不能为空\"}")
        @Assert(out[2], "{\"row\":2,\"field\":\"手机号\",\"reason\":\"不能为空\"}")
        @Assert(out[3], "{\"row\":2,\"field\":\"部门\",\"reason\":\"不能为空\"}")
        @Assert(out[4], "{\"row\":2,\"field\":\"岗位\",\"reason\":\"不能为空\"}")
        @Assert(out[5], "{\"row\":2,\"field\":\"入职日期\",\"reason\":\"不能为空\"}")
    }

    // ---- 6. 响应 JSON 组装 ----

    @TestCase
    func testImportFailJson(): Unit {
        @Assert(importFailJson(7, "工号", "不能为空"), "{\"row\":7,\"field\":\"工号\",\"reason\":\"不能为空\"}")
        @Assert(importFailJson(1, "a", "b"), "{\"row\":1,\"field\":\"a\",\"reason\":\"b\"}")
        @Assert(importFailJson(12, "工号", "长度超过 32 字符"), "{\"row\":12,\"field\":\"工号\",\"reason\":\"长度超过 32 字符\"}")
        // 原因里带引号 / 反斜杠必须转义，否则整个响应体 JSON 坏掉，前端连错误列表都渲染不出来
        @Assert(importFailJson(7, "备注", "含\"引号\""), "{\"row\":7,\"field\":\"备注\",\"reason\":\"含\\\"引号\\\"\"}")
        @Assert(importFailJson(7, "备注", "含\\反斜杠"), "{\"row\":7,\"field\":\"备注\",\"reason\":\"含\\\\反斜杠\"}")
    }

    @TestCase
    func testImportResultJson(): Unit {
        let none = ArrayList<String>()
        @Assert(importResultJson(3, 2, 1, 0, true, none), "{\"total\":3,\"successCount\":2,\"failedCount\":1,\"imported\":0,\"dryRun\":true,\"failed\":[]}")
        @Assert(importResultJson(3, 3, 0, 3, false, none), "{\"total\":3,\"successCount\":3,\"failedCount\":0,\"imported\":3,\"dryRun\":false,\"failed\":[]}")
        @Assert(importResultJson(0, 0, 0, 0, false, none), "{\"total\":0,\"successCount\":0,\"failedCount\":0,\"imported\":0,\"dryRun\":false,\"failed\":[]}")
        let one = ArrayList<String>()
        one.add(importFailJson(2, "工号", "不能为空"))
        @Assert(importResultJson(2, 0, 1, 0, false, one), "{\"total\":2,\"successCount\":0,\"failedCount\":1,\"imported\":0,\"dryRun\":false,\"failed\":[{\"row\":2,\"field\":\"工号\",\"reason\":\"不能为空\"}]}")
        let two = ArrayList<String>()
        two.add(importFailJson(2, "a", "b"))
        two.add(importFailJson(3, "c", "d"))
        @Assert(importResultJson(3, 1, 2, 0, false, two), "{\"total\":3,\"successCount\":1,\"failedCount\":2,\"imported\":0,\"dryRun\":false,\"failed\":[{\"row\":2,\"field\":\"a\",\"reason\":\"b\"},{\"row\":3,\"field\":\"c\",\"reason\":\"d\"}]}")
    }

    @TestCase
    func testEmpImportHeaderShape(): Unit {
        // 模板列序是「后端校验 / CSV 模板 / 前端预览」三方共享的契约，
        // 任何一处单方面改动都会让老文件解析错位，因此逐位钉死。
        let h = empImportHeader()
        @Assert(h.size, 13)
        @Assert(h[0], "工号")
        @Assert(h[1], "姓名")
        @Assert(h[2], "性别")
        @Assert(h[3], "手机号")
        @Assert(h[4], "邮箱")
        @Assert(h[5], "身份证号")
        @Assert(h[6], "部门")
        @Assert(h[7], "岗位")
        @Assert(h[8], "基本薪资")
        @Assert(h[9], "年假余额")
        @Assert(h[10], "入职日期")
        @Assert(h[11], "合同到期日期")
        @Assert(h[12], "状态")
    }
}
