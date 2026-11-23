/**
 * P2.4 考勤月度汇总导出。
 *
 * 这个 spec 存在的核心目的是钉住验收项「**导出报表与页面数字一致**」：
 * 后端 handleAttendanceMonthlySummary 一次返回全量 list + summary，
 * 前端表格与 CSV 共用同一份 sumList / sumTotals，任何一侧偷偷做二次计算都会被这里抓住。
 *
 * 另外三条锁：
 * 1. tab 只对 ADMIN / HR / MANAGER 可见（与后端 requireRoles 同一口径）。
 * 2. MANAGER 的汇总被强制限定在本部门，不是靠前端不显示部门下拉实现的。
 * 3. 部门筛选按后端契约发 deptId（而不是 deptName / departmentId）。
 *
 * 数值断言全部依赖 mock 种子，因此 REAL_BACKEND 下跳过（真实库的人数与考勤不可控）。
 */
import type { Page } from '@playwright/test'
import { HISTORY_MONTH, PAYROLL_MONTH } from './support/mock-server'
import { expect, REAL_BACKEND, signIn, test, toast } from './support/fixtures'

/** 表格里可见行的单元格文本（按列顺序）。 */
async function tableCells(page: Page): Promise<string[][]> {
  const rows = page.locator('#pane-summary .el-table__body tr:visible')
  const count = await rows.count()
  const out: string[][] = []
  for (let i = 0; i < count; i += 1) {
    out.push(await rows.nth(i).locator('td').allInnerTexts())
  }
  return out
}

/** 切到「月度汇总导出」并等真正可见；首次进入会触发部门树 + 汇总两个请求。 */
async function openSummaryPane(page: Page): Promise<void> {
  const req = page.waitForRequest((r) => r.method() === 'GET' && new URL(r.url()).pathname === '/api/v1/attendance/monthly-summary')
  await page.getByRole('tab', { name: '月度汇总导出' }).click()
  await expect(page.locator('#pane-summary')).toBeVisible()
  await req
}

/**
 * 把汇总月份固定到种子月，避免用例随运行日期漂移。
 *
 * 两个坑：
 * 1. waitForRequest 必须先注册再触发 —— Vue 的 @change 是微任务，先 fill 后注册
 *    会漏掉已经发出的请求（这里踩过一次假红）。
 * 2. 当前月恰好就是种子月时（PAYROLL_MONTH = 2026-11），el-date-picker 的值没变，
 *    @change 根本不会触发，所以要先比对 inputValue 再决定等不等。
 */
async function pickMonth(page: Page, month: string): Promise<void> {
  const input = page.locator('#pane-summary').getByPlaceholder('选择月份')
  if ((await input.inputValue()) === month) return
  const req = page.waitForRequest(
    (r) => r.method() === 'GET' && new URL(r.url()).pathname === '/api/v1/attendance/monthly-summary'
  )
  await input.fill(month)
  await input.press('Enter')
  expect(new URL((await req).url()).searchParams.get('month'), '切月要把新月份带进请求').toBe(month)
}

/** 解析 CSV：剥 BOM、按 CRLF 拆行，返回字符串二维数组。 */
async function readCsv(page: Page): Promise<string[][]> {
  const [download] = await Promise.all([
    page.waitForEvent('download'),
    page.locator('#pane-summary').getByRole('button', { name: '一键导出 CSV' }).click()
  ])
  expect(download.suggestedFilename()).toBe(`考勤月度汇总_${PAYROLL_MONTH}.csv`)
  let text = ''
  const stream = await download.createReadStream()
  for await (const chunk of stream) text += Buffer.from(chunk as Uint8Array).toString('utf8')
  expect(text.charCodeAt(0), 'CSV 必须以 UTF-8 BOM 开头，否则 Excel 会把中文打开成乱码').toBe(0xfeff)
  return text
    .replace(/^\uFEFF/, '')
    .split('\r\n')
    .filter((l) => l.length > 0)
    .map((l) => l.split(','))
}

test.describe('月度汇总导出（P2.4）', () => {
  test('普通员工看不到月度汇总 tab', async ({ page }) => {
    await signIn(page, 'emp01', '/attendance')
    await expect(page.getByRole('tab', { name: '月度汇总导出' })).toHaveCount(0)
    await expect(page.getByRole('tab', { name: '全员考勤监控' })).toHaveCount(0)
  })

  test('人事有月度汇总 tab', async ({ page }) => {
    await signIn(page, 'hr', '/attendance')
    await expect(page.getByRole('tab', { name: '月度汇总导出' })).toBeVisible()
  })

  test('人事切到汇总 tab：默认按月取数，卡片与明细同源', async ({ page }) => {
    test.skip(REAL_BACKEND, '真实库人数不可控')
    await signIn(page, 'hr', '/attendance')
    await openSummaryPane(page)
    await pickMonth(page, PAYROLL_MONTH)

    const pane = page.locator('#pane-summary')
    await expect(pane.getByText('统计人数')).toBeVisible()
    await expect(pane.locator('.hrms-card').filter({ hasText: '统计人数' })).toContainText('5 人')
    await expect(pane.locator('.hrms-card').filter({ hasText: '整体出勤率' })).toContainText('1.82%')
    await expect(pane.locator('.hrms-card').filter({ hasText: '合计出勤天数' })).toContainText('2 天')
    await expect(pane.locator('.hrms-card').filter({ hasText: '迟到 / 早退次数' })).toContainText('1 / 0')
    await expect(pane.locator('.hrms-card').filter({ hasText: '迟到 / 早退分钟' })).toContainText('20 / 0')
    await expect(pane.locator('.hrms-card').filter({ hasText: '请假 / 加班' })).toContainText('1 天 / 3 h')

    // 整月一次卡都没打的人必须以 0 天出现在报表里（主表是员工而不是考勤）
    const rows = page.locator('#pane-summary .el-table__body tr:visible')
    await expect(rows).toHaveCount(5)
    await expect(rows.filter({ hasText: 'EMP20260001' }).first()).toContainText('总经办')
    // 唯一的迟到者：2 天 / 9.09% / 迟到 1 次 20 分钟 / 请假 1 天 / 加班 3 小时
    await expect(rows.filter({ hasText: 'EMP20260004' }).first()).toContainText('9.09')
    // 试用期员工同样纳入统计（后端只排除 RESIGNED）
    await expect(rows.filter({ hasText: 'EMP20260005' })).toHaveCount(1)
  })

  test('导出 CSV 的每一格都等于页面上的同一格', async ({ page }) => {
    test.skip(REAL_BACKEND, '真实库人数不可控')
    await signIn(page, 'hr', '/attendance')
    await openSummaryPane(page)
    await pickMonth(page, PAYROLL_MONTH)

    const cells = await tableCells(page)
    expect(cells.length).toBeGreaterThan(0)

    // ElMessage 3 秒自动关闭，断言要赶在读取下载流之前挂上。
    const tipped = toast(page, `已导出 ${cells.length} 人的月度考勤汇总`)
      .waitFor({ state: 'visible' })
      .then(() => true)
      .catch(() => false)
    const csv = await readCsv(page)
    // 行数 = 表头 + N 行明细 + 1 行合计
    expect(csv.length).toBe(cells.length + 2)
    expect(csv[0]).toEqual(['部门', '工号', '姓名', '出勤天数', '应出勤天数', '出勤率(%)', '迟到次数', '早退次数', '迟到(分钟)', '早退(分钟)', '请假(天)', '加班(小时)'])

    // CSV 比页面多一列「应出勤天数」（页面把它放在说明文字与卡片里），按列序映射后逐格比对
    const map = [0, 1, 2, 3, 5, 6, 7, 8, 9, 10, 11]
    for (let i = 0; i < cells.length; i += 1) {
      const line = csv[i + 1]
      expect(line[4], '每行明细的应出勤天数都是固定口径 22').toBe('22')
      for (let c = 0; c < map.length; c += 1) {
        expect(line[map[c]], `第 ${i + 1} 行第 ${c + 1} 列与页面不一致`).toBe(cells[i][c].trim())
      }
    }

    // 合计行：由明细累加而来，而不是另算一遍
    const totals = csv[csv.length - 1]
    expect(totals[0]).toBe('合计')
    expect(totals[2]).toBe(`${cells.length} 人`)
    const sum = (col: number): number => csv.slice(1, csv.length - 1).reduce((s, r) => s + Number(r[col]), 0)
    expect(Number(totals[3])).toBe(sum(3))
    expect(Number(totals[4])).toBe(cells.length * 22)
    expect(Number(totals[6])).toBe(sum(6))
    expect(Number(totals[8])).toBe(sum(8))
    expect(totals[5]).toBe('1.82')

    expect(await tipped, '导出成功后要给出人数提示').toBe(true)
  })

  test('换成历史月份重新取数，出勤天数随之变化', async ({ page }) => {
    test.skip(REAL_BACKEND, '依赖 mock 种子月份')
    await signIn(page, 'hr', '/attendance')
    await openSummaryPane(page)
    await pickMonth(page, HISTORY_MONTH)

    const cells = await tableCells(page)
    expect(cells.length).toBe(5)
    const cellOf = (empNo: string): string[] => {
      const row = cells.find((c) => c.includes(empNo))
      expect(row, `报表里缺少 ${empNo}`).toBeDefined()
      return row as string[]
    }
    // 2026-08 种子：陈思远 2 天正常、李泽宇 1 天、王静整条是 ABSENT、其余无记录
    expect(cellOf('EMP20260004')[3]).toBe('2')
    expect(cellOf('EMP20260004')[4]).toBe('9.09')
    expect(cellOf('EMP20260003')[3]).toBe('1')
    expect(cellOf('EMP20260003')[4]).toBe('4.55')
    // 缺勤当天有记录，但不能计成出勤；同时这一行必须仍然存在
    expect(cellOf('EMP20260002')[3]).toBe('0')
    expect(cellOf('EMP20260002')[4]).toBe('0')
    // 2 + 1 + 0 + 0 + 0 = 3 天
    await expect(page.locator('#pane-summary .hrms-card').filter({ hasText: '合计出勤天数' })).toContainText('3 天')
    // 该月没有已批准的请假 / 加班
    await expect(page.locator('#pane-summary .hrms-card').filter({ hasText: '请假 / 加班' })).toContainText('0 天 / 0 h')
  })

  test('部门经理的汇总被限定在本部门', async ({ page }) => {
    test.skip(REAL_BACKEND, '真实库部门人数不可控')
    await signIn(page, 'manager', '/attendance')
    await openSummaryPane(page)
    await pickMonth(page, PAYROLL_MONTH)

    const rows = page.locator('#pane-summary .el-table__body tr:visible')
    // manager 属技术研发中心：李泽宇 / 陈思远 / 林小满
    await expect(rows).toHaveCount(3)
    await expect(page.locator('#pane-summary .hrms-card').filter({ hasText: '统计人数' })).toContainText('3 人')
    // 2 / (3 × 22) = 3.03%
    await expect(page.locator('#pane-summary .hrms-card').filter({ hasText: '整体出勤率' })).toContainText('3.03%')
    // 后端按部门强制过滤，不信任 deptId 参数，所以经理看不到别的部门
    await expect(rows.filter({ hasText: '王静' })).toHaveCount(0)
  })

  test('人事按部门筛选要按后端契约发 deptId', async ({ page }) => {
    test.skip(REAL_BACKEND, '真实库部门 ID 不可控')
    await signIn(page, 'hr', '/attendance')
    await openSummaryPane(page)
    await pickMonth(page, PAYROLL_MONTH)

    const select = page.locator('#pane-summary .el-select').first()
    await select.locator('.el-select__wrapper').click()
    const option = page.locator('.el-select-dropdown:visible .el-select-dropdown__item').filter({ hasText: '人力资源部' })
    const req = page.waitForRequest(
      (r) => r.method() === 'GET' && new URL(r.url()).pathname === '/api/v1/attendance/monthly-summary'
    )
    await option.click()

    const params = new URL((await req).url()).searchParams
    expect(params.get('deptId')).toBe('3')
    expect([...params.keys()]).not.toContain('deptName')
    expect([...params.keys()]).not.toContain('departmentId')
    await expect(page.locator('#pane-summary .el-table__body tr:visible')).toHaveCount(1)
    await expect(page.locator('#pane-summary .el-table__body tr:visible').first()).toContainText('王静')
  })
})
