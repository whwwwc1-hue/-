package hrms_backend.controller

import std.collection.*
import std.convert.*
import stdx.net.http.*
import hrms_backend.common.*
import hrms_backend.db.*
import hrms_backend.middleware.*

/// GET /api/v1/notifications?page=1&pageSize=10&onlyUnread=1
/// 返回当前账号的消息列表与未读数，供顶栏铃铛与抽屉使用。
public func handleNotificationList(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            var page = getQueryInt(ctx, "page", 1)
            var pageSize = getQueryInt(ctx, "pageSize", 10)
            if (page < 1) { page = 1 }
            if (pageSize < 1 || pageSize > 50) { pageSize = 10 }
            let onlyUnread = getQueryStr(ctx, "onlyUnread", "") == "1"

            let conds = ArrayList<String>()
            conds.add("n.user_id = ${u.userId}")
            if (onlyUnread) {
                conds.add("n.is_read = 0")
            }
            let whereSql = "WHERE " + String.join(conds.toArray(), delimiter: " AND ")
            let total = querySingleInt("SELECT COUNT(*) FROM sys_notification n ${whereSql}", 0)
            let unread = querySingleInt("SELECT COUNT(*) FROM sys_notification WHERE user_id = ${u.userId} AND is_read = 0", 0)
            let offset = (page - 1) * pageSize
            let rows = queryRows("""
SELECT n.id, n.title, n.content, n.biz_type, n.is_read,
       DATE_FORMAT(n.created_at, '%Y-%m-%d %H:%i:%s')
FROM sys_notification n
${whereSql}
ORDER BY n.id DESC
LIMIT ${pageSize} OFFSET ${offset}
""")
            let list = ArrayList<String>()
            for (r in rows) {
                let readJson = if (r[4] == "1") { "true" } else { "false" }
                let item = "{" +
                    "\"id\":${r[0]}," +
                    "\"title\":${jsonStr(r[1])}," +
                    "\"content\":${jsonStr(r[2])}," +
                    "\"bizType\":${jsonStr(r[3])}," +
                    "\"isRead\":${readJson}," +
                    "\"createdAt\":${jsonStr(r[5])}" +
                "}"
                list.add(item)
            }
            let listJson = "[" + String.join(list.toArray(), delimiter: ",") + "]"
            sendOk(ctx, "{\"list\":${listJson},\"total\":${total},\"page\":${page},\"pageSize\":${pageSize},\"unread\":${unread}}")
    }
}

/// POST /api/v1/notifications/{id}/read
public func handleNotificationRead(ctx: HttpContext, notifyId: Int64): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            executeSql("UPDATE sys_notification SET is_read = 1 WHERE id = ${notifyId} AND user_id = ${u.userId}")
            sendOk(ctx, "null")
    }
}

/// POST /api/v1/notifications/read-all
public func handleNotificationReadAll(ctx: HttpContext): Unit {
    match (requireAuth(ctx)) {
        case None => return
        case Some(u) =>
            executeSql("UPDATE sys_notification SET is_read = 1 WHERE user_id = ${u.userId} AND is_read = 0")
            sendOk(ctx, "null")
    }
}
