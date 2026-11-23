package hrms_backend.middleware

import std.collection.*
import std.convert.*
import std.sync.*
import stdx.net.http.*
import hrms_backend.common.*

// P0.3：登录失败限流。
// 原实现里 /auth/login 对凭据猜测没有任何约束，可以无限次爆破。
// 这里用「进程内内存表」做窗口计数：既不引入新依赖，也符合本项目
// 「无连接池、无外部缓存」的轻量部署形态。
//
// 已知限制（诚实记录）：
//   L-RL-1 单进程内存表，多实例部署时每个实例各自计数；
//   L-RL-2 重启即清空，不做持久化；
//   L-RL-3 服务绑定 127.0.0.1 时几乎拿不到真实对端 IP，
//          因此主键取「用户名 + 转发头 IP」，用户名是必选项。

// 窗口长度：连续失败在这个时间窗内累计
public let LOGIN_WINDOW_SECONDS: Int64 = 900
// 达到阈值后封锁
public let LOGIN_MAX_FAILURES: Int64 = 5
// 封锁时长
public let LOGIN_BLOCK_SECONDS: Int64 = 900
// 内存表上限，防止被随机用户名撑爆内存
public let LOGIN_MAX_KEYS: Int64 = 4096

public class LoginAttempt {
    public var key: String = ""
    public var firstAt: Int64 = 0
    public var lastAt: Int64 = 0
    public var failures: Int64 = 0
    public var blockedUntil: Int64 = 0

    public init(key: String, firstAt: Int64) {
        this.key = key
        this.firstAt = firstAt
        this.lastAt = firstAt
        this.failures = 0
        this.blockedUntil = 0
    }

    // 记录过期时间：封锁期与窗口期取较晚者
    public func expiresAt(): Int64 {
        let windowEnd = firstAt + LOGIN_WINDOW_SECONDS
        return if (blockedUntil > windowEnd) { blockedUntil } else { windowEnd }
    }
}

// 用「不可变引用 + 可变内容」的容器承载状态，
// 与基线中 `let queryCounter = AtomicInt64(0)` 的写法同构，避免顶层 var 的不确定性。
public class ThrottleStore {
    public var attempts: ArrayList<LoginAttempt> = ArrayList<LoginAttempt>()
    public var totalBlocked: Int64 = 0
}

let throttleGate = ReentrantMutex()
let throttleStore = ThrottleStore()

// 内部：调用方必须已持有 throttleGate
func findIndexLocked(key: String): Int64 {
    for (i in 0..throttleStore.attempts.size) {
        if (throttleStore.attempts[i].key == key) {
            return i
        }
    }
    return -1
}

// 内部：调用方必须已持有 throttleGate。
// 只用 add / size / [] 三个已被基线证实的 ArrayList 能力重建表，不使用 removeAt。
func pruneLocked(now: Int64): Unit {
    let kept = ArrayList<LoginAttempt>()
    for (i in 0..throttleStore.attempts.size) {
        let item = throttleStore.attempts[i]
        if (item.expiresAt() > now) {
            kept.add(item)
        }
    }
    throttleStore.attempts = kept
}

// 内部：调用方必须已持有 throttleGate。丢弃指定键并顺带清理过期项。
func dropKeyLocked(key: String, now: Int64): Unit {
    let kept = ArrayList<LoginAttempt>()
    for (i in 0..throttleStore.attempts.size) {
        let item = throttleStore.attempts[i]
        if (item.key != key && item.expiresAt() > now) {
            kept.add(item)
        }
    }
    throttleStore.attempts = kept
}

// 客户端标识：优先取反向代理转发头，退化到固定值。
// 不直接读 remoteAddress，避免依赖未经证实的 HTTP 层 API。
public func clientIp(ctx: HttpContext): String {
    let fwd = (ctx.request.headers.getFirst("X-Forwarded-For") ?? "").trimAscii()
    if (!fwd.isEmpty()) {
        let parts = fwd.split(",")
        return parts[0].trimAscii()
    }
    let real = (ctx.request.headers.getFirst("X-Real-IP") ?? "").trimAscii()
    if (!real.isEmpty()) {
        return real
    }
    return "local"
}

// 登录限流主键：用户名优先，附带来源标识。
public func loginThrottleKey(username: String, ip: String): String {
    let name = username.toAsciiLower()
    if (ip.isEmpty()) {
        return name
    }
    return "${name}@${ip}"
}

// 内部：调用方必须已持有 throttleGate
func ensureEntryLocked(key: String, now: Int64): LoginAttempt {
    let idx = findIndexLocked(key)
    if (idx >= 0) {
        return throttleStore.attempts[idx]
    }
    pruneLocked(now)
    if (throttleStore.attempts.size >= LOGIN_MAX_KEYS) {
        // 表仍然满：复用下标 0 的槽位（等价于最旧条目被淘汰后立刻重用）
        let slot = throttleStore.attempts[0]
        slot.key = key
        slot.firstAt = now
        slot.lastAt = now
        slot.failures = 0
        slot.blockedUntil = 0
        return slot
    }
    let created = LoginAttempt(key, now)
    throttleStore.attempts.add(created)
    return created
}

// 返回剩余封锁秒数；0 表示当前未被封锁。
public func loginBlockedSeconds(key: String): Int64 {
    let now = nowUnixSeconds()
    throttleGate.lock()
    try {
        let idx = findIndexLocked(key)
        if (idx < 0) {
            return 0
        }
        let item = throttleStore.attempts[idx]
        if (item.blockedUntil > now) {
            return item.blockedUntil - now
        }
        return 0
    } finally {
        throttleGate.unlock()
    }
}

public func loginBlocked(key: String): Bool {
    return loginBlockedSeconds(key) > 0
}

// 记录一次登录失败；返回记录后的累计失败次数。
public func recordLoginFailure(key: String): Int64 {
    let now = nowUnixSeconds()
    throttleGate.lock()
    try {
        let item = ensureEntryLocked(key, now)
        if (item.firstAt + LOGIN_WINDOW_SECONDS < now && item.blockedUntil < now) {
            item.firstAt = now
            item.failures = 0
        }
        item.lastAt = now
        item.failures = item.failures + 1
        if (item.failures >= LOGIN_MAX_FAILURES) {
            item.blockedUntil = now + LOGIN_BLOCK_SECONDS
            throttleStore.totalBlocked = throttleStore.totalBlocked + 1
        }
        return item.failures
    } finally {
        throttleGate.unlock()
    }
}

// 登录成功后清空该键的失败记录。
public func clearLoginFailures(key: String): Unit {
    let now = nowUnixSeconds()
    throttleGate.lock()
    try {
        dropKeyLocked(key, now)
    } finally {
        throttleGate.unlock()
    }
}

// 当前还剩几次失败机会（未跟踪时返回阈值本身）。
public func loginRemainingAttempts(key: String): Int64 {
    let now = nowUnixSeconds()
    throttleGate.lock()
    try {
        let idx = findIndexLocked(key)
        if (idx < 0) {
            return LOGIN_MAX_FAILURES
        }
        let item = throttleStore.attempts[idx]
        if (item.expiresAt() <= now) {
            return LOGIN_MAX_FAILURES
        }
        if (item.failures >= LOGIN_MAX_FAILURES) {
            return 0
        }
        return LOGIN_MAX_FAILURES - item.failures
    } finally {
        throttleGate.unlock()
    }
}

// 本次失败之后还剩几次机会（用于回显给用户，避免在字符串插值里写 if 表达式）。
public func remainingAfterFailure(currentRemaining: Int64): Int64 {
    if (currentRemaining <= 0) {
        return 0
    }
    return currentRemaining - 1
}

// 供 /health 或运维排查使用：(跟踪键数, 封锁中键数, 累计失败次数)。
public func loginThrottleStats(): (Int64, Int64, Int64) {
    let now = nowUnixSeconds()
    throttleGate.lock()
    try {
        var blockedCount: Int64 = 0
        var trackedFailures: Int64 = 0
        for (i in 0..throttleStore.attempts.size) {
            let item = throttleStore.attempts[i]
            if (item.blockedUntil > now) {
                blockedCount = blockedCount + 1
            }
            trackedFailures = trackedFailures + item.failures
        }
        return (throttleStore.attempts.size, blockedCount, trackedFailures)
    } finally {
        throttleGate.unlock()
    }
}

// 累计触发封锁的次数。
public func loginThrottleTotalBlocked(): Int64 {
    throttleGate.lock()
    try {
        return throttleStore.totalBlocked
    } finally {
        throttleGate.unlock()
    }
}

// 运维/测试：清空整表。
public func resetLoginThrottle(): Unit {
    throttleGate.lock()
    try {
        throttleStore.attempts = ArrayList<LoginAttempt>()
        throttleStore.totalBlocked = 0
    } finally {
        throttleGate.unlock()
    }
}
