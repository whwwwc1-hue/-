package hrms_backend.controller

import std.collection.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*

// P3.1 长假二级审批纯函数单元测试。
//
// 覆盖 request_controller.cj 中与数据库无关的状态机函数：
//   reqIsPendingLike / reqInitialStatus / reqCurrentLevel / reqNextStatus
//   reqCanActStep / reqActionDeniedMessage / reqShouldDeductAnnual
//   reqStatusCondition / reqPendingCountCondition
//   reqTrailSql / reqTrailJsonFor / reqIdListFromRows / reqIsNumericId
//   requestRowToJson
//
// 为什么必须钉死这一层：验收项「4 天长假必须两级签完才扣年假」的正确性
// 完全落在 reqNextStatus + reqCanActStep + reqShouldDeductAnnual 三个函数上，
// 扣减动作只在 handler 里发生一次，纯函数错则「重复扣」或「跳过一级」都会静默发生。
//
// 纪律（与 attendance/payroll 测试一致）：本文件不使用
//   - 数组字面量（[..]）——一律 ArrayList<String>() + add()
//   - 元组下标
//   - String.contains——结构断言全部整串 pin
// 可见性说明：被测函数一律显式 public，避免依赖「包内私有跨文件可见」这一未经验证的假设。

// ============================ 测试辅助函数 ============================

// 构造一条 17 列的申请单行（顺序与 /requests、/requests/list 的 SELECT 严格一致）。
func reqpRowId(id: String, status: String): ArrayList<String> {
    let r = ArrayList<String>()
    r.add(id)
    r.add("4")
    r.add("E0004")
    r.add("李四")
    r.add("研发部")
    r.add("LEAVE")
    r.add("ANNUAL")
    r.add("2026-12-01 09:00:00")
    r.add("2026-12-04 18:00:00")
    r.add("4.00")
    r.add("回老家过年")
    r.add(status)
    r.add("0")
    r.add("")
    r.add("")
    r.add("")
    r.add("2026-11-24 10:00:00")
    return r
}

func reqpRow(status: String): ArrayList<String> {
    return reqpRowId("7", status)
}

// 构造一行审批链记录（8 列，与 reqTrailSql 的 SELECT 严格一致）。
func reqpTrailRow(reqId: String, step: String, approver: String, role: String, action: String, resultStatus: String, remark: String, at: String): ArrayList<String> {
    let t = ArrayList<String>()
    t.add(reqId)
    t.add(step)
    t.add(approver)
    t.add(role)
    t.add(action)
    t.add(resultStatus)
    t.add(remark)
    t.add(at)
    return t
}

// ============================ 分级：哪些单据走两级 ============================

@test class ReqInitialStatusTest {
    @TestCase
    func testLongLeaveEntersManagerLevel(): Unit {
        // 4 天年假：必须一级起步
        @Assert(actual: reqInitialStatus("LEAVE", 4.0), expected: "PENDING_MGR")
        @Assert(actual: reqInitialStatus("LEAVE", 3.5), expected: "PENDING_MGR")
        // 阈值取严格「大于」：正好 3 天仍走单级，保持历史行为
        @Assert(actual: reqInitialStatus("LEAVE", 3.0), expected: "PENDING")
        @Assert(actual: reqInitialStatus("LEAVE", 0.5), expected: "PENDING")
    }

    @TestCase
    func testOvertimeNeverSplitsLevels(): Unit {
        // 加班 duration 单位是小时，12 小时也不能误判为长假
        @Assert(actual: reqInitialStatus("OVERTIME", 12.0), expected: "PENDING")
        @Assert(actual: reqInitialStatus("OVERTIME", 3.5), expected: "PENDING")
        @Assert(actual: reqInitialStatus("", 99.0), expected: "PENDING")
    }

    @TestCase
    func testInitialStatusIsAlwaysPendingLike(): Unit {
        @Assert(actual: reqIsPendingLike(reqInitialStatus("LEAVE", 4.0)), expected: true)
        @Assert(actual: reqIsPendingLike(reqInitialStatus("LEAVE", 1.0)), expected: true)
        @Assert(actual: reqIsPendingLike(reqInitialStatus("OVERTIME", 2.0)), expected: true)
    }
}

@test class ReqPendingStatusTest {
    @TestCase
    func testThreePendingStatuses(): Unit {
        @Assert(actual: reqIsPendingLike("PENDING"), expected: true)
        @Assert(actual: reqIsPendingLike("PENDING_MGR"), expected: true)
        @Assert(actual: reqIsPendingLike("PENDING_HR"), expected: true)
    }

    @TestCase
    func testTerminalStatusesAreNotPending(): Unit {
        @Assert(actual: reqIsPendingLike("APPROVED"), expected: false)
        @Assert(actual: reqIsPendingLike("REJECTED"), expected: false)
        @Assert(actual: reqIsPendingLike("CANCELLED"), expected: false)
        @Assert(actual: reqIsPendingLike(""), expected: false)
        // 近似但非法的值不能被误判为未终态
        @Assert(actual: reqIsPendingLike("PENDING_XX"), expected: false)
        @Assert(actual: reqIsPendingLike("pending"), expected: false)
    }

    @TestCase
    func testCurrentLevelMapping(): Unit {
        @Assert(actual: reqCurrentLevel("PENDING"), expected: 1)
        @Assert(actual: reqCurrentLevel("PENDING_MGR"), expected: 1)
        @Assert(actual: reqCurrentLevel("PENDING_HR"), expected: 2)
        @Assert(actual: reqCurrentLevel("APPROVED"), expected: 0)
        @Assert(actual: reqCurrentLevel("REJECTED"), expected: 0)
        @Assert(actual: reqCurrentLevel("CANCELLED"), expected: 0)
        @Assert(actual: reqCurrentLevel("UNKNOWN"), expected: -1)
    }
}

// ============================ 状态迁移 ============================

@test class ReqNextStatusTest {
    @TestCase
    func testSingleLevelGoesTerminal(): Unit {
        @Assert(actual: reqNextStatus("PENDING", "APPROVED"), expected: "APPROVED")
        @Assert(actual: reqNextStatus("PENDING", "REJECTED"), expected: "REJECTED")
    }

    @TestCase
    func testManagerLevelApprovalOnlyAdvances(): Unit {
        // 关键不变式：一级通过绝不产出 APPROVED
        @Assert(actual: reqNextStatus("PENDING_MGR", "APPROVED"), expected: "PENDING_HR")
        @Assert(actual: reqNextStatus("PENDING_MGR", "APPROVED") == "APPROVED", expected: false)
        @Assert(actual: reqNextStatus("PENDING_MGR", "REJECTED"), expected: "REJECTED")
    }

    @TestCase
    func testHrLevelApprovalFinalizes(): Unit {
        @Assert(actual: reqNextStatus("PENDING_HR", "APPROVED"), expected: "APPROVED")
        @Assert(actual: reqNextStatus("PENDING_HR", "REJECTED"), expected: "REJECTED")
    }

    @TestCase
    func testIllegalActionYieldsEmpty(): Unit {
        @Assert(actual: reqNextStatus("PENDING", "APPROVE"), expected: "")
        @Assert(actual: reqNextStatus("PENDING", ""), expected: "")
        @Assert(actual: reqNextStatus("PENDING_MGR", "CANCELLED"), expected: "")
    }

    @TestCase
    func testChainCannotSkipLevels(): Unit {
        // PENDING_MGR 一步推进后的状态仍在待处理域内，且必须再走一次才是终态
        let afterFirst = reqNextStatus("PENDING_MGR", "APPROVED")
        @Assert(actual: reqIsPendingLike(afterFirst), expected: true)
        @Assert(actual: reqCurrentLevel(afterFirst), expected: 2)
        let afterSecond = reqNextStatus(afterFirst, "APPROVED")
        @Assert(actual: afterSecond, expected: "APPROVED")
        @Assert(actual: reqIsPendingLike(afterSecond), expected: false)
    }
}

// ============================ 级次权限 ============================

@test class ReqCanActStepTest {
    @TestCase
    func testFirstLevelBelongsToManager(): Unit {
        @Assert(actual: reqCanActStep("PENDING_MGR", "MANAGER", true), expected: true)
        @Assert(actual: reqCanActStep("PENDING_MGR", "MANAGER", false), expected: false)
        // HR 不能代签一级，否则「二级审批」形同虚设
        @Assert(actual: reqCanActStep("PENDING_MGR", "HR", true), expected: false)
        @Assert(actual: reqCanActStep("PENDING_MGR", "EMPLOYEE", true), expected: false)
        // ADMIN 可代签一级，但一次只推一级（由 reqNextStatus 保证）
        @Assert(actual: reqCanActStep("PENDING_MGR", "ADMIN", true), expected: true)
    }

    @TestCase
    func testSecondLevelBelongsToHr(): Unit {
        @Assert(actual: reqCanActStep("PENDING_HR", "HR", true), expected: true)
        @Assert(actual: reqCanActStep("PENDING_HR", "HR", false), expected: true)
        @Assert(actual: reqCanActStep("PENDING_HR", "MANAGER", true), expected: false)
        @Assert(actual: reqCanActStep("PENDING_HR", "EMPLOYEE", true), expected: false)
        @Assert(actual: reqCanActStep("PENDING_HR", "ADMIN", true), expected: true)
    }

    @TestCase
    func testSingleLevelKeepsLegacyRoles(): Unit {
        @Assert(actual: reqCanActStep("PENDING", "MANAGER", true), expected: true)
        @Assert(actual: reqCanActStep("PENDING", "MANAGER", false), expected: false)
        @Assert(actual: reqCanActStep("PENDING", "HR", true), expected: true)
        @Assert(actual: reqCanActStep("PENDING", "ADMIN", true), expected: true)
        @Assert(actual: reqCanActStep("PENDING", "EMPLOYEE", true), expected: false)
    }

    @TestCase
    func testTerminalStatusNeverActable(): Unit {
        @Assert(actual: reqCanActStep("APPROVED", "ADMIN", true), expected: false)
        @Assert(actual: reqCanActStep("REJECTED", "HR", true), expected: false)
        @Assert(actual: reqCanActStep("CANCELLED", "MANAGER", true), expected: false)
        @Assert(actual: reqCanActStep("", "ADMIN", true), expected: false)
    }

    @TestCase
    func testDeniedMessagesAreDistinguishable(): Unit {
        @Assert(actual: reqActionDeniedMessage("PENDING_MGR", "HR", true), expected: "长假一级审批请由部门主管或系统管理员处理")
        @Assert(actual: reqActionDeniedMessage("PENDING_MGR", "MANAGER", false), expected: "长假一级审批仅可由申请本部门主管处理")
        @Assert(actual: reqActionDeniedMessage("PENDING_HR", "MANAGER", true), expected: "长假已进入二级审批，请由人力资源部门或系统管理员处理")
        @Assert(actual: reqActionDeniedMessage("PENDING", "MANAGER", false), expected: "该申请单已处理，无法重复审批")
    }
}

// ============================ 年假扣减时机 ============================

@test class ReqDeductAnnualTest {
    @TestCase
    func testOnlyFinalApprovalDeducts(): Unit {
        @Assert(actual: reqShouldDeductAnnual("LEAVE", "ANNUAL", "APPROVED"), expected: true)
        // 一级通过只是推进，扣了就会在二级再扣一次
        @Assert(actual: reqShouldDeductAnnual("LEAVE", "ANNUAL", "PENDING_HR"), expected: false)
        @Assert(actual: reqShouldDeductAnnual("LEAVE", "ANNUAL", "REJECTED"), expected: false)
        @Assert(actual: reqShouldDeductAnnual("LEAVE", "ANNUAL", "CANCELLED"), expected: false)
    }

    @TestCase
    func testOnlyAnnualLeaveDeducts(): Unit {
        @Assert(actual: reqShouldDeductAnnual("LEAVE", "SICK", "APPROVED"), expected: false)
        @Assert(actual: reqShouldDeductAnnual("LEAVE", "PERSONAL", "APPROVED"), expected: false)
        @Assert(actual: reqShouldDeductAnnual("OVERTIME", "ANNUAL", "APPROVED"), expected: false)
        @Assert(actual: reqShouldDeductAnnual("", "", "APPROVED"), expected: false)
    }

    @TestCase
    func testWholeChainDeductsExactlyOnce(): Unit {
        // 4 天长假整条链：一级不扣，二级才扣，且只命中一次
        let s1 = reqNextStatus("PENDING_MGR", "APPROVED")
        let s2 = reqNextStatus(s1, "APPROVED")
        let hit1 = reqShouldDeductAnnual("LEAVE", "ANNUAL", s1)
        let hit2 = reqShouldDeductAnnual("LEAVE", "ANNUAL", s2)
        @Assert(actual: hit1, expected: false)
        @Assert(actual: hit2, expected: true)
        @Assert(actual: hit1 && hit2, expected: false)
    }
}

// ============================ 查询片段 ============================

@test class ReqSqlFragmentTest {
    @TestCase
    func testStatusConditionPendingMeansAnyLevel(): Unit {
        @Assert(actual: reqStatusCondition(""), expected: "")
        @Assert(actual: reqStatusCondition("PENDING"), expected: "lo.status IN ('PENDING', 'PENDING_MGR', 'PENDING_HR')")
    }

    @TestCase
    func testStatusConditionOthersAreExactAndQuoted(): Unit {
        @Assert(actual: reqStatusCondition("APPROVED"), expected: "lo.status = 'APPROVED'")
        @Assert(actual: reqStatusCondition("PENDING_MGR"), expected: "lo.status = 'PENDING_MGR'")
        // 单引号必须被反斜杠转义，否则筛选值可注入 SQL（sqlEscape 用 \' 而非 ''）
        @Assert(actual: reqStatusCondition("A'B"), expected: "lo.status = 'A" + "\\" + "'B'")
    }

    @TestCase
    func testPendingCountConditionCoversBothLevels(): Unit {
        @Assert(actual: reqPendingCountCondition(), expected: "status IN ('PENDING', 'PENDING_MGR', 'PENDING_HR')")
    }

    @TestCase
    func testTrailSqlShape(): Unit {
        let expected = "\n" +
            "SELECT request_id, step, approver_name, approver_role, action, result_status," +
            "\n       IFNULL(remark, ''),\n       DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s')" +
            "\nFROM hr_approval_log\nWHERE request_id IN (7,8)" +
            "\nORDER BY request_id ASC, step ASC\n"
        @Assert(actual: reqTrailSql("7,8"), expected: expected)
    }
}

// ============================ 审批链装配 ============================

@test class ReqTrailAssembleTest {
    @TestCase
    func testEmptyTrailIsJsonArray(): Unit {
        let rows = ArrayList<ArrayList<String>>()
        @Assert(actual: reqTrailJsonFor(rows, "7"), expected: "[]")
    }

    @TestCase
    func testTwoStepsInOrder(): Unit {
        let rows = ArrayList<ArrayList<String>>()
        rows.add(reqpTrailRow("7", "1", "manager", "MANAGER", "APPROVED", "PENDING_HR", "同意", "2026-11-24 10:05:00"))
        rows.add(reqpTrailRow("7", "2", "hr", "HR", "APPROVED", "APPROVED", "核准", "2026-11-24 11:00:00"))
        let expected = "[" +
            "{\"step\":1,\"approverName\":\"manager\",\"approverRole\":\"MANAGER\",\"action\":\"APPROVED\",\"resultStatus\":\"PENDING_HR\",\"remark\":\"同意\",\"at\":\"2026-11-24 10:05:00\"}" +
            ",{\"step\":2,\"approverName\":\"hr\",\"approverRole\":\"HR\",\"action\":\"APPROVED\",\"resultStatus\":\"APPROVED\",\"remark\":\"核准\",\"at\":\"2026-11-24 11:00:00\"}" +
            "]"
        @Assert(actual: reqTrailJsonFor(rows, "7"), expected: expected)
    }

    @TestCase
    func testOtherRequestsAreFilteredOut(): Unit {
        let rows = ArrayList<ArrayList<String>>()
        rows.add(reqpTrailRow("8", "1", "manager", "MANAGER", "REJECTED", "REJECTED", "人手不足", "2026-11-24 10:05:00"))
        rows.add(reqpTrailRow("7", "1", "manager", "MANAGER", "APPROVED", "PENDING_HR", "", "2026-11-24 10:05:00"))
        @Assert(actual: reqTrailJsonFor(rows, "9"), expected: "[]")
        // 意见为空时是空串而不是 null，前端可直接渲染
        let one = reqTrailJsonFor(rows, "7")
        let expected = "[{\"step\":1,\"approverName\":\"manager\",\"approverRole\":\"MANAGER\",\"action\":\"APPROVED\",\"resultStatus\":\"PENDING_HR\",\"remark\":\"\",\"at\":\"2026-11-24 10:05:00\"}]"
        @Assert(actual: one, expected: expected)
    }

    @TestCase
    func testShortRowIsSkipped(): Unit {
        let rows = ArrayList<ArrayList<String>>()
        let broken = ArrayList<String>()
        broken.add("7")
        broken.add("1")
        rows.add(broken)
        @Assert(actual: reqTrailJsonFor(rows, "7"), expected: "[]")
    }

    @TestCase
    func testIdListFromRows(): Unit {
        let rows = ArrayList<ArrayList<String>>()
        rows.add(reqpRowId("7", "PENDING_MGR"))
        rows.add(reqpRowId("8", "PENDING_HR"))
        @Assert(actual: reqIdListFromRows(rows), expected: "7,8")
        let empty = ArrayList<ArrayList<String>>()
        @Assert(actual: reqIdListFromRows(empty), expected: "")
    }

    @TestCase
    func testIdListSkipsNonNumeric(): Unit {
        let rows = ArrayList<ArrayList<String>>()
        rows.add(reqpRowId("7", "PENDING"))
        rows.add(reqpRowId("8;DROP TABLE hr_leave_overtime", "PENDING"))
        @Assert(actual: reqIdListFromRows(rows), expected: "7")
        let allDirty = ArrayList<ArrayList<String>>()
        allDirty.add(reqpRowId("", "PENDING"))
        @Assert(actual: reqIdListFromRows(allDirty), expected: "")
    }

    @TestCase
    func testNumericIdGuard(): Unit {
        @Assert(actual: reqIsNumericId("123"), expected: true)
        @Assert(actual: reqIsNumericId("0"), expected: true)
        @Assert(actual: reqIsNumericId(""), expected: false)
        @Assert(actual: reqIsNumericId("1a"), expected: false)
        @Assert(actual: reqIsNumericId("-5"), expected: false)
        @Assert(actual: reqIsNumericId("1.5"), expected: false)
        @Assert(actual: reqIsNumericId("1;DROP"), expected: false)
    }
}

// ============================ 行 JSON 契约（前端消费的字段） ============================

@test class ReqRowJsonTest {
    @TestCase
    func testManagerLevelRowCarriesLevelAndAction(): Unit {
        let json = requestRowToJson(reqpRow("PENDING_MGR"), "APPROVE", "[]")
        let expected = "{" +
            "\"id\":7,\"employeeId\":4,\"empNo\":\"E0004\",\"empName\":\"李四\",\"deptName\":\"研发部\"," +
            "\"category\":\"LEAVE\",\"subType\":\"ANNUAL\"," +
            "\"startTime\":\"2026-12-01 09:00:00\",\"endTime\":\"2026-12-04 18:00:00\"," +
            "\"duration\":4.00,\"reason\":\"回老家过年\",\"status\":\"PENDING_MGR\"," +
            "\"approverId\":0,\"approverName\":\"\",\"approveRemark\":\"\",\"approvedAt\":\"\",\"createdAt\":\"2026-11-24 10:00:00\"," +
            "\"currentLevel\":1,\"myAction\":\"APPROVE\",\"approvalTrail\":[]}"
        @Assert(actual: json, expected: expected)
    }

    @TestCase
    func testHrLevelRowHasLevelTwoAndNoAction(): Unit {
        let json = requestRowToJson(reqpRow("PENDING_HR"), "", "[]")
        let expected = "{" +
            "\"id\":7,\"employeeId\":4,\"empNo\":\"E0004\",\"empName\":\"李四\",\"deptName\":\"研发部\"," +
            "\"category\":\"LEAVE\",\"subType\":\"ANNUAL\"," +
            "\"startTime\":\"2026-12-01 09:00:00\",\"endTime\":\"2026-12-04 18:00:00\"," +
            "\"duration\":4.00,\"reason\":\"回老家过年\",\"status\":\"PENDING_HR\"," +
            "\"approverId\":0,\"approverName\":\"\",\"approveRemark\":\"\",\"approvedAt\":\"\",\"createdAt\":\"2026-11-24 10:00:00\"," +
            "\"currentLevel\":2,\"myAction\":\"\",\"approvalTrail\":[]}"
        @Assert(actual: json, expected: expected)
    }

    @TestCase
    func testLegacySingleLevelRowUnchangedSemantics(): Unit {
        // 单级单据必须仍报 currentLevel=1、myAction 由调用方决定，保证旧数据不出现新语义漂移
        let json = requestRowToJson(reqpRow("PENDING"), "APPROVE", "[]")
        let expected = "{" +
            "\"id\":7,\"employeeId\":4,\"empNo\":\"E0004\",\"empName\":\"李四\",\"deptName\":\"研发部\"," +
            "\"category\":\"LEAVE\",\"subType\":\"ANNUAL\"," +
            "\"startTime\":\"2026-12-01 09:00:00\",\"endTime\":\"2026-12-04 18:00:00\"," +
            "\"duration\":4.00,\"reason\":\"回老家过年\",\"status\":\"PENDING\"," +
            "\"approverId\":0,\"approverName\":\"\",\"approveRemark\":\"\",\"approvedAt\":\"\",\"createdAt\":\"2026-11-24 10:00:00\"," +
            "\"currentLevel\":1,\"myAction\":\"APPROVE\",\"approvalTrail\":[]}"
        @Assert(actual: json, expected: expected)
    }
}
