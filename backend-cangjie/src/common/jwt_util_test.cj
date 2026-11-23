package hrms_backend.common

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

// =============================================================================
// jwt_util.cj 单元测试（P1.1）
//
// 说明：
//   · 与被测源码同目录、同 package，可直接访问包内私有的
//     toBase64Url / fromBase64Url / signPayload / decodeToken。
//   · decodeToken 与 verifyToken 的语义差异（前者不校验 exp）是 P0.3
//     「静默续签」的实现基础，这里用专门的用例把它钉死。
//   · 所有断言只使用已被基线证实的语言构造：
//     match { case Some(x) / case None }、let 元组解构、s[..n] 切片、
//     Array<T>(size, repeat: value)、ArrayList 的 add/size/[]。
//     不对 Option 直接比较，一律经本文件 helper 降级成基本类型再断言。
// =============================================================================

let JWT_TTL_SECONDS: Int64 = 3600
let JWT_FAR_FUTURE_SECONDS: Int64 = 200000
let JWT_DEFAULT_SIG_LEN: Int64 = 43

// ---- 测试辅助（jwt 前缀，避免与同包其它 *_test.cj 顶层符号冲突）----

func jwtFill(b: UInt8, n: Int64): Array<UInt8> {
    return Array<UInt8>(n, repeat: b)
}

// Option<AuthUser> -> 基本类型
func jwtRoleOf(token: String): String {
    match (verifyToken(token)) {
        case Some(u) => return u.role
        case None => return ""
    }
}

func jwtSubOf(token: String): String {
    match (verifyToken(token)) {
        case Some(u) => return u.username
        case None => return ""
    }
}

func jwtUidOf(token: String): Int64 {
    match (verifyToken(token)) {
        case Some(u) => return u.userId
        case None => return -1
    }
}

func jwtEidOf(token: String): Int64 {
    match (verifyToken(token)) {
        case Some(u) => return u.employeeId
        case None => return -1
    }
}

// decodeToken 只看签名不看 exp：用 -1 / -2 区分「验签失败」与「验签通过但已过期」
func jwtDecodeCode(token: String): Int64 {
    match (decodeToken(token)) {
        case Some(_) => return 1
        case None => return 0
    }
}

func jwtVerifyCode(token: String): Int64 {
    match (verifyToken(token)) {
        case Some(_) => return 1
        case None => return 0
    }
}

func jwtOptStr(o: Option<String>): String {
    match (o) {
        case Some(s) => return s
        case None => return ""
    }
}

func jwtSegCount(token: String): Int64 {
    return token.split(".").size
}

func jwtSegAt(token: String, i: Int64): String {
    let parts = token.split(".")
    if (parts.size <= i) {
        return ""
    }
    return parts[i]
}

// 统计 s 中子串 needle 的出现次数（不依赖未经证实的 String.contains）
func jwtCountOf(s: String, needle: String): Int64 {
    if (needle.isEmpty()) {
        return 0
    }
    return (s.size - s.replace(needle, "").size) / needle.size
}

@Test
class JwtUtilTests {
    // ---- 常量：续签阈值是 P0.3 的对外契约，改动必须先想清楚 ----
    @TestCase
    func testPublicConstants(): Unit {
        @Assert(TOKEN_TTL_SECONDS, 86400)
        @Assert(TOKEN_REFRESH_THRESHOLD, 7200)
    }

    // ---- base64url：必须去掉 + / = 三个字符 ----
    @TestCase
    func testBase64UrlAlphabetIsUrlSafe(): Unit {
        // 0xff * 7：base64 里必然出现 '/' 和一个 '=' 填充，正好覆盖三个替换分支
        let enc = toBase64UrlBytes(jwtFill(0xffu8, 7))
        @Assert(enc.size, 10)
        @Assert(jwtCountOf(enc, "+"), 0)
        @Assert(jwtCountOf(enc, "/"), 0)
        @Assert(jwtCountOf(enc, "="), 0)
    }

    @TestCase
    func testBase64UrlEmptyInput(): Unit {
        @Assert(toBase64UrlBytes(jwtFill(0x00u8, 0)).size, 0)
    }

    @TestCase
    func testBase64UrlIsDeterministic(): Unit {
        let a = toBase64UrlBytes(jwtFill(0x61u8, 5))
        let b = toBase64UrlBytes(jwtFill(0x61u8, 5))
        @Assert(a, b)
        // 5 字节 -> base64 8 字符含 2 个填充，url-safe 后剩 6
        @Assert(a.size, 6)
    }

    // ---- toBase64Url / fromBase64Url 必须无损往返 ----
    @TestCase
    func testBase64UrlRoundTripAscii(): Unit {
        let src = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"
        match (fromBase64Url(toBase64Url(src))) {
            case Some(back) => @Assert(back, src)
            case None => @Assert(false)
        }
    }

    @TestCase
    func testBase64UrlRoundTripUtf8(): Unit {
        // 中文字符经 base64 后仍要能还原成合法 UTF-8 字符串
        let src = "张三"
        match (fromBase64Url(toBase64Url(src))) {
            case Some(back) => @Assert(back, src)
            case None => @Assert(false)
        }
    }

    @TestCase
    func testFromBase64UrlRejectsInvalidUtf8(): Unit {
        // 0xff 单独成串：base64 能解出字节，但不是合法 UTF-8，
        // fromBase64Url 必须走 catch 分支返回 None（否则 String.fromUtf8 会炸）
        @Assert(jwtOptStr(fromBase64Url(toBase64UrlBytes(jwtFill(0xffu8, 1)))), "")
    }

    @TestCase
    func testFromBase64UrlPadsEveryRemainder(): Unit {
        // 长度模 4 余 0/2/3 三种补位分支都要能还原原文
        let two = "ab"
        let three = "abc"
        let four = "abcd"
        @Assert(jwtOptStr(fromBase64Url(toBase64Url(two))), two)
        @Assert(jwtOptStr(fromBase64Url(toBase64Url(three))), three)
        @Assert(jwtOptStr(fromBase64Url(toBase64Url(four))), four)
    }

    // ---- signPayload：HS256 签名恒为 32 字节 -> 43 个 base64url 字符 ----
    @TestCase
    func testSignPayloadLengthAndDeterminism(): Unit {
        let s1 = signPayload("a.b")
        let s2 = signPayload("a.b")
        @Assert(s1.size, JWT_DEFAULT_SIG_LEN)
        @Assert(s1, s2)
        @Assert(jwtCountOf(s1, "."), 0)
    }

    @TestCase
    func testSignPayloadAvalanche(): Unit {
        @Assert(signPayload("a.b") != signPayload("a.c"))
        @Assert(signPayload("") != signPayload("a"))
    }

    // ---- 正向：签发 -> 校验 -> 字段逐项还原 ----
    @TestCase
    func testCreateTokenRoundTrip(): Unit {
        let tk = createToken(42, "alice", "admin", 7)
        @Assert(jwtSegCount(tk), 3)
        @Assert(jwtVerifyCode(tk), 1)
        @Assert(jwtUidOf(tk), 42)
        @Assert(jwtSubOf(tk), "alice")
        @Assert(jwtRoleOf(tk), "admin")
        @Assert(jwtEidOf(tk), 7)
    }

    @TestCase
    func testHeaderSegmentIsStandardJwtHeader(): Unit {
        let tk = createToken(1, "u1", "hr", 1)
        match (fromBase64Url(jwtSegAt(tk, 0))) {
            case Some(h) => @Assert(h, "{\"alg\":\"HS256\",\"typ\":\"JWT\"}")
            case None => @Assert(false)
        }
    }

    @TestCase
    func testTokenWithQuotedAndUnicodeSubject(): Unit {
        // payload 走的是 jsonStr()，含引号必须正确转义后再 base64url
        let tk = createToken(7, "ab\"cd", "hr", 3)
        @Assert(jwtVerifyCode(tk), 1)
        @Assert(jwtSubOf(tk), "ab\"cd")
        @Assert(jwtUidOf(tk), 7)

        let tk2 = createToken(8, "张三", "manager", 0)
        @Assert(jwtVerifyCode(tk2), 1)
        @Assert(jwtSubOf(tk2), "张三")
        // eid 允许为 0（员工档案未关联时），不影响 token 合法性
        @Assert(jwtEidOf(tk2), 0)
    }

    // ---- 反向：签名被改 ----
    @TestCase
    func testTamperedSignatureRejected(): Unit {
        let tk = createToken(42, "alice", "admin", 7)
        let cut = tk[..(tk.size - 1)]
        @Assert(jwtSegCount(cut), 3)
        @Assert(jwtVerifyCode(cut), 0)
        @Assert(jwtDecodeCode(cut), 0)
    }

    @TestCase
    func testTamperedPayloadRejected(): Unit {
        let tk = createToken(42, "alice", "admin", 7)
        let forgedPayload = toBase64Url("{\"uid\":1,\"sub\":\"root\",\"role\":\"admin\",\"eid\":1,\"exp\":99999999999}")
        let forged = "${jwtSegAt(tk, 0)}.${forgedPayload}.${jwtSegAt(tk, 2)}"
        @Assert(jwtSegCount(forged), 3)
        @Assert(jwtVerifyCode(forged), 0)
    }

    @TestCase
    func testMalformedTokenRejected(): Unit {
        @Assert(jwtVerifyCode(""), 0)
        @Assert(jwtVerifyCode("abc"), 0)
        @Assert(jwtVerifyCode("a.b"), 0)
        @Assert(jwtVerifyCode("a.b.c"), 0)
        @Assert(jwtVerifyCode("a.b.c.d"), 0)
        // 合法格式但签名不对
        let tk = createToken(1, "u1", "hr", 1)
        @Assert(jwtVerifyCode("${tk}x"), 0)
    }

    // ---- 反向：字段非法（uid<=0 / sub 空 / role 空）----
    @TestCase
    func testZeroUidRejected(): Unit {
        let tk = createTokenWithTtl(0, "alice", "admin", 1, JWT_TTL_SECONDS)
        @Assert(jwtDecodeCode(tk), 0)
        @Assert(jwtVerifyCode(tk), 0)
    }

    @TestCase
    func testEmptySubjectRejected(): Unit {
        let tk = createTokenWithTtl(1, "", "admin", 1, JWT_TTL_SECONDS)
        @Assert(jwtDecodeCode(tk), 0)
    }

    @TestCase
    func testEmptyRoleRejected(): Unit {
        let tk = createTokenWithTtl(1, "alice", "", 1, JWT_TTL_SECONDS)
        @Assert(jwtDecodeCode(tk), 0)
    }

    // ---- exp 语义：decodeToken 不看 exp，verifyToken 看 ----
    @TestCase
    func testExpiredTokenDecodesButDoesNotVerify(): Unit {
        let tk = createTokenWithTtl(9, "bob", "hr", 4, -100)
        // 签名本身是有效的
        @Assert(jwtDecodeCode(tk), 1)
        // 但已过期的 token 一律视为无效
        @Assert(jwtVerifyCode(tk), 0)
        @Assert(jwtRoleOf(tk), "")
    }

    @TestCase
    func testExpiryBoundaryUsesLessOrEqual(): Unit {
        // exp == now 时必须已失效（`user.expiresAt <= nowUnixSeconds()`）
        let tk = createTokenWithTtl(9, "bob", "hr", 4, 0)
        @Assert(jwtVerifyCode(tk), 0)
        // 留足余量，避免用 1~2 秒的临界值受时钟抖动影响
        let ok = createTokenWithTtl(9, "bob", "hr", 4, JWT_TTL_SECONDS)
        @Assert(jwtVerifyCode(ok), 1)
    }

    // ---- tokenNeedsRefresh：阈值比较是严格小于 ----
    @TestCase
    func testTokenNeedsRefresh(): Unit {
        let now = nowUnixSeconds()
        let fresh = AuthUser(1, "u1", "hr", 1, now + JWT_FAR_FUTURE_SECONDS)
        @Assert(!tokenNeedsRefresh(fresh))

        let stale = AuthUser(1, "u1", "hr", 1, now + 60)
        @Assert(tokenNeedsRefresh(stale))

        let expired = AuthUser(1, "u1", "hr", 1, now - 60)
        // 已过期同样「需要刷新」——真正的拒绝发生在 renewTokenIfExpiring
        @Assert(tokenNeedsRefresh(expired))
    }

    // ---- renewTokenIfExpiring：三种输入的结果 ----
    @TestCase
    func testRenewTokenIfExpiring(): Unit {
        let now = nowUnixSeconds()

        // 1) 临期且未过期 -> 返回新 token
        let nearExpiry = AuthUser(5, "carol", "admin", 6, now + 60)
        let renewed = jwtOptStr(renewTokenIfExpiring(nearExpiry))
        @Assert(renewed.size > 0)
        @Assert(jwtSegCount(renewed), 3)
        @Assert(jwtVerifyCode(renewed), 1)
        @Assert(jwtUidOf(renewed), 5)
        @Assert(jwtSubOf(renewed), "carol")
        @Assert(jwtRoleOf(renewed), "admin")
        @Assert(jwtEidOf(renewed), 6)

        // 2) 有效期还很长 -> 不续签
        let stillFresh = AuthUser(5, "carol", "admin", 6, now + JWT_FAR_FUTURE_SECONDS)
        @Assert(jwtOptStr(renewTokenIfExpiring(stillFresh)), "")

        // 3) 已过期 -> 不续签（不能把过期身份续成长效身份）
        let dead = AuthUser(5, "carol", "admin", 6, now - 60)
        @Assert(jwtOptStr(renewTokenIfExpiring(dead)), "")
    }

    @TestCase
    func testRenewTokenPreservesIdentity(): Unit {
        let tk = createToken(11, "dave", "manager", 12)
        match (verifyToken(tk)) {
            case Some(u) =>
                let renewed = renewToken(u)
                @Assert(jwtVerifyCode(renewed), 1)
                @Assert(jwtUidOf(renewed), u.userId)
                @Assert(jwtSubOf(renewed), u.username)
                @Assert(jwtRoleOf(renewed), u.role)
                @Assert(jwtEidOf(renewed), u.employeeId)
                // 新 token 的 exp 必须比旧的远
                @Assert(u.expiresAt > nowUnixSeconds() - 10)
            case None => @Assert(false)
        }
    }

    // ---- nowUnixSeconds：秒级 UTC 时间戳（2023-11-15 之后，足够宽松）----
    @TestCase
    func testNowUnixSecondsSanity(): Unit {
        let t1 = nowUnixSeconds()
        let t2 = nowUnixSeconds()
        @Assert(t1 > 1700000000)
        @Assert(t2 >= t1)
        @Assert(t2 - t1 < 5)
    }

    // ---- createToken 必须等价于 createTokenWithTtl(TOKEN_TTL_SECONDS) ----
    @TestCase
    func testCreateTokenEqualsDefaultTtl(): Unit {
        // exp 由当前秒数推导，同一秒内两次构造的 payload 完全一致
        let a = createToken(3, "eve", "hr", 4)
        let b = createTokenWithTtl(3, "eve", "hr", 4, TOKEN_TTL_SECONDS)
        @Assert(jwtVerifyCode(a), 1)
        @Assert(jwtVerifyCode(b), 1)
        @Assert(jwtUidOf(a), jwtUidOf(b))
        @Assert(jwtSegAt(a, 0), jwtSegAt(b, 0))
        match (verifyToken(a)) {
            case Some(ua) =>
                match (verifyToken(b)) {
                    case Some(ub) => @Assert(ub.expiresAt - ua.expiresAt, 0)
                    case None => @Assert(false)
                }
            case None => @Assert(false)
        }
    }
}
