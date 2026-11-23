package hrms_backend.common

import std.convert.*
import std.random.*
import std.sync.*
import stdx.crypto.digest.*
import stdx.encoding.hex.*

// =============================================================================
// 密码学工具（P0.3 安全加固版）
//
// 修复的两个原始缺陷：
//   D7  口令哈希使用「固定全局盐」，导致
//         - 撞库：两个用户密码相同则哈希相同，可横向比对；
//         - 彩虹表： salts 公开在源码里，一次预计算即可全库命中。
//       现在改为「每用户随机盐 + 迭代拉伸」，并保留对旧格式的校验兼容，
//       老库无需重置密码即可登录，登录成功后由调用方静默升级为 newHash。
//   D8  JWT 的 header 声称 HS256，实际用的是 sha256(input + "." + secret)
//       —— 这不是 HMAC，长度扩展等构造性差异使它不能按 HS256 被第三方验证。
//       现在实现真正的 RFC 2104 HMAC-SHA256，并使用常数时间比较。
//
// API 约束：本文件只使用仓库内已验证可用的 stdx.crypto.digest / stdx.encoding.hex
// 接口（SHA256().write(Array<UInt8>) / .finish() / toHexString），以及官方文档
// 背书的 std.random.Random.nextUInt8s 与 std.sync.ReentrantMutex。
// =============================================================================

let HMAC_BLOCK_SIZE: Int64 = 64
let IPAD_BYTE: UInt8 = 0x36
let OPAD_BYTE: UInt8 = 0x5C
let SHA256_DIGEST_LEN: Int64 = 32

// ---- 口令哈希参数 -----------------------------------------------------------
// 新格式：cj1<SEP><迭代次数><SEP><盐的十六进制><SEP><派生值的十六进制>
let PWD_PREFIX = "cj1"
let PWD_SALT_BYTES: Int64 = 16
let PWD_ITERATIONS: Int64 = 2000
let LEGACY_HEX_LEN: Int64 = 64

// 分隔符。仓库基线里不存在任何「裸 $ 字符串字面量」，而仓颉的插值语法以 "${" 起始，
// "$${X}" / "..." 这类写法存在词法歧义风险。这里用基线已证实的
// Array<T>(size, repeat:) + String.fromUtf8 逐字节构造，彻底绕开该不确定性。
let DOLLAR_BYTE: UInt8 = 0x24
let PWD_SEP: String = String.fromUtf8(Array<UInt8>(1, repeat: DOLLAR_BYTE))

// 遗留格式（只读兼容，不再用于新写入）：sha256(固定盐 + 明文)
let PASSWORD_SALT = "HRMS_CANGJIE_2026_SALT:"

let rngGate = ReentrantMutex()
let rng = Random()

// =============================================================================
// SHA256 / HMAC-SHA256
// =============================================================================

public func sha256Bytes(data: Array<UInt8>): Array<UInt8> {
    let digest = SHA256()
    digest.write(data)
    return digest.finish()
}

public func sha256Hex(input: String): String {
    return toHexString(sha256Bytes(input.toArray()))
}

// RFC 2104：HMAC(K, m) = H((K' ^ opad) || H((K' ^ ipad) || m))
// K' 为密钥补齐 / 压缩到 64 字节分组后的结果。
public func hmacSha256(key: Array<UInt8>, message: Array<UInt8>): Array<UInt8> {
    let block = Array<UInt8>(HMAC_BLOCK_SIZE, repeat: 0)
    if (key.size > HMAC_BLOCK_SIZE) {
        let compressed = sha256Bytes(key)
        for (i in 0..SHA256_DIGEST_LEN) {
            block[i] = compressed[i]
        }
    } else {
        for (i in 0..key.size) {
            block[i] = key[i]
        }
    }

    let inner = Array<UInt8>(HMAC_BLOCK_SIZE + message.size, repeat: 0)
    for (i in 0..HMAC_BLOCK_SIZE) {
        inner[i] = block[i] ^ IPAD_BYTE
    }
    for (i in 0..message.size) {
        inner[HMAC_BLOCK_SIZE + i] = message[i]
    }
    let innerHash = sha256Bytes(inner)

    let outer = Array<UInt8>(HMAC_BLOCK_SIZE + SHA256_DIGEST_LEN, repeat: 0)
    for (i in 0..HMAC_BLOCK_SIZE) {
        outer[i] = block[i] ^ OPAD_BYTE
    }
    for (i in 0..SHA256_DIGEST_LEN) {
        outer[HMAC_BLOCK_SIZE + i] = innerHash[i]
    }
    return sha256Bytes(outer)
}

public func hmacSha256Hex(key: String, message: String): String {
    return toHexString(hmacSha256(key.toArray(), message.toArray()))
}

// 签名 / 摘要比对必须与内容无关地耗时，否则攻击者可逐字节爆破合法签名。
public func constantTimeEquals(a: String, b: String): Bool {
    let ba = a.toArray()
    let bb = b.toArray()
    if (ba.size != bb.size) {
        return false
    }
    var diff: UInt8 = 0
    for (i in 0..ba.size) {
        diff = diff ^ (ba[i] ^ bb[i])
    }
    return diff == 0
}

// =============================================================================
// 随机数 / 十六进制
// =============================================================================

// 注意：std.random.Random 是伪随机数发生器，不是 CSPRNG。
// 口令盐只需要「唯一且不可预测到足以对抗彩虹表」，用于会话令牌等更高强度
// 场景时应替换为操作系统熵源（见 FOLLOWUP_PLAN 遗留项 L-SEC-1）。
public func randomBytes(len: Int64): Array<UInt8> {
    let out = Array<UInt8>(len, repeat: 0)
    rngGate.lock()
    rng.nextUInt8s(out)
    rngGate.unlock()
    return out
}

public func randomHex(len: Int64): String {
    return toHexString(randomBytes(len))
}

// =============================================================================
// 口令哈希：每用户随机盐 + 迭代拉伸
// =============================================================================

func deriveKey(saltHex: String, rawPassword: String, iterations: Int64): String {
    var acc = sha256Hex("${saltHex}:${rawPassword}")
    if (iterations <= 1) {
        return acc
    }
    var i: Int64 = 1
    while (i < iterations) {
        acc = sha256Hex("${acc}${saltHex}")
        i = i + 1
    }
    return acc
}

public func hashPassword(rawPassword: String): String {
    let saltHex = randomHex(PWD_SALT_BYTES)
    let iterText = "${PWD_ITERATIONS}"
    return PWD_PREFIX + PWD_SEP + iterText + PWD_SEP + saltHex + PWD_SEP + deriveKey(saltHex, rawPassword, PWD_ITERATIONS)
}

func legacyHash(rawPassword: String): String {
    return sha256Hex(PASSWORD_SALT + rawPassword)
}

func isLegacyHash(storedHash: String): Bool {
    if (storedHash.size != LEGACY_HEX_LEN) {
        return false
    }
    for (b in storedHash.toArray()) {
        let isDigit = (b >= 0x30 && b <= 0x39)
        let isLowerHex = (b >= 0x61 && b <= 0x66)
        let isUpperHex = (b >= 0x41 && b <= 0x46)
        if (!isDigit && !isLowerHex && !isUpperHex) {
            return false
        }
    }
    return true
}

// 从存储值中取出 (前缀, 迭代次数, 盐, 摘要)；格式非法返回 None
func splitStoredHash(storedHash: String): Option<(String, Int64, String, String)> {
    let parts = storedHash.split(PWD_SEP)
    if (parts.size != 4) {
        return Option<(String, Int64, String, String)>.None
    }
    if (parts[0] != PWD_PREFIX) {
        return Option<(String, Int64, String, String)>.None
    }
    match (Int64.tryParse(parts[1])) {
        case Some(iter) =>
            if (iter <= 0 || parts[2].isEmpty() || parts[3].isEmpty()) {
                return Option<(String, Int64, String, String)>.None
            }
            return Option<(String, Int64, String, String)>.Some((parts[0], iter, parts[2], parts[3]))
        case None => return Option<(String, Int64, String, String)>.None
    }
}

public func verifyPassword(rawPassword: String, storedHash: String): Bool {
    if (storedHash.isEmpty()) {
        return false
    }
    // 注意：match 的 case 模式里不做元组解构（该写法未在基线出现过）。
    // 统一先绑定整体，再用基线已证实的 `let (a, _, b) = tuple` 解构
    // （见 mysql_pool.cj:322 `let (code, _, errStr) = runMysqlFile(sql)`）。
    match (splitStoredHash(storedHash)) {
        case Some(stored) =>
            let (_, iter, saltHex, digestHex) = stored
            let derived = deriveKey(saltHex, rawPassword, iter)
            return constantTimeEquals(derived, digestHex)
        case None =>
            if (isLegacyHash(storedHash)) {
                // 老库里的固定盐哈希：继续放行，让调用方有机会升级
                return constantTimeEquals(legacyHash(rawPassword), storedHash)
            }
            return false
    }
}

// 登录成功后据此判断是否需要把遗留哈希 / 低迭代哈希升级为当前参数
public func needsRehash(storedHash: String): Bool {
    match (splitStoredHash(storedHash)) {
        case Some(stored) =>
            let (iter, _, _, _) = stored
            return iter != PWD_ITERATIONS
        case None => return true
    }
}

public func passwordHashParams(): (Int64, Int64) {
    return (PWD_ITERATIONS, PWD_SALT_BYTES)
}
