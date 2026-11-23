/**
 * E2E 运行环境的单一真源。
 *
 * 默认走「有状态内存 mock」：用 page.route 在 vite 代理之前拦截 /api/v1/**，
 * 因此不需要仓颉后端、不需要 MySQL 就能跑通全部关键路径。
 * 真实后端联调时设 E2E_REAL=1 关闭 mock（此时必须自己启动 8080 后端）。
 */
export const REAL_BACKEND = process.env.E2E_REAL === '1'

export const BASE_URL = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:5173'

/** 演示账号，与 backend-cangjie/src/main.cj 里 sys_user 的种子完全一致，口令统一 123456。 */
export type DemoAccount = 'admin' | 'hr' | 'manager' | 'emp01'

export const DEMO_PASSWORD = '123456'
