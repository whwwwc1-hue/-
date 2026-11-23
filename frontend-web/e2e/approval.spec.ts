/**
 * P1.3（四）假勤审批：建单校验 → 提交 → 跨角色审批 → 年假余额扣减 → 撤回 / 驳回。
 *
 * 这一组用例把「审批的因果链」钉死成三层同时成立的断言：
 * 1. UI 文案（toast / 表格状态标签 / 弹窗标题）；
 * 2. 出发的 HTTP 请求（方法、路径、查询参数、请求体）——契约层；
 * 3. mock 内部状态（余额、单据 status/approverName）——语义层。
 *
 * 关键语义：**年假只在审批通过时扣减，提交时不扣**；驳回与撤回都不动余额。
 * 这条规则同时决定薪酬模块的事假/加班统计口径，所以任何一层漂移都必须红。
 *
 * 跨角色用例统一走 openRole()：每个角色一个 BrowserContext（各自的 localStorage
 * token 互不污染），但共享同一个 MockBackend 实例，见 support/fixtures.ts。
 */
import type { Locator, Page } from '@playwright/test'
import { confirmBox, expect, REAL_BACKEND, signIn, test, toast } from './support/fixtures'

/** 我的申请记录里按事由定位唯一一行（事由在各用例里都是唯一的）。 */
function rowByReason(page: Page, pane: 'pane-my' | 'pane-approve', reason: string): Locator {
  return page.locator(`#${pane} tr.el-table__row`).filter({ hasText: reason })
}

/** 年假余额标签里的数字。 */
function balanceValue(page: Page): Locator {
  return page.locator('.el-tag').filter({ hasText: '当前可用年假余额' }).locator('strong')
}

/**
 * 打开建单弹窗。
 *
 * 注意组件在 openCreateDialog() 里就预填了「今天 09:00 / 18:00、请假天数 1、事由空」，
 * 所以校验用例只需保留事由为空即可命中三分支校验，不必去操作那两个没有
 * placeholder 的 datetime 选择器。
 */
async function openCreateDialog(page: Page): Promise<Locator> {
  await page.getByRole('button', { name: '发起请假 / 加班申请' }).click()
  const dialog = page.locator('.el-dialog').filter({ hasText: '发起假勤' })
  await expect(dialog).toBeVisible()
  return dialog
}

/** 选 element-plus 下拉项：选项 teleport 到 body 且关闭后仍留在 DOM，必须限定 :visible。 */
async function pickOption(page: Page, scope: Locator, index: number, label: string): Promise<void> {
  await scope.locator('.el-select').nth(index).locator('.el-select__wrapper').click()
  await page
    .locator('.el-select-dropdown:visible .el-select-dropdown__item')
    .filter({ hasText: label })
    .first()
    .click()
}

/** 收集本用例内前端发出的 /api/v1 请求（mock 侧只有 unmatched 日志，所以自己收）。 */
function trackApi(page: Page): string[] {
  const calls: string[] = []
  page.on('request', (req) => {
    if (req.url().includes('/api/v1/')) calls.push(`${req.method()} ${new URL(req.url()).pathname}`)
  })
  return calls
}

test.describe('建单表单', () => {
  test('事由为空时提交：前端拦截、不关窗、零请求', async ({ page }) => {
    await signIn(page, 'emp01', '/approval')
    const calls = trackApi(page)
    const dialog = await openCreateDialog(page)

    await dialog.getByRole('button', { name: '提交审批' }).click()
    await expect(toast(page, '请完整填写开始时间、结束时间和申请事由')).toBeVisible()
    // 校验失败绝不能关窗，否则用户填的内容就丢了
    await expect(dialog).toBeVisible()
    expect(calls.filter((c) => c.startsWith('POST'))).toEqual([])
  })

  test('请假/加班切换：细分类型选项与时长单位联动', async ({ page }) => {
    await signIn(page, 'emp01', '/approval')
    const dialog = await openCreateDialog(page)
    await expect(dialog.getByText('请假天数')).toBeVisible()

    // el-radio-button 的原生 input 是 opacity:0，点可见的 label 才稳
    await dialog.getByText('加班申请', { exact: true }).click()
    await expect(dialog.getByText('加班小时')).toBeVisible()
    await expect(dialog.getByText('请假天数')).toHaveCount(0)

    await dialog.locator('.el-select').first().locator('.el-select__wrapper').click()
    const items = page.locator('.el-select-dropdown:visible .el-select-dropdown__item')
    await expect(items).toHaveCount(3)
    await expect(items.filter({ hasText: '节假日加班' })).toBeVisible()
    await page.keyboard.press('Escape')

    await dialog.getByRole('button', { name: '取消' }).click()
    await expect(dialog).toBeHidden()
  })
})

test.describe('审批闭环', () => {
  test('员工提交 → 主管通过：余额 5 → 4，意见回显，工作台按状态过滤', async ({ page, mock, openRole }) => {
    test.skip(REAL_BACKEND, '真实后端余额取决于库内既有数据，无法钉死 5 → 4')
    const reason = 'E2E 年假闭环'

    await signIn(page, 'emp01', '/approval')
    await expect(balanceValue(page)).toHaveText('5')

    const dialog = await openCreateDialog(page)
    await dialog.getByPlaceholder('请简述请假或加班事由').fill(reason)
    const created = page.waitForRequest(
      (req) => req.method() === 'POST' && new URL(req.url()).pathname === '/api/v1/requests'
    )
    await dialog.getByRole('button', { name: '提交审批' }).click()
    expect(JSON.parse((await created).postData() ?? '{}')).toMatchObject({
      category: 'LEAVE',
      subType: 'ANNUAL',
      duration: 1,
      reason,
    })
    await expect(toast(page, '申请已提交')).toBeVisible()
    await expect(dialog).toBeHidden()

    const myRow = rowByReason(page, 'pane-my', reason)
    await expect(myRow).toContainText('待审批')
    // 提交阶段不扣余额：扣减只发生在审批通过时
    expect(mock.leaveBalance('emp01')).toBe(5)
    expect(mock.findRequestByReason(reason)?.status).toBe('PENDING')

    const mgr = await openRole('manager', '/approval')
    await mgr.getByRole('tab', { name: '审批工作台' }).click()
    await expect(mgr.locator('#pane-approve')).toBeVisible()
    // 工作台默认 status=PENDING（契约参数名与后端一致），所以新单此刻可见
    const workRow = rowByReason(mgr, 'pane-approve', reason)
    await expect(workRow).toContainText('陈思远')
    await workRow.getByRole('button', { name: '通过' }).click()

    const approveDialog = mgr.locator('.el-dialog').filter({ hasText: '确认审批通过' })
    await expect(approveDialog).toBeVisible()
    await expect(approveDialog.getByText('陈思远')).toBeVisible()
    await expect(approveDialog.getByPlaceholder('填写审批意见或驳回原因')).toHaveValue('同意')

    const approved = mgr.waitForRequest(
      (req) => req.method() === 'POST' && /\/api\/v1\/requests\/\d+\/approve$/.test(req.url())
    )
    await approveDialog.getByRole('button', { name: '同意通过' }).click()
    expect(JSON.parse((await approved).postData() ?? '{}')).toMatchObject({
      action: 'APPROVED',
      approveRemark: '同意',
    })
    await expect(toast(mgr, '审批已通过')).toBeVisible()

    expect(mock.findRequestByReason(reason)?.status).toBe('APPROVED')
    // 审批人落的是账号名，UI 在「审批操作」列直接显示它
    expect(mock.findRequestByReason(reason)?.approverName).toBe('manager')
    expect(mock.leaveBalance('emp01')).toBe(4)

    // 通过后该行退出默认视图，切到「已通过」才能看到审批人回显
    await pickOption(mgr, mgr.locator('#pane-approve'), 1, '已通过')
    await expect(rowByReason(mgr, 'pane-approve', reason)).toContainText('manager')

    // 员工侧重新加载：余额与审批结果都必须刷新
    await page.reload()
    await expect(balanceValue(page)).toHaveText('4')
    const rowAfter = rowByReason(page, 'pane-my', reason)
    await expect(rowAfter).toContainText('已通过')
    await expect(rowAfter).toContainText('同意')
  })

  test('撤回：二次确认后落 CANCELLED，余额不动，撤回按钮消失', async ({ page, mock }) => {
    const reason = '年假出行' // 种子里那条待审批年假
    await signIn(page, 'emp01', '/approval')
    const row = rowByReason(page, 'pane-my', reason)
    await expect(row).toContainText('待审批')

    await row.getByRole('button', { name: '撤回' }).click()
    const box = confirmBox(page, '撤回确认')
    await expect(box).toContainText('确认撤回该待审批申请单吗？')
    await box.getByRole('button', { name: '确定' }).click()

    await expect(toast(page, '已撤回申请')).toBeVisible()
    await expect(row).toContainText('已撤回')
    await expect(row.getByRole('button', { name: '撤回' })).toHaveCount(0)
    expect(mock.findRequestByReason(reason)?.status).toBe('CANCELLED')
    expect(mock.leaveBalance('emp01')).toBe(5)
  })

  test('驳回：两步确认 + 意见落到员工侧，余额不扣', async ({ page, mock, openRole }) => {
    const reason = '年假出行'

    const mgr = await openRole('manager', '/approval')
    await mgr.getByRole('tab', { name: '审批工作台' }).click()
    await expect(mgr.locator('#pane-approve')).toBeVisible()
    await rowByReason(mgr, 'pane-approve', reason).getByRole('button', { name: '驳回' }).click()

    const rejectDialog = mgr.locator('.el-dialog').filter({ hasText: '驳回申请' })
    await expect(rejectDialog).toBeVisible()
    await expect(rejectDialog.getByPlaceholder('填写审批意见或驳回原因')).toHaveValue('')
    await rejectDialog.getByPlaceholder('填写审批意见或驳回原因').fill('项目关键期，暂缓休假')
    await rejectDialog.getByRole('button', { name: '确认驳回' }).click()

    const box = confirmBox(mgr, '驳回确认')
    await expect(box).toContainText('确认驳回「陈思远」的申请吗？')
    await box.getByRole('button', { name: '确定' }).click()
    await expect(toast(mgr, '已驳回该申请')).toBeVisible()

    expect(mock.findRequestByReason(reason)?.status).toBe('REJECTED')
    expect(mock.leaveBalance('emp01')).toBe(5)

    await signIn(page, 'emp01', '/approval')
    const myRow = rowByReason(page, 'pane-my', reason)
    await expect(myRow).toContainText('已驳回')
    await expect(myRow).toContainText('项目关键期，暂缓休假')
  })

  test('余额边界：恰好扣满允许通过，扣完后再申请/再审批都被拒绝', async ({ page, mock, openRole }) => {
    test.skip(REAL_BACKEND, '依赖 mock 内部余额构造越界条件')
    const reason = 'E2E 全额年假'
    const tooMuch = 'E2E 余额已空'

    await signIn(page, 'emp01', '/approval')
    await expect(balanceValue(page)).toHaveText('5')

    // 请假天数 = 余额 = 5：`balance < duration` 为假，这是「刚好用完」的合法边界
    const dialog = await openCreateDialog(page)
    await dialog.getByPlaceholder('请简述请假或加班事由').fill(reason)
    const durationInput = dialog.locator('.el-input-number input')
    await durationInput.fill('5')
    await durationInput.press('Enter')
    await expect(durationInput).toHaveValue('5')
    const created = page.waitForRequest(
      (req) => req.method() === 'POST' && new URL(req.url()).pathname === '/api/v1/requests'
    )
    await dialog.getByRole('button', { name: '提交审批' }).click()
    expect(JSON.parse((await created).postData() ?? '{}')).toMatchObject({ duration: 5, reason })
    await expect(toast(page, '申请已提交')).toBeVisible()

    const mgr = await openRole('manager', '/approval')
    await mgr.getByRole('tab', { name: '审批工作台' }).click()
    await rowByReason(mgr, 'pane-approve', reason).getByRole('button', { name: '通过' }).click()
    const firstApprove = mgr.locator('.el-dialog').filter({ hasText: '确认审批通过' })
    await firstApprove.getByRole('button', { name: '同意通过' }).click()
    await expect(toast(mgr, '审批已通过')).toBeVisible()
    expect(mock.leaveBalance('emp01')).toBe(0)

    await page.reload()
    await expect(balanceValue(page)).toHaveText('0')

    // 余额已空：建单阶段就被后端拒绝，前端必须报错而不是假装提交成功
    const dialog2 = await openCreateDialog(page)
    await dialog2.getByPlaceholder('请简述请假或加班事由').fill(tooMuch)
    await dialog2.getByRole('button', { name: '提交审批' }).click()
    await expect(toast(page, '剩余年假天数不足')).toBeVisible()
    await expect(toast(page, '申请已提交')).toHaveCount(0)
    expect(mock.findRequestByReason(tooMuch)).toBeUndefined()
    await dialog2.getByRole('button', { name: '取消' }).click()

    // 种子里那条 1 天年假仍挂着，此刻审批也会因余额不足被拒，且单据不得变成已通过
    const staleRow = rowByReason(mgr, 'pane-approve', '年假出行')
    await staleRow.getByRole('button', { name: '通过' }).click()
    const secondApprove = mgr.locator('.el-dialog').filter({ hasText: '确认审批通过' })
    await secondApprove.getByRole('button', { name: '同意通过' }).click()
    // 只断言错误提示：成功 toast 此刻可能仍残留在屏幕上，用「不得变为已通过」的
    // 状态断言（下面两行）来兜底才是可靠写法。
    await expect(toast(mgr, '剩余年假不足')).toBeVisible()
    await secondApprove.getByRole('button', { name: '取消' }).click()
    expect(mock.findRequestByReason('年假出行')?.status).toBe('PENDING')
    expect(mock.leaveBalance('emp01')).toBe(0)
  })
})

test.describe('审批入口的权限门', () => {
  test('普通员工没有审批工作台 tab，主管有', async ({ page, mock, openRole }) => {
    void mock
    await signIn(page, 'emp01', '/approval')
    await expect(page.getByRole('tab', { name: '我的申请记录' })).toBeVisible()
    await expect(page.getByRole('tab', { name: '审批工作台' })).toHaveCount(0)

    const mgr = await openRole('manager', '/approval')
    await expect(mgr.getByRole('tab', { name: '审批工作台' })).toBeVisible()
  })
})
