package hrms_backend.common

import std.collection.*
import std.convert.*
import stdx.net.http.*
import stdx.encoding.json.*

public func jsonEscape(raw: String): String {
    var out = raw.replace("\\", "\\\\")
    out = out.replace("\"", "\\\"")
    out = out.replace("\r", "\\r")
    out = out.replace("\n", "\\n")
    out = out.replace("\t", "\\t")
    return out
}

public func jsonStr(raw: String): String {
    return "\"" + jsonEscape(raw) + "\""
}

public func jsonNullableStr(raw: String): String {
    if (raw.isEmpty()) {
        return "null"
    }
    return jsonStr(raw)
}

public func addCorsHeaders(builder: HttpResponseBuilder): HttpResponseBuilder {
    return builder
        .header("Access-Control-Allow-Origin", "*")
        .header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        .header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        // P0.3：/auth/me 通过响应头回发续签后的 token，跨域时必须显式暴露，
        // 否则浏览器 JS 读不到该头。
        .header("Access-Control-Expose-Headers", "X-Renewed-Token")
}

public func sendJson(ctx: HttpContext, httpStatus: UInt16, code: Int64, message: String, dataJson: String): Unit {
    let body = "{\"code\":${code},\"message\":${jsonStr(message)},\"data\":${dataJson}}"
    addCorsHeaders(ctx.responseBuilder)
        .status(httpStatus)
        .header("Content-Type", "application/json; charset=utf-8")
        .body(body)
}

// P0.3：带续签 Token 的成功响应（响应头 X-Renewed-Token）。
public func sendJsonWithToken(ctx: HttpContext, renewedToken: String, dataJson: String): Unit {
    let body = "{\"code\":200,\"message\":\"success\",\"data\":${dataJson}}"
    addCorsHeaders(ctx.responseBuilder)
        .status(200)
        .header("Content-Type", "application/json; charset=utf-8")
        .header("X-Renewed-Token", renewedToken)
        .body(body)
}

public func sendOk(ctx: HttpContext, dataJson: String): Unit {
    sendJson(ctx, 200, 200, "success", dataJson)
}

public func sendOkMsg(ctx: HttpContext, message: String, dataJson: String): Unit {
    sendJson(ctx, 200, 200, message, dataJson)
}

public func sendPage(ctx: HttpContext, listJson: String, total: Int64, page: Int64, pageSize: Int64): Unit {
    let data = "{\"list\":${listJson},\"total\":${total},\"page\":${page},\"pageSize\":${pageSize}}"
    sendOk(ctx, data)
}

public func sendErr(ctx: HttpContext, httpStatus: UInt16, code: Int64, message: String): Unit {
    sendJson(ctx, httpStatus, code, message, "null")
}

public func parseJsonObject(body: String): Option<JsonObject> {
    let trimmed = body.trimAscii()
    if (trimmed.isEmpty()) {
        return Option<JsonObject>.None
    }
    try {
        let jv = JsonValue.fromStr(trimmed)
        if (jv is JsonObject) {
            return Option<JsonObject>.Some(jv.asObject())
        }
        return Option<JsonObject>.None
    } catch (_: Exception) {
        return Option<JsonObject>.None
    }
}

public func getJsonStr(obj: JsonObject, key: String, def: String): String {
    match (obj.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case JsonKind.JsInt => return "${v.asInt().getValue()}"
                case JsonKind.JsFloat => return "${v.asFloat().getValue()}"
                case JsonKind.JsBool => return "${v.asBool().getValue()}"
                case _ => return def
            }
        case None => return def
    }
}

public func getJsonInt(obj: JsonObject, key: String, def: Int64): Int64 {
    match (obj.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case JsonKind.JsFloat => return Int64(v.asFloat().getValue())
                case JsonKind.JsString => return Int64.tryParse(v.asString().getValue().trimAscii()) ?? def
                case JsonKind.JsBool => if (v.asBool().getValue()) { return 1 } else { return 0 }
                case _ => return def
            }
        case None => return def
    }
}

public func getJsonFloat(obj: JsonObject, key: String, def: Float64): Float64 {
    match (obj.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsFloat => return v.asFloat().getValue()
                case JsonKind.JsInt => return Float64(v.asInt().getValue())
                case JsonKind.JsString => return Float64.tryParse(v.asString().getValue().trimAscii()) ?? def
                case _ => return def
            }
        case None => return def
    }
}

public func getJsonBool(obj: JsonObject, key: String, def: Bool): Bool {
    match (obj.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsBool => return v.asBool().getValue()
                case JsonKind.JsInt => return v.asInt().getValue() != 0
                case JsonKind.JsString =>
                    let s = v.asString().getValue().trimAscii().toAsciiLower()
                    if (s == "true" || s == "1") { return true }
                    if (s == "false" || s == "0") { return false }
                    return def
                case _ => return def
            }
        case None => return def
    }
}

public func formatNum2(val: Float64): String {
    let neg = val < 0.0
    let absVal = if (neg) { -val } else { val }
    let cents = Int64(absVal * 100.0 + 0.5)
    let whole = cents / 100
    let frac = cents % 100
    let fracStr = if (frac < 10) { "0${frac}" } else { "${frac}" }
    let prefix = if (neg && cents > 0) { "-" } else { "" }
    return "${prefix}${whole}.${fracStr}"
}

// 按字节上限截断，且保证不会把一个多字节 UTF-8 字符切成半个（否则响应体非法）
public func truncateUtf8(text: String, maxBytes: Int64): String {
    if (maxBytes <= 0) {
        return ""
    }
    let bytes = text.toArray()
    if (bytes.size <= maxBytes) {
        return text
    }
    let contLow: UInt8 = 0x80
    let contHigh: UInt8 = 0xBF
    var cut = maxBytes
    while (cut > 0 && bytes[cut] >= contLow && bytes[cut] <= contHigh) {
        cut = cut - 1
    }
    return text[..cut]
}

public func round2(val: Float64): Float64 {
    let neg = val < 0.0
    let absVal = if (neg) { -val } else { val }
    let cents = Int64(absVal * 100.0 + 0.5)
    let res = Float64(cents) / 100.0
    return if (neg) { -res } else { res }
}
