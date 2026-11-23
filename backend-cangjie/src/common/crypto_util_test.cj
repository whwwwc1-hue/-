package hrms_backend.common

import std.unittest.*
import std.unittest.testmacro.*
import std.convert.*
import stdx.encoding.hex.*

// =============================================================================
// crypto_util.cj 单元测试（P1.1）
//
// 与被测源码同目录、同 package，因此可以直接访问包内私有的
// deriveKey / legacyHash / isLegacyHash / splitStoredHash / PWD_SEP 等符号。
//
// 期望值来源（务必不要凭记忆改动）：
//   · SHA-256：FIPS 180-1 标准向量 + 本机 .NET 实算
//   · HMAC-SHA256：RFC 4231 Case 1 / 3 / 6 / 7（用例集取自 RFC 原文，
//     且自研 hmacSha256 的算法复刻已与 .NET HMACSHA256 逐用例比对 6/6 全等）
//   · deriveKey / legacyHash：本机 .NET 实算
// 详见 FOLLOWUP_PLAN.md 第十二节。
// =============================================================================

let CRYPT_SALT_HEX = "0a1b2c3d4e5f60718293a4b5c6d7e8f9"
let CRYPT_PWD = "Passw0rd!"

let CRYPT_RFC6_DATA = "Test Using Larger Than Block-Size Key - Hash Key First"
let CRYPT_RFC7_DATA = "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."

// 64 个十六进制字符（大写 / 含非法字符 / 长度不足）三种边界，用于 isLegacyHash
let CRYPT_HEX64_UPPER = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
let CRYPT_NONHEX64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg"
let CRYPT_HEX63 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde"
let CRYPT_ZEROS64 = "0000000000000000000000000000000000000000000000000000000000000000"

// ---- 测试辅助（名字带 crypt 前缀，避免与同包其它 *_test.cj 的顶层符号冲突）----

// RFC 4231 里大量出现「n 个相同字节」的 key / data，用已证实的 Array<T>(size, repeat:) 构造
func cryptFill(b: UInt8, n: Int64): Array<UInt8> {
    return Array<UInt8>(n, repeat: b)
}

// 由单字符重复出精确长度的字符串，避免手抄定长字面量数错字符
func cryptRepeatStr(s: String, n: Int64): String {
    var out = ""
    var i: Int64 = 0
    while (i < n) {
        out = out + s
        i = i + 1
    }
    return out
}

// 把 Option<元组> 拆成基本类型再断言：match 里不解构元组，先整体绑定再 let 解构
func cryptSplitIterations(storedHash: String): Int64 {
    match (splitStoredHash(storedHash)) {
        case Some(stored) =>
            let (iter, _, _, _) = stored
            return iter
        case None => return -1
    }
}

func cryptSplitSalt(storedHash: String): String {
    match (splitStoredHash(storedHash)) {
        case Some(stored) =>
            let (_, _, saltHex, _) = stored
            return saltHex
        case None => return ""
    }
}

@Test
class CryptoUtilTests {
    // ---- 固定字面量的自检：若这里红了，说明下面所有用例的输入都不成立 ----
    @TestCase
    func testVectorLiteralsAreWellFormed(): Unit {
        @Assert(CRYPT_RFC6_DATA.toArray().size, 54)
        @Assert(CRYPT_RFC7_DATA.toArray().size, 152)
        @Assert(CRYPT_HEX64_UPPER.size, 64)
        @Assert(CRYPT_NONHEX64.size, 64)
        @Assert(CRYPT_HEX63.size, 63)
        @Assert(CRYPT_ZEROS64.size, 64)
        @Assert(cryptRepeatStr("K", 80).size, 80)
        @Assert(cryptRepeatStr("a", 64).size, 64)
        @Assert(cryptRepeatStr("a", 65).size, 65)
        @Assert(cryptFill(0xaa, 131).size, 131)
    }

    // ---- SHA-256 ----
    @TestCase
    func testSha256KnownVectors(): Unit {
        @Assert(sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        @Assert(sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        @Assert(sha256Hex("hrms"), "fa1a197bd9f96af5adb2a3a789258a1c8e6d92fd11ae7246f713f50491e28c6c")
    }

    // 多字节字符：证明 String.toArray() 走 UTF-8 编码，而不是逐字符塞进单字节
    @TestCase
    func testSha256UsesUtf8Encoding(): Unit {
        @Assert(sha256Hex("中文"), "72726d8818f693066ceb69afa364218b692e62ea92b385782363780f47529c21")
        @Assert(sha256Hex("中").size, 64)
    }

    @TestCase
    func testSha256BytesLengthAndDeterminism(): Unit {
        let a = sha256Bytes("hrms-cangjie".toArray())
        let b = sha256Bytes("hrms-cangjie".toArray())
        @Assert(a.size, 32)
        @Assert(toHexString(a), toHexString(b))
        @Assert(sha256Bytes("".toArray()).size, 32)
    }

    // ---- HMAC-SHA256：RFC 4231 官方向量 ----
    // Case 1：20 字节 key（<= 64 → 零填充分支），data 为 ASCII
    @TestCase
    func testHmacRfc4231Case1(): Unit {
        let mac = toHexString(hmacSha256(cryptFill(0x0b, 20), "Hi There".toArray()))
        @Assert(mac, "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    }

    // Case 3：20 字节 key + 50 字节全 0xdd 的 data（二进制消息路径）
    @TestCase
    func testHmacRfc4231Case3(): Unit {
        let mac = toHexString(hmacSha256(cryptFill(0xaa, 20), cryptFill(0xdd, 50)))
        @Assert(mac, "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe")
    }

    // Case 6：131 字节 key（> 64 → 先 SHA-256 压缩分支）
    @TestCase
    func testHmacRfc4231Case6HashesLongKey(): Unit {
        let mac = toHexString(hmacSha256(cryptFill(0xaa, 131), CRYPT_RFC6_DATA.toArray()))
        @Assert(mac, "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    }

    // Case 7：长 key + 长 data（152 字节，跨多个 SHA-256 分组）
    @TestCase
    func testHmacRfc4231Case7LongKeyLongData(): Unit {
        let mac = toHexString(hmacSha256(cryptFill(0xaa, 131), CRYPT_RFC7_DATA.toArray()))
        @Assert(mac, "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2")
    }

    // 字符串重载必须与字节重载完全一致，且覆盖 key 长度 0 / 64（恰好分组）/ 65（刚超）三个边界
    @TestCase
    func testHmacHexWrapperMatchesBytesAndCoversKeyBoundaries(): Unit {
        @Assert(hmacSha256Hex("secret", "message"), "8b5f48702995c1598c573db1e21866a9b825d4a794d169d7060a03605796360b")
        @Assert(hmacSha256Hex("", ""), "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad")
        @Assert(hmacSha256Hex(cryptRepeatStr("a", 64), "abc"), "6608ac82dca1cb1fddbb5d81e3d9877642b744f565cd9697ac27daa250c80d28")
        @Assert(hmacSha256Hex(cryptRepeatStr("a", 65), "abc"), "c0d2f0e7f578e80e4996cf2ffb922ea70fe1094e693f2cd75bbba0281add9da5")
        @Assert(hmacSha256Hex(cryptRepeatStr("K", 80), "payload"), "3d894929e2e6e1624e70f4dd61a35656225fda4b1150bcd21d48c3023a2e286f")
        @Assert(hmacSha256Hex("Jefe", "what do ya want for nothing?"), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        // 字节重载与字符串重载在 ASCII 输入下必须逐位相同
        @Assert(toHexString(hmacSha256("Jefe".toArray(), "what do ya want for nothing?".toArray())),
                hmacSha256Hex("Jefe", "what do ya want for nothing?"))
    }

    // 改一个 bit 就必须换整个 MAC（否则签名可以被逐位伪造）
    @TestCase
    func testHmacAvalanche(): Unit {
        let m1 = hmacSha256Hex("key", "message")
        let m2 = hmacSha256Hex("key", "messagf")
        let m3 = hmacSha256Hex("kez", "message")
        @Assert(m1.size, 64)
        @Assert(m1 != m2)
        @Assert(m1 != m3)
        @Assert(m2 != m3)
    }

    // ---- 常数时间比较 ----
    @TestCase
    func testConstantTimeEquals(): Unit {
        @Assert(constantTimeEquals("", ""))
        @Assert(constantTimeEquals("abc", "abc"))
        @Assert(constantTimeEquals(CRYPT_ZEROS64, CRYPT_ZEROS64))
        @Assert(!constantTimeEquals("abc", "abd"))
        @Assert(!constantTimeEquals("abc", "ab"))
        @Assert(!constantTimeEquals("ab", "abc"))
        @Assert(!constantTimeEquals("", "a"))
        @Assert(!constantTimeEquals("中文", "中"))
    }

    // ---- 随机数 ----
    @TestCase
    func testRandomBytesAndHex(): Unit {
        @Assert(randomBytes(0).size, 0)
        @Assert(randomBytes(8).size, 8)
        @Assert(randomBytes(32).size, 32)
        @Assert(randomHex(16).size, 32)
        // 盐必须唯一：两次取样的十六进制串不应相同
        @Assert(randomHex(16) != randomHex(16))
    }

    // ---- 口令派生：迭代拉伸必须真正生效 ----
    @TestCase
    func testDeriveKeyIterations(): Unit {
        @Assert(deriveKey(CRYPT_SALT_HEX, CRYPT_PWD, 1), "7e761c1334828544d447f253a916f367104c0c16c054951f90208eca55196ed6")
        @Assert(deriveKey(CRYPT_SALT_HEX, CRYPT_PWD, 2), "49d0540dd3bfd9c02fed2406a03758371aa8b77b99403d8d6ffd5c3178f1cb49")
        @Assert(deriveKey(CRYPT_SALT_HEX, CRYPT_PWD, 3), "3e1a3768115e7c5b5c8719f9c7ad88f61d6e92213d89700ce611235f01917d1b")
        // iterations <= 1 与 1 等价（边界：0 / 负数不得让 while 死循环）
        @Assert(deriveKey(CRYPT_SALT_HEX, CRYPT_PWD, 0), deriveKey(CRYPT_SALT_HEX, CRYPT_PWD, 1))
        @Assert(deriveKey(CRYPT_SALT_HEX, CRYPT_PWD, -5), deriveKey(CRYPT_SALT_HEX, CRYPT_PWD, 1))
        // 不同口令 / 不同盐必须派生出不同摘要
        @Assert(deriveKey(CRYPT_SALT_HEX, "other", 3) != deriveKey(CRYPT_SALT_HEX, CRYPT_PWD, 3))
        @Assert(deriveKey("ffffffffffffffffffffffffffffffff", CRYPT_PWD, 3) != deriveKey(CRYPT_SALT_HEX, CRYPT_PWD, 3))
    }

    // ---- 遗留格式（只读兼容） ----
    @TestCase
    func testLegacyHashAndDetection(): Unit {
        @Assert(legacyHash("admin123"), "01af9bb1ecaaa9cca89e8e32f9d910ce776133525f804dc117a29d7ee6b14e7c")
        @Assert(legacyHash("admin123").size, 64)
        @Assert(isLegacyHash(legacyHash("admin123")))
        @Assert(isLegacyHash(CRYPT_HEX64_UPPER))
        @Assert(!isLegacyHash(CRYPT_NONHEX64))
        @Assert(!isLegacyHash(CRYPT_HEX63))
        @Assert(!isLegacyHash(""))
        @Assert(!isLegacyHash(CRYPT_ZEROS64 + "0"))
    }

    // ---- 新格式哈希：结构 + 往返 ----
    @TestCase
    func testHashPasswordFormatAndRoundTrip(): Unit {
        let stored = hashPassword(CRYPT_PWD)
        @Assert(stored.startsWith(PWD_PREFIX))
        @Assert(cryptSplitIterations(stored), PWD_ITERATIONS)
        @Assert(cryptSplitSalt(stored).size, PWD_SALT_BYTES * 2)
        @Assert(verifyPassword(CRYPT_PWD, stored))
        @Assert(!verifyPassword("Passw0rd", stored))
        @Assert(!verifyPassword(CRYPT_PWD, hashPassword("different")))
        @Assert(!needsRehash(stored))
        // 两个用户即使口令相同，落库哈希也必须不同（这正是 D7 要修的撞库问题）
        @Assert(hashPassword(CRYPT_PWD) != hashPassword(CRYPT_PWD))
    }

    // 每个哈希段之间必须恰好由 PWD_SEP 分隔成 4 段
    @TestCase
    func testHashPasswordHasFourSegments(): Unit {
        let parts = hashPassword(CRYPT_PWD).split(PWD_SEP)
        @Assert(parts.size, 4)
        @Assert(parts[0], PWD_PREFIX)
        @Assert(parts[1], "${PWD_ITERATIONS}")
    }

    // ---- verifyPassword 对畸形存储值的健壮性（不得抛异常，一律拒绝） ----
    @TestCase
    func testVerifyPasswordRejectsMalformed(): Unit {
        @Assert(!verifyPassword(CRYPT_PWD, ""))
        @Assert(!verifyPassword(CRYPT_PWD, "x"))
        @Assert(!verifyPassword(CRYPT_PWD, PWD_PREFIX))
        @Assert(!verifyPassword(CRYPT_PWD, "cj" + PWD_SEP + "2000" + PWD_SEP + "ab" + PWD_SEP + "cd"))
        @Assert(!verifyPassword(CRYPT_PWD, PWD_PREFIX + PWD_SEP + "2000" + PWD_SEP + "ab"))
        @Assert(!verifyPassword(CRYPT_PWD, PWD_PREFIX + PWD_SEP + "abc" + PWD_SEP + "ab" + PWD_SEP + "cd"))
        @Assert(!verifyPassword(CRYPT_PWD, PWD_PREFIX + PWD_SEP + "0" + PWD_SEP + "ab" + PWD_SEP + "cd"))
        @Assert(!verifyPassword(CRYPT_PWD, PWD_PREFIX + PWD_SEP + "-1" + PWD_SEP + "ab" + PWD_SEP + "cd"))
        @Assert(!verifyPassword(CRYPT_PWD, PWD_PREFIX + PWD_SEP + "2000" + PWD_SEP + PWD_SEP + "cd"))
        @Assert(!verifyPassword(CRYPT_PWD, PWD_PREFIX + PWD_SEP + "2000" + PWD_SEP + "ab" + PWD_SEP + ""))
    }

    @TestCase
    func testSplitStoredHashParsesWellFormedOnly(): Unit {
        let stored = hashPassword(CRYPT_PWD)
        @Assert(cryptSplitIterations(stored) > 0)
        @Assert(cryptSplitIterations("nope") == -1)
        @Assert(cryptSplitIterations("cj2" + PWD_SEP + "10" + PWD_SEP + "aa" + PWD_SEP + "bb") == -1)
        @Assert(cryptSplitIterations(PWD_PREFIX + PWD_SEP + "10" + PWD_SEP + "aa" + PWD_SEP + "bb"), 10)
    }

    // ---- 低迭代旧参数：能通过校验，但需要升级 ----
    @TestCase
    func testLowIterationHashVerifiesButNeedsRehash(): Unit {
        let weak = PWD_PREFIX + PWD_SEP + "1000" + PWD_SEP + CRYPT_SALT_HEX + PWD_SEP + deriveKey(CRYPT_SALT_HEX, CRYPT_PWD, 1000)
        @Assert(cryptSplitIterations(weak), 1000)
        @Assert(verifyPassword(CRYPT_PWD, weak))
        @Assert(!verifyPassword("wrong-pwd", weak))
        @Assert(needsRehash(weak))
    }

    // ---- 摘要被篡改：必须拒绝，且绝不能把非法值当成遗留哈希放行 ----
    @TestCase
    func testTamperedDigestIsRejected(): Unit {
        let tampered = PWD_PREFIX + PWD_SEP + "2000" + PWD_SEP + CRYPT_SALT_HEX + PWD_SEP + CRYPT_ZEROS64
        @Assert(!verifyPassword(CRYPT_PWD, tampered))
        @Assert(needsRehash(tampered) == false)
        // 遗留哈希走的是另一条分支：口令对得上才放行
        let legacy = legacyHash("admin123")
        @Assert(verifyPassword("admin123", legacy))
        @Assert(!verifyPassword("admin124", legacy))
        @Assert(needsRehash(legacy))
        @Assert(cryptSplitIterations(legacy) == -1)
    }

    // ---- 暴露给 /health 的参数快照 ----
    @TestCase
    func testPasswordHashParams(): Unit {
        let (iter, saltLen) = passwordHashParams()
        @Assert(iter, PWD_ITERATIONS)
        @Assert(saltLen, PWD_SALT_BYTES)
        @Assert(iter > 0)
        @Assert(saltLen > 0)
    }

    // ---- 口令为空串时的行为要确定（不能把空口令哈希成可校验通过的值） ----
    @TestCase
    func testEmptyPasswordBehaviour(): Unit {
        let stored = hashPassword("")
        @Assert(verifyPassword("", stored))
        @Assert(!verifyPassword(" ", stored))
        @Assert(!verifyPassword("a", stored))
    }
}
