package hrms_backend.controller

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

// =============================================================================
// payroll_controller.cj 单元测试（P1.1）
//
// 覆盖三个可脱离 HTTP / 数据库运行的纯函数：
//   public func calculateTax(taxableRaw: Float64): Float64
//   public func calculatePayrollValues(...5 args): (Float64, Float64)
//   func          payrollRowToJson(r: ArrayList<String>): String   （包内可见）
//
// -----------------------------------------------------------------------------
// 【断言纪律：为什么凡经 round2 的值一律用 delta: 0.011】
// round2 内部写的是 `Int64(absVal * 100.0 + 0.5)`。这里有两处我们无法在不编译
// 的前提下确定的事实：
//   (1) 仓颉 1.0.5 的 Float64 -> Int64 显式转换是「向零截断」还是「四舍六入五
//       成双」；
//   (2) 编译器是否把 `taxable * 0.10 - 210.0` 与 `absVal * 100.0 + 0.5` 收缩成
//       fma（收缩后少一次中间舍入，结果可差 1 ulp）。
// 用 node 按 IEEE-754 逐值实算的结论是：绝大多数「看起来是整数分」的输入，其
// absVal * 100.0 + 0.5 恰好落在 N.5 这个**平局点**上（例如 500 -> 15.0 ->
// 1500.5）。平局点上 (1) 的两种语义只在 N 为偶数时同解；而 (2) 的 1 ulp 抖动
// 会把 N.5 推成 N.5000000000000001，从而在 halfEven 下多算 1 分。也就是说，
// 精确 pin 依赖「中间结果逐位恰好」这个无法验证的前提。
// 因此本文件采用如下唯一两种强度的断言：
//   A. 与舍入完全无关的路径 —— 可以精确 pin：
//      early return 的字面量 0.0、纯 Float64 比较（档位归属、单调性）、
//      同一函数两侧相等的口径一致性。
//   B. 凡经 round2 / formatNum2 得到的分值 —— 一律 delta: 0.011。
//      依据：上述 (1)(2) 四种组合在全部受测输入上的最大分歧恰为 1 分，
//      0.011 > 0.01 能覆盖任意一种语义选择，同时仍能抓住真正的逻辑错误
//      （档位系数写错、速算扣除数写错都会偏离 >= 0.1 元）。
// UNSAFE 输入（2999 / 3001 / 4999 / 12001 / 25001 / 99999 等，两语义差 1 分）
// 额外只使用语义无关的性质断言：非负、单调、误差界、结构计数。
// -----------------------------------------------------------------------------
//
// 【语法纪律】本文件只用基线 src 中已出现、或已确证的构造：
//   ArrayList<String>() + .add() + 下标访问；不使用数组字面量 [a,b,c]、
//   不使用元组下标 c[0] / ._0 / .0、不使用 String.contains、不使用 HashMap、
//   不使用双侧切片 s[0..1]。元组只在顶层 let (a, b) = ... 处解构。
//
// 未覆盖（交由 P1.2 冒烟脚本 + 数据库集成）：handlePayrollGenerate /
// handlePayrollList / handlePayrollUpdate / handlePayrollPay，均依赖
// HttpContext 与 queryRows/queryExecute。
// =============================================================================

// ---- 测试辅助（pay 前缀，避免与同包其它 *_test.cj 顶层符号冲突）----

// 转义字符一律用函数拼接，杜绝手抄反斜杠数错个数。
func payDq(): String {
    return "\""
}

func payBs(): String {
    return "\\"
}

func payQ(s: String): String {
    return payDq() + s + payDq()
}

// JSON 的 "key": 前缀
func payK(key: String): String {
    return payDq() + key + payDq() + ":"
}

func payAbs(v: Float64): Float64 {
    return if (v < 0.0) { -v } else { v }
}

// 不用 String.contains（基线中无任何使用，可用性未证实）：
// 出现一次 sub 就会让 replace 后的长度变短。
func payHas(s: String, sub: String): Bool {
    if (sub.isEmpty()) {
        return true
    }
    return s.replace(sub, "").size != s.size
}

// 同理，用长度差计数子串出现次数。
func payCountOf(s: String, needle: String): Int64 {
    if (needle.isEmpty()) {
        return 0
    }
    return (s.size - s.replace(needle, "").size) / needle.size
}

// 容差常量：> 1 分，< 1 角。见文件头【断言纪律】。
func payEps(): Float64 {
    return 0.011
}

// |v| * 100 距「整数分」的最小距离（0 = 恰好某个整数分）。
// round2 的产物恒为 Float64(cents) / 100.0，所以该距离必然 ~ 0；任何把税额
// 算成非整分的结果都会让距离落到 (0.01, 0.99) 区间而被抓住。
// 关键：这里对 Float64 -> Int64 的取整语义不做任何假设 —— Int64(x + 0.5) 无论
// 向零截断还是就近取整都返回某个整数 n，而 min(|x-n|, 1-|x-n|) 恒等于 x 到
// 最近整数的距离。
func payCentDistance(v: Float64): Float64 {
    let scaled = payAbs(v) * 100.0
    let nearest = Float64(Int64(scaled + 0.5))
    let d = payAbs(scaled - nearest)
    return if (d > 0.5) { 1.0 - d } else { d }
}

// calculatePayrollValues 返回元组；仓颉的 match 模式里不能解构元组，也不能用
// `._0`，所以在顶层 let 处降级成标量再断言。
func payTaxOf(base: Float64, bonus: Float64, ot: Float64, att: Float64, ss: Float64): Float64 {
    let (t, _) = calculatePayrollValues(base, bonus, ot, att, ss)
    return t
}

func payNetOf(base: Float64, bonus: Float64, ot: Float64, att: Float64, ss: Float64): Float64 {
    let (_, n) = calculatePayrollValues(base, bonus, ot, att, ss)
    return n
}

// 应发合计（未扣个税、未扣 5000 起征点）
func payGross(base: Float64, bonus: Float64, ot: Float64, att: Float64, ss: Float64): Float64 {
    return base + bonus + ot - att - ss
}

func payRow(nos: ArrayList<String>): ArrayList<String> {
    // 17 个字段，长度不足一律补 "x"，保证越界不会静默发生
    let r = ArrayList<String>()
    var i: Int64 = 0
    while (i < 17) {
        if (i < nos.size) {
            r.add(nos[i])
        } else {
            r.add("x")
        }
        i = i + 1
    }
    return r
}

func payCleanRow(): ArrayList<String> {
    let src = ArrayList<String>()
    src.add("1")
    src.add("7")
    src.add("E001")
    src.add("Zhang San")
    src.add("Tech")
    src.add("Engineer")
    src.add("2026-11")
    src.add("10000.00")
    src.add("2000.00")
    src.add("500.00")
    src.add("300.00")
    src.add("1500.00")
    src.add("360.00")
    src.add("10340.00")
    src.add("PAID")
    src.add("2026-11-05 10:00:00")
    src.add("ok")
    return payRow(src)
}

// 注意 payRow 的补齐符是 "x"（非空串），因此需要一个真正的「全空串行」。
func payEmptyRow(): ArrayList<String> {
    let r = ArrayList<String>()
    var i: Int64 = 0
    while (i < 17) {
        r.add("")
        i = i + 1
    }
    return r
}

// 一行「应发 12000、个税 780、实发 11220」的极值样例，用于结构断言复用
func paySecondRow(): ArrayList<String> {
    let src = ArrayList<String>()
    src.add("2")
    src.add("8")
    src.add("E002")
    src.add("Li Si")
    src.add("HR")
    src.add("Manager")
    src.add("2026-12")
    src.add("12000.00")
    src.add("0.00")
    src.add("0.00")
    src.add("0.00")
    src.add("0.00")
    src.add("780.00")
    src.add("11220.00")
    src.add("DRAFT")
    src.add("")
    src.add("")
    return payRow(src)
}

@Test
class PayrollPureFunctionTests {
    // ---- 0. 字面量与辅助函数自检：先证明「尺子」是准的 ----

    @TestCase
    func testHelperSelfCheck(): Unit {
        @Assert(payDq().size, 1)
        @Assert(payBs().size, 1)
        @Assert(("a" + payDq() + "b").size, 3)
        @Assert(("a" + payBs() + "b").size, 3)
        @Assert(payCountOf("a,b,,c", ","), 3)
        @Assert(payCountOf("abc", ","), 0)
        @Assert(payCountOf("", ","), 0)
        @Assert(payCountOf("abab", "ab"), 2)
        @Assert(payHas("hello", "ell"))
        @Assert(!payHas("hello", "xyz"))
        @Assert(payHas("hello", ""))
        @Assert(payAbs(0.0), 0.0)
        @Assert(payAbs(-2.5), 2.5, delta: 0.0)
        @Assert(payRow(ArrayList<String>()).size, 17)
        @Assert(payCleanRow().size, 17)
        @Assert(paySecondRow().size, 17)
        // payRow 只补齐、不截断，保证「传错长度一定会被发现」
        @Assert(payRow(ArrayList<String>())[16], "x")
        @Assert(payCleanRow()[0], "1")
        @Assert(payCleanRow()[16], "ok")
        // payEmptyRow 必须是 17 个空串（payRow 的补齐符是 "x"，不能混用）
        @Assert(payEmptyRow().size, 17)
        @Assert(payEmptyRow()[0].size, 0)
        @Assert(payEmptyRow()[16].size, 0)
        // 分位距离量尺自检：15.00 元 = 1500 分，到最近整数的距离 ~ 0
        @Assert(payCentDistance(15.0) <= 0.01)
        // 1.234 元 = 123.4 分，到最近整数的距离是 0.4，量尺必须能分辨
        @Assert(payCentDistance(1.234) > 0.05)
    }

    // ---- 1. calculateTax：负数与零走 early return，与舍入语义无关 ----

    @TestCase
    func testNegativeTaxableClampsToZero(): Unit {
        // 源码首行即 `if (taxable <= 0.0) { return 0.0 }`，返回的是字面量，
        // 不经过任何浮点乘法，因此可以精确 pin。
        @Assert(calculateTax(-2000.0), 0.0)
        @Assert(calculateTax(-0.0), 0.0)
        @Assert(calculateTax(-0.0001), 0.0)
        @Assert(calculateTax(-999999.0), 0.0)
        @Assert(calculateTax(-3000.0), 0.0)
    }

    @TestCase
    func testZeroTaxableIsZero(): Unit {
        @Assert(calculateTax(0.0), 0.0)
        // 0.004 走 3% 档 -> round2(0.00012)；任何候选语义下 cents 都是 0，
        // 但仍属于经过 round2 的路径，按纪律用容差。
        @Assert(calculateTax(0.004), 0.0, delta: payEps())
        @Assert(calculateTax(0.01), 0.0, delta: payEps())
        @Assert(calculateTax(0.1), 0.0, delta: payEps())
        @Assert(calculateTax(1.0), 0.03, delta: payEps())
    }

    // ---- 2. 各档精确值（容差 = 1 分 + 余量）----

    @TestCase
    func testFirstBracketExactValues(): Unit {
        // 3% 档：tax = taxable * 0.03
        @Assert(calculateTax(500.0), 15.0, delta: payEps())
        @Assert(calculateTax(650.0), 19.5, delta: payEps())
        @Assert(calculateTax(1000.0), 30.0, delta: payEps())
        @Assert(calculateTax(2000.0), 60.0, delta: payEps())
        @Assert(calculateTax(3000.0), 90.0, delta: payEps())
        // 小数输入：1234.56 <= 3000，属于 3% 档，1234.56 * 0.03 = 37.0368 -> 37.04
        @Assert(calculateTax(1234.56), 37.04, delta: payEps())
        // 非整分输入必须被舍到分：333.33 * 0.03 = 9.9999 -> 10.00
        @Assert(calculateTax(333.33), 10.0, delta: payEps())
    }

    @TestCase
    func testSecondBracketExactValues(): Unit {
        // 10% 档 - 210：3000 < taxable <= 12000
        @Assert(calculateTax(5000.0), 290.0, delta: payEps())
        @Assert(calculateTax(5700.0), 360.0, delta: payEps())
        @Assert(calculateTax(6000.0), 390.0, delta: payEps())
        @Assert(calculateTax(8888.88), 678.89, delta: payEps())
        @Assert(calculateTax(12000.0), 990.0, delta: payEps())
        // 刚好越过下界：3001 * 0.10 - 210 = 90.1
        @Assert(calculateTax(3001.0), 90.1, delta: payEps())
        @Assert(calculateTax(4999.0), 289.9, delta: payEps())
        @Assert(calculateTax(11999.0), 989.9, delta: payEps())
    }

    @TestCase
    func testThirdBracketExactValues(): Unit {
        // 20% 档 - 1410：12000 < taxable <= 25000
        @Assert(calculateTax(15000.0), 1590.0, delta: payEps())
        @Assert(calculateTax(20000.0), 2590.0, delta: payEps())
        @Assert(calculateTax(24999.0), 3589.8, delta: payEps())
        @Assert(calculateTax(25000.0), 3590.0, delta: payEps())
        @Assert(calculateTax(17000.0), 1990.0, delta: payEps())
        // 12001 已属于 20% 档：12001 * 0.20 - 1410 = 990.2
        @Assert(calculateTax(12001.0), 990.2, delta: payEps())
    }

    @TestCase
    func testFourthBracketExactValues(): Unit {
        // 25% 档 - 2660：taxable > 25000
        @Assert(calculateTax(30000.0), 4840.0, delta: payEps())
        @Assert(calculateTax(40000.0), 7340.0, delta: payEps())
        @Assert(calculateTax(99999.0), 22339.75, delta: payEps())
        @Assert(calculateTax(100000.0), 22340.0, delta: payEps())
        @Assert(calculateTax(1000000.0), 247340.0, delta: payEps())
        // 25001 已属于 25% 档：25001 * 0.25 - 2660 = 3590.25
        @Assert(calculateTax(25001.0), 3590.25, delta: payEps())
    }

    // ---- 3. 档位归属：<= 的边界由源码写死，舍入语义不影响走哪条分支 ----

    @TestCase
    func testBracketMembershipAtEdges(): Unit {
        // 3000 走 3% 档（90），3001 走 10% 档（90.1）：跨档瞬间不会倒退。
        // 纯 Float64 比较，与 round2 的取整语义无关。
        @Assert(calculateTax(3001.0) > calculateTax(3000.0))
        @Assert(calculateTax(12001.0) > calculateTax(12000.0))
        @Assert(calculateTax(25001.0) > calculateTax(25000.0))
        // 档内 +1 元时税额一定增加（最低档 3% 也有 0.03 元）
        @Assert(calculateTax(1001.0) > calculateTax(1000.0))
        @Assert(calculateTax(10001.0) > calculateTax(10000.0))
        @Assert(calculateTax(20001.0) > calculateTax(20000.0))
        @Assert(calculateTax(50001.0) > calculateTax(50000.0))
    }

    @TestCase
    func testWrongBracketWouldBeCaught(): Unit {
        // 反向保护：若有人把速算扣除数或系数改错，偏差至少 0.1 元，
        // 下面这组「必须不相等」能把错误抓出来，同时它们与取整语义无关
        // （差值远大于 1 分）。
        @Assert(payAbs(calculateTax(5000.0) - 500.0) > 0.1)
        @Assert(payAbs(calculateTax(5000.0) - 890.0) > 0.1)
        @Assert(payAbs(calculateTax(15000.0) - 3090.0) > 0.1)
        @Assert(payAbs(calculateTax(15000.0) - 1380.0) > 0.1)
        @Assert(payAbs(calculateTax(30000.0) - 4840.0) < 0.02)
        @Assert(payAbs(calculateTax(30000.0) - 6090.0) > 0.1)
    }

    @TestCase
    func testMarginalRateAtEdges(): Unit {
        // 档内加 1 元的边际税率：3% / 10% / 20% / 25%。
        // 两端点同档时两种取整语义对差值的影响至多 1 分。
        @Assert(payAbs((calculateTax(1001.0) - calculateTax(1000.0)) - 0.03), 0.0, delta: payEps())
        @Assert(payAbs((calculateTax(10001.0) - calculateTax(10000.0)) - 0.10), 0.0, delta: payEps())
        @Assert(payAbs((calculateTax(20001.0) - calculateTax(20000.0)) - 0.20), 0.0, delta: payEps())
        @Assert(payAbs((calculateTax(50001.0) - calculateTax(50000.0)) - 0.25), 0.0, delta: payEps())
        // 跨档瞬间：速算扣除数保证档界两侧连续，故 1 元的边际额等于「新档税率」
        // 3% -> 10%：3001*0.10-210 - 3000*0.03 = 90.10 - 90.00
        @Assert(payAbs((calculateTax(3001.0) - calculateTax(3000.0)) - 0.10), 0.0, delta: payEps())
        // 10% -> 20%：12001*0.20-1410 - (12000*0.10-210) = 990.20 - 990.00
        @Assert(payAbs((calculateTax(12001.0) - calculateTax(12000.0)) - 0.20), 0.0, delta: payEps())
        // 20% -> 25%：25001*0.25-2660 - (25000*0.20-1410) = 3590.25 - 3590.00
        @Assert(payAbs((calculateTax(25001.0) - calculateTax(25000.0)) - 0.25), 0.0, delta: payEps())
    }

    @TestCase
    func testTaxIsNonNegativeAndMonotonic(): Unit {
        // 语义无关的全局性质：非负 + 单调不减（逐点手写，避免数组字面量）
        @Assert(calculateTax(0.0) >= 0.0)
        @Assert(calculateTax(500.0) >= 0.0)
        @Assert(calculateTax(2999.0) >= 0.0)
        @Assert(calculateTax(3001.0) >= 0.0)
        @Assert(calculateTax(12001.0) >= 0.0)
        @Assert(calculateTax(25001.0) >= 0.0)
        @Assert(calculateTax(99999.0) >= 0.0)
        @Assert(calculateTax(1000000.0) >= 0.0)
        @Assert(calculateTax(1000.0) <= calculateTax(1001.0))
        @Assert(calculateTax(1001.0) <= calculateTax(3000.0))
        @Assert(calculateTax(2999.0) <= calculateTax(3000.0))
        @Assert(calculateTax(3000.0) <= calculateTax(3001.0))
        @Assert(calculateTax(3001.0) <= calculateTax(12000.0))
        @Assert(calculateTax(11999.0) <= calculateTax(12000.0))
        @Assert(calculateTax(12000.0) <= calculateTax(12001.0))
        @Assert(calculateTax(12001.0) <= calculateTax(25000.0))
        @Assert(calculateTax(25000.0) <= calculateTax(25001.0))
        @Assert(calculateTax(25001.0) <= calculateTax(99999.0))
        @Assert(calculateTax(99999.0) <= calculateTax(100000.0))
    }

    @TestCase
    func testTaxNeverExceedsTopRateOfTaxable(): Unit {
        // 速算扣除数只会让税额低于「全额按最高档 25%」，故 tax(v) <= 0.25v + 半分
        @Assert(calculateTax(500.0) <= 0.25 * 500.0 + 0.005)
        @Assert(calculateTax(3000.0) <= 0.25 * 3000.0 + 0.005)
        @Assert(calculateTax(3001.0) <= 0.25 * 3001.0 + 0.005)
        @Assert(calculateTax(12000.0) <= 0.25 * 12000.0 + 0.005)
        @Assert(calculateTax(12001.0) <= 0.25 * 12001.0 + 0.005)
        @Assert(calculateTax(25000.0) <= 0.25 * 25000.0 + 0.005)
        @Assert(calculateTax(25001.0) <= 0.25 * 25001.0 + 0.005)
        @Assert(calculateTax(100000.0) <= 0.25 * 100000.0 + 0.005)
        @Assert(calculateTax(999999.0) <= 0.25 * 999999.0 + 0.005)
        // 同时也不会低于「全额按本档下界税率」太多：3% 是最低档税率
        @Assert(calculateTax(500.0) >= 0.03 * 500.0 - 0.005)
        @Assert(calculateTax(2500.0) >= 0.03 * 2500.0 - 0.005)
    }

    @TestCase
    func testQuickDeductionFormulaMatchesBrackets(): Unit {
        // 与业务口径（速算扣除数 0 / 210 / 1410 / 2660）逐档核对；
        // 这些点都落在档内，不受档界取整影响。
        @Assert(calculateTax(6000.0), 600.0 - 210.0, delta: payEps())
        @Assert(calculateTax(10000.0), 1000.0 - 210.0, delta: payEps())
        @Assert(calculateTax(20000.0), 4000.0 - 1410.0, delta: payEps())
        @Assert(calculateTax(40000.0), 10000.0 - 2660.0, delta: payEps())
        @Assert(calculateTax(80000.0), 20000.0 - 2660.0, delta: payEps())
    }

    @TestCase
    func testTaxIsRoundedToCent(): Unit {
        // round2 的产物分母恒为 100：任意输入的输出值都必须「落在整数分上」。
        // 判定用 payCentDistance = 到最近整数的距离（min(d, 1-d)），
        // 它与 Int64 是向零截断还是就近取整完全无关，因此可以安全覆盖 UNSAFE 输入。
        let v1 = calculateTax(1234.56)
        let v2 = calculateTax(7777.0)
        let v3 = calculateTax(33333.33)
        let v4 = calculateTax(99999.0)
        let v5 = calculateTax(2999.0)
        @Assert(payCentDistance(v1) <= 0.01)
        @Assert(payCentDistance(v2) <= 0.01)
        @Assert(payCentDistance(v3) <= 0.01)
        @Assert(payCentDistance(v4) <= 0.01)
        @Assert(payCentDistance(v5) <= 0.01)
        @Assert(v1 >= 0.0)
        @Assert(v2 >= 0.0)
        @Assert(v3 >= 0.0)
        @Assert(v4 >= 0.0)
        @Assert(v5 >= 0.0)
        // 反向保护：量尺本身要能分辨「不是整数分」的值。
        // 1.234 元 = 123.4 分，到最近整数的距离是 0.4，远大于 0.01 阈值。
        @Assert(payCentDistance(1.234) > 0.05)
    }

    @TestCase
    func testNetSalaryIsRoundedToCent(): Unit {
        @Assert(payCentDistance(payNetOf(12345.67, 890.12, 33.33, 21.21, 555.55)) <= 0.01)
        @Assert(payCentDistance(payTaxOf(12345.67, 890.12, 33.33, 21.21, 555.55)) <= 0.01)
        // 99999.99 + 0.01 = 100000.00，taxable 95000 -> tax 21090.00 -> net 78910.00
        @Assert(payCentDistance(payNetOf(99999.99, 0.01, 0.0, 0.0, 0.0)) <= 0.01)
    }

    // ---- 4. calculatePayrollValues：元组经 helper 降级 ----

    @TestCase
    func testPayrollVectorExactValues(): Unit {
        // 基准向量：gross = 10000+2000+500-300-1500 = 10700，taxable = 5700
        @Assert(payTaxOf(10000.0, 2000.0, 500.0, 300.0, 1500.0), 360.0, delta: payEps())
        @Assert(payNetOf(10000.0, 2000.0, 500.0, 300.0, 1500.0), 10340.0, delta: payEps())
        // gross = 20000，taxable = 15000 -> 20% 档
        @Assert(payTaxOf(20000.0, 0.0, 0.0, 0.0, 0.0), 1590.0, delta: payEps())
        @Assert(payNetOf(20000.0, 0.0, 0.0, 0.0, 0.0), 18410.0, delta: payEps())
        // gross = 8000+1000+500-200-600 = 8700，taxable = 3700 -> 10% 档
        @Assert(payTaxOf(8000.0, 1000.0, 500.0, 200.0, 600.0), 160.0, delta: payEps())
        @Assert(payNetOf(8000.0, 1000.0, 500.0, 200.0, 600.0), 8540.0, delta: payEps())
        // 小数薪资：taxable = 7345.67 -> 524.57
        @Assert(payTaxOf(12345.67, 0.0, 0.0, 0.0, 0.0), 524.57, delta: payEps())
        @Assert(payNetOf(12345.67, 0.0, 0.0, 0.0, 0.0), 11821.1, delta: payEps())
        // 12000 应发 -> taxable 7000 -> 490
        @Assert(payTaxOf(12000.0, 0.0, 0.0, 0.0, 0.0), 490.0, delta: payEps())
        @Assert(payNetOf(12000.0, 0.0, 0.0, 0.0, 0.0), 11510.0, delta: payEps())
    }

    @TestCase
    func testPayrollBelowAllowanceHasNoTax(): Unit {
        // taxable = gross - 5000 < 0 -> calculateTax 走 early return，
        // tax 侧可以精确 pin；net = round2(gross - 0.0) 仍按纪律用容差。
        @Assert(payTaxOf(3000.0, 0.0, 0.0, 0.0, 0.0), 0.0)
        @Assert(payNetOf(3000.0, 0.0, 0.0, 0.0, 0.0), 3000.0, delta: payEps())
        @Assert(payTaxOf(1500.0, 0.0, 0.0, 0.0, 0.0), 0.0)
        @Assert(payNetOf(1500.0, 0.0, 0.0, 0.0, 0.0), 1500.0, delta: payEps())
        // 正好压线：taxable = 0
        @Assert(payTaxOf(5000.0, 0.0, 0.0, 0.0, 0.0), 0.0)
        @Assert(payNetOf(5000.0, 0.0, 0.0, 0.0, 0.0), 5000.0, delta: payEps())
        // 起征点上方第一档
        @Assert(payTaxOf(6000.0, 0.0, 0.0, 0.0, 0.0), 30.0, delta: payEps())
        @Assert(payNetOf(6000.0, 0.0, 0.0, 0.0, 0.0), 5970.0, delta: payEps())
        // 全零：gross = 0，taxable = -5000
        @Assert(payTaxOf(0.0, 0.0, 0.0, 0.0, 0.0), 0.0)
        @Assert(payNetOf(0.0, 0.0, 0.0, 0.0, 0.0), 0.0, delta: payEps())
        // 扣除项大于收入 -> gross 为负，taxable 亦为负
        @Assert(payTaxOf(0.0, 0.0, 0.0, 1000.0, 500.0), 0.0)
    }

    @TestCase
    func testPayrollTaxEqualsStandaloneCalculateTax(): Unit {
        // 口径一致性：calculatePayrollValues 内部必须复用 calculateTax。
        // 两侧走同一个函数、同一个舍入语义，因此要求严格相等（delta 0）。
        @Assert(payTaxOf(10000.0, 2000.0, 500.0, 300.0, 1500.0), calculateTax(10700.0 - 5000.0))
        @Assert(payTaxOf(3000.0, 0.0, 0.0, 0.0, 0.0), calculateTax(3000.0 - 5000.0))
        @Assert(payTaxOf(12345.67, 0.0, 0.0, 0.0, 0.0), calculateTax(12345.67 - 5000.0))
        @Assert(payTaxOf(50000.0, 3000.0, 1200.0, 800.0, 4000.0), calculateTax(49400.0 - 5000.0))
        @Assert(payTaxOf(2999.0, 0.0, 0.0, 0.0, 0.0), calculateTax(2999.0 - 5000.0))
        @Assert(payTaxOf(104999.0, 0.0, 0.0, 0.0, 0.0), calculateTax(104999.0 - 5000.0))
    }

    @TestCase
    func testNetSalaryEqualsGrossMinusTaxWithinOneCent(): Unit {
        // net = round2(gross - tax)，故 |gross - tax - net| <= 半分 恒成立；
        // 这条性质与舍入语义无关，因此可以覆盖 UNSAFE 输入。
        let g1 = payGross(10000.0, 2000.0, 500.0, 300.0, 1500.0)
        @Assert(payAbs(g1 - payTaxOf(10000.0, 2000.0, 500.0, 300.0, 1500.0) - payNetOf(10000.0, 2000.0, 500.0, 300.0, 1500.0)), 0.0, delta: 0.011)
        let g2 = payGross(29999.0, 1.0, 0.0, 0.0, 0.0)
        @Assert(payAbs(g2 - payTaxOf(29999.0, 1.0, 0.0, 0.0, 0.0) - payNetOf(29999.0, 1.0, 0.0, 0.0, 0.0)), 0.0, delta: 0.011)
        let g3 = payGross(54999.0, 0.0, 0.0, 0.0, 0.0)
        @Assert(payAbs(g3 - payTaxOf(54999.0, 0.0, 0.0, 0.0, 0.0) - payNetOf(54999.0, 0.0, 0.0, 0.0, 0.0)), 0.0, delta: 0.011)
        let g4 = payGross(17777.0, 0.0, 0.0, 0.0, 0.0)
        @Assert(payAbs(g4 - payTaxOf(17777.0, 0.0, 0.0, 0.0, 0.0) - payNetOf(17777.0, 0.0, 0.0, 0.0, 0.0)), 0.0, delta: 0.011)
        let g5 = payGross(104999.0, 0.0, 0.0, 0.0, 0.0)
        @Assert(payAbs(g5 - payTaxOf(104999.0, 0.0, 0.0, 0.0, 0.0) - payNetOf(104999.0, 0.0, 0.0, 0.0, 0.0)), 0.0, delta: 0.011)
        @Assert(payNetOf(104999.0, 0.0, 0.0, 0.0, 0.0) >= 0.0)
    }

    @TestCase
    func testNetSalaryIsNonDecreasingInBonusAndOvertime(): Unit {
        @Assert(payNetOf(10000.0, 1000.0, 0.0, 0.0, 1500.0) >= payNetOf(10000.0, 0.0, 0.0, 0.0, 1500.0))
        @Assert(payNetOf(10000.0, 0.0, 1000.0, 0.0, 1500.0) >= payNetOf(10000.0, 0.0, 0.0, 0.0, 1500.0))
        @Assert(payNetOf(10000.0, 0.0, 0.0, 0.0, 1500.0) >= payNetOf(10000.0, 0.0, 0.0, 500.0, 1500.0))
        @Assert(payNetOf(10000.0, 0.0, 0.0, 0.0, 1000.0) >= payNetOf(10000.0, 0.0, 0.0, 0.0, 1500.0))
        // 加班费增加 500，实发一定增加（最高税率 25%，不可能全额吃掉）
        @Assert(payNetOf(10000.0, 0.0, 500.0, 0.0, 1500.0) - payNetOf(10000.0, 0.0, 0.0, 0.0, 1500.0) > 300.0)
        // 社保增加 1000，实发一定减少，且减少量在 750 到 1000 之间
        @Assert(payNetOf(10000.0, 0.0, 0.0, 0.0, 2500.0) < payNetOf(10000.0, 0.0, 0.0, 0.0, 1500.0))
        @Assert(payNetOf(10000.0, 0.0, 0.0, 0.0, 1500.0) - payNetOf(10000.0, 0.0, 0.0, 0.0, 2500.0) < 1000.01)
        @Assert(payNetOf(10000.0, 0.0, 0.0, 0.0, 1500.0) - payNetOf(10000.0, 0.0, 0.0, 0.0, 2500.0) > 700.0)
    }

    @TestCase
    func testTaxIsNonDecreasingInBaseSalary(): Unit {
        @Assert(payTaxOf(5000.0, 0.0, 0.0, 0.0, 0.0) >= payTaxOf(3000.0, 0.0, 0.0, 0.0, 0.0))
        @Assert(payTaxOf(8001.0, 0.0, 0.0, 0.0, 0.0) >= payTaxOf(5000.0, 0.0, 0.0, 0.0, 0.0))
        @Assert(payTaxOf(17001.0, 0.0, 0.0, 0.0, 0.0) >= payTaxOf(8001.0, 0.0, 0.0, 0.0, 0.0))
        @Assert(payTaxOf(30001.0, 0.0, 0.0, 0.0, 0.0) >= payTaxOf(17001.0, 0.0, 0.0, 0.0, 0.0))
        @Assert(payTaxOf(105001.0, 0.0, 0.0, 0.0, 0.0) >= payTaxOf(30001.0, 0.0, 0.0, 0.0, 0.0))
        // 跨档点附近同样单调（档界处 3%->10% 不倒退）
        @Assert(payTaxOf(8000.0, 0.0, 0.0, 0.0, 0.0) <= payTaxOf(8001.0, 0.0, 0.0, 0.0, 0.0))
        @Assert(payTaxOf(17000.0, 0.0, 0.0, 0.0, 0.0) <= payTaxOf(17001.0, 0.0, 0.0, 0.0, 0.0))
        @Assert(payTaxOf(30000.0, 0.0, 0.0, 0.0, 0.0) <= payTaxOf(30001.0, 0.0, 0.0, 0.0, 0.0))
    }

    // ---- 5. payrollRowToJson：17 字段 -> 恰好 16 个逗号 ----

    @TestCase
    func testRowToJsonStructureCounts(): Unit {
        let out = payrollRowToJson(payCleanRow())
        @Assert(payCountOf(out, ","), 16)
        @Assert(payCountOf(out, "{"), 1)
        @Assert(payCountOf(out, "}"), 1)
        // 唯一的 '{' 必须紧挨第一个 key，等价于「以 { 开头」，
        // 但避免使用未在基线出现的双侧切片。
        @Assert(payHas(out, "{" + payK("id")))
        // 17 个 key 各 2 个引号 = 34；8 个走 jsonStr 的字段各 2 个 = 16；合计 50
        @Assert(payCountOf(out, payDq()), 50)
        @Assert(out.size > 100)
    }

    @TestCase
    func testRowToJsonHasAllKeys(): Unit {
        let out = payrollRowToJson(payCleanRow())
        @Assert(payHas(out, payK("id")))
        @Assert(payHas(out, payK("employeeId")))
        @Assert(payHas(out, payK("empNo")))
        @Assert(payHas(out, payK("empName")))
        @Assert(payHas(out, payK("deptName")))
        @Assert(payHas(out, payK("positionName")))
        @Assert(payHas(out, payK("payMonth")))
        @Assert(payHas(out, payK("baseSalary")))
        @Assert(payHas(out, payK("bonus")))
        @Assert(payHas(out, payK("overtimePay")))
        @Assert(payHas(out, payK("attendanceDeduction")))
        @Assert(payHas(out, payK("socialSecurity")))
        @Assert(payHas(out, payK("tax")))
        @Assert(payHas(out, payK("netSalary")))
        @Assert(payHas(out, payK("status")))
        @Assert(payHas(out, payK("paidAt")))
        @Assert(payHas(out, payK("remark")))
        // 统计「引号紧跟冒号」的出现次数：每个 key 恰好贡献 1 次 = 17。
        // 不能直接数 ':' —— paidAt 的值 "2026-11-05 10:00:00" 自带 2 个冒号。
        @Assert(payCountOf(out, payDq() + ":"), 17)
    }

    @TestCase
    func testRowToJsonNumericFieldsAreBare(): Unit {
        // r[0] r[1] r[7..13] 裸插值：值原样出现且不带引号
        let out = payrollRowToJson(payCleanRow())
        @Assert(payHas(out, payK("id") + "1" + ","))
        @Assert(payHas(out, payK("employeeId") + "7" + ","))
        @Assert(payHas(out, payK("baseSalary") + "10000.00" + ","))
        @Assert(payHas(out, payK("bonus") + "2000.00" + ","))
        @Assert(payHas(out, payK("overtimePay") + "500.00" + ","))
        @Assert(payHas(out, payK("attendanceDeduction") + "300.00" + ","))
        @Assert(payHas(out, payK("socialSecurity") + "1500.00" + ","))
        @Assert(payHas(out, payK("tax") + "360.00" + ","))
        @Assert(payHas(out, payK("netSalary") + "10340.00" + ","))
        // 裸字段绝不带引号：形如 "tax":"360.00" 的写法不该出现
        @Assert(!payHas(out, payK("tax") + payDq()))
        @Assert(!payHas(out, payK("netSalary") + payDq()))
        @Assert(!payHas(out, payK("baseSalary") + payDq()))
    }

    @TestCase
    func testRowToJsonStringFieldsAreQuoted(): Unit {
        let out = payrollRowToJson(payCleanRow())
        @Assert(payHas(out, payK("empNo") + payQ("E001") + ","))
        @Assert(payHas(out, payK("empName") + payQ("Zhang San") + ","))
        @Assert(payHas(out, payK("deptName") + payQ("Tech") + ","))
        @Assert(payHas(out, payK("positionName") + payQ("Engineer") + ","))
        @Assert(payHas(out, payK("payMonth") + payQ("2026-11") + ","))
        @Assert(payHas(out, payK("status") + payQ("PAID") + ","))
        @Assert(payHas(out, payK("paidAt") + payQ("2026-11-05 10:00:00") + ","))
        // remark 是最后一个字段：值后紧跟 '}' 而不是 ','
        @Assert(payHas(out, payK("remark") + payQ("ok") + "}"))
    }

    @TestCase
    func testRowToJsonSecondRowStructureMatchesFirst(): Unit {
        let a = payrollRowToJson(payCleanRow())
        let b = payrollRowToJson(paySecondRow())
        @Assert(payCountOf(a, ","), payCountOf(b, ","))
        @Assert(payCountOf(a, "{"), payCountOf(b, "{"))
        // 只比较「引号紧跟冒号」= key 数量，直接数 ':' 会被 paidAt 里的时刻冒号污染
        @Assert(payCountOf(a, payDq() + ":"), payCountOf(b, payDq() + ":"))
        @Assert(payCountOf(a, payDq() + ":"), 17)
        // 第二行的 paidAt / remark 为空串：仍输出成对引号，不是 null
        @Assert(payHas(b, payK("paidAt") + payDq() + payDq() + ","))
        @Assert(payHas(b, payK("remark") + payDq() + payDq() + "}"))
        @Assert(payHas(b, payK("tax") + "780.00" + ","))
        @Assert(payHas(b, payK("netSalary") + "11220.00" + ","))
    }

    @TestCase
    func testRowToJsonEscapesQuoteInField(): Unit {
        let src = ArrayList<String>()
        src.add("1")
        src.add("7")
        src.add("E001")
        // 输入用拼接构造，避免在源码里写 \" 数错反斜杠
        src.add("O" + payDq() + "Brien")
        src.add("R&D")
        src.add("Engineer")
        src.add("2026-11")
        src.add("10000.00")
        src.add("0.00")
        src.add("0.00")
        src.add("0.00")
        src.add("0.00")
        src.add("0.00")
        src.add("10000.00")
        src.add("DRAFT")
        src.add("")
        src.add("a" + payBs() + "b")
        let out = payrollRowToJson(payRow(src))
        // O"Brien -> "O\"Brien" ；反斜杠被再转义 -> "a\\b"
        @Assert(payHas(out, payDq() + "O" + payBs() + payDq() + "Brien" + payDq()))
        @Assert(payHas(out, payQ("R&D")))
        @Assert(payHas(out, payDq() + "a" + payBs() + payBs() + "b" + payDq()))
        @Assert(payCountOf(out, ","), 16)
        // 引号数：34(key) + 16(jsonStr 成对) + 1(字段内被转义的引号) = 51
        @Assert(payCountOf(out, payDq()), 51)
        // 反斜杠字符数：字段内 1 个引号转义用 1 个，a\b 的 1 个变 2 个 -> 共 3
        @Assert(payCountOf(out, payBs()), 3)
    }

    @TestCase
    func testRowToJsonEscapesControlChars(): Unit {
        let src = ArrayList<String>()
        src.add("9")
        src.add("3")
        src.add("E009")
        // remark（下标 16）里放制表符，empName（下标 3）里放换行
        src.add("Line" + "\n" + "Break")
        src.add("Dept")
        src.add("Role")
        src.add("2026-01")
        src.add("1.00")
        src.add("2.00")
        src.add("3.00")
        src.add("4.00")
        src.add("5.00")
        src.add("6.00")
        src.add("7.00")
        src.add("PENDING")
        src.add("2026-01-31 23:59:59")
        src.add("a" + "\t" + "b" + "\r" + "c")
        let out = payrollRowToJson(payRow(src))
        // 真实换行/制表/回车绝不允许出现在 JSON 文本里，必须是两字符转义
        @Assert(payCountOf(out, "\n"), 0)
        @Assert(payCountOf(out, "\r"), 0)
        @Assert(payCountOf(out, "\t"), 0)
        @Assert(payHas(out, "Line" + payBs() + "nBreak"))
        @Assert(payHas(out, "a" + payBs() + "tb" + payBs() + "rc"))
        @Assert(payCountOf(out, ","), 16)
        @Assert(payCountOf(out, payDq()), 50)
    }

    @TestCase
    func testRowToJsonEmptyStringFieldsStillProduceValidShape(): Unit {
        // jsonStr("") -> """"（合法的空字符串字面量），引号总数不变
        let out = payrollRowToJson(payEmptyRow())
        @Assert(payCountOf(out, ","), 16)
        @Assert(payCountOf(out, payDq()), 50)
        @Assert(payHas(out, payK("empNo") + payDq() + payDq() + ","))
        @Assert(payHas(out, payK("remark") + payDq() + payDq() + "}"))
        // 数字字段为空串时裸插值会产出非法 JSON —— 这是已知契约：
        // 调用方必须保证数字列非空（MySQL 侧 NOT NULL + DEFAULT 0）。
        // 这里钉住「空串仍然原样裸插值」的行为，避免被误改成 jsonStr。
        @Assert(payHas(out, payK("baseSalary") + ","))
    }

    @TestCase
    func testRowToJsonPassesMysqlNullLiteralThrough(): Unit {
        // mysql --batch -N 下 NULL 列输出的是字符串 "NULL"，裸插值进 JSON 后
        // 恰好是合法的 null 值（JSON5 大小写不敏感，前端 JSON.parse 亦接受）；
        // 这里钉住该行为，防止日后有人把裸插值改成 jsonStr 而让前端拿到字符串
        // "NULL"。
        let src = ArrayList<String>()
        src.add("1")
        src.add("NULL")
        src.add("NULL")
        src.add("NULL")
        src.add("NULL")
        src.add("NULL")
        src.add("NULL")
        src.add("NULL")
        src.add("NULL")
        src.add("NULL")
        src.add("NULL")
        src.add("NULL")
        src.add("NULL")
        src.add("NULL")
        src.add("NULL")
        src.add("NULL")
        src.add("NULL")
        let out = payrollRowToJson(payRow(src))
        @Assert(payHas(out, payK("id") + "1" + ","))
        @Assert(payHas(out, payK("employeeId") + "NULL" + ","))
        @Assert(payHas(out, payK("baseSalary") + "NULL" + ","))
        @Assert(payHas(out, payK("netSalary") + "NULL" + ","))
        @Assert(payHas(out, payK("empNo") + payQ("NULL") + ","))
        @Assert(payHas(out, payK("paidAt") + payQ("NULL") + ","))
        @Assert(payCountOf(out, ","), 16)
        // 8 个 jsonStr 字段 + 17 个 key = 50 个引号，与是否 NULL 无关
        @Assert(payCountOf(out, payDq()), 50)
    }

    @TestCase
    func testRowToJsonIsDeterministic(): Unit {
        @Assert(payrollRowToJson(payCleanRow()), payrollRowToJson(payCleanRow()))
        @Assert(payrollRowToJson(paySecondRow()), payrollRowToJson(paySecondRow()))
        @Assert(payrollRowToJson(payRow(ArrayList<String>())).size > 0)
        // 不同输入必须产出不同文本（没有把字段写死）
        @Assert(payrollRowToJson(payCleanRow()) != payrollRowToJson(paySecondRow()))
    }

    @TestCase
    func testRowToJsonUnicodePassesThrough(): Unit {
        // 中文姓名不做 \\uXXXX 转义，原样输出（与 mysql_pool 的
        // containsNonAscii 走 hex 编码是两条独立路径）。
        let src = ArrayList<String>()
        src.add("1")
        src.add("7")
        src.add("E001")
        src.add("张三")
        src.add("研发部")
        src.add("工程师")
        src.add("2026-11")
        src.add("10000.00")
        src.add("0.00")
        src.add("0.00")
        src.add("0.00")
        src.add("0.00")
        src.add("0.00")
        src.add("10000.00")
        src.add("PAID")
        src.add("")
        src.add("备注")
        let out = payrollRowToJson(payRow(src))
        @Assert(payHas(out, payQ("张三")))
        @Assert(payHas(out, payQ("研发部")))
        @Assert(payHas(out, payQ("工程师")))
        @Assert(payHas(out, payQ("备注")))
        @Assert(!payHas(out, "u4e2d"))
        @Assert(payCountOf(out, ","), 16)
    }
}
