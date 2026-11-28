package hrms_backend.service

import hrms_backend.db.*

/// 写入一条站内消息。
/// 通知属于旁路能力：写入失败只打印日志，绝不影响调用方已经完成的业务操作。
public func pushNotification(userId: Int64, title: String, content: String, bizType: String): Unit {
    if (userId <= 0) {
        return
    }
    try {
        executeSql("INSERT INTO sys_notification (user_id, title, content, biz_type, is_read) VALUES (${userId}, ${sqlStr(title)}, ${sqlStr(content)}, ${sqlStr(bizType)}, 0)")
    } catch (e: Exception) {
        println("站内通知写入失败（不影响业务结果）：${e.message}")
    }
}

/// 按员工 ID 找到其绑定账号后写入站内消息，找不到账号则静默跳过。
public func pushNotificationToEmployee(employeeId: Int64, title: String, content: String, bizType: String): Unit {
    if (employeeId <= 0) {
        return
    }
    let userId = querySingleInt("SELECT IFNULL(MAX(id), 0) FROM sys_user WHERE employee_id = ${employeeId}", 0)
    pushNotification(userId, title, content, bizType)
}
