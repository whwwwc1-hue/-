/**
 * P2.2 员工花名册批量导入（对接 P2.1 的 POST /api/v1/employees/import）。
 *
 * 断言全部压在「行为」而不是「提示语」上：
 *  - 预检是否真的不写库 —— 用「导入后回列表搜这个工号，一条都没有」证明；
 *  - 行号是否可信 —— 用「字段里带换行」的 CSV 证明。后端报的是物理行号，
 *    预览与报错必须同口径，否则用户照着提示去改数据会改错行；
 *  - BOM 必须剥掉 —— 否则第一列表头变成 `<BOM>工号`，连官方模板自己都导不进去。
 *
 * mock 侧契约镜像 employee_controller.cj 的 doEmployeeImport；
 * 前端发出的任何未被 mock 认领的请求都会被 fixtures 的 unmatched 闸门判红。
 */
import { writeFileSync } from 'node:fs'
import type { Page } from '@playwright/test'
import { expect, signIn, test, toast } from './support/fixtures'

const HEADER = '工号,姓名,性别,手机号,邮箱,身份证号,部门,岗位,基本薪资,年假余额,入职日期,合同到期日期,状态'

/**
 * 一条合法数据行。默认值全部落在真实存在的部门（技术研发中心）与合法日期上，
 * 只有被测的那一项是特意改坏的 —— 这样每条用例的失败原因都是唯一的。
 */
function row(
  empNo: string,
  over: Partial<{ name: string; dept: string; phone: string; hireDate: string; position: string }> = {}
): string {
  const o = { name: '测试员工', dept: '技术研发中心', phone: '13900009000', hireDate: '2026-03-02', position: '测试岗', ...over }
  return [
    empNo,
    o.name,
    '男',
    o.phone,
    `${empNo.toLowerCase()}@hrms.demo`,
    '110101199003031234',
    o.dept,
    o.position,
    '11000',
    '5',
    o.hireDate,
    '2029-03-01',
    '试用期'
  ].join(',')
}

const CSV_OK = `${HEADER}\r\n${row('EMP20269001')}\r\n${row('EMP20269002', { name: '李四' })}\r\n`
const CSV_DUP = `${HEADER}\r\n${row('EMP20269003')}\r\n${row('EMP20269003', { name: '王五' })}\r\n`

// 三行数据：第 1 行合法、第 2 行部门不存在、第 3 行手机号非数字。
// 故意让合法行排在最前，才能证明「有 1 行通过」和「整批仍不写库」是两件事。
const CSV_BAD =
  `${HEADER}\r\n` +
  `${row('EMP20269004')}\r\n` +
  `${row('EMP20269005', { name: '赵六', dept: '财务部' })}\r\n` +
  `${row('EMP20269006', { name: '孙七', phone: 'abc139', hireDate: '2026-03-04' })}\r\n`

// 岗位写成带引号的字段：内含逗号不能拆列，内含换行不能拆行
const CSV_QUOTES =
  `${HEADER}\r\n` +
  `${row('EMP20269010', { name: '张十', position: '"高级,资深\\n工程师"' })}\r\n` +
  `${row('EMP20269011', { name: '钱十一', dept: '不存在的部门' })}\r\n`

async function openImport(page: Page) {
  await page.getByRole('button', { name: '批量导入', exact: true }).click()
  await expect(page.getByText('员工花名册批量导入')).toBeVisible()
}

function pickFile(page: Page, path: string) {
  return page.locator('[data-testid="import-file"]').setInputFiles(path)
}

/** 回列表按工号搜索 —— 这是「到底写没写进库」的唯一硬证据。 */
async function searchEmpNo(page: Page, empNo: string) {
  await page.getByPlaceholder('搜索工号 / 姓名 / 手机号').fill(empNo)
  await page.getByRole('button', { name: '查询', exact: true }).click()
}

test.describe('员工花名册批量导入（HR）', () => {
  test.beforeEach(async ({ page }) => {
    await signIn(page, 'hr')
    await page.goto('/employee')
    await expect(page.getByRole('button', { name: '批量导入', exact: true })).toBeVisible()
  })

  test('下载模板：带 BOM，13 列表头逐字对齐后端 empImportHeader', async ({ page }) => {
    await openImport(page)
    const [download] = await Promise.all([
      page.waitForEvent('download'),
      page.getByRole('button', { name: '下载模板', exact: true }).click()
    ])
    expect(download.suggestedFilename()).toBe('员工花名册导入模板.csv')

    let text = ''
    const stream = await download.createReadStream()
    for await (const chunk of stream) text += Buffer.from(chunk as Uint8Array).toString('utf8')

    // BOM 是刻意的：Excel 双击打开无 BOM 的 UTF-8 CSV 会把中文表头显示成乱码，
    // 而这份台账恰恰就在 Excel 里编辑；后端 csvStripBom 会把这三个字节剥掉。
    expect(text.charCodeAt(0)).toBe(0xfeff)
    const lines = text.replace(/^\uFEFF/, '').split('\r\n')
    expect(lines[0]).toBe(HEADER)
    const cells = lines[1].split(',')
    expect(cells).toHaveLength(13)
    // 示例行的部门必须真实存在，否则用户照抄示例会立刻撞上「部门不存在」
    expect(cells[6]).toBe('技术研发中心')
  })

  test('选文件先预览；默认预检，预检不写库', async ({ page }, testInfo) => {
    const file = testInfo.outputPath('ok.csv')
    writeFileSync(file, CSV_OK, 'utf8')

    await openImport(page)
    await pickFile(page, file)

    await expect(page.getByText('· UTF-8 · 数据 2 行')).toBeVisible()
    await expect(page.getByText('数据预览（前 2 行')).toBeVisible()
    await expect(page.getByRole('cell', { name: 'EMP20269001', exact: true })).toBeVisible()

    await page.getByRole('button', { name: '开始校验', exact: true }).click()
    await toast(page, '预检通过：2 行可导入')
    const result = page.getByTestId('import-result')
    await expect(result).toContainText('预检结果')
    await expect(result).toContainText('实际写入 0')

    await page.getByRole('button', { name: '关闭', exact: true }).click()
    await searchEmpNo(page, 'EMP20269001')
    await expect(page.getByText('暂无数据')).toBeVisible()
  })

  test('取消预检后正式导入：新员工进花名册，可按工号检索', async ({ page }, testInfo) => {
    const file = testInfo.outputPath('persist.csv')
    writeFileSync(file, CSV_OK, 'utf8')

    await openImport(page)
    await pickFile(page, file)
    await page.getByText('仅校验不写库（预检）').click()
    await page.getByRole('button', { name: '开始导入', exact: true }).click()

    await toast(page, '导入完成：新增 2 名员工，登录账号已按工号开通')
    await expect(page.getByTestId('import-result')).toContainText('实际写入 2')

    await page.getByRole('button', { name: '关闭', exact: true }).click()
    await searchEmpNo(page, 'EMP20269002')
    await expect(page.getByRole('cell', { name: '李四' })).toBeVisible()
  })

  test('行级错误逐条回显，且整批一条都不写', async ({ page }, testInfo) => {
    const file = testInfo.outputPath('bad.csv')
    writeFileSync(file, CSV_BAD, 'utf8')

    await openImport(page)
    await pickFile(page, file)
    await page.getByText('仅校验不写库（预检）').click()
    await page.getByRole('button', { name: '开始导入', exact: true }).click()

    const failures = page.getByTestId('import-failures')
    await expect(failures).toBeVisible()
    await expect(failures).toContainText('部门「财务部」不存在')
    await expect(failures).toContainText('手机号只能由数字组成')
    await expect(page.getByTestId('import-result')).toContainText('通过 1')
    await expect(page.getByTestId('import-result')).toContainText('实际写入 0')

    await page.getByRole('button', { name: '关闭', exact: true }).click()
    // 第 2 行本身合法，但后端是整批事务：有任何失败就一条都不写
    await searchEmpNo(page, 'EMP20269004')
    await expect(page.getByText('暂无数据')).toBeVisible()
  })

  test('文件内工号重复：第二条报重复，而不是静默覆盖', async ({ page }, testInfo) => {
    const file = testInfo.outputPath('dup.csv')
    writeFileSync(file, CSV_DUP, 'utf8')

    await openImport(page)
    await pickFile(page, file)
    await page.getByRole('button', { name: '开始校验', exact: true }).click()
    await expect(page.getByTestId('import-failures')).toContainText('工号 EMP20269003 在本次文件内重复')
  })

  test('官方模板带 BOM 也认表头，不弹表头告警', async ({ page }, testInfo) => {
    const file = testInfo.outputPath('bom.csv')
    writeFileSync(file, `\uFEFF${CSV_OK}`, 'utf8')

    await openImport(page)
    await pickFile(page, file)
    await expect(page.getByText('表头与模板不完全一致')).toHaveCount(0)
    await expect(page.getByRole('button', { name: '开始校验', exact: true })).toBeEnabled()
    await page.getByRole('button', { name: '开始校验', exact: true }).click()
    await toast(page, '预检通过：2 行可导入')
  })

  test('引号内逗号不拆列、换行不拆行；报错行号是物理行号', async ({ page }, testInfo) => {
    const file = testInfo.outputPath('quote.csv')
    writeFileSync(file, CSV_QUOTES.replace('\\n', '\n'), 'utf8')

    await openImport(page)
    await pickFile(page, file)
    await page.getByText('仅校验不写库（预检）').click()
    await page.getByRole('button', { name: '开始导入', exact: true }).click()

    const failures = page.getByTestId('import-failures')
    await expect(failures).toContainText('部门「不存在的部门」不存在')
    // 表头占第 1 行，引号行占第 2~3 行，出错的那条在第 4 行。
    // 按下标 +1 报行号的实现会指到第 3 行，用户就永远改不对。
    await expect(failures.getByRole('cell', { name: '4', exact: true })).toBeVisible()
    // 引号内的逗号没有把 13 列撑成 14 列，否则会报「必填列缺失」而不是部门错误
    await expect(failures).not.toContainText('不能为空')
  })
})

test.describe('批量导入入口的角色隔离', () => {
  test('MANAGER 能看花名册，但看不到批量导入', async ({ page }) => {
    await signIn(page, 'manager')
    await page.goto('/employee')
    await expect(page.getByRole('button', { name: '查询', exact: true })).toBeVisible()
    await expect(page.getByRole('button', { name: '批量导入', exact: true })).toHaveCount(0)
  })

  test('EMPLOYEE 直达 /employee 被守卫拦下，不会漏出入口', async ({ page }) => {
    await signIn(page, 'emp01')
    await page.goto('/employee')
    await expect(page.getByRole('button', { name: '批量导入', exact: true })).toHaveCount(0)
  })
})
