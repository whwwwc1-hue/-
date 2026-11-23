/**
 * P2.3 电子工资条「打印 / 存为 PDF」。
 *
 * ## 这里测的是什么
 * 打印专版是**同一份 DOM 的第二套媒体查询**，不是新页面、不是 PDF 库生成的文件。
 * 所以断言分成三层：
 *   1. 屏媒（screen）：专版必须完全不占位，SPA 照常可交互 —— 否则日常使用被打印样式污染。
 *   2. 纸媒（print）：专版是唯一可见内容，侧边栏 / 核算表格 / 弹窗 / 遮罩全部让位。
 *      第 2 层就是 FOLLOWUP_PLAN 验收项「打印预览无侧边栏」的可执行兑付。
 *   3. 金额：纸质件上的每一个数字都必须等于 payroll.spec.ts 里那组逐位推导过的权威值，
 *      且页脚的「复算校验」是前端独立重算的结果（第十一节规则③），不是把后端净额抄一遍。
 *
 * ## 为什么桩掉 window.print
 * 无头 Chromium 的真实打印会走浏览器的打印流程，用例要么卡住要么依赖平台。
 * 这里用 addInitScript 把 window.print 换成计数器，只验证「组件确实调了它」；
 * 纸张效果本身由 emulateMedia({ media: 'print' }) 驱动，与是否真弹打印面板无关。
 *
 * ## 为什么只在 HR 侧点打印按钮
 * 「员工侧」用例的工资条要靠 openRole 另开上下文，而 init script 只能在该 context
 * 首次导航前注入 —— 夹具在那之后才登录，桩注不进去。所以员工侧只验专版内容，
 * 点击动作由 HR 侧用例覆盖（同一个组件、同一个 handler）。
 */
import * as fs from 'node:fs'
import type { Locator, Page, TestInfo } from '@playwright/test'
import { PAYROLL_MONTH } from './support/mock-server'
import { expect, signIn, test, toast } from './support/fixtures'

/** 陈思远（employeeId=4）2026-11 权威值，与 payroll.spec.ts 同源。 */
const CHEN = {
  empNo: 'EMP20260004',
  base: '￥19000.00',
  bonus: '￥1710.00',
  overtime: '￥491.38',
  gross: '￥21201.38',
  deduction: '￥923.56',
  social: '￥3515.00',
  tax: '￥966.28',
  deductions: '￥5404.84',
  net: '￥15796.54'
}

/** 把 window.print 变成计数器；必须在任何导航之前调用。 */
async function stubPrint(page: Page): Promise<void> {
  await page.addInitScript(() => {
    const w = window as any
    w.__printCalls = 0
    w.print = () => {
      w.__printCalls += 1
    }
  })
}

async function printCalls(page: Page): Promise<number> {
  return page.evaluate(() => (window as any).__printCalls)
}

function root(page: Page): Locator {
  return page.locator('[data-testid="payslip-print-root"]')
}

function slipDialog(page: Page): Locator {
  return page.locator('.el-dialog').filter({ hasText: '月度电子工资条明细' })
}

/** 「发放状态 / 发放时间」那一行的第二个值单元格（该行有两个 td，last 即发放时间）。 */
function paidCell(sheet: Locator): Locator {
  return sheet.locator('tr').filter({ hasText: '发放时间' }).locator('td').last()
}

/** 核算中心里按姓名锁定唯一一行，并返回该行的「电子凭条」入口。 */
function adminSlipButton(page: Page, name: string): Locator {
  return page.locator('#pane-admin tr.el-table__row').filter({ hasText: name }).getByRole('button', { name: '电子凭条' })
}

/** 一键核算，落地 5 条草稿。 */
async function generate(page: Page): Promise<void> {
  await page.getByRole('button', { name: '一键核算生成' }).click()
  await expect(toast(page, `${PAYROLL_MONTH} 薪资核算完成，共生成/更新 5 条记录`)).toBeVisible()
  await expect(page.locator('#pane-admin tr.el-table__row')).toHaveCount(5)
}

/**
 * 把纸媒渲染固化成两个可人工复核的产物：PNG 看版式，PDF 证明浏览器 print-to-PDF
 * 这条流水线确实吃下了我们的 @page 与 @media print。两者都落在 gitignore 的 test-results/。
 */
async function capturePaper(page: Page, testInfo: TestInfo): Promise<void> {
  fs.mkdirSync('test-results', { recursive: true })
  const png = await page.screenshot({ path: 'test-results/payslip-print.png', fullPage: true })
  await testInfo.attach('纸媒渲染（PNG）', { body: png, contentType: 'image/png' })
  const pdfPath = 'test-results/payslip-print.pdf'
  await page.pdf({ path: pdfPath, preferCSSPageSize: true })
  expect(fs.readFileSync(pdfPath).subarray(0, 5).toString('latin1')).toBe('%PDF-')
  await testInfo.attach('纸媒渲染（PDF）', { path: pdfPath, contentType: 'application/pdf' })
}

test.describe('打印专版的媒体边界', () => {
  test('屏媒不占位，纸媒里专版是唯一内容且侧边栏消失', async ({ page }, testInfo) => {
    await stubPrint(page)
    await signIn(page, 'hr', '/payroll')
    await generate(page)

    // 未打开任何工资条时，DOM 里根本不该存在专版（v-if 挂在 activeSlip 上）
    await expect(root(page)).toHaveCount(0)

    await adminSlipButton(page, '陈思远').click()
    await expect(slipDialog(page)).toBeVisible()

    // 模式类由弹窗状态驱动，可被直接断言
    await expect(page.locator('html.hrms-payslip-print-mode')).toHaveCount(1)

    // —— 屏媒：专版存在但不可见，正常页面照常可交互 ——
    await expect(root(page)).toBeHidden()
    await expect(page.locator('aside')).toBeVisible()
    await expect(page.locator('#pane-admin')).toBeVisible()

    // —— 纸媒：验收项「打印预览无侧边栏」在这里兑付 ——
    await page.emulateMedia({ media: 'print' })
    await expect(root(page)).toBeVisible()
    await expect(page.locator('aside')).toBeHidden()
    await expect(page.locator('#app')).toBeHidden()
    await expect(page.locator('#pane-admin')).toBeHidden()
    await expect(slipDialog(page)).toBeHidden()
    await capturePaper(page, testInfo)

    // —— 回到屏媒，一切复原（证明隐藏确实由 print 媒体触发，而不是组件被拆掉）——
    await page.emulateMedia({ media: 'screen' })
    await expect(root(page)).toBeHidden()
    await expect(page.locator('aside')).toBeVisible()
  })

  test('纸质件金额逐项等于权威值，页脚是前端独立复算', async ({ page }) => {
    await stubPrint(page)
    await signIn(page, 'hr', '/payroll')
    await generate(page)
    await adminSlipButton(page, '陈思远').click()

    const sheet = root(page)
    await page.emulateMedia({ media: 'print' })
    await expect(sheet).toBeVisible()

    // 抬头三要素：月份 / 单据编号 / 渲染时间（时间戳是固定格式，不用 toLocaleString）
    await expect(sheet).toContainText(`发薪月份：${PAYROLL_MONTH}`)
    await expect(sheet).toContainText(/单据编号：PS-\d+-\d{4}-\d{2}/)
    await expect(sheet).toContainText(/渲染时间：\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/)

    // 身份与状态：草稿单也必须能出条，但纸质件要如实标注「草稿（尚未发放）」且发放时间留空
    await expect(sheet).toContainText('陈思远')
    await expect(sheet).toContainText(CHEN.empNo)
    await expect(sheet).toContainText('草稿（尚未发放）')
    // 草稿单没有发放时间，纸质件这一格必须是「—」而不是空白或当前时间
    await expect(paidCell(sheet)).toHaveText('—')

    // 应发 / 代扣 / 实发三段金额
    for (const v of [CHEN.base, CHEN.bonus, CHEN.overtime, CHEN.gross]) {
      await expect(sheet).toContainText(v)
    }
    await expect(sheet).toContainText(`-${CHEN.deduction}`)
    await expect(sheet).toContainText(`-${CHEN.social}`)
    await expect(sheet).toContainText(`-${CHEN.tax}`)
    await expect(sheet).toContainText(`-${CHEN.deductions}`)
    await expect(sheet).toContainText(CHEN.net)

    // 复算文案：21201.38 − 5404.84 = 15796.54，与记账实发一致
    const verify = sheet.locator('[data-testid="payslip-verify"]')
    await expect(verify).toHaveClass(/hrms-print-verify/)
    await expect(verify).toContainText('复算校验')
    await expect(verify).toContainText(CHEN.gross)
    await expect(verify).toContainText(CHEN.deductions)
    await expect(verify).toContainText(CHEN.net)
    await expect(verify).toContainText('一致')
  })

  test('点「打印 / 存为 PDF」确实调用打印，并刷新渲染时间', async ({ page }) => {
    await stubPrint(page)
    await signIn(page, 'hr', '/payroll')
    await generate(page)
    await adminSlipButton(page, '陈思远').click()

    expect(await printCalls(page)).toBe(0)
    const dialog = slipDialog(page)
    await dialog.getByRole('button', { name: '打印 / 存为 PDF' }).click()
    expect(await printCalls(page)).toBe(1)

    // 再次点击仍是同一份专版，不往 body 里堆第二份
    await dialog.getByRole('button', { name: '打印 / 存为 PDF' }).click()
    expect(await printCalls(page)).toBe(2)
    await expect(root(page)).toHaveCount(1)
  })

  test('关闭弹窗摘掉模式类：Ctrl+P 退化成打印正常页面', async ({ page }) => {
    await stubPrint(page)
    await signIn(page, 'hr', '/payroll')
    await generate(page)
    await adminSlipButton(page, '陈思远').click()
    await expect(page.locator('html.hrms-payslip-print-mode')).toHaveCount(1)

    // exact 是必需的：EP 的关闭叉号可访问名是「关闭此对话框」，包含匹配会命中两个按钮
    await slipDialog(page).getByRole('button', { name: '关闭', exact: true }).click()
    await expect(slipDialog(page)).toBeHidden()
    await expect(page.locator('html.hrms-payslip-print-mode')).toHaveCount(0)

    // 专版本身刻意留着（避免关闭动画期间正文先消失），但没有模式类时纸媒也打不出它
    await expect(root(page)).toHaveCount(1)
    await page.emulateMedia({ media: 'print' })
    await expect(root(page)).toBeHidden()
    await expect(page.locator('aside')).toBeVisible()
  })

  test('路由切换时组件卸载，模式类与专版一并清除', async ({ page }) => {
    await stubPrint(page)
    await signIn(page, 'hr', '/payroll')
    await generate(page)
    await adminSlipButton(page, '陈思远').click()
    await expect(page.locator('html.hrms-payslip-print-mode')).toHaveCount(1)

    // 弹窗遮罩盖住侧边栏，普通 click 会被拦截；dispatchEvent 直接命中 router-link，
    // 走的是真实 SPA 导航，因此能证明 onBeforeUnmount 兜底生效（而不是整页刷新顺手清掉）。
    await page.locator('aside nav a').filter({ hasText: '工作台概览' }).dispatchEvent('click')
    await expect(page).toHaveURL(/\/dashboard$/)
    await expect(page.locator('html.hrms-payslip-print-mode')).toHaveCount(0)
    await expect(root(page)).toHaveCount(0)
  })
})

test.describe('员工侧已发放工资条的纸质件', () => {
  test('PAID 单据标注已发放并带出发放时间', async ({ page, openRole }) => {
    await signIn(page, 'hr', '/payroll')
    await generate(page)
    await page.getByRole('button', { name: '一键全部发放' }).click()
    await page.locator('.el-message-box').getByRole('button', { name: '确定' }).click()
    await expect(toast(page, '批量发薪成功，共发放 5 笔')).toBeVisible()

    const emp = await openRole('emp01', '/payroll')
    const slipRow = emp.locator('#pane-my tr.el-table__row').filter({ hasText: PAYROLL_MONTH })
    await expect(slipRow).toHaveCount(1)
    await slipRow.getByRole('button', { name: '电子凭条' }).click()
    await expect(emp.locator('.el-dialog').filter({ hasText: '月度电子工资条明细' })).toBeVisible()
    await expect(emp.locator('html.hrms-payslip-print-mode')).toHaveCount(1)

    const sheet = root(emp)
    await emp.emulateMedia({ media: 'print' })
    await expect(sheet).toBeVisible()
    await expect(emp.locator('aside')).toBeHidden()
    await expect(sheet).toContainText('已发放')
    await expect(sheet).not.toContainText('草稿（尚未发放）')
    // 发放时间是发放动作写入的时间戳，纸质件这一格不能是「—」
    await expect(paidCell(sheet)).toHaveText(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/)
    await expect(sheet).toContainText(CHEN.net)
    await expect(sheet.locator('[data-testid="payslip-verify"]')).toContainText('一致')
  })
})
