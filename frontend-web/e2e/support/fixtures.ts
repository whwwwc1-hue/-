/**
 * Playwright 测试夹具：把有状态 mock 后端挂到浏览器上下文上。
 *
 * 为什么要单独一层 fixture：
 * 1. `page.route` 的作用域是 BrowserContext。默认 fixture 只有 `page`，
 *    而跨角色用例（emp01 提单 → manager 审批 → hr 生成发放 → emp01 看工资条）
 *    必须用**不同 context** 才能持有不同的 localStorage（各自的 token）。
 *    所以这里把拦截挂在 `context` 上，并提供 `openRole()` 在 teardown 统一关闭派生上下文。
 * 2. 同一个 MockBackend 实例被 attach 到多个 context，因此跨角色共享内存状态；
 *    而每个用例一个新实例，保证用例之间零串扰、可任意顺序重排。
 * 3. teardown 里断言 `mock.unmatched` 为空，这是防「假绿」的闸门：
 *    只要前端调用了 mock 未覆盖的接口，用例必定失败，而不是悄悄走 vite 代理打到不存在的 8080。
 *
 * E2E_REAL=1 时不挂任何路由，请求会经 vite 代理真正打到 127.0.0.1:8080，
 * 便于后端可用时做真实联调；依赖 mock 内部数据的用例需自行跳过（见各 spec 的 beforeEach）。
 */
import { test as base, expect, type BrowserContext, type Locator, type Page } from '@playwright/test'
import { MockBackend } from './mock-server'
import { BASE_URL, DEMO_PASSWORD, REAL_BACKEND, type DemoAccount } from './env'

type HrmsFixtures = {
  /** 每个用例一个全新的有状态 mock。 */
  mock: MockBackend
  /** 以另一角色打开新上下文（新 token），返回已登录的 page；teardown 自动关闭。 */
  openRole: (account: DemoAccount, path?: string) => Promise<Page>
}

/**
 * 走真实登录表单完成鉴权。
 *
 * 刻意不用 `addInitScript` 塞 localStorage：那样会绕过登录页与 `router.beforeEach`
 * 的 refreshProfile 分支，等于没测到东西。这里让 UI 真正跑一遍
 * `/auth/login` → `auth.setAuth` → `router.replace('/dashboard')`。
 */
export async function signIn(page: Page, account: DemoAccount, path = '/dashboard'): Promise<void> {
  await page.goto('/login')
  await page.getByPlaceholder('请输入用户名').fill(account)
  await page.getByPlaceholder('请输入密码').fill(DEMO_PASSWORD)
  await page.getByRole('button', { name: '立即登录' }).click()
  // 登录成功后组件内固定 router.replace('/dashboard')，目标页靠随后的显式导航到达
  await page.waitForURL('**/dashboard')
  // 只断言稳定锚点（侧边栏），刻意不断言 ElMessage「欢迎回来」：
  // 全局提示 3 秒自动销毁，放在通用夹具里会让所有用例继承一个偶发假红。
  // toast 本身在 auth.spec.ts 的专项用例里紧跟点击断言。
  await expect(page.locator('aside').getByText('考勤打卡')).toBeVisible()
  if (path !== '/dashboard') {
    await page.goto(path)
    await page.waitForURL(`**${path}`)
  }
}

/**
 * ElMessage 全局提示的定位器工厂。
 *
 * element-plus 的消息条 3 秒后自动销毁，且同一页面可能同时堆叠多条，
 * 所以统一走 `.el-message` + hasText 过滤，并只在**触发动作的紧后一步**断言，
 * 不要把它塞进通用夹具（见 signIn 的注释）。
 */
export function toast(page: Page, text: string): Locator {
  return page.locator('.el-message').filter({ hasText: text })
}

/** ElMessageBox（确认框）——按钮文案固定为「取消 / 确定」，不是「确认」。 */
export function confirmBox(page: Page, title: string): Locator {
  return page.locator('.el-message-box').filter({ hasText: title })
}

export const test = base.extend<HrmsFixtures>({
  // auto: true 是必需的，不是风格问题：Playwright 的 fixture 是**惰性**的，
  // 只有被用例（或其依赖）解构到的 fixture 才会 setup。
  // 之前写成普通 fixture，凡是 `async ({ page }) => {}` 的用例里 mock 根本没初始化，
  // context.route 从未挂载，登录请求直接穿过 vite 代理打到不存在的 8080，表现为 waitForURL 超时。
  // 改成 auto 后，拦截与 unmatched 闸门对**所有**用例生效。
  // 另：依赖 context 而非 page，避免为只用 openRole 的用例凭空多开一个页面。
  mock: [
    async ({ context }, use) => {
      const mock = new MockBackend()
      if (!REAL_BACKEND) mock.attach(context)
      await use(mock)
      expect(
        mock.unmatched,
        `以下接口前端发起了但 mock 未实现，说明契约与后端不一致或 mock 覆盖不全：\n${mock.unmatched.join('\n')}`
      ).toEqual([])
    },
    { auto: true }
  ],

  openRole: async ({ browser, context, mock }, use) => {
    const extras: BrowserContext[] = []
    await use(async (account, path = '/dashboard') => {
      const ctx = await browser.newContext({ baseURL: BASE_URL, locale: 'zh-CN' })
      extras.push(ctx)
      if (!REAL_BACKEND) mock.attach(ctx)
      const page = await ctx.newPage()
      await signIn(page, account, path)
      return page
    })
    // 与默认 context 同生共死：用例结束统一回收，防止测试进程泄漏页面。
    void context
    await Promise.all(extras.map((c) => c.close()))
  }
})

export { expect, REAL_BACKEND }
