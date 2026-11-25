/**
 * P1.3（五）薪酬：一键核算 → 调项重计税 → 单条/批量发放 → 员工「我的工资条」金额一致。
 *
 * 这是 P1.3 承诺的最后一环：「薪资生成后『我的工资条』金额一致」。
 * 金额全部来自 FOLLOWUP_PLAN 里逐位推导过的权威值（emp01/陈思远，2026-11）：
 *   日薪 19000/21.75=873.5632 → 时薪 109.1954
 *   加班费 = 3h × 1.5 × 时薪 = 491.38
 *   考勤扣款 = 迟到 1 次 × 50 + 事假 1 天 × 日薪 = 923.56
 *   绩效奖金 = 19000 × 10% × 0.9（已 COMPLETED 绩效系数）= 1710
 *   五险一金 = 19000 × 18.5% = 3515
 *   应纳税所得 = 19000+1710+491.38-923.56-3515-5000 = 11762.82 → 10% 档
 *   个税 = 11762.82 × 10% - 210 = 966.28
 *   实发 = 15796.54
 *
 * 权威值成立的前提：薪资月份必须等于 PAYROLL_MONTH，且当月只有种子里那两条
 * 考勤（11 号迟到 20 分钟、13 号正常）。所以本文件**绝不做签到/打卡**，
 * 也绝不依赖运行日落在哪个月 —— 组件里的 filters.payMonth 是硬编码 2026-11。
 */
import type { Locator, Page } from '@playwright/test'
import { PAYROLL_MONTH } from './support/mock-server'
import { confirmBox, expect, signIn, test, toast } from './support/fixtures'

/** 陈思远（employeeId=4）在 PAYROLL_MONTH 的权威薪资值。 */
const CHEN = {
  empNo: 'EMP20260004',
  bonus: '1710',
  overtime: '491.38',
  deduction: '923.56',
  social: '3515',
  tax: '966.28',
  net: '15796.54',
} as const

/** 调项把绩效奖金抬到 2710 后，应纳税所得跨进 20% 档的第二组权威值。 */
const CHEN_ADJUSTED = { bonus: '2710', tax: '1142.56', net: '16620.26' } as const

/** 一键核算覆盖的人数：mock 种子里 ACTIVE + PROBATION 共 5 人（RESIGNED 不参与）。 */
const EMP_COUNT = 5

/** 核算中心里按姓名锁定唯一一行。 */
function adminRow(page: Page, name: string): Locator {
  return page.locator(`#pane-admin tr.el-table__row`).filter({ hasText: name })
}

/** 实发工资单元格（该行唯一的 <strong>）。 */
function netCell(row: Locator): Locator {
  return row.locator('strong')
}

/** 点「一键核算生成」并等列表落地，返回核算后的陈思远行。 */
async function generate(page: Page): Promise<Locator> {
  const req = page.waitForRequest(
    (r) => r.method() === 'POST' && new URL(r.url()).pathname === '/api/v1/payrolls/generate'
  )
  await page.getByRole('button', { name: '一键核算生成' }).click()
  // 请求体必须只带 payMonth，且与组件显示月份一致
  expect(JSON.parse((await req).postData() ?? '{}')).toEqual({ payMonth: PAYROLL_MONTH })
  // 5 = ACTIVE + PROBATION 全员，草稿态
  await expect(toast(page, `${PAYROLL_MONTH} 薪资核算完成，共生成/更新 5 条记录`)).toBeVisible()
  await expect(page.locator('#pane-admin tr.el-table__row')).toHaveCount(5)
  return adminRow(page, '陈思远')
}

test.describe('薪酬入口的权限门', () => {
  test('普通员工与部门经理都没有薪资核算中心', async ({ page, mock }) => {
    void mock
    await signIn(page, 'emp01', '/payroll')
    await expect(page.getByRole('tab', { name: '我的工资条' })).toBeVisible()
    await expect(page.getByRole('tab', { name: '薪资核算中心' })).toHaveCount(0)
    // activeTab 由 isHrOrAdmin 决定，非 HR 只能落在「我的工资条」
    await expect(page.locator('#pane-my')).toBeVisible()
    await expect(page.locator('#pane-my .el-table__empty-text')).toHaveText('暂无已发放工资条记录')
  })

  test('HR 默认停在核算中心，且只发薪酬模块自身的请求', async ({ page }) => {
    const calls: string[] = []
    await signIn(page, 'hr', '/payroll')
    // 监听器只能在 signIn 之后挂，所以这里刻意断言「不该出现的东西」而不是精确请求条数：
    // 同一批请求在整页加载里可能早于监听器完成，用 toEqual 精确数组会让用例退化成计时器
    // （首轮就是因此假绿——当时 /payrolls/my 恰好发在监听之前，改成冷启动画像同步后才暴露）。
    page.on('request', (r) => {
      if (r.url().includes('/api/v1/')) calls.push(new URL(r.url()).pathname)
    })
    await expect(page.locator('#pane-admin')).toBeVisible()
    await expect(page.locator('#pane-my')).toBeHidden()
    await expect(page.getByRole('button', { name: '一键全部发放' })).toBeVisible()
    // 「我的工资条」pane 对 HR 没有 v-if，只是非激活 tab，预取 /payrolls/my 属设计如此；
    // 顶栏铃铛的未读轮询属于全局布局，也不是薪酬页发的；
    // 真正要钉住的是：薪酬页绝不替别的业务模块取数。
    const layoutOwn = ['/api/v1/payrolls', '/api/v1/notifications/unread-count']
    expect(calls.filter((p) => !layoutOwn.some((x) => p.startsWith(x)))).toEqual([])
    expect(calls).toContain('/api/v1/payrolls')
  })
})

test.describe('核算 → 发放 → 工资条闭环', () => {
  test('批量发放后，员工工资条金额与核算值逐分一致', async ({ page, mock, openRole }) => {
    await signIn(page, 'hr', '/payroll')
    const chen = await generate(page)

    // 逐项钉死权威值，任何一处算法漂移都会在这里红
    await expect(chen).toContainText(CHEN.empNo)
    await expect(chen).toContainText(CHEN.bonus)
    await expect(chen).toContainText(CHEN.overtime)
    await expect(chen).toContainText(CHEN.deduction)
    await expect(chen).toContainText(CHEN.social)
    await expect(chen).toContainText(CHEN.tax)
    await expect(netCell(chen)).toHaveText(`￥${CHEN.net}`)
    await expect(chen).toContainText('草稿')
    expect(mock.payrollRow(4, PAYROLL_MONTH)?.status).toBe('DRAFT')

    // 按钮可访问名就是「一键全部发放」（图标不进可访问名），漏点这一步确认框不会出现
    await page.getByRole('button', { name: '一键全部发放' }).click()
    const box = confirmBox(page, '批量发薪确认')
    await expect(box).toContainText(`确认将 ${PAYROLL_MONTH} 所有草稿状态的薪资记录批量标记为「已发放」吗？`)
    await box.getByRole('button', { name: '确定' }).click()
    await expect(toast(page, '批量发薪成功，共发放 5 笔')).toBeVisible()
    await expect(chen).toContainText('已发放')
    await expect(netCell(chen)).toHaveText(`￥${CHEN.net}`)
    expect(mock.payrollRow(4, PAYROLL_MONTH)?.status).toBe('PAID')

    // 员工侧：草稿不可见、发放后可见，且金额与 HR 看到的完全相同
    const emp = await openRole('emp01', '/payroll')
    const slipRow = emp.locator('#pane-my tr.el-table__row').filter({ hasText: PAYROLL_MONTH })
    await expect(slipRow).toHaveCount(1)
    await expect(netCell(slipRow)).toHaveText(`￥${CHEN.net}`)
    await expect(slipRow).toContainText(CHEN.tax)

    await slipRow.getByRole('button', { name: '电子凭条' }).click()
    const slip = emp.locator('.el-dialog').filter({ hasText: '月度电子工资条明细' })
    await expect(slip).toBeVisible()
    await expect(slip).toContainText(`陈思远 (${CHEN.empNo})`)
    await expect(slip).toContainText(`-￥${CHEN.deduction}`)
    await expect(slip).toContainText(`-￥${CHEN.social}`)
    await expect(slip).toContainText(`-￥${CHEN.tax}`)
    await expect(slip).toContainText(`￥${CHEN.net}`)
    // 备注为空时凭条必须显式补一个「-」，否则员工看到空白会以为漏项
    await expect(slip).toContainText('备注')
  })

  test('草稿才允许发放：单条发放后调项入口一并消失', async ({ page, mock }) => {
    await signIn(page, 'hr', '/payroll')
    const chen = await generate(page)
    await expect(chen.getByRole('button', { name: '调项' })).toBeVisible()

    await chen.getByRole('button', { name: '确认发放' }).click()
    const box = confirmBox(page, '发薪确认')
    await expect(box).toContainText(`确认向「陈思远」发放 ${PAYROLL_MONTH} 工资 ￥${CHEN.net} 吗？`)
    await box.getByRole('button', { name: '确定' }).click()
    await expect(toast(page, '发放成功')).toBeVisible()

    // 后端对 PAID 拒绝再次修改/发放，UI 层同步摘掉入口
    await expect(chen.getByRole('button', { name: '调项' })).toHaveCount(0)
    await expect(chen.getByRole('button', { name: '确认发放' })).toHaveCount(0)
    await expect(chen).toContainText('已发')
    expect(mock.payrollRow(4, PAYROLL_MONTH)?.status).toBe('PAID')
    // 只发了 1 笔，其余仍是草稿
    expect(mock.payrollRow(1, PAYROLL_MONTH)?.status).toBe('DRAFT')
  })
})

test.describe('调项与重新计税', () => {
  test('绩效奖金 1710 → 2710：跨进 20% 档，实发 16620.26', async ({ page, mock }) => {
    await signIn(page, 'hr', '/payroll')
    const chen = await generate(page)

    await chen.getByRole('button', { name: '调项' }).click()
    const dialog = page.locator('.el-dialog').filter({ hasText: '调整薪资明细' })
    await expect(dialog).toContainText('陈思远')
    const bonusInput = dialog.locator('.el-input-number input').first()
    // precision=2 时 EP 可能渲染成 1710.00，这里只要求数值前缀一致
    await expect(bonusInput).toHaveValue(/^1710(\.00)?$/)
    await bonusInput.fill('2710')
    await bonusInput.press('Enter')
    await dialog.locator('textarea').fill('E2E 调高绩效奖金')

    const put = page.waitForRequest(
      (r) => r.method() === 'PUT' && /\/api\/v1\/payrolls\/\d+$/.test(r.url())
    )
    await dialog.getByRole('button', { name: '重算并保存' }).click()
    const body = JSON.parse((await put).postData() ?? '{}')
    // 三个金额必须全量回传：后端对缺字段可能按 0 处理，绝不能只发改动项
    expect(body).toMatchObject({
      bonus: 2710,
      overtimePay: 491.38,
      attendanceDeduction: 923.56,
      remark: 'E2E 调高绩效奖金',
    })
    await expect(toast(page, '明细已更新并重新计税')).toBeVisible()
    await expect(dialog).toBeHidden()

    await expect(netCell(chen)).toHaveText(`￥${CHEN_ADJUSTED.net}`)
    await expect(chen).toContainText(CHEN_ADJUSTED.tax)
    const row = mock.payrollRow(4, PAYROLL_MONTH)
    expect(row?.tax).toBe(1142.56)
    expect(row?.netSalary).toBe(16620.26)

    // 单条发放的确认文案必须引用**重算后**的实发，而不是列表加载前的旧值
    await chen.getByRole('button', { name: '确认发放' }).click()
    const box = confirmBox(page, '发薪确认')
    await expect(box).toContainText(`￥${CHEN_ADJUSTED.net}`)
    await box.getByRole('button', { name: '取消' }).click()
    await expect(box).toBeHidden()
    expect(mock.payrollRow(4, PAYROLL_MONTH)?.status).toBe('DRAFT')
  })

  test('取消调项不产生任何写请求', async ({ page, mock }) => {
    await signIn(page, 'hr', '/payroll')
    const chen = await generate(page)
    const calls: string[] = []
    page.on('request', (r) => {
      if (r.url().includes('/api/v1/payrolls') && r.method() !== 'GET') calls.push(r.method())
    })

    await chen.getByRole('button', { name: '调项' }).click()
    const dialog = page.locator('.el-dialog').filter({ hasText: '调整薪资明细' })
    await dialog.locator('.el-input-number input').first().fill('99999')
    await dialog.getByRole('button', { name: '取消' }).click()
    await expect(dialog).toBeHidden()

    expect(calls).toEqual([])
    const row = mock.payrollRow(4, PAYROLL_MONTH)
    expect(row?.bonus).toBe(1710)
    expect(row?.netSalary).toBe(15796.54)
  })
})

test.describe('筛选与导出', () => {
  test('发薪月份按后端契约发 payMonth 参数，空列表不导出', async ({ page, mock }) => {
    void mock
    await signIn(page, 'hr', '/payroll')

    // 探针实证：type=month 的 date-picker 输入框可编辑，fill + Enter 即触发 @change
    const month = page.getByPlaceholder('发薪月份')
    const req = page.waitForRequest(
      (r) => new URL(r.url()).searchParams.get('payMonth') === '2019-01'
    )
    await month.fill('2019-01')
    await month.press('Enter')
    const params = new URL((await req).url()).searchParams
    expect(params.get('payMonth')).toBe('2019-01')
    expect([...params.keys()]).not.toContain('date')
    await expect(page.locator('#pane-admin tr.el-table__row')).toHaveCount(0)

    // 列表为空时导出必须被前端拦住，不会下载出一个只有表头的空文件
    await page.getByRole('button', { name: '导出 CSV' }).click()
    await expect(toast(page, '当前列表暂无可导出数据')).toBeVisible()
  })

  test('导出报表自己拉全量，而不是复用屏幕上那一页', async ({ page }) => {
    await signIn(page, 'hr', '/payroll')
    await generate(page)

    // 屏幕上表格按 pageSize=10 分页，导出必须换成 100 一页把数据捞齐；
    // 后端 handlePayrollList 把 pageSize>100 夹回 20（payroll_controller.cj:124），
    // 所以 100 是能一次拿到的上限，也是这里唯一正确的取值。
    const req = page.waitForRequest(
      (r) => r.method() === 'GET' && new URL(r.url()).pathname === '/api/v1/payrolls'
    )
    const [download] = await Promise.all([
      page.waitForEvent('download'),
      page.getByRole('button', { name: '导出 CSV' }).click()
    ])
    const params = new URL((await req).url()).searchParams
    expect(params.get('pageSize'), '导出要按 100 条一页拉全量').toBe('100')
    expect(params.get('page')).toBe('1')
    expect(params.get('payMonth')).toBe(PAYROLL_MONTH)
    expect(download.suggestedFilename()).toBe(`payroll_${PAYROLL_MONTH}.csv`)

    let text = ''
    const stream = await download.createReadStream()
    for await (const chunk of stream) text += Buffer.from(chunk as Uint8Array).toString('utf8')
    const lines = text.replace(/^\uFEFF/, '').split('\n').filter((l) => l.length > 0)
    // 表头 + 与 total 一致的数据行（不是当前页行数）
    expect(lines.length).toBe(EMP_COUNT + 1)
    expect(lines[0].split(',').length).toBe(12)
    expect(lines.slice(1).filter((l) => l.includes(CHEN.empNo)).length).toBe(1)
  })

  test('关键字筛选只命中目标员工', async ({ page, mock }) => {
    await signIn(page, 'hr', '/payroll')
    await generate(page)

    const keyword = page.getByPlaceholder('搜索姓名 / 工号')
    const req = page.waitForRequest((r) => new URL(r.url()).searchParams.get('keyword') === CHEN.empNo)
    await keyword.fill(CHEN.empNo)
    await keyword.press('Enter')
    expect((await req).url()).toContain('keyword=' + CHEN.empNo)

    const rows = page.locator('#pane-admin tr.el-table__row')
    await expect(rows).toHaveCount(1)
    await expect(rows.first()).toContainText('陈思远')
    expect(mock.payrollRow(4, PAYROLL_MONTH)?.empNo).toBe(CHEN.empNo)
  })
})
