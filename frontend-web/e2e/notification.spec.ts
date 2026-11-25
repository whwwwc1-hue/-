/**
 * P3.2 站内通知中心：事件落库 → 铃铛计数 → 抽屉列表 → 点击跳转 → 已读收敛。
 *
 * 为什么值得单独一个 spec：通知是这个系统里唯一「跨模块写副作用」的链路。
 * 审批、发薪、工作台三条主流程各自成功了，并不代表通知也成功了——
 * 后端三个触发点全部走「拼 SQL → mysql.exe 执行」的旁路，异常只打日志不返回给调用方，
 * 一旦列名/去重键写错，症状是「通知静默丢失」，页面上一切正常。
 * 所以本文件的断言成对出现：既看 mock 内部真正落了哪几条（notifList/notifRefIds），
 * 也看用户看得见的红点与文案。
 *
 * 三条去重键是本模块最需要钉死的行为（真实库靠 UNIQUE(user_id, type, ref_id) + INSERT IGNORE）：
 *   PAYROLL_PAID 的 ref_id = 工资单 id      → 同一月反复点「一键全部发放」只有一条
 *   LEAVE_* 的 ref_id = 审批单 id           → 两张单不会互相吞，终态也不会补发
 *   CONTRACT_EXPIRING 的 ref_id = 员工id:到期日 → 刷新多少次工作台都只有一条
 *
 * REAL_BACKEND 下条数取决于库里既有账号与合同数据，整组 skip，与 payroll/approval 一致。
 */
import type { Locator, Page } from '@playwright/test'
import { PAYROLL_MONTH } from './support/mock-server'
import { confirmBox, expect, REAL_BACKEND, signIn, test, toast } from './support/fixtures'

const bell = (page: Page): Locator => page.getByTestId('notif-bell')
const badge = (page: Page): Locator => page.getByTestId('notif-badge').locator('.el-badge__content')
const drawer = (page: Page): Locator => page.getByTestId('notif-drawer')
const notifItems = (page: Page): Locator => drawer(page).getByTestId('notif-item')

/** 打开通知抽屉（顶栏常驻，不需要等导航）。 */
async function openDrawer(page: Page): Promise<void> {
  await expect(bell(page)).toBeVisible()
  await bell(page).click()
  await expect(drawer(page)).toBeVisible()
}

/**
 * 用当前页面已登录身份直连接口。
 *
 * 越权这条分支界面永远点不出来——抽屉只列自己的通知，别人的 id 根本不可见，
 * 所以只能像 approval.spec 那样绕开按钮直接 PUT，
 * 断言「看不见」与「服务端也改不动」同时成立。
 */
async function apiFetch(
  page: Page,
  method: string,
  path: string,
  body?: unknown
): Promise<{ status: number; code: number; message: string; data: Record<string, unknown> }> {
  return page.evaluate(
    async ([m, p, b]) => {
      const token = localStorage.getItem('hrms_token') ?? ''
      const res = await fetch(`/api/v1${p}`, {
        method: m,
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: b === undefined ? undefined : JSON.stringify(b)
      })
      const json = await res.json()
      return { status: res.status, code: json.code, message: json.message, data: (json.data ?? {}) as Record<string, unknown> }
    },
    [method, path, body] as [string, string, unknown]
  )
}

/** 按事由锁定审批工作台/我的记录里的行。 */
function rowByReason(page: Page, pane: string, reason: string): Locator {
  return page.locator(`#${pane} tr.el-table__row`).filter({ hasText: reason })
}

/**
 * 建一张 N 天的年假单（弹窗默认细分类型就是 ANNUAL，不必再选）。
 * 打开弹窗时组件已把开始/结束时间预填为今天 09:00–18:00，所以只需填时长与事由。
 */
async function createLeave(page: Page, reason: string, days: number): Promise<void> {
  await page.getByRole('button', { name: '发起请假 / 加班申请' }).click()
  const dialog = page.locator('.el-dialog').filter({ hasText: '发起假勤' })
  await expect(dialog).toBeVisible()
  await dialog.getByPlaceholder('请简述请假或加班事由').fill(reason)
  const durationInput = dialog.locator('.el-input-number input')
  await durationInput.fill(String(days))
  await durationInput.press('Enter')
  await dialog.getByRole('button', { name: '提交审批' }).click()
  await expect(toast(page, '申请已提交').last()).toBeVisible()
  await expect(dialog).toBeHidden()
}

/** HR 侧走完「一键核算 + 一键全部发放」，返回发放笔数所在的 toast。 */
async function generateAndBatchPay(page: Page): Promise<void> {
  await page.getByRole('button', { name: '一键核算生成' }).click()
  await expect(toast(page, '薪资核算完成')).toBeVisible()
  await page.getByRole('button', { name: '一键全部发放' }).click()
  const box = confirmBox(page, '批量发薪确认')
  await box.getByRole('button', { name: '确定' }).click()
  await expect(toast(page, '批量发薪成功')).toBeVisible()
}

test.describe('站内通知中心（P3.2）', () => {
  test.skip(REAL_BACKEND, '通知条数取决于库内账号与既有工资单状态')

  test.describe('发薪 → 铃铛 → 工资条', () => {
    test('批量发薪给每位有账号的员工落一条通知，员工点通知直达自己的工资条', async ({ page, mock, openRole }) => {
      await signIn(page, 'hr', '/payroll')
      await generateAndBatchPay(page)

      // 5 人发薪，但 4 个账号能按 employeeId 解析到 user_id；
      // 第 5 位员工没有账号，后端 notifResolveUser 返回 0 后直接跳过。
      expect(mock.notifCountByType('emp01', 'PAYROLL_PAID')).toBe(1)
      expect(mock.notifRefIds('emp01', 'PAYROLL_PAID')).toHaveLength(1)
      expect(mock.notifCountByType('admin', 'PAYROLL_PAID')).toBe(1)

      const emp = await openRole('emp01', '/dashboard')
      await expect(badge(emp)).toHaveText('1')

      await openDrawer(emp)
      const item = notifItems(emp).filter({ hasText: '工资条已发放' }).first()
      await expect(item).toBeVisible()
      await expect(item.getByTestId('notif-title')).toContainText(`${PAYROLL_MONTH} 工资条已发放`)

      await item.click()
      await expect(emp).toHaveURL(/\/payroll\?tab=my/)
      await expect(drawer(emp)).toBeHidden()
      // 后端在响应里回传剩余未读数，红点应就地归零，不必等下一轮 30 秒轮询
      await expect(badge(emp)).toBeHidden()
      // HR/ADMIN 进薪酬页默认落在「薪资核算中心」，带 tab=my 必须停在员工自己的工资条
      await expect(emp.locator('#pane-my tr.el-table__row').filter({ hasText: PAYROLL_MONTH })).toHaveCount(1)
    })

    test('同一月份反复点发放，通知不会翻倍', async ({ page, mock, openRole }) => {
      await signIn(page, 'hr', '/payroll')
      await generateAndBatchPay(page)
      expect(mock.notifCountByType('emp01', 'PAYROLL_PAID')).toBe(1)

      // 此刻已无草稿，paidCount=0；即便后端真的又拼了一遍 INSERT，UNIQUE 也会吃掉。
      await page.getByRole('button', { name: '一键全部发放' }).click()
      await confirmBox(page, '批量发薪确认').getByRole('button', { name: '确定' }).click()
      await expect(toast(page, '批量发薪成功，共发放 0 笔')).toBeVisible()
      expect(mock.notifCountByType('emp01', 'PAYROLL_PAID')).toBe(1)

      // 换上下文登录才会触发顶栏的首次未读拉取（同一 context 再进 /login 会被守卫弹回）
      const emp = await openRole('emp01', '/dashboard')
      await expect(badge(emp)).toHaveText('1')
    })

    test('单条发放同样落一条；读过后未读数递减而不是清零', async ({ page, mock, openRole }) => {
      await signIn(page, 'hr', '/payroll')
      await page.getByRole('button', { name: '一键核算生成' }).click()
      await expect(toast(page, '薪资核算完成')).toBeVisible()

      // 只发陈思远一个人：其余仍是草稿，不该收到通知
      const chen = page.locator('#pane-admin tr.el-table__row').filter({ hasText: '陈思远' })
      await chen.getByRole('button', { name: '确认发放' }).click()
      await confirmBox(page, '发薪确认').getByRole('button', { name: '确定' }).click()
      await expect(toast(page, '发放成功')).toBeVisible()
      expect(mock.notifCountByType('emp01', 'PAYROLL_PAID')).toBe(1)
      expect(mock.notifList('manager')).toHaveLength(0)

      const emp = await openRole('emp01', '/dashboard')
      await expect(badge(emp)).toHaveText('1')
      await openDrawer(emp)
      await notifItems(emp).filter({ hasText: '工资条已发放' }).first().click()
      await expect(emp).toHaveURL(/\/payroll\?tab=my$/)
      expect(mock.notifUnread('emp01')).toBe(0)
    })
  })

  test.describe('审批与合同到期', () => {
    test('通过给申请人落 LEAVE_APPROVED，驳回落 LEAVE_REJECTED，两条互不吞掉', async ({ page, mock, openRole }) => {
      const passReason = 'E2E 通知-年假通过'
      const rejectReason = 'E2E 通知-年假驳回'

      await signIn(page, 'emp01', '/approval')
      await createLeave(page, passReason, 2)
      await createLeave(page, rejectReason, 2)

      const mgr = await openRole('manager', '/approval')
      await mgr.getByRole('tab', { name: '审批工作台' }).click()
      await expect(mgr.locator('#pane-approve')).toBeVisible()

      await rowByReason(mgr, 'pane-approve', passReason).getByRole('button', { name: '通过' }).click()
      const passDialog = mgr.locator('.el-dialog').filter({ hasText: '确认审批通过' })
      await expect(passDialog).toBeVisible()
      await passDialog.getByRole('button', { name: '同意通过' }).click()
      await expect(toast(mgr, '审批已通过').last()).toBeVisible()

      // 驳回是两步：弹窗填意见 → 二次确认框，少点一步请求就不会发出
      await rowByReason(mgr, 'pane-approve', rejectReason).getByRole('button', { name: '驳回' }).click()
      const rejectDialog = mgr.locator('.el-dialog').filter({ hasText: '驳回申请' })
      await rejectDialog.getByPlaceholder('填写审批意见或驳回原因').fill('排期冲突')
      await rejectDialog.getByRole('button', { name: '确认驳回' }).click()
      const box = confirmBox(mgr, '驳回确认')
      await box.getByRole('button', { name: '确定' }).click()
      await expect(toast(mgr, '已驳回该申请').last()).toBeVisible()
      // 刻意不 mgr.close()：审批提示之后组件还在刷新列表，提前关上下文会把在途请求甩给
      // vite 代理（表现为 ECONNREFUSED 8080 的噪音），fixtures 的 teardown 会统一回收。

      expect(mock.notifCountByType('emp01', 'LEAVE_APPROVED')).toBe(1)
      expect(mock.notifCountByType('emp01', 'LEAVE_REJECTED')).toBe(1)
      // 两条通知的 ref_id 必须是两张不同的审批单：
      // 若去重键退化成「只按 type」，第二张单的通知就会被第一张吞掉。
      const approvedRef = mock.notifRefIds('emp01', 'LEAVE_APPROVED')[0]
      const rejectedRef = mock.notifRefIds('emp01', 'LEAVE_REJECTED')[0]
      expect(approvedRef).not.toBe(rejectedRef)

      // 换上下文重新拉取未读数（同一 context 的顶栏不会自己发现新通知）
      const emp = await openRole('emp01', '/dashboard')
      await expect(badge(emp)).toHaveText('2')
      await openDrawer(emp)
      await expect(notifItems(emp).filter({ hasText: '请假申请已通过' })).toHaveCount(1)
      await expect(notifItems(emp).filter({ hasText: '请假申请被驳回' })).toHaveCount(1)
      // 驳回通知必须带上「请查看审批意见」，员工在通知里就知道下一步该做什么
      await expect(notifItems(emp).filter({ hasText: '请查看审批意见' })).toHaveCount(1)
    })

    test('长假升到二级只发一次待复核，终态不会补发', async ({ page, mock, openRole }) => {
      const reason = 'E2E 通知-长假两级'

      await signIn(page, 'emp01', '/approval')
      await createLeave(page, reason, 4)
      expect(mock.findRequestByReason(reason)?.status).toBe('PENDING_MGR')
      // 建单阶段谁都不该收到通知
      expect(mock.notifList('emp01')).toHaveLength(0)
      expect(mock.notifList('hr')).toHaveLength(0)

      const mgr = await openRole('manager', '/approval')
      await mgr.getByRole('tab', { name: '审批工作台' }).click()
      await rowByReason(mgr, 'pane-approve', reason).getByRole('button', { name: '通过' }).click()
      await mgr.locator('.el-dialog').filter({ hasText: '确认审批通过' }).getByRole('button', { name: '同意通过' }).click()
      await expect(toast(mgr, '一级审批通过').last()).toBeVisible()
      expect(mock.findRequestByReason(reason)?.status).toBe('PENDING_HR')

      // 二级待办同时通知 HR 与 ADMIN（后端 notifHrUserSql 就是这个集合），员工自己收不到
      expect(mock.notifCountByType('hr', 'LEAVE_NEXT_LEVEL')).toBe(1)
      expect(mock.notifCountByType('admin', 'LEAVE_NEXT_LEVEL')).toBe(1)
      expect(mock.notifCountByType('emp01', 'LEAVE_NEXT_LEVEL')).toBe(0)

      // 从工作台点通知跳审批页：这条同时验证 ApprovalView 认 route.query.tab
      const hrPage = await openRole('hr', '/dashboard')
      // 打开工作台顺带触发了合同到期提醒，所以红点是 2 而不是 1
      await expect(badge(hrPage)).toHaveText('2')
      await openDrawer(hrPage)
      await notifItems(hrPage).filter({ hasText: '待你复核' }).click()
      await expect(hrPage).toHaveURL(/\/approval\?tab=approve$/)
      await expect(hrPage.locator('#pane-approve')).toBeVisible()
      // 点一条只清一条：合同到期那条仍是未读，红点不会整体清零
      expect(mock.notifUnread('hr')).toBe(1)

      await rowByReason(hrPage, 'pane-approve', reason).getByRole('button', { name: '通过' }).click()
      await hrPage.locator('.el-dialog').filter({ hasText: '确认审批通过' }).getByRole('button', { name: '同意通过' }).click()
      await expect(toast(hrPage, '审批已通过').last()).toBeVisible()

      expect(mock.findRequestByReason(reason)?.status).toBe('APPROVED')
      // 终态只给申请人补一条 LEAVE_APPROVED，HR 侧不会再来第二条待复核
      expect(mock.notifCountByType('hr', 'LEAVE_NEXT_LEVEL')).toBe(1)
      expect(mock.notifUnread('hr')).toBe(1)
      await expect(badge(hrPage)).toHaveText('1')
      expect(mock.notifCountByType('emp01', 'LEAVE_APPROVED')).toBe(1)
      // 两条通知的 ref_id 都必须是同一张审批单 id：去重键的口径不能漂
      const reqId = String(mock.findRequestByReason(reason)?.id)
      expect(mock.notifRefIds('emp01', 'LEAVE_APPROVED')).toEqual([reqId])
      expect(mock.notifRefIds('hr', 'LEAVE_NEXT_LEVEL')).toEqual([reqId])
    })

    test('合同到期提醒只给 HR/ADMIN，反复刷新工作台只有一条', async ({ page, mock, openRole }) => {
      await signIn(page, 'hr', '/dashboard')
      await expect(badge(page)).toHaveText('1')
      expect(mock.notifCountByType('hr', 'CONTRACT_EXPIRING')).toBe(1)

      await page.reload()
      await expect(badge(page)).toHaveText('1')
      expect(mock.notifCountByType('hr', 'CONTRACT_EXPIRING')).toBe(1)

      await openDrawer(page)
      const item = notifItems(page).filter({ hasText: '合同到期提醒' }).first()
      // typeLabel 落在徽标上、title 是「合同即将到期」，员工姓名与到期日只在正文里——
      // 三层都要有，否则 HR 根本不知道该找谁续签。
      await expect(item.getByTestId('notif-type')).toHaveText('合同到期提醒')
      await expect(item.getByTestId('notif-title')).toHaveText('合同即将到期')
      await expect(item).toContainText('陈思远')
      await expect(item).toContainText('2026-12-15')
      await item.click()
      await expect(page).toHaveURL(/\/employee$/)
      expect(mock.notifUnread('hr')).toBe(0)

      // 员工收不到合同到期提醒——这是 HR 的职责边界，不是全员公告
      const emp = await openRole('emp01', '/dashboard')
      await expect(badge(emp)).toBeHidden()
      expect(mock.notifCountByType('emp01', 'CONTRACT_EXPIRING')).toBe(0)
    })
  })

  test.describe('读取、筛选与越权', () => {
    test('全部已读一次清空，重复点击给出「没有未读通知」而不是报错', async ({ page, mock, openRole }) => {
      await signIn(page, 'hr', '/payroll')
      await generateAndBatchPay(page)

      const admin = await openRole('admin', '/dashboard')
      // admin 既是发薪操作者（自己也有账号）又收得到合同到期提醒，至少 2 条
      expect(mock.notifUnread('admin')).toBeGreaterThanOrEqual(2)
      await expect(badge(admin)).toHaveText(String(mock.notifUnread('admin')))

      await openDrawer(admin)
      await expect(notifItems(admin)).toHaveCount(mock.notifList('admin').length)

      await admin.getByTestId('notif-read-all').click()
      await expect(toast(admin, '已标记').last()).toBeVisible()
      await expect(badge(admin)).toBeHidden()
      expect(mock.notifUnread('admin')).toBe(0)

      await admin.getByTestId('notif-read-all').click()
      await expect(toast(admin, '没有未读通知').last()).toBeVisible()
      expect(mock.notifUnread('admin')).toBe(0)
    })

    test('越权改他人通知返回 404，对方那条仍是未读', async ({ page, mock, openRole }) => {
      const hrPage = await openRole('hr', '/dashboard')
      await expect(badge(hrPage)).toHaveText('1')
      const hrNotifId = mock.notifList('hr')[0].id

      await signIn(page, 'emp01', '/dashboard')
      const foreign = await apiFetch(page, 'PUT', `/notifications/${hrNotifId}/read`, {})
      expect(foreign.status).toBe(404)
      expect(foreign.code).toBe(404)
      expect(foreign.message).toBe('通知不存在或无权限')
      expect(mock.notifUnread('hr')).toBe(1)

      // 不存在的通知同样 404：后端刻意不区分「不存在」与「不属于你」，避免枚举
      const missing = await apiFetch(page, 'PUT', '/notifications/999999/read', {})
      expect(missing.status).toBe(404)

      await openDrawer(page)
      await expect(notifItems(page)).toHaveCount(0)
      await expect(page.getByText('暂无通知')).toBeVisible()
    })

    test('未读筛选与脏参数：脏 readFlag 退回全部，limit 被夹到 50 而不是报错', async ({ page, mock }) => {
      await signIn(page, 'hr', '/payroll')
      await generateAndBatchPay(page)

      // 顶栏常驻在布局上，不必回工作台；打开抽屉本身就会重新拉一次列表与未读数
      await openDrawer(page)
      await expect(notifItems(page)).toHaveCount(mock.notifList('hr').length)

      await page.getByTestId('notif-filter').getByText('未读', { exact: true }).click()
      await expect(notifItems(page)).toHaveCount(mock.notifUnread('hr'))

      // 直接喂脏参数：后端 notifReadCond 回落空串（宁可查全部），notifClampLimit 夹到 50。
      // 这条断言的意义是——注入面与异常参数都不会变成 500。
      const dirty = await apiFetch(page, 'GET', '/notifications?readFlag=1%20OR%201%3D1&limit=9999')
      expect(dirty.status).toBe(200)
      expect((dirty.data.list as unknown[]).length).toBe(mock.notifList('hr').length)
      expect(dirty.data.unread).toBe(mock.notifUnread('hr'))
    })
  })
})
