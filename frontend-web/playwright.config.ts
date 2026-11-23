import { defineConfig, devices } from '@playwright/test'
import { BASE_URL } from './e2e/support/env'

/**
 * HRMS 前端 E2E 配置。
 *
 * - testDir: ./e2e
 * - 浏览器：默认复用本机已安装的 Microsoft Edge（channel: 'msedge'），
 *   这样在无 Chrome、且不便下载 Playwright 内置浏览器的环境里也能真实执行。
 *   需要换内核时设 E2E_CHANNEL（如 'chrome' / 'chromium'）。
 * - webServer：自动拉起 vite dev；本地已有服务时复用，CI 上强制新建。
 */
export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  workers: process.env.CI ? 2 : 1,
  retries: 0,
  reporter: process.env.CI ? [['list'], ['github']] : [['list']],
  timeout: 30_000,
  expect: { timeout: 8_000 },
  use: {
    baseURL: BASE_URL,
    channel: process.env.E2E_CHANNEL ?? 'msedge',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'off',
    actionTimeout: 10_000,
    locale: 'zh-CN'
  },
  projects: [{ name: 'desktop-chromium', use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 900 } } }],
  webServer: {
    command: 'npm run dev',
    url: BASE_URL,
    timeout: 120_000,
    reuseExistingServer: !process.env.CI
  }
})
