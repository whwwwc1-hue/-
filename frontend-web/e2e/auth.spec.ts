/**
 * P1.3（一）认证链路：表单校验、错误口令、一键填充、路由守卫、画像恢复、
 * Token 失效、滑动续期、退出登录、修改密码。
 *
 * 设计约定（改这个文件前先读）：
 * - 一律走真实 UI 完成登录，不用 addInitScript 塞 localStorage：
 *   那样会跳过登录页与 router.beforeEach 的 refreshProfile 分支，等于没测。
 * - 需要「前端拦住了、没发请求」的负向断言，用 trackApi() 监听浏览器侧请求，
 *   而不是去 mock 里加日志——mock 只负责给数据，不承担断言职责。
 * - toast 只在「触发动作的紧后一步」断言：element-plus 的消息条 3 秒自毁。
 */
import type { Page } from '@playwright/test'
import { DEMO_PASSWORD } from './support/env'
import { expect, REAL_BACKEND, signIn, test, toast } from './support/fixtures'

/** 收集浏览器发出的 /api/v1 请求，用于「本应零请求」的断言。 */
function trackApi(page: Page): string[] {
  const calls: string[] = []
  page.on('request', (req) => {
    if (req.url().includes('/api/v1/')) calls.push(`${req.method()} ${new URL(req.url()).pathname}`)
  })
  return calls
}

/** 打开顶栏用户下拉（trigger=click，菜单 teleport 到 body）。 */
async function openUserDropdown(page: Page): Promise<void> {
  await page.locator('header').getByText('陈思远', { exact: true }).click()
  await expect(page.locator('.el-dropdown-menu__item').filter({ hasText: '退出登录' })).toBeVisible()
}

test.describe('登录页', () => {
  test('空表单提交被前端校验拦截，一条请求都不发', async ({ page, mock }) => {
    void mock
    const calls = trackApi(page)
    await page.goto('/login')
    await page.getByRole('button', { name: '立即登录' }).click()

    await expect(page.locator('.el-form-item__error')).toHaveText(['请输入用户名', '请输入密码'])
    await expect(page).toHaveURL(/\/login$/)
    expect(calls).toEqual([])
  })

  test('口令错误时原样透出后端文案，停留在登录页且不留 token', async ({ page, mock }) => {
    void mock
    await page.goto('/login')
    await page.getByPlaceholder('请输入用户名').fill('emp01')
    await page.getByPlaceholder('请输入密码').fill('wrong-pass')
    await page.getByRole('button', { name: '立即登录' }).click()

    // 5 次机会里的第 1 次失败 → 剩余 4 次，这个计数由 mock 侧维护，可稳定断言
    await expect(toast(page, '账号或密码错误（剩余尝试 4 次）')).toBeVisible()
    await expect(page).toHaveURL(/\/login$/)
    expect(await page.evaluate(() => localStorage.getItem('hrms_token'))).toBeNull()
  })

  test('测试账号一键填充：点「部门经理」自动带上 manager / 123456 并登录成功', async ({ page, mock }) => {
    void mock
    await page.goto('/login')
    await page.getByRole('button', { name: '部门经理' }).click()
    await expect(page.getByPlaceholder('请输入用户名')).toHaveValue('manager')
    await expect(page.getByPlaceholder('请输入密码')).toHaveValue(DEMO_PASSWORD)

    await page.getByRole('button', { name: '立即登录' }).click()
    await expect(toast(page, '欢迎回来，李泽宇')).toBeVisible()
    await expect(page).toHaveURL(/\/dashboard$/)
    await expect(page.locator('header .el-tag')).toHaveText('部门经理 MANAGER')
  })
})

test.describe('路由守卫', () => {
  test('未登录直达业务路由 → 弹回登录页', async ({ page, mock }) => {
    void mock
    const calls = trackApi(page)
    await page.goto('/attendance')
    await expect(page).toHaveURL(/\/login$/)
    // 守卫在组件挂载前就重定向，因此不该有任何受保护接口的请求
    expect(calls).toEqual([])
  })

  test('已登录再访问 /login → 直接回工作台', async ({ page, mock }) => {
    void mock
    await signIn(page, 'emp01')
    await page.goto('/login')
    await expect(page).toHaveURL(/\/dashboard$/)
  })

  test('token 健在但画像丢失：守卫自动调 /auth/me 恢复，余额随画像回来', async ({ page, mock }) => {
    void mock
    await signIn(page, 'emp01')
    await page.evaluate(() => localStorage.removeItem('hrms_user'))

    const me = page.waitForResponse('**/api/v1/auth/me')
    await page.reload()
    expect((await me).status()).toBe(200)

    await expect(page.locator('header')).toContainText('陈思远')
    const profile = await page.evaluate(() => JSON.parse(localStorage.getItem('hrms_user') ?? '{}'))
    expect(profile).toMatchObject({ username: 'emp01', name: '陈思远', role: 'EMPLOYEE', annualLeaveBalance: 5 })
  })

  test('服务端作废 token 后：401 触发拦截器清鉴权并回到登录页', async ({ page, mock }) => {
    test.skip(REAL_BACKEND, '需要 mock 主动作废已签发 token')
    await signIn(page, 'emp01')
    mock.invalidateTokens()
    await page.reload()

    // 刻意不断言 401 的 toast：clearAuthAndRedirect 用 location.href 整页跳转，
    // DOM 连同消息条会被立刻销毁，断言它只会带来偶发假红。
    await expect(page).toHaveURL(/\/login$/)
    const keys = await page.evaluate(() => [localStorage.getItem('hrms_token'), localStorage.getItem('hrms_user')])
    expect(keys).toEqual([null, null])
  })

  test('响应头 X-Renewed-Token 被拦截器写回 localStorage（滑动续期）', async ({ page, mock }) => {
    test.skip(REAL_BACKEND, '需要 mock 主动下发新 token')
    const renewed = 'mock-jwt-renewed-by-e2e'
    await signIn(page, 'emp01')
    mock.enableRenewToken(renewed)
    await page.evaluate(() => localStorage.removeItem('hrms_user'))
    await page.reload()

    // 读 localStorage 而不是 store：store 里的 token ref 只在初始化时取值，续签后必然滞后，
    // 而请求拦截器每次现读 localStorage，所以 localStorage 才是这个分支的真相。
    await expect
      .poll(async () => page.evaluate(() => localStorage.getItem('hrms_token')), { timeout: 8000 })
      .toBe(renewed)
    await expect(page).toHaveURL(/\/dashboard$/)
  })
})

test.describe('顶栏用户菜单', () => {
  test('退出登录清空 token 与画像并回到登录页', async ({ page, mock }) => {
    void mock
    await signIn(page, 'emp01')
    await openUserDropdown(page)
    await page.locator('.el-dropdown-menu__item').filter({ hasText: '退出登录' }).click()

    await expect(page).toHaveURL(/\/login$/)
    const keys = await page.evaluate(() => [localStorage.getItem('hrms_token'), localStorage.getItem('hrms_user')])
    expect(keys).toEqual([null, null])
    await expect(page.getByPlaceholder('请输入用户名')).toBeVisible()
  })

  test('修改密码：两条前端校验先拦住，真提交成功后弹窗关闭', async ({ page, mock }) => {
    void mock
    const calls = trackApi(page)
    await signIn(page, 'emp01')
    await openUserDropdown(page)
    await page.locator('.el-dropdown-menu__item').filter({ hasText: '修改密码' }).click()

    const dialog = page.locator('.el-dialog:visible').filter({ hasText: '修改登录密码' })
    await expect(dialog).toBeVisible()

    const before = calls.length
    await dialog.getByRole('button', { name: '确认修改' }).click()
    await expect(toast(page, '请填写当前密码，新密码至少6位')).toBeVisible()
    expect(calls.slice(before)).toEqual([])

    await dialog.getByPlaceholder('请输入当前密码').fill(DEMO_PASSWORD)
    await dialog.getByPlaceholder('至少6位字符').fill('Newpass123')
    await dialog.getByPlaceholder('再次输入新密码').fill('Newpass999')
    await dialog.getByRole('button', { name: '确认修改' }).click()
    await expect(toast(page, '两次输入的新密码不一致')).toBeVisible()

    await dialog.getByPlaceholder('再次输入新密码').fill('Newpass123')
    await dialog.getByRole('button', { name: '确认修改' }).click()
    await expect(toast(page, '密码修改成功')).toBeVisible()
    await expect(dialog).toBeHidden()
    expect(calls.slice(before)).toContain('PUT /api/v1/auth/password')
  })
})
