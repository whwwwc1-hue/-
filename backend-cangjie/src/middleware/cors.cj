package hrms_backend.middleware

import stdx.net.http.*
import hrms_backend.common.*

public func handleCorsPreflight(ctx: HttpContext): Bool {
    if (ctx.request.method == "OPTIONS") {
        addCorsHeaders(ctx.responseBuilder)
            .status(204)
            .body("")
        return true
    }
    return false
}
