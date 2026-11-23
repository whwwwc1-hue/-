package hrms_backend.common

import std.convert.*
import std.time.*
import stdx.encoding.base64.*
import stdx.encoding.json.*
import hrms_backend.config.*

public class AuthUser {
    public let userId: Int64
    public let username: String
    public let role: String
    public let employeeId: Int64

    public init(userId: Int64, username: String, role: String, employeeId: Int64) {
        this.userId = userId
        this.username = username
        this.role = role
        this.employeeId = employeeId
    }
}

func toBase64Url(raw: String): String {
    var b64 = toBase64String(raw.toArray())
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

func signPayload(signingInput: String): String {
    let sigHex = sha256Hex(signingInput + "." + globalConfig.jwtSecret)
    return toBase64Url(sigHex)
}

public func nowUnixSeconds(): Int64 {
    return DateTime.now().toUnixTimeStamp().toSeconds()
}

public func createToken(userId: Int64, username: String, role: String, employeeId: Int64): String {
    let headerJson = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"
    let exp = nowUnixSeconds() + 86400
    let payloadJson = "{\"uid\":${userId},\"sub\":${jsonStr(username)},\"role\":${jsonStr(role)},\"eid\":${employeeId},\"exp\":${exp}}"
    let headerB64 = toBase64Url(headerJson)
    let payloadB64 = toBase64Url(payloadJson)
    let signingInput = "${headerB64}.${payloadB64}"
    let sig = signPayload(signingInput)
    return "${signingInput}.${sig}"
}

public func verifyToken(token: String): Option<AuthUser> {
    let parts = token.split(".")
    if (parts.size != 3) {
        return Option<AuthUser>.None
    }
    let signingInput = "${parts[0]}.${parts[1]}"
    let expectedSig = signPayload(signingInput)
    if (parts[2] != expectedSig) {
        return Option<AuthUser>.None
    }
    match (fromBase64Url(parts[1])) {
        case None => return Option<AuthUser>.None
        case Some(payloadStr) =>
            match (parseJsonObject(payloadStr)) {
                case None => return Option<AuthUser>.None
                case Some(obj) =>
                    let exp = getJsonInt(obj, "exp", 0)
                    if (exp <= nowUnixSeconds()) {
                        return Option<AuthUser>.None
                    }
                    let uid = getJsonInt(obj, "uid", 0)
                    let sub = getJsonStr(obj, "sub", "")
                    let role = getJsonStr(obj, "role", "")
                    let eid = getJsonInt(obj, "eid", 0)
                    if (uid <= 0 || sub.isEmpty() || role.isEmpty()) {
                        return Option<AuthUser>.None
                    }
                    return Option<AuthUser>.Some(AuthUser(uid, sub, role, eid))
            }
    }
}
