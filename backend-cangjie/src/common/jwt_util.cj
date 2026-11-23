package hrms_backend.common

import std.convert.*
import std.time.*
import stdx.encoding.base64.*
import stdx.encoding.json.*
import hrms_backend.config.*

// Token 有效期与「静默续签」阈值。
// 剩余有效期不足 TOKEN_REFRESH_THRESHOLD 秒时，/auth/me 会顺带回发一个新 token，
// 前端只要正常轮询 /auth/me 就能长期保持登录，而不需要用户重新登录。
public let TOKEN_TTL_SECONDS: Int64 = 86400
public let TOKEN_REFRESH_THRESHOLD: Int64 = 7200

public class AuthUser {
    public let userId: Int64
    public let username: String
    public let role: String
    public let employeeId: Int64
    public let expiresAt: Int64

    public init(userId: Int64, username: String, role: String, employeeId: Int64, expiresAt: Int64) {
        this.userId = userId
        this.username = username
        this.role = role
        this.employeeId = employeeId
        this.expiresAt = expiresAt
    }
}

func toBase64Url(raw: String): String {
    return toBase64UrlBytes(raw.toArray())
}

// P0.3：签名结果是二进制摘要，必须先按字节做 base64url，
// 不能像旧实现那样先 hex 化（hex 也是合法的 base64url 文本，容易混淆但语义不同）。
public func toBase64UrlBytes(data: Array<UInt8>): String {
    var b64 = toBase64String(data)
    b64 = b64.replace("+", "-")
    b64 = b64.replace("/", "_")
    b64 = b64.replace("=", "")
    return b64
}

func fromBase64Url(b64Url: String): Option<String> {
    var s = b64Url.replace("-", "+").replace("_", "/")
    let rem = s.size % 4
    if (rem == 2) {
        s = s + "=="
    } else if (rem == 3) {
        s = s + "="
    }
    match (fromBase64String(s)) {
        case Some(bytes) =>
            try {
                return Option<String>.Some(String.fromUtf8(bytes))
            } catch (_: Exception) {
                return Option<String>.None
            }
        case None => return Option<String>.None
    }
}

// P0.3 修复 D8：旧实现是 sha256(input + "." + secret)（长度扩展风险的简化版 + 非标准），
// 现在改为标准 HS256 = HMAC-SHA256(secret, base64url(header) + "." + base64url(payload))。
func signPayload(signingInput: String): String {
    let mac = hmacSha256(globalConfig.jwtSecret.toArray(), signingInput.toArray())
    return toBase64UrlBytes(mac)
}

public func nowUnixSeconds(): Int64 {
    return DateTime.now().toUnixTimeStamp().toSeconds()
}

public func createToken(userId: Int64, username: String, role: String, employeeId: Int64): String {
    return createTokenWithTtl(userId, username, role, employeeId, TOKEN_TTL_SECONDS)
}

// 便于单测：允许显式指定有效期（负数可用来构造已过期 token）。
public func createTokenWithTtl(userId: Int64, username: String, role: String, employeeId: Int64, ttlSeconds: Int64): String {
    let headerJson = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"
    let exp = nowUnixSeconds() + ttlSeconds
    let payloadJson = "{\"uid\":${userId},\"sub\":${jsonStr(username)},\"role\":${jsonStr(role)},\"eid\":${employeeId},\"exp\":${exp}}"
    let headerB64 = toBase64Url(headerJson)
    let payloadB64 = toBase64Url(payloadJson)
    let signingInput = "${headerB64}.${payloadB64}"
    let sig = signPayload(signingInput)
    return "${signingInput}.${sig}"
}

// 只做验签 + 解析，不校验 exp；由调用方决定过期语义。
func decodeToken(token: String): Option<AuthUser> {
    let parts = token.split(".")
    if (parts.size != 3) {
        return Option<AuthUser>.None
    }
    let signingInput = "${parts[0]}.${parts[1]}"
    let expectedSig = signPayload(signingInput)
    // P0.3：常数时间比较，避免通过响应时延逐字节猜签名。
    if (!constantTimeEquals(parts[2], expectedSig)) {
        return Option<AuthUser>.None
    }
    match (fromBase64Url(parts[1])) {
        case None => return Option<AuthUser>.None
        case Some(payloadStr) =>
            match (parseJsonObject(payloadStr)) {
                case None => return Option<AuthUser>.None
                case Some(obj) =>
                    let exp = getJsonInt(obj, "exp", 0)
                    let uid = getJsonInt(obj, "uid", 0)
                    let sub = getJsonStr(obj, "sub", "")
                    let role = getJsonStr(obj, "role", "")
                    let eid = getJsonInt(obj, "eid", 0)
                    if (uid <= 0 || sub.isEmpty() || role.isEmpty()) {
                        return Option<AuthUser>.None
                    }
                    return Option<AuthUser>.Some(AuthUser(uid, sub, role, eid, exp))
            }
    }
}

public func verifyToken(token: String): Option<AuthUser> {
    match (decodeToken(token)) {
        case None => return Option<AuthUser>.None
        case Some(user) =>
            if (user.expiresAt <= nowUnixSeconds()) {
                return Option<AuthUser>.None
            }
            return Option<AuthUser>.Some(user)
    }
}

// 剩余有效期是否已经短到需要续签。
public func tokenNeedsRefresh(user: AuthUser): Bool {
    return (user.expiresAt - nowUnixSeconds()) < TOKEN_REFRESH_THRESHOLD
}

// 用同一份身份签发一个新的长效 token；旧 token 不显式吊销（无状态 JWT 的固有限制），
// 真正的下线能力由 sys_user.is_active 与后续可选的黑名单承担。
public func renewToken(user: AuthUser): String {
    return createToken(user.userId, user.username, user.role, user.employeeId)
}

// 供 /auth/me 使用：返回「新的 token 字符串」，续签失败（比如已过期）时返回 None。
public func renewTokenIfExpiring(user: AuthUser): Option<String> {
    if (user.expiresAt <= nowUnixSeconds()) {
        return Option<String>.None
    }
    if (!tokenNeedsRefresh(user)) {
        return Option<String>.None
    }
    return Option<String>.Some(renewToken(user))
}
