package hrms_backend.middleware

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*

// =============================================================================
// rate_limit.cj 单元测试（P1.1）
//
// 覆盖：
//   常量契约      LOGIN_WINDOW_SECONDS / LOGIN_MAX_FAILURES /
//                 LOGIN_BLOCK_SECONDS / LOGIN_MAX_KEYS
//   纯函数        remainingAfterFailure / loginThrottleKey
//   数据结构      LoginAttempt.expiresAt()
//   状态机        recordLoginFailure / loginBlocked / loginBlockedSeconds /
//                 loginRemainingAttempts / clearLoginFailures /
//                 loginThrottleStats / loginThrottleTotalBlocked /
//                 resetLoginThrottle
//
// 未覆盖：clientIp(ctx) —— 需要构造 HttpContext，属于集成层，交给 P1.2 冒烟脚本。
//
// -----------------------------------------------------------------------------
// 【测试纪律：为什么每个用例第一件事是 resetLoginThrottle()】
// 限流表是进程内的全局可变状态（throttleStore），仓颉 unittest 不保证用例之间
// 的隔离与执行顺序。因此：
//   (1) 每个会读写全表的用例，首行必须 resetLoginThrottle()；
//   (2) 每个用例仍使用 rl-<用例名> 形态的独立键，避免万一有用例漏 reset 时
//       互相污染（键空间隔离是第二道防线）；
//   (3) 涉及「窗口过期 / 封锁到期」的分支无法测 —— 那两个判断依赖
//       nowUnixSeconds() 的真实推进，用例不能注入时钟。这里只测
//       「同一秒内必然成立」的状态迁移，不对时间流逝做任何假设。
//
// 【语法纪律】只用基线 src 中已出现的构造：
//   ArrayList<T>() + add + 下标 + size；for (i in 0..n)；while；
//   元组只在顶层 let (a, b, c) = ... 处解构（含 let (_, x, y) 这种占位）；
//   不使用 HashMap、不使用 removeAt、不使用 String.contains、
//   不使用元组下标 ._0。
//   特别注意：本仓库基线里不存在「丢弃非 Unit 返回值」的写法
//   （既没有 `_ = f()`，也没有 `let _ = f()`），只有 auth_controller.cj:96
//   那种「直接调用返回 Unit 的函数」作为语句。因此凡是 recordLoginFailure /
//   rlFailNTimes 这类返回 Int64 的调用，一律先 let 绑定再拿去断言，
//   循环里则累加进具名 var —— 既不违反语法纪律，又白送一批断言。
// =============================================================================

// ---- 测试辅助（rl 前缀）----

// 用例专用键：保证即便有用例忘了 reset，也不会跨用例污染。
func rlKey(name: String): String {
    return "rl-" + name
}

func rlFailNTimes(key: String, n: Int64): Int64 {
    // 返回最后一次 recordLoginFailure 的返回值，顺便让「调了几次」这件事
    // 在断言里可读。
    var last: Int64 = 0
    var i: Int64 = 0
    while (i < n) {
        last = recordLoginFailure(key)
        i = i + 1
    }
    return last
}

func rlAttempt(key: String, at: Int64): LoginAttempt {
    return LoginAttempt(key, at)
}

func rlWindowEnd(at: Int64): Int64 {
    return at + LOGIN_WINDOW_SECONDS
}

// Int64 -> String：只用插值，不调用未经证实的 str()/toString 变体。
func rlItoa(v: Int64): String {
    return "${v}"
}

@Test
class RateLimitTests {
    // ---- 0. 辅助自检 ----

    @TestCase
    func testHelperSelfCheck(): Unit {
        resetLoginThrottle()
        @Assert(rlKey("a"), "rl-a")
        @Assert(rlKey("a").size, 4)
        @Assert(rlWindowEnd(0), 900)
        @Assert(rlWindowEnd(1000), 1900)
        // 空表上计数为 0
        let (tracked, blocked, failures) = loginThrottleStats()
        @Assert(tracked, 0)
        @Assert(blocked, 0)
        @Assert(failures, 0)
        @Assert(loginThrottleTotalBlocked(), 0)
    }

    // ---- 1. 常量契约：改了任何一个都会破坏运维口径 ----

    @TestCase
    func testWindowConstant(): Unit {
        @Assert(LOGIN_WINDOW_SECONDS, 900)
    }

    @TestCase
    func testMaxFailuresConstant(): Unit {
        @Assert(LOGIN_MAX_FAILURES, 5)
    }

    @TestCase
    func testBlockSecondsConstant(): Unit {
        @Assert(LOGIN_BLOCK_SECONDS, 900)
    }

    @TestCase
    func testMaxKeysConstant(): Unit {
        @Assert(LOGIN_MAX_KEYS, 4096)
    }

    @TestCase
    func testConstantsArePositiveAndOrdered(): Unit {
        @Assert(LOGIN_WINDOW_SECONDS > 0)
        @Assert(LOGIN_MAX_FAILURES > 0)
        @Assert(LOGIN_BLOCK_SECONDS > 0)
        @Assert(LOGIN_MAX_KEYS > 0)
        // 阈值至少给攻击者 3 次以上机会，又不能宽到失去意义
        @Assert(LOGIN_MAX_FAILURES >= 3)
        @Assert(LOGIN_MAX_FAILURES <= 10)
        // 封锁不应短于统计窗口，否则「解封即重开」等于没封
        @Assert(LOGIN_BLOCK_SECONDS >= LOGIN_WINDOW_SECONDS)
    }

    // ---- 2. remainingAfterFailure：纯函数 ----

    @TestCase
    func testRemainingAfterFailureStepsDown(): Unit {
        @Assert(remainingAfterFailure(5), 4)
        @Assert(remainingAfterFailure(4), 3)
        @Assert(remainingAfterFailure(3), 2)
        @Assert(remainingAfterFailure(2), 1)
        @Assert(remainingAfterFailure(1), 0)
    }

    @TestCase
    func testRemainingAfterFailureClampsAtZero(): Unit {
        // 已经是 0 或负数时不能返回 -1，否则前端会显示「剩余 -1 次」
        @Assert(remainingAfterFailure(0), 0)
        @Assert(remainingAfterFailure(-1), 0)
        @Assert(remainingAfterFailure(-100), 0)
    }

    @TestCase
    func testRemainingAfterFailureNeverNegative(): Unit {
        var i: Int64 = -10
        while (i <= 50) {
            @Assert(remainingAfterFailure(i) >= 0)
            i = i + 1
        }
    }

    @TestCase
    func testRemainingAfterFailureBoundedByInput(): Unit {
        // 结果恒 <= 入参，且入参为正时恒 < 入参
        @Assert(remainingAfterFailure(5) < 5)
        @Assert(remainingAfterFailure(10) < 10)
        @Assert(remainingAfterFailure(1000) < 1000)
        @Assert(remainingAfterFailure(0) <= 0)
        @Assert(remainingAfterFailure(1000) > 0)
    }

    // ---- 3. loginThrottleKey：用户名必选 + 大小写归一 ----

    @TestCase
    func testThrottleKeyLowercasesUsername(): Unit {
        @Assert(loginThrottleKey("ZhangSan", "1.2.3.4"), "zhangsan@1.2.3.4")
        @Assert(loginThrottleKey("ADMIN", "10.0.0.1"), "admin@10.0.0.1")
    }

    @TestCase
    func testThrottleKeyDropsAtSignWhenIpEmpty(): Unit {
        // 没有转发头时只按用户名计数，避免 "admin@" 这种带尾巴的键
        @Assert(loginThrottleKey("Admin", ""), "admin")
        @Assert(loginThrottleKey("admin", "").size, 5)
    }

    @TestCase
    func testThrottleKeyIsCaseInsensitive(): Unit {
        @Assert(loginThrottleKey("Bob", "1.1.1.1"), loginThrottleKey("BOB", "1.1.1.1"))
        @Assert(loginThrottleKey("bob", "1.1.1.1"), loginThrottleKey("BoB", "1.1.1.1"))
    }

    @TestCase
    func testThrottleKeySeparatesIps(): Unit {
        @Assert(loginThrottleKey("a", "1.1.1.1") != loginThrottleKey("a", "2.2.2.2"))
        @Assert(loginThrottleKey("a", "1.1.1.1") != loginThrottleKey("b", "1.1.1.1"))
        @Assert(loginThrottleKey("a", "") != loginThrottleKey("a", "1.1.1.1"))
    }

    @TestCase
    func testThrottleKeyKeepsUnicodeUsernameAsIs(): Unit {
        // toAsciiLower 只折叠 ASCII 大写，中文用户名必须原样保留，
        // 否则两个不同中文账号会被并成同一个键。
        @Assert(loginThrottleKey("张三", "1.1.1.1"), "张三@1.1.1.1")
        @Assert(loginThrottleKey("张三", "") != loginThrottleKey("李四", ""))
    }

    // ---- 4. LoginAttempt.expiresAt：取窗口末与封锁末的较晚者 ----

    @TestCase
    func testAttemptDefaults(): Unit {
        let a = rlAttempt("k", 1000)
        @Assert(a.key, "k")
        @Assert(a.firstAt, 1000)
        @Assert(a.lastAt, 1000)
        @Assert(a.failures, 0)
        @Assert(a.blockedUntil, 0)
    }

    @TestCase
    func testAttemptExpiresAtIsWindowEndWhenNotBlocked(): Unit {
        let a = rlAttempt("k", 1000)
        @Assert(a.expiresAt(), rlWindowEnd(1000))
        let b = rlAttempt("k", 0)
        @Assert(b.expiresAt(), LOGIN_WINDOW_SECONDS)
    }

    @TestCase
    func testAttemptExpiresAtTakesLaterOfBlock(): Unit {
        let a = rlAttempt("k", 1000)
        // 封锁期比窗口末更晚 -> 过期时间必须以封锁期为准，
        // 否则解封后旧窗口一过期就前功尽弃。
        a.blockedUntil = rlWindowEnd(1000) + 1
        @Assert(a.expiresAt(), a.blockedUntil)
        a.blockedUntil = rlWindowEnd(1000) + 99999
        @Assert(a.expiresAt(), a.blockedUntil)
    }

    @TestCase
    func testAttemptExpiresAtIgnoresEarlierBlock(): Unit {
        let a = rlAttempt("k", 1000)
        a.blockedUntil = 1500
        @Assert(a.expiresAt(), rlWindowEnd(1000))
        // 封锁期恰好等于窗口末：两侧同值，仍返回窗口末
        a.blockedUntil = rlWindowEnd(1000)
        @Assert(a.expiresAt(), rlWindowEnd(1000))
    }

    @TestCase
    func testAttemptExpiresAtDoesNotMutate(): Unit {
        let a = rlAttempt("k", 2000)
        let before = a.expiresAt()
        @Assert(a.expiresAt(), before)
        @Assert(a.expiresAt(), before)
        @Assert(a.failures, 0)
        @Assert(a.blockedUntil, 0)
    }

    // ---- 5. 全表状态机 ----

    @TestCase
    func testFreshKeyIsNotBlocked(): Unit {
        resetLoginThrottle()
        let key = rlKey("fresh")
        @Assert(!loginBlocked(key))
        @Assert(loginBlockedSeconds(key), 0)
        @Assert(loginRemainingAttempts(key), LOGIN_MAX_FAILURES)
    }

    @TestCase
    func testFailureCounterIncrementsOneByOne(): Unit {
        resetLoginThrottle()
        let key = rlKey("inc")
        @Assert(recordLoginFailure(key), 1)
        @Assert(recordLoginFailure(key), 2)
        @Assert(recordLoginFailure(key), 3)
        @Assert(recordLoginFailure(key), 4)
        @Assert(recordLoginFailure(key), 5)
    }

    @TestCase
    func testRemainingDecreasesWithFailures(): Unit {
        resetLoginThrottle()
        let key = rlKey("rem")
        @Assert(loginRemainingAttempts(key), 5)
        let r1 = recordLoginFailure(key)
        @Assert(r1, 1)
        @Assert(loginRemainingAttempts(key), 4)
        let r2 = recordLoginFailure(key)
        @Assert(r2, 2)
        @Assert(loginRemainingAttempts(key), 3)
        let r3 = recordLoginFailure(key)
        @Assert(r3, 3)
        @Assert(loginRemainingAttempts(key), 2)
        let r4 = recordLoginFailure(key)
        @Assert(r4, 4)
        @Assert(loginRemainingAttempts(key), 1)
        @Assert(!loginBlocked(key))
    }

    @TestCase
    func testBlockedExactlyAtThreshold(): Unit {
        resetLoginThrottle()
        let key = rlKey("block")
        let last = rlFailNTimes(key, LOGIN_MAX_FAILURES - 1)
        @Assert(last, 4)
        // 第 4 次还不该封
        @Assert(!loginBlocked(key))
        @Assert(loginBlockedSeconds(key), 0)
        // 第 5 次正好触达阈值
        @Assert(recordLoginFailure(key), LOGIN_MAX_FAILURES)
        @Assert(loginBlocked(key))
        @Assert(loginBlockedSeconds(key) > 0)
        @Assert(loginRemainingAttempts(key), 0)
    }

    @TestCase
    func testBlockedSecondsWithinBlockWindow(): Unit {
        resetLoginThrottle()
        let key = rlKey("secs")
        let reached = rlFailNTimes(key, LOGIN_MAX_FAILURES)
        @Assert(reached, LOGIN_MAX_FAILURES)
        let s = loginBlockedSeconds(key)
        // blockedUntil = 触封那一刻 + LOGIN_BLOCK_SECONDS，而读取时 now 已经往前走了一点，
        // 所以剩余秒数只会「不超过阈值」且「离阈值不远」。
        // 这里留 5 秒容差而不是 1 秒：本用例全程只做内存操作，正常远小于 1 秒，
        // 但断言不该把「宿主机恰好在此处卡顿」当成被测代码的缺陷。
        @Assert(s > 0)
        @Assert(s <= LOGIN_BLOCK_SECONDS)
        @Assert(s >= LOGIN_BLOCK_SECONDS - 5)
    }

    @TestCase
    func testRemainingZeroWhileBlocked(): Unit {
        resetLoginThrottle()
        let key = rlKey("zero")
        let reached = rlFailNTimes(key, LOGIN_MAX_FAILURES)
        @Assert(reached, LOGIN_MAX_FAILURES)
        @Assert(loginRemainingAttempts(key), 0)
        @Assert(loginRemainingAttempts(key) <= 0)
    }

    @TestCase
    func testExtraFailuresWhileBlockedKeepCountingUp(): Unit {
        resetLoginThrottle()
        let key = rlKey("over")
        let reached = rlFailNTimes(key, LOGIN_MAX_FAILURES)
        @Assert(reached, LOGIN_MAX_FAILURES)
        // 封锁期内继续失败，计数仍然单调递增（用于日志与风控），
        // 且必须仍处于封锁状态。
        @Assert(recordLoginFailure(key), 6)
        @Assert(recordLoginFailure(key), 7)
        @Assert(loginBlocked(key))
        @Assert(loginRemainingAttempts(key), 0)
    }

    @TestCase
    func testClearUnblocksImmediately(): Unit {
        resetLoginThrottle()
        let key = rlKey("clear")
        let reached = rlFailNTimes(key, LOGIN_MAX_FAILURES)
        @Assert(reached, LOGIN_MAX_FAILURES)
        @Assert(loginBlocked(key))
        clearLoginFailures(key)
        @Assert(!loginBlocked(key))
        @Assert(loginBlockedSeconds(key), 0)
        @Assert(loginRemainingAttempts(key), LOGIN_MAX_FAILURES)
    }

    @TestCase
    func testClearRestartsCounterFromOne(): Unit {
        resetLoginThrottle()
        let key = rlKey("restart")
        let reached = rlFailNTimes(key, LOGIN_MAX_FAILURES)
        @Assert(reached, LOGIN_MAX_FAILURES)
        clearLoginFailures(key)
        // 清空后必须从 1 重新计，而不是 6 —— 否则成功登录后仍被误封
        @Assert(recordLoginFailure(key), 1)
        @Assert(loginRemainingAttempts(key), 4)
    }

    @TestCase
    func testClearUnknownKeyIsNoop(): Unit {
        resetLoginThrottle()
        let key = rlKey("unknown")
        clearLoginFailures(key)
        @Assert(!loginBlocked(key))
        @Assert(loginRemainingAttempts(key), LOGIN_MAX_FAILURES)
        let (tracked, blocked, failures) = loginThrottleStats()
        @Assert(tracked, 0)
        @Assert(blocked, 0)
        @Assert(failures, 0)
    }

    @TestCase
    func testClearOnlyAffectsTargetKey(): Unit {
        resetLoginThrottle()
        let a = rlKey("onlyA")
        let b = rlKey("onlyB")
        let la = rlFailNTimes(a, 3)
        let lb = rlFailNTimes(b, 4)
        @Assert(la, 3)
        @Assert(lb, 4)
        clearLoginFailures(a)
        @Assert(loginRemainingAttempts(a), LOGIN_MAX_FAILURES)
        @Assert(loginRemainingAttempts(b), 1)
    }

    @TestCase
    func testKeysAreIsolated(): Unit {
        resetLoginThrottle()
        let a = rlKey("isoA")
        let b = rlKey("isoB")
        let reached = rlFailNTimes(a, LOGIN_MAX_FAILURES)
        @Assert(reached, LOGIN_MAX_FAILURES)
        @Assert(loginBlocked(a))
        @Assert(!loginBlocked(b))
        @Assert(loginRemainingAttempts(b), LOGIN_MAX_FAILURES)
    }

    @TestCase
    func testStatsTrackDistinctKeysAndFailures(): Unit {
        resetLoginThrottle()
        let k1 = rlKey("s1")
        let k2 = rlKey("s2")
        let n1 = recordLoginFailure(k1)
        let n2 = rlFailNTimes(k2, 3)
        @Assert(n1, 1)
        @Assert(n2, 3)
        let (tracked, blocked, failures) = loginThrottleStats()
        @Assert(tracked, 2)
        @Assert(blocked, 0)
        @Assert(failures, 4)
        @Assert(loginThrottleTotalBlocked(), 0)
    }

    @TestCase
    func testStatsCountBlockedKeys(): Unit {
        resetLoginThrottle()
        let n1 = rlFailNTimes(rlKey("b1"), LOGIN_MAX_FAILURES)
        let n2 = rlFailNTimes(rlKey("b2"), LOGIN_MAX_FAILURES)
        let n3 = rlFailNTimes(rlKey("b3"), 2)
        @Assert(n1, LOGIN_MAX_FAILURES)
        @Assert(n2, LOGIN_MAX_FAILURES)
        @Assert(n3, 2)
        let (tracked, blocked, failures) = loginThrottleStats()
        @Assert(tracked, 3)
        @Assert(blocked, 2)
        @Assert(failures, 12)
        @Assert(loginThrottleTotalBlocked(), 2)
    }

    @TestCase
    func testTotalBlockedIsCumulativeEvenAfterUnblock(): Unit {
        resetLoginThrottle()
        let key = rlKey("cum")
        let reached1 = rlFailNTimes(key, LOGIN_MAX_FAILURES)
        @Assert(reached1, LOGIN_MAX_FAILURES)
        @Assert(loginThrottleTotalBlocked(), 1)
        // 解封只清计数，不清「历史上封过几次」这个运维指标
        clearLoginFailures(key)
        @Assert(loginThrottleTotalBlocked(), 1)
        let reached2 = rlFailNTimes(key, LOGIN_MAX_FAILURES)
        @Assert(reached2, LOGIN_MAX_FAILURES)
        @Assert(loginThrottleTotalBlocked(), 2)
    }

    @TestCase
    func testResetEmptiesWholeTable(): Unit {
        resetLoginThrottle()
        let key = rlKey("reset")
        let reached = rlFailNTimes(key, LOGIN_MAX_FAILURES)
        @Assert(reached, LOGIN_MAX_FAILURES)
        @Assert(loginBlocked(key))
        resetLoginThrottle()
        let (tracked, blocked, failures) = loginThrottleStats()
        @Assert(tracked, 0)
        @Assert(blocked, 0)
        @Assert(failures, 0)
        @Assert(loginThrottleTotalBlocked(), 0)
        @Assert(!loginBlocked(key))
        @Assert(loginRemainingAttempts(key), LOGIN_MAX_FAILURES)
    }

    @TestCase
    func testBlockedAfterResetOnFreshKey(): Unit {
        // reset 之后同一键必须能重新累计（进程重启即清空 = L-RL-2）
        resetLoginThrottle()
        let key = rlKey("afterreset")
        let reached = rlFailNTimes(key, LOGIN_MAX_FAILURES)
        @Assert(reached, LOGIN_MAX_FAILURES)
        @Assert(loginBlocked(key))
        resetLoginThrottle()
        @Assert(!loginBlocked(key))
        @Assert(recordLoginFailure(key), 1)
    }

    @TestCase
    func testStatsConsistentWithRemaining(): Unit {
        resetLoginThrottle()
        let key = rlKey("consist")
        var expected: Int64 = LOGIN_MAX_FAILURES
        var last: Int64 = 0
        var i: Int64 = 1
        while (i <= LOGIN_MAX_FAILURES - 1) {
            last = recordLoginFailure(key)
            @Assert(last, i)
            expected = expected - 1
            @Assert(loginRemainingAttempts(key), expected)
            i = i + 1
        }
        // 循环里最后一次失败应当正好是阈值前的一次
        @Assert(last, LOGIN_MAX_FAILURES - 1)
        let (tracked, blocked, failures) = loginThrottleStats()
        @Assert(tracked, 1)
        @Assert(blocked, 0)
        @Assert(failures, LOGIN_MAX_FAILURES - 1)
        let lastOne = recordLoginFailure(key)
        @Assert(lastOne, LOGIN_MAX_FAILURES)
        let (_, blocked2, failures2) = loginThrottleStats()
        @Assert(blocked2, 1)
        @Assert(failures2, LOGIN_MAX_FAILURES)
    }

    @TestCase
    func testManyDistinctKeysGrowsTableLinearly(): Unit {
        resetLoginThrottle()
        var acc: Int64 = 0
        var i: Int64 = 0
        while (i < 50) {
            // 每个键都是首次失败，返回值恒为 1，累加起来应恰好等于键的个数
            acc = acc + recordLoginFailure("rl-many-" + rlItoa(i))
            i = i + 1
        }
        @Assert(acc, 50)
        let (tracked, blocked, failures) = loginThrottleStats()
        @Assert(tracked, 50)
        @Assert(blocked, 0)
        @Assert(failures, 50)
        // 每个键都独立计 1 次，remaining 必须是阈值 - 1
        @Assert(loginRemainingAttempts("rl-many-0"), LOGIN_MAX_FAILURES - 1)
        @Assert(loginRemainingAttempts("rl-many-49"), LOGIN_MAX_FAILURES - 1)
        @Assert(loginBlocked("rl-many-0") == false)
        resetLoginThrottle()
    }
}
