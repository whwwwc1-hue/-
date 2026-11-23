package hrms_backend.common

import std.collection.*
import std.convert.*
import stdx.net.http.*

public func readRequestBody(ctx: HttpContext): String {
    let chunks = ArrayList<Byte>()
    let buf = Array<Byte>(4096, repeat: 0)
    while (true) {
        let n = ctx.request.body.read(buf)
        if (n <= 0) {
            break
        }
        for (i in 0..n) {
            chunks.add(buf[i])
        }
    }
    if (chunks.size == 0) {
        return ""
    }
    return String.fromUtf8(chunks.toArray())
}

public func getQueryStr(ctx: HttpContext, key: String, def: String): String {
    return ctx.request.url.queryForm.get(key) ?? def
}

public func getQueryInt(ctx: HttpContext, key: String, def: Int64): Int64 {
    let s = (ctx.request.url.queryForm.get(key) ?? "").trimAscii()
    if (s.isEmpty()) {
        return def
    }
    return Int64.tryParse(s) ?? def
}

public func parsePathSegments(path: String): ArrayList<String> {
    let segs = ArrayList<String>()
    let parts = path.split("/")
    for (p in parts) {
        if (!p.isEmpty()) {
            segs.add(p)
        }
    }
    return segs
}

public func parseIntId(seg: String): Int64 {
    return Int64.tryParse(seg.trimAscii()) ?? 0
}
