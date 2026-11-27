/**
 * P4.1「培训与学分」端到端（/training，培训计划 / 可报名 / 我的培训 / 学分统计）。
 *
 * 契约要点（mock-server.ts 逐条镜像 training_controller.cj）：
 *   管理端 = GET|POST /api/v1/trainings、PUT /api/v1/trainings/{id}（状态机）、
 *            GET|POST /api/v1/trainings/{id}/records（花名册 / 录入结果）
 *   员工端 = GET /api/v1/trainings/available、GET /api/v1/trainings/my、
 *            POST|DELETE /api/v1/trainings/{id}/signup、POST /api/v1/trainings/{id}/checkin
 *   统计端 = GET /api/v1/trainings/stats
 *
 * 定位约定：el-tabs 切走的面板只是隐藏、DOM 仍在页面里，所以所有表格/卡片都要先圈进
 * `.el-tab-pane:visible`，否则会命中上一个面板的同名元素。
 *
 * 请求断言用 `mock.waitForCall()`：同一个接口一屏内常被打多次（首屏、点查询、写操作后重拉），
 * 所以约定「先 await 掉首屏那条，再把下一次 waitForCall 建在点击之前」，避免拿错请求。
 */
import { test, expect, signIn, toast, confirmBox, REAL_BACKEND } from './support/fixtures'
import type { Locator, Page } from 'playwright'

/**
 * 本文件的数值与请求断言全部钉在 init.sql 的 P4.1 种子 + mock 内存态上，
 * 而新建/发布/结课/录入都是不可逆写操作，真实库跑第二条用例就会被第一条改脏，
 * 因此 E2E_REAL=1 时整组跳过（与 payroll / notification 的做法一致）。
 */
test.skip(REAL_BACKEND, '培训用例依赖 mock 种子与写操作状态机，真实库会被前一条用例改脏')

/** sql/init.sql 的 P4.1 种子课 id（mock 与真库一致） */
const C_DEV = 1
const C_ALL = 2
const C_DONE = 3
const C_DRAFT = 4
/** 主题按种子原文，只取足够唯一的前缀 */
const T_DEV = '仓颉语言工程实践'
const T_ALL = '信息安全与合规必修'
const T_DONE = '高效绩效面谈技巧'
const T_DRAFT = '新员工入职引导'

/** 当前可见的 tab 面板 */
const pane = (page: Page): Locator => page.locator('.el-tab-pane:visible')

/** 表格行按主题文本定位（主题唯一，比 nth 稳） */
const row = (page: Page, text: string): Locator => pane(page).locator('.el-table__row').filter({ hasText: text })

/** 单元格（nth 从 0 数起，与列顺序一致） */
const cell = (r: Locator, i: number): Locator => r.locator('td').nth(i)

/** 行内按钮：exact 防止「报名」命中「取消报名」 */
const btn = (scope: Locator, name: string): Locator => scope.getByRole('button', { name, exact: true })

/** 统计卡片的数值 = 标签 div 的兄弟 div */
const statValue = (scope: Locator, label: string): Locator =>
  scope.locator('div.text-xs', { hasText: new RegExp(`^${label}$`) }).locator('xpath=following-sibling::div[1]')

/** 与 mock-server 同口径：目标日 = 本地时区当天 + n 天（el-date-picker 的 value-format 前缀） */
function localDate(offsetDays: number): string {
  const d = new Date(Date.now() + offsetDays * 86400000)
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
}

const TIME_RE = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/

test.describe('培训计划（HR 管理视角）', () => {
  test('默认落在「培训计划」，操作列严格由状态驱动', async ({ page, mock }) => {
    await signIn(page, 'hr', '/training')
    await mock.waitForCall('GET', '/api/v1/trainings')
    // 管理角色看到 4 个 tab，落点是培训计划
    await expect(page.locator('.el-tabs__item')).toHaveText(['培训计划', '可报名培训', '我的培训', '学分统计'])
    await expect(page.locator('.el-tabs__item.is-active')).toHaveText('培训计划')
    await expect(pane(page).locator('.el-table__header-wrapper th .cell')).toHaveText([
      '主题',
      '类别',
      '讲师',
      '适用部门',
      '开课时间',
      '结课时间',
      '学分',
      '报名',
      '状态',
      '操作'
    ])
    await expect(pane(page).locator('.el-table__row')).toHaveCount(4)

    // DRAFT：只有编辑 + 发布（还没人可管，不给花名册）
    const draft = row(page, T_DRAFT)
    await expect(cell(draft, 8)).toHaveText('草稿')
    await expect(cell(draft, 7)).toHaveText('0/50')
    await expect(draft.getByRole('button')).toHaveCount(2)
    await expect(btn(draft, '发布')).toBeVisible()
    await expect(btn(draft, '花名册')).toHaveCount(0)

    // PUBLISHED：编辑 + 花名册 + 结课 + 取消
    const pub = row(page, T_DEV)
    await expect(pub.getByRole('button')).toHaveCount(4)
    await expect(cell(pub, 3)).toHaveText('技术研发中心')
    await expect(cell(pub, 6)).toHaveText('2')
    await expect(cell(pub, 7)).toHaveText('0/30')
    await expect(cell(pub, 8)).toHaveText('已发布')

    // DONE：终态只剩花名册，报名数来自种子记录（3 人）
    const done = row(page, T_DONE)
    await expect(done.getByRole('button')).toHaveCount(1)
    await expect(btn(done, '花名册')).toBeVisible()
    await expect(cell(done, 6)).toHaveText('1.5')
    await expect(cell(done, 7)).toHaveText('3/20')
    await expect(cell(done, 8)).toHaveText('已结课')
  })

  test('筛选走后端参数：查询带 keyword，重置把参数清掉', async ({ page, mock }) => {
    await signIn(page, 'hr', '/training')
    const first = await mock.waitForCall('GET', '/api/v1/trainings')
    // 首屏三个筛选项都是空值，前端用 `|| undefined` 直接不发送参数
    expect(first.query.get('keyword')).toBeNull()

    await page.getByPlaceholder('搜索主题 / 讲师 / 地点').fill('李泽宇')
    const req = mock.waitForCall('GET', '/api/v1/trainings')
    await btn(pane(page), '查询').click()
    expect((await req).query.get('keyword')).toBe('李泽宇')
    await expect(pane(page).locator('.el-table__row')).toHaveCount(1)
    await expect(row(page, T_DEV)).toBeVisible()

    const req2 = mock.waitForCall('GET', '/api/v1/trainings')
    await btn(pane(page), '重置').click()
    expect((await req2).query.get('keyword')).toBeNull()
    await expect(pane(page).locator('.el-table__row')).toHaveCount(4)

    // 状态下拉同理：只拉草稿
    const req3 = mock.waitForCall('GET', '/api/v1/trainings')
    await page.locator('.el-select').first().click()
    await page.locator('.el-select-dropdown__item').filter({ hasText: '草稿' }).click()
    expect((await req3).query.get('status')).toBe('DRAFT')
    await expect(pane(page).locator('.el-table__row')).toHaveCount(1)
  })

  test('新建培训：必填校验在前端，POST body 字段与时间格式交给后端', async ({ page, mock }) => {
    await signIn(page, 'hr', '/training')
    await page.getByRole('button', { name: '新建培训' }).click()
    const dlg = page.locator('.el-dialog').filter({ hasText: '新建培训计划' })
    await expect(dlg).toBeVisible()
    const posts = () => mock.calls.filter((c) => c.method === 'POST' && c.path === '/api/v1/trainings').length
    const before = posts()
    await btn(dlg, '保存').click()
    await expect(dlg.getByText('请填写培训主题')).toBeVisible()
    await expect(dlg.getByText('请填写讲师姓名')).toBeVisible()
    expect(posts()).toBe(before) // 校验没过就不该发请求

    await dlg.getByPlaceholder('如：仓颉语言实战训练营').fill('E2E 影子值班制度宣贯')
    await dlg.getByPlaceholder('讲师姓名').fill('赵晨')
    await dlg.getByPlaceholder('培训室 / 线上会议链接').fill('总部 4F 会议室')
    await dlg.getByPlaceholder('选择开课时间').fill(`${localDate(9)} 14:00:00`)
    await page.keyboard.press('Enter')
    await dlg.getByPlaceholder('选择结课时间').fill(`${localDate(9)} 16:30:00`)
    await page.keyboard.press('Enter')

    const req = mock.waitForCall('POST', '/api/v1/trainings')
    await btn(dlg, '保存').click()
    const call = await req
    expect(call.status).toBe(200)
    expect(call.body.title).toBe('E2E 影子值班制度宣贯')
    expect(call.body.trainer).toBe('赵晨')
    expect(call.body.category).toBe('INTERNAL')
    expect(call.body.deptId).toBe(0) // 适用部门默认「全员培训」
    expect(call.body.location).toBe('总部 4F 会议室')
    expect(call.body.capacity).toBe(0) // 名额默认 0 = 不限
    expect(call.body.credit).toBe(1)
    // 时间必须是后端 DATETIME 认的 value-format，而不是 Date.toString 或 ISO 带 T
    expect(String(call.body.startTime)).toMatch(TIME_RE)
    expect(String(call.body.endTime)).toMatch(TIME_RE)
    expect(call.body.status).toBeUndefined() // 新建只能是草稿，发布是另一条流转

    await expect(toast(page, '培训计划已创建')).toBeVisible()
    await expect(dlg).toBeHidden()
    const created = row(page, 'E2E 影子值班制度宣贯')
    await expect(cell(created, 3)).toHaveText('全员')
    await expect(cell(created, 6)).toHaveText('1')
    await expect(cell(created, 7)).toHaveText('0/不限')
    await expect(cell(created, 8)).toHaveText('草稿')
    await expect(created.getByRole('button')).toHaveCount(2)
  })

  test('发布草稿：先「再想想」不发请求，确认后 PUT 回填完整内容', async ({ page, mock }) => {
    await signIn(page, 'hr', '/training')
    const draft = row(page, T_DRAFT)
    await btn(draft, '发布').click()
    const box = confirmBox(page, '发布确认')
    await expect(box).toBeVisible()
    await expect(box).toContainText('确认发布「新员工入职引导（草稿）」吗')
    await box.getByRole('button', { name: '再想想' }).click()
    await expect(box).toBeHidden()
    expect(mock.calls.some((c) => c.method === 'PUT')).toBe(false)

    const req = mock.waitForCall('PUT', `/api/v1/trainings/${C_DRAFT}`)
    await btn(draft, '发布').click()
    await confirmBox(page, '发布确认').getByRole('button', { name: '确认' }).click()
    const call = await req
    expect(call.status).toBe(200)
    // handleTrainingUpdate 先跑表单校验：只传 {status} 会被「培训主题必填」挡下，
    // 所以视图必须回填原内容，这里断的就是回填成功（不是只推进状态）。
    expect(call.body.title).toBeTruthy()
    expect(String(call.body.title)).toBe('新员工入职引导（草稿）')
    expect(String(call.body.trainer)).toBe('王静')
    expect(String(call.body.startTime)).toMatch(TIME_RE)
    expect(String(call.body.endTime)).toMatch(TIME_RE)
    expect(call.body.status).toBe('PUBLISHED')
    expect(call.body.credit).toBe(1)

    await expect(toast(page, '已发布')).toBeVisible()
    await expect(cell(draft, 8)).toHaveText('已发布')
    await expect(draft.getByRole('button')).toHaveCount(4) // 发布后操作列换成 编辑/花名册/结课/取消
  })

  test('结课：状态机推到 DONE 后只剩花名册，员工端可报名列表不再出现该课', async ({ page, mock }) => {
    await signIn(page, 'hr', '/training')
    const pub = row(page, T_ALL)
    await expect(cell(pub, 7)).toHaveText('0/不限')
    const req = mock.waitForCall('PUT', `/api/v1/trainings/${C_ALL}`)
    await btn(pub, '结课').click()
    await confirmBox(page, '结课确认').getByRole('button', { name: '确认' }).click()
    const call = await req
    expect(call.status).toBe(200)
    expect(call.body.status).toBe('DONE')
    await expect(toast(page, '已结课')).toBeVisible()
    await expect(cell(pub, 8)).toHaveText('已结课')
    await expect(pub.getByRole('button')).toHaveCount(1)
    // 终态不可回退：mock 按后端话术挡下 DONE → PUBLISHED
    await expect(pub.getByRole('button', { name: '发布' })).toHaveCount(0)

    // invalidateTabs 把可报名面板打脏，但 onMounted 只加载当前 tab，所以这条请求只在切过去后才发；
    // 王静在人力资源部，原本唯一可见的就是这门全员课 → 结课后列表应为空
    const offers = mock.waitForCall('GET', '/api/v1/trainings/available')
    await page.getByRole('tab', { name: '可报名培训' }).click()
    const offerCall = await offers
    expect(offerCall.status).toBe(200)
    expect(offerCall.data.list ?? []).toEqual([])
    await expect(pane(page).getByText('暂无可报名的培训')).toBeVisible()
    await expect(pane(page).locator('.el-table__row')).toHaveCount(0)
  })
})

test.describe('员工自助（emp01 / manager）', () => {
  test('员工看不到「培训计划」「学分统计」，默认落在可报名培训', async ({ page, mock }) => {
    await signIn(page, 'emp01', '/training')
    await mock.waitForCall('GET', '/api/v1/trainings/available')
    await expect(page.locator('.el-tabs__item')).toHaveText(['可报名培训', '我的培训'])
    await expect(page.locator('.el-tabs__item.is-active')).toHaveText('可报名培训')
    await expect(page.getByText('培训计划')).toHaveCount(0)
    await expect(page.getByText('学分统计')).toHaveCount(0)
    await expect(page.getByRole('button', { name: '新建培训' })).toHaveCount(0)
    // 员工端连培训计划列表都不该请求
    expect(mock.calls.some((c) => c.path === '/api/v1/trainings')).toBe(false)
  })

  test('不可报名的行：不给报名按钮，改为展示后端 blockReason 原文', async ({ page, mock }) => {
    // 把研发专属课的 30 个名额占满 → 后端 capacityLeft=0、blockReason 走「名额已满」分支
    mock.fillTrainingSeats(C_DEV, 30)
    await signIn(page, 'emp01', '/training')
    const full = row(page, T_DEV)
    await expect(cell(full, 6)).toHaveText('0')
    await expect(btn(full, '报名')).toHaveCount(0)
    await expect(full.getByText('该培训名额已满，如需加位请联系 HR')).toBeVisible()
    await expect(cell(full, 7)).toHaveText('未报名')

    // 全员必修 capacity=0 → 剩余名额渲染成「不限」，且没有 blockReason（按钮照常给）
    const unlimited = row(page, T_ALL)
    await expect(cell(unlimited, 6)).toHaveText('不限')
    await expect(unlimited.getByText('名额已满')).toHaveCount(0)
    await expect(btn(unlimited, '报名')).toBeVisible()
    await expect(cell(unlimited, 7)).toHaveText('未报名')

    // 汇总卡片：陈思远只有第 3 课一条已出勤记录（55 分 → 不合格 → 0 学分、2 学时）
    await expect(statValue(pane(page), '累计学分')).toHaveText('0')
    await expect(statValue(pane(page), '已报名')).toHaveText('1')
    await expect(statValue(pane(page), '已出勤')).toHaveText('1')
    await expect(statValue(pane(page), '累计学时')).toHaveText('2 h')
  })

  test('报名：命中 POST signup，行状态、剩余名额、按钮三处同时翻转', async ({ page, mock }) => {
    await signIn(page, 'emp01', '/training')
    const dev = row(page, T_DEV)
    await expect(cell(dev, 6)).toHaveText('30')
    const req = mock.waitForCall('POST', `/api/v1/trainings/${C_DEV}/signup`)
    await btn(dev, '报名').click()
    const call = await req
    expect(call.status).toBe(200)
    // 前端只发一个空体：名额与状态一律由服务端算，绝不允许前端自己报数
    expect(call.body).toEqual({})
    expect(call.data.trainingId).toBe(C_DEV)
    expect(call.data.status).toBe('REGISTERED')
    expect(call.data.capacityLeft).toBe(29) // 占位之后的真实余量
    await expect(toast(page, '报名成功，剩余名额 29')).toBeVisible()
    await expect(cell(dev, 6)).toHaveText('29')
    await expect(cell(dev, 7)).toHaveText('已报名')
    await expect(btn(dev, '报名')).toHaveCount(0)
    await expect(btn(dev, '取消报名')).toBeVisible()
    await expect(dev.getByText('你已报名该培训')).toBeVisible()
    await expect(statValue(pane(page), '已报名')).toHaveText('2')
  })

  test('取消报名：「保留」不改状态，「确认取消」释放名额', async ({ page, mock }) => {
    await signIn(page, 'emp01', '/training')
    const dev = row(page, T_DEV)
    const signup = mock.waitForCall('POST', `/api/v1/trainings/${C_DEV}/signup`)
    await btn(dev, '报名').click()
    await signup
    await expect(cell(dev, 6)).toHaveText('29')

    await btn(dev, '取消报名').click()
    const box = confirmBox(page, '取消报名确认')
    await expect(box).toContainText('确认取消报名「仓颉语言工程实践：从并发到数据访问层」吗')
    await box.getByRole('button', { name: '保留' }).click()
    await expect(box).toBeHidden()
    expect(mock.calls.some((c) => c.method === 'DELETE')).toBe(false)
    await expect(cell(dev, 7)).toHaveText('已报名')

    const del = mock.waitForCall('DELETE', `/api/v1/trainings/${C_DEV}/signup`)
    await btn(dev, '取消报名').click()
    await confirmBox(page, '取消报名确认').getByRole('button', { name: '确认取消' }).click()
    const call = await del
    expect(call.status).toBe(200)
    expect(call.data.trainingId).toBe(C_DEV)
    expect(call.data.status).toBe('CANCELLED')
    await expect(toast(page, '已取消报名')).toBeVisible()
    await expect(cell(dev, 6)).toHaveText('30') // 取消不占名额
    await expect(cell(dev, 7)).toHaveText('已取消')
    await expect(btn(dev, '报名')).toBeVisible() // 开课前可以重新报名
  })

  test('我的培训：未考核行的考核分是「—」，已考核行是分数与折算学分', async ({ page, mock }) => {
    await signIn(page, 'emp01', '/training')
    // 先报一门，制造一行 score = null 的「已报名」记录（0 分与未考核是两种语义）
    const signup = mock.waitForCall('POST', `/api/v1/trainings/${C_DEV}/signup`)
    await btn(row(page, T_DEV), '报名').click()
    await signup
    const list = mock.waitForCall('GET', '/api/v1/trainings/my')
    await page.getByRole('tab', { name: '我的培训' }).click()
    await list
    await expect(pane(page).locator('.el-table__row')).toHaveCount(2)

    const enrolled = row(page, T_DEV)
    await expect(cell(enrolled, 4)).toHaveText('—') // 考核分：null ≠ 0
    await expect(cell(enrolled, 7)).toHaveText('—') // 签到时间
    await expect(cell(enrolled, 6)).toHaveText('已报名')
    await expect(cell(enrolled, 5)).toHaveText('0 / 2') // 折算 0 分，课程满分 2 分
    await expect(cell(enrolled, 3)).toContainText(localDate(3)) // 开课时间跟着课程走

    const graded = row(page, T_DONE)
    await expect(cell(graded, 4)).toHaveText('55') // 已考核且不及格，必须显示分数而不是 —
    await expect(cell(graded, 5)).toHaveText('0 / 1.5')
    await expect(cell(graded, 6)).toHaveText('已出勤')
    await expect(cell(graded, 7)).toContainText(localDate(-10))

    await expect(statValue(pane(page), '累计学分')).toHaveText('0')
    await expect(statValue(pane(page), '已报名')).toHaveText('2')
    await expect(statValue(pane(page), '已出勤')).toHaveText('1')
  })

  test('零报名员工看到空态文案', async ({ page, mock }) => {
    // manager = 李泽宇（研发总监），种子里没有他的报名记录
    await signIn(page, 'manager', '/training')
    await mock.waitForCall('GET', '/api/v1/trainings/available')
    await expect(page.locator('.el-tabs__item')).toHaveText(['可报名培训', '我的培训'])
    await page.getByRole('tab', { name: '我的培训' }).click()
    await mock.waitForCall('GET', '/api/v1/trainings/my')
    await expect(pane(page).getByText('你还没有报名任何培训')).toBeVisible()
    await expect(statValue(pane(page), '已报名')).toHaveText('0')
  })
})

test.describe('学分统计与花名册（HR）', () => {
  test('学分统计：概览卡片与两张表的数字来自同一批种子记录', async ({ page, mock }) => {
    await signIn(page, 'hr', '/training')
    await page.getByRole('tab', { name: '学分统计' }).click()
    const req = await mock.waitForCall('GET', '/api/v1/trainings/stats')
    expect(req.status).toBe(200)
    const active = pane(page)
    await expect(statValue(active, '培训总数')).toHaveText('4')
    await expect(statValue(active, '已发布')).toHaveText('2')
    await expect(statValue(active, '累计学时')).toHaveText('9 h') // 已发布 + 已结课：5h + 2h + 2h
    await expect(statValue(active, '平均分')).toHaveText('71.5') // (88 + 55) / 2
    await expect(statValue(active, '覆盖人数')).toHaveText('2 人') // 后端只认 ATTENDED/REGISTERED，缺席的林小满不计入

    const tables = active.locator('.el-table')
    const rank = tables.nth(0)
    await expect(rank.locator('.el-table__header-wrapper th .cell')).toHaveText(['排名', '姓名', '部门', '学分'])
    await expect(rank.locator('.el-table__row')).toHaveCount(3)
    const first = rank.locator('.el-table__row').nth(0)
    await expect(cell(first, 0)).toHaveText('1')
    await expect(cell(first, 1)).toHaveText('王静')
    await expect(cell(first, 2)).toHaveText('人力资源部')
    await expect(cell(first, 3)).toHaveText('1.5') // 88 分 >= 80 → 全额学分
    await expect(cell(rank.locator('.el-table__row').nth(1), 1)).toHaveText('陈思远')
    await expect(cell(rank.locator('.el-table__row').nth(1), 3)).toHaveText('0') // 55 分不及格
    await expect(cell(rank.locator('.el-table__row').nth(2), 1)).toHaveText('林小满')

    const course = tables.nth(1)
    await expect(course.locator('.el-table__header-wrapper th .cell')).toHaveText([
      '主题',
      '平均分',
      '报名',
      '出勤',
      '学分合计'
    ])
    await expect(course.locator('.el-table__row')).toHaveCount(1) // 只有已结课那门课有报名记录
    const c0 = course.locator('.el-table__row').nth(0)
    await expect(c0).toContainText(T_DONE)
    await expect(cell(c0, 1)).toHaveText('71.5')
    await expect(cell(c0, 2)).toHaveText('3')
    await expect(cell(c0, 3)).toHaveText('2')
    await expect(cell(c0, 4)).toHaveText('1.5')
  })

  test('花名册录入结果：POST body 与折算学分一致，行内容即时更新', async ({ page, mock }) => {
    await signIn(page, 'hr', '/training')
    await btn(row(page, T_DONE), '花名册').click()
    await mock.waitForCall('GET', `/api/v1/trainings/${C_DONE}/records`)
    const roster = page.locator('.el-dialog').filter({ hasText: '培训花名册 · 高效绩效面谈技巧' })
    await expect(roster).toBeVisible()
    await expect(roster.getByText('名册共 3 人')).toBeVisible()
    await expect(roster.locator('.el-table__row')).toHaveCount(3)
    // 排序跟着后端 FIELD(status,...)：已报名 → 已出勤 → 已缺席 → 已取消，种子没有报名行，所以出勤在前
    await expect(roster.locator('.el-table__row').nth(0)).toContainText('王静')

    const lin = roster.locator('.el-table__row').filter({ hasText: '林小满' })
    await expect(cell(lin, 3)).toHaveText('已缺席')
    await expect(cell(lin, 5)).toHaveText('—') // 缺席行 score 是 null，不是 0
    await expect(cell(lin, 1)).toHaveText('EMP20260005')

    await btn(lin, '录入结果').click()
    const form = page.locator('.el-dialog').filter({ hasText: '录入培训结果 · 林小满' })
    await expect(form).toBeVisible()
    await expect(form.getByPlaceholder('如：缺席原因 / 补录说明')).toHaveValue('入职当周未参加')
    await form.locator('.el-switch').click() // 是否出勤：关 → 开
    const score = form.locator('.el-form-item').filter({ hasText: '考核得分' }).locator('input')
    await score.fill('92')
    await score.press('Enter') // el-input-number 靠 change/blur 提交 modelValue
    const req = mock.waitForCall('POST', `/api/v1/trainings/${C_DONE}/records`)
    await btn(form, '保存结果').click()
    const call = await req
    expect(call.status).toBe(200)
    expect(call.body.employeeId).toBe(5)
    expect(call.body.attended).toBe(true)
    expect(call.body.score).toBe(92)
    expect(call.body.remark).toBe('入职当周未参加') // 打开时回填了名册里的原备注
    await expect(toast(page, '已记录出勤，本次折算学分 1.5')).toBeVisible()
    await expect(form).toBeHidden()
    await expect(cell(lin, 3)).toHaveText('已出勤')
    await expect(cell(lin, 5)).toHaveText('92')
    await expect(cell(lin, 6)).toHaveText('1.5')

    // 名册改动同样打脏统计页，切过去重新拉。必须先关掉仍挡着页面的花名册弹窗。
    await roster.locator('.el-dialog__headerbtn').click()
    await expect(roster).toBeHidden()
    await page.getByRole('tab', { name: '学分统计' }).click()
    await mock.waitForCall('GET', '/api/v1/trainings/stats')
    await expect(statValue(pane(page), '覆盖人数')).toHaveText('3 人') // 补录出勤后林小满被计入
  })
})
