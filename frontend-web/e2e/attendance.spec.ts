/**
 * P1.3（三）考勤：签到签退闭环、角色可见性、全员监控筛选，以及两条
 * 曾经真实存在、现已修复的前端契约缺陷的回归锁。
 *
 * L-FE-2：全员监控曾把月份作为 `date` 参数发出，而后端只读 `month`，
 *        于是「按月份筛选」形同虚设 —— 见「筛选月份要按后端契约发 month」。
 * L-FE-4：修正弹窗曾只回传 status/remark，后端对 lateMinutes/earlyMinutes
 *        取 `getJsonInt(..., 0)`，等于一次修正就把迟到分钟数清零，
 *        进而让「迟到/早退次数」与算薪扣款失真 —— 见「修正考勤不得抹掉迟到分钟数」。
 *
 * 每个筛选用例都重新 signIn 开一个干净页面：筛选条件会互相继承，
 * 上一条用例留下的 status=ABSENT 会让下一条的列表为空（探针阶段踩过这个坑）。
 */
import type { Page } from '@playwright/test'
import { PAYROLL_MONTH } from './support/mock-server'
import { expect, REAL_BACKEND, signIn, test, toast } from './support/fixtures'

const LATE_DATE = `${PAYROLL_MONTH}-11`

/** 切到「全员考勤监控」并等其真正可见。 */
async function openAllPane(page: Page): Promise<void> {
  await page.getByRole('tab', { name: '全员考勤监控' }).click()
  // element-plus 的隐藏 pane 仍留在 DOM 里，所以任何断言都必须限定 :visible，
  // 而定位器一律从 #pane-all 往下找，避免命中 #pane-my 的同名结构。
  await expect(page.locator('#pane-all')).toBeVisible()
}

test.describe('今日考勤工作台', () => {
  test('上班签到 → 按钮锁定 → 下班签退，全程状态自洽', async ({ page, mock }) => {
    // 撞日只可能发生在运行日恰为种子日（2026-11-11/13）时，此时后端本就该拒绝重复打卡
    test.skip(!REAL_BACKEND && mock.hasTodayRecord('emp01'), '运行日与考勤种子撞日，onClockIn 按契约应返回已打卡')

    await signIn(page, 'emp01', '/attendance')
    const card = page.locator('.hrms-card').first()
    await expect(card.getByText('今日考勤工作台')).toBeVisible()
    await expect(card.locator('strong').filter({ hasText: '未签到' })).toBeVisible()

    const inBtn = page.getByRole('button', { name: '上班签到' })
    await expect(inBtn).toBeEnabled()
    await inBtn.click()
    await expect(toast(page, '签到成功')).toBeVisible()

    // 已签到后按钮改名且禁用，这是防重复打卡在 UI 层的第一道闸
    const doneBtn = page.getByRole('button', { name: '已签到' })
    await expect(doneBtn).toBeDisabled()
    await expect(card.locator('strong').filter({ hasText: '未签到' })).toHaveCount(0)

    await page.getByRole('button', { name: '下班签退' }).click()
    await expect(toast(page, '签退成功')).toBeVisible()
    await expect(card.locator('strong').filter({ hasText: '未签退' })).toHaveCount(0)

    // 刻意不断言「迟到/早退次数」等月度统计：mock 与后端一致地按当前时刻判定迟到，
    // 跑测试的时间点会改变统计值，那是真实行为而不是缺陷，不该钉进断言。
  })

  test('普通员工看不到全员考勤监控 tab', async ({ page, mock }) => {
    void mock
    await signIn(page, 'emp01', '/attendance')
    await expect(page.getByRole('tab', { name: '我的考勤记录' })).toBeVisible()
    await expect(page.getByRole('tab', { name: '全员考勤监控' })).toHaveCount(0)
  })

  test('人事主管能看到全员监控与修正操作列', async ({ page, mock }) => {
    void mock
    await signIn(page, 'hr', '/attendance')
    await openAllPane(page)
    await expect(page.locator('#pane-all .el-table__body tr:visible').first().getByRole('button', { name: '补卡/修正' })).toBeVisible()
  })

  test('部门经理能看到监控 tab 但没有修正操作列（isHrOrAdmin 门禁）', async ({ page, mock }) => {
    void mock
    await signIn(page, 'manager', '/attendance')
    await openAllPane(page)
    const rows = page.locator('#pane-all .el-table__body tr:visible')
    await expect(rows.first()).toBeVisible()
    // 操作列由 v-if="isHrOrAdmin" 整体摘掉，表头里根本不该出现「操作」
    await expect(page.locator('#pane-all').getByText('操作', { exact: true })).toHaveCount(0)
    await expect(rows.first().getByRole('button', { name: '补卡/修正' })).toHaveCount(0)
  })
})

test.describe('全员考勤监控筛选', () => {
  /** L-FE-2 回归。 */
  test('按月份筛选要按后端契约发 month，而不是 date', async ({ page, mock }) => {
    void mock
    await signIn(page, 'hr', '/attendance')
    await openAllPane(page)

    const monthInput = page.getByPlaceholder('按月份筛选')
    const reqPromise = page.waitForRequest(
      (req) => req.method() === 'GET' && new URL(req.url()).pathname === '/api/v1/attendance'
    )
    await monthInput.fill('2019-01')
    await monthInput.press('Enter')
    const params = new URL((await reqPromise).url()).searchParams

    expect(params.get('month')).toBe('2019-01')
    expect([...params.keys()]).not.toContain('date')
    await expect(page.locator('#pane-all').getByText('暂无数据')).toBeVisible()
  })

  test('按状态筛选缺勤只回未打卡的那一条', async ({ page, mock }) => {
    void mock
    await signIn(page, 'hr', '/attendance')
    await openAllPane(page)

    const select = page.locator('#pane-all .el-select').first()
    await select.locator('.el-select__wrapper').click()
    // 下拉面板 teleport 到 body 且关闭后仍留在 DOM，必须只取可见 dropdown 里的项
    const option = page.locator('.el-select-dropdown:visible .el-select-dropdown__item').filter({ hasText: '缺勤' })
    const reqPromise = page.waitForRequest(
      (req) => req.method() === 'GET' && new URL(req.url()).pathname === '/api/v1/attendance'
    )
    await option.click()

    const params = new URL((await reqPromise).url()).searchParams
    expect(params.get('status')).toBe('ABSENT')
    const rows = page.locator('#pane-all .el-table__body tr:visible')
    await expect(rows).toHaveCount(1)
    await expect(rows.first()).toContainText('王静')
    await expect(rows.first()).toContainText('未打卡')
  })

  test('关键字搜索按工号或姓名过滤且回到第一页', async ({ page, mock }) => {
    void mock
    await signIn(page, 'hr', '/attendance')
    await openAllPane(page)

    const keyword = page.getByPlaceholder('搜索姓名 / 工号')
    const reqPromise = page.waitForRequest(
      (req) => req.method() === 'GET' && new URL(req.url()).pathname === '/api/v1/attendance'
    )
    await keyword.fill('EMP20260004')
    await keyword.press('Enter')
    expect(new URL((await reqPromise).url()).searchParams.get('keyword')).toBe('EMP20260004')

    const rows = page.locator('#pane-all .el-table__body tr:visible')
    await expect(rows.first()).toContainText('陈思远')
    await expect(rows).toHaveCount(4) // 2 条 PAYROLL_MONTH + 2 条历史种子
  })
})

test.describe('补卡/修正弹窗', () => {
  /** L-FE-4 回归：本次修复的核心，钉住「回传当前分钟数」这个行为。 */
  test('修正考勤不得抹掉迟到分钟数', async ({ page, mock }) => {
    void mock
    await signIn(page, 'hr', '/attendance')
    await openAllPane(page)

    const keyword = page.getByPlaceholder('搜索姓名 / 工号')
    await keyword.fill('陈思远')
    await keyword.press('Enter')

    const lateRow = page.locator('#pane-all .el-table__body tr:visible').filter({ hasText: LATE_DATE })
    await expect(lateRow).toHaveCount(1)
    await expect(lateRow).toContainText('迟到')
    await lateRow.getByRole('button', { name: '补卡/修正' }).click()

    // 标题模板是「修正考勤记录 · 陈思远」，中点两侧的空白容易被渲染影响，只钉前半段
    const dialog = page.locator('.el-dialog:visible').filter({ hasText: '修正考勤记录' })
    await expect(dialog).toBeVisible()
    await expect(dialog).toContainText('陈思远')
    // 弹窗必须把当前值带进来：第一个 el-input-number 是迟到(分)
    await expect(dialog.locator('.el-input-number input').first()).toHaveValue('20')

    await dialog.locator('.el-select .el-select__wrapper').click()
    await page.locator('.el-select-dropdown:visible .el-select-dropdown__item').filter({ hasText: '正常 NORMAL' }).click()
    const remark = '探针核实：实际为准时到岗，系统抖动'
    await dialog.getByPlaceholder('如：忘记打卡，主管核实补卡').fill(remark)

    const reqPromise = page.waitForRequest(
      (req) => req.method() === 'PUT' && /^\/api\/v1\/attendance\/\d+$/.test(new URL(req.url()).pathname)
    )
    await dialog.getByRole('button', { name: '确认修正' }).click()

    const body = JSON.parse((await reqPromise).postData() ?? '{}')
    expect(body).toMatchObject({ status: 'NORMAL', lateMinutes: 20, remark })
    await expect(toast(page, '考勤状态已修正')).toBeVisible()
    await expect(dialog).toBeHidden()

    // 服务端确实保住了分钟数：重开弹窗仍是 20（若回归成清零，这里会变成 0）
    const fixedRow = page.locator('#pane-all .el-table__body tr:visible').filter({ hasText: LATE_DATE })
    await expect(fixedRow).toContainText('正常')
    await fixedRow.getByRole('button', { name: '补卡/修正' }).click()
    await expect(dialog.locator('.el-input-number input').first()).toHaveValue('20')
    await dialog.getByRole('button', { name: '取消' }).click()
  })
})
