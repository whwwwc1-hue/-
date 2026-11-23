/**
 * P1.3（二）四角色 RBAC：侧边栏菜单隔离 + 越权直达的守卫行为。
 *
 * 菜单真源有两处且必须一致：`src/router/index.ts` 的 meta.roles 与
 * `src/layout/AppLayout.vue` 的 menuItems.roles。这里按角色逐一断言完整菜单文本，
 * 等于同时钉住了这两份配置——任何一处漏改都会红。
 */
import type { Page } from '@playwright/test'
import { expect, signIn, test, toast } from './support/fixtures'
import type { DemoAccount } from './support/env'

const MENUS: Record<DemoAccount, string[]> = {
  admin: ['工作台概览', '组织与岗位', '员工花名册', '考勤打卡', '假勤审批', '绩效评估', '薪酬与工资条', '招聘管理', '系统与审计'],
  hr: ['工作台概览', '组织与岗位', '员工花名册', '考勤打卡', '假勤审批', '绩效评估', '薪酬与工资条', '招聘管理'],
  manager: ['工作台概览', '员工花名册', '考勤打卡', '假勤审批', '绩效评估', '薪酬与工资条'],
  emp01: ['工作台概览', '考勤打卡', '假勤审批', '绩效评估', '薪酬与工资条']
}

const ROLE_TAG: Record<DemoAccount, string> = {
  admin: '系统管理员 ADMIN',
  hr: '人事主管 HR',
  manager: '部门经理 MANAGER',
  emp01: '普通员工 EMPLOYEE'
}

/**
 * 除工作台自身接口外，其他 /api/v1 请求都算「越权页面偷跑数据」。
 * 白名单来源两处：
 * 1. DashboardView 的挂载逻辑：它同时拉 overview 与 attendance/today
 *    （工作台上有签到卡片），这两条属于落地页自身，不是越权模块的。
 * 2. router.beforeEach 的冷启动画像同步 GET /auth/me：page.goto 是整页加载，
 *    守卫必须先用服务端画像覆盖 localStorage 快照（否则角色与年假余额会过期，
 *    见 FOLLOWUP_PLAN L-FE-5），这条发生在目标组件挂载之前，同样不算越权取数。
 */
function trackProtectedApi(page: Page): string[] {
  const allowed = ['/api/v1/dashboard/', '/api/v1/attendance/today', '/api/v1/auth/me']
  const calls: string[] = []
  page.on('request', (req) => {
    const path = new URL(req.url()).pathname
    if (path.startsWith('/api/v1/') && !allowed.some((p) => path.startsWith(p))) calls.push(`${req.method()} ${path}`)
  })
  return calls
}

test.describe('侧边栏菜单按角色隔离', () => {
  for (const account of ['admin', 'hr', 'manager', 'emp01'] as DemoAccount[]) {
    test(`${account} 登录后只看到 ${MENUS[account].length} 个有权菜单`, async ({ page, mock }) => {
      void mock
      await signIn(page, account)
      await expect(page.locator('header .el-tag')).toHaveText(ROLE_TAG[account])
      await expect(page.locator('aside nav a')).toHaveText(MENUS[account])
      // 无权项连渲染都不该发生（而不是渲染后靠 CSS 藏起来）
      for (const hidden of ['系统与审计', '组织与岗位', '招聘管理', '员工花名册']) {
        if (!MENUS[account].includes(hidden)) {
          await expect(page.locator('aside nav').getByText(hidden)).toHaveCount(0)
        }
      }
    })
  }
})

test.describe('越权直达被守卫拦截', () => {
  const cases: Array<{ account: DemoAccount; path: string; tag: string }> = [
    { account: 'emp01', path: '/system', tag: '系统与审计' },
    { account: 'hr', path: '/system', tag: '系统与审计' },
    { account: 'manager', path: '/organization', tag: '组织与岗位' }
  ]

  for (const { account, path } of cases) {
    test(`${account} 直接访问 ${path} 会被退回工作台且不发业务请求`, async ({ page, mock }) => {
      void mock
      await signIn(page, account)
      const calls = trackProtectedApi(page)
      await page.goto(path)

      await expect(page).toHaveURL(/\/dashboard$/)
      await expect(toast(page, '当前账号无权访问该模块')).toBeVisible()
      // 拦截发生在组件挂载之前，所以目标页面的接口一次都不该跑
      expect(calls).toEqual([])
    })
  }

  test('未知路径落到 catch-all 重定向回工作台', async ({ page, mock }) => {
    void mock
    await signIn(page, 'emp01')
    await page.goto('/not-a-real-module')
    await expect(page).toHaveURL(/\/dashboard$/)
    await expect(page.locator('aside nav a')).toHaveText(MENUS.emp01)
  })

  test('有权角色仍可正常进入自己的敏感模块', async ({ page, mock, openRole }) => {
    void mock
    await signIn(page, 'admin', '/system')
    await expect(page.locator('header')).toContainText('系统与审计')
    // 换角色必须开新上下文：同一 page 上直接 goto('/login') 会被守卫弹回 /dashboard，
    // 而且 localStorage 里残留的 admin 画像会污染第二个角色的 store。
    const hrPage = await openRole('hr', '/organization')
    await expect(hrPage).toHaveURL(/\/organization$/)
    await expect(hrPage.locator('header')).toContainText('组织与岗位')
  })
})
