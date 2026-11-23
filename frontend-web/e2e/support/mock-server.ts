/**
 * 有状态内存 mock —— 逐行镜像仓颉后端的 HTTP 契约，供 Playwright E2E 拦截 /api/v1/** 使用。
 *
 * ## 为什么要有这个文件
 * 仓颉 SDK 在本机装不上（无 cjc / 无 MSVC link），后端从未真正编译运行过，
 * 因此前端关键路径无法用真实服务做回归。这里的 mock 不是随手编的假数据，
 * 而是严格对照 backend-cangjie/src 的真实实现翻译过来的：
 *   - common/response.cj        → 统一信封 {code,message,data}、sendOk/sendOkMsg/sendErr/sendPage
 *   - controller/auth_controller.cj        → 登录/档案/改密的字段与错误文案
 *   - controller/attendance_controller.cj  → today/my/list/clock-in/clock-out/update 与 summary 口径
 *   - controller/request_controller.cj     → 申请、审批（含年假扣减）、撤回
 *   - controller/payroll_controller.cj     → 算薪公式（5000 起征、18.5% 社保、21.75 日薪、1.5 倍加班）
 *   - controller/dashboard_controller.cj   → overview 的 kpis/图表/到期合同结构
 *   - controller/employee_controller.cj    → 员工列表 20 字段、CSV 解析与批量导入校验
 *   - middleware/auth 守卫                  → 401/403 的状态码与文案
 *
 * ## 已知并有意保留的偏差（不要当 bug 修）
 * 1. 后端把金额裸插值成 `19000.00` 文本，JSON.parse 后是 number 19000；
 *    mock 直接输出 number，前端拿到的运行时类型一致。
 * 2. mock 不发 `X-Renewed-Token`（滑动续期），只有显式调用 mock.enableRenewToken() 时才发，
 *    用于专门验证前端 request.ts 的 adoptRenewedToken 分支。
 * 3. mock 不做 JWT 签名校验，只按 token 字符串查会话表（等价于「Token 有效/无效」两态）。
 *
 * ## 防假绿
 * 任何落入 if 链之外、没人认领的 /api/v1 请求都会记进 unmatched，
 * fixtures 在每个用例结束时断言 unmatched 为空，避免接口写错却悄悄通过。
 */
import type { BrowserContext, Route } from '@playwright/test'
import type { UserProfile } from '../../src/api/hrms'
import { DEMO_PASSWORD, type DemoAccount } from './env'

/* ------------------------------------------------------------------ 工具 */

/** 与 response.cj 的 round2 同口径：先取绝对值 *100+0.5 再截断，最后补符号。 */
export function round2(v: number): number {
  const sign = v < 0 ? -1 : 1
  return (sign * Math.trunc(Math.abs(v) * 100 + 0.5)) / 100
}

/** 与 payroll_controller.cj calculateTax 完全一致的个人所得税口径。 */
export function calculateTax(taxableRaw: number): number {
  const taxable = Math.max(0, taxableRaw)
  if (taxable <= 0) return 0
  if (taxable <= 3000) return round2(taxable * 0.03)
  if (taxable <= 12000) return round2(taxable * 0.1 - 210)
  if (taxable <= 25000) return round2(taxable * 0.2 - 1410)
  return round2(taxable * 0.25 - 2660)
}

/** 与 calculatePayrollValues 完全一致：返回 [tax, netSalary]。 */
export function calculatePayrollValues(
  baseSalary: number,
  bonus: number,
  overtimePay: number,
  attendanceDeduction: number,
  socialSecurity: number
): [number, number] {
  const taxable = baseSalary + bonus + overtimePay - attendanceDeduction - socialSecurity - 5000
  const tax = calculateTax(taxable)
  const net = round2(baseSalary + bonus + overtimePay - attendanceDeduction - socialSecurity - tax)
  return [tax, net]
}

function pad(n: number): string {
  return n < 10 ? `0${n}` : `${n}`
}

/** 本地日期 YYYY-MM-DD。 */
export function localDate(offsetDays = 0): string {
  const d = new Date()
  d.setDate(d.getDate() + offsetDays)
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

/**
 * 前端 AttendanceView.myMonth 用的是 new Date().toISOString().slice(0,7)（UTC 月份），
 * mock 必须用同一个表达式，否则在月初/月末跑测试会出现「查不到种子数据」的假失败。
 */
export function utcMonth(): string {
  return new Date().toISOString().slice(0, 7)
}

/** PayrollView.filters.payMonth 是硬编码常量，mock 的薪资种子必须落在同一个月。 */
export const PAYROLL_MONTH = '2026-11'

/**
 * 历史考勤种子所在月份：必须是**固定的过去月份**，绝不能取墙钟月份。
 * 详见 seedAttendance() 里的两条约束（撞 todayRow / 污染算薪统计）。
 */
export const HISTORY_MONTH = '2026-08'

/**
 * 与 attendance_controller.cj 的 attShouldAttendDays 同口径：
 * 本项目没有排班表 / 工作日历表，应出勤天数固定按「每周 5 天 × 4.4 周 = 22 天」统计，
 * 不随法定节假日变化（已知限制见 FOLLOWUP_PLAN 第十节 L-ATT-1）。
 */
export const ATT_SHOULD_ATTEND_DAYS = 22

function nowStamp(offsetDays = 0): string {
  return `${localDate(offsetDays)} 10:00:00`
}

/* ------------------------------------------------------------- 行数据结构 */

interface Employee {
  id: number
  empNo: string
  name: string
  deptId: number
  deptName: string
  positionName: string
  baseSalary: number
  annualLeaveBalance: number
  hireDate: string
  contractEndDate: string
  empStatus: string
  phone: string
  email: string
  /**
   * 以下字段是 GET /employees（employeeRowToJson 共 20 个出参）需要的完整口径。
   * init.sql 的种子行里没有落这些列，因此做成可选、由 employeeRowJson 给确定性缺省值；
   * 批量导入进来的新员工则会全部显式赋值，正好覆盖两条分支。
   */
  gender?: number
  positionId?: number
  idCard?: string
  probationEndDate?: string
  resignDate?: string
  resignReason?: string
  createdAt?: string
}

/** 字段名严格等于 attendance_controller.cj 的 attendanceRowToJson。 */
export interface AttRow {
  id: number
  employeeId: number
  empNo: string
  empName: string
  deptName: string
  workDate: string
  clockInTime: string
  clockOutTime: string
  lateMinutes: number
  earlyMinutes: number
  status: string
  remark: string
}

/**
 * P3.1 长假二级审批状态机 —— request_controller.cj 的 TypeScript 镜像。
 *
 * 逐函数对应：reqLongLeaveDays / reqIsPendingLike / reqInitialStatus /
 * reqCurrentLevel / reqNextStatus / reqCanActStep / reqShouldDeductAnnual。
 * mock 的价值就在于「同一套判断在两端各写一遍仍然同结论」，因此这里
 * 不允许出现任何后端没有的额外规则，也不允许省略后端有的分支。
 */
const REQ_LONG_LEAVE_DAYS = 3
const REQ_PENDING_STATUSES = ['PENDING', 'PENDING_MGR', 'PENDING_HR']

function reqIsPendingLike(status: string): boolean {
  return REQ_PENDING_STATUSES.includes(status)
}

function reqInitialStatus(category: string, duration: number): string {
  return category === 'LEAVE' && duration > REQ_LONG_LEAVE_DAYS ? 'PENDING_MGR' : 'PENDING'
}

function reqCurrentLevel(status: string): number {
  if (status === 'PENDING' || status === 'PENDING_MGR') return 1
  if (status === 'PENDING_HR') return 2
  if (reqIsPendingLike(status)) return 1
  if (status === 'APPROVED' || status === 'REJECTED' || status === 'CANCELLED') return 0
  return -1
}

function reqNextStatus(status: string, action: string): string {
  if (action === 'REJECTED') return 'REJECTED'
  if (action !== 'APPROVED') return ''
  if (status === 'PENDING_MGR') return 'PENDING_HR'
  return 'APPROVED'
}

function reqCanActStep(status: string, role: string, sameDept: boolean): boolean {
  if (!reqIsPendingLike(status)) return false
  if (role === 'ADMIN') return true
  if (status === 'PENDING_MGR') return role === 'MANAGER' && sameDept
  if (status === 'PENDING_HR') return role === 'HR'
  if (role === 'HR') return true
  return role === 'MANAGER' && sameDept
}

function reqActionDeniedMessage(status: string, role: string, sameDept: boolean): string {
  if (status === 'PENDING_MGR') {
    if (role === 'MANAGER' && !sameDept) return '长假一级审批仅可由申请本部门主管处理'
    return '长假一级审批请由部门主管或系统管理员处理'
  }
  if (status === 'PENDING_HR') return '长假已进入二级审批，请由人力资源部门或系统管理员处理'
  return '该申请单已处理，无法重复审批'
}

function reqShouldDeductAnnual(category: string, subType: string, next: string): boolean {
  return category === 'LEAVE' && subType === 'ANNUAL' && next === 'APPROVED'
}

/** 字段名严格等于 hr_approval_log 的列（经 reqTrailJsonFor 后是驼峰出参）。 */
export interface ApprovalLogRow {
  requestId: number
  step: number
  approverId: number
  approverName: string
  approverRole: string
  action: string
  resultStatus: string
  remark: string
  createdAt: string
}

/** 审批链出参口径（approvalTrail 数组元素），与 reqTrailJsonFor 拼出的键一致。 */
interface ApprovalTrailItem {
  step: number
  approverName: string
  approverRole: string
  action: string
  resultStatus: string
  remark: string
  at: string
}

/** 字段名严格等于 request_controller.cj 的 requestRowToJson（approverName 取 sys_user.username）。 */
export interface ReqRow {
  id: number
  employeeId: number
  empNo: string
  empName: string
  deptName: string
  category: string
  subType: string
  startTime: string
  endTime: string
  duration: number
  reason: string
  status: string
  approverId: number
  approverName: string
  approveRemark: string
  approvedAt: string
  createdAt: string
  /** 以下三项由后端按「当前查看者」实时计算，不是 hr_leave_overtime 的列。 */
  currentLevel: number
  myAction: string
  approvalTrail: ApprovalTrailItem[]
}

/** 字段名严格等于 payroll_controller.cj 的 payrollRowToJson。 */
export interface PayRow {
  id: number
  employeeId: number
  empNo: string
  empName: string
  deptName: string
  positionName: string
  payMonth: string
  baseSalary: number
  bonus: number
  overtimePay: number
  attendanceDeduction: number
  socialSecurity: number
  tax: number
  netSalary: number
  status: string
  paidAt: string
  remark: string
}

interface PerfRow {
  id: number
  employeeId: number
  status: string
  bonusRatio: number
}

interface Account {
  userId: number
  username: DemoAccount
  role: UserProfile['role']
  employeeId: number
  isActive: boolean
  /** 以下两项只被 GET /system/users 消费，字段名对齐 sys_user 列。 */
  lastLoginAt: string
  createdAt: string
}

/** 字段名严格等于 org_controller.cj 的 DeptRow（tree 节点另加 children）。 */
interface DeptSeed {
  id: number
  parentId: number
  deptName: string
  leaderName: string
  headcountLimit: number
  description: string
}

/** 字段名严格等于 org_controller.cj 的 handlePositionList 输出。 */
interface PosSeed {
  id: number
  posCode: string
  posName: string
  deptId: number
  levelRange: string
  minSalary: number
  maxSalary: number
  createdAt: string
}

/** 字段名严格等于 system_controller.cj 的 handleSystemAuditLogs 输出。 */
interface AuditSeed {
  id: number
  userId: number
  username: string
  module: string
  action: string
  detail: string
  createdAt: string
}

type Json = Record<string, unknown>

interface Call {
  method: string
  path: string
  query: URLSearchParams
  body: Json
  /** 由 Authorization 解析出来的会话，未登录时为 null。 */
  account: Account | null
  /** 401 的具体成因，文案与 middleware 保持一致。 */
  authFailure: string | null
}

interface Reply {
  status: number
  body: Json
  headers?: Record<string, string>
}

/* ------------------------------------------------------------------ mock */

export class MockBackend {
  /** 未被任何 handler 认领的请求，用例结束时必须为空。 */
  readonly unmatched: string[] = []

  private readonly tokens = new Map<string, string>()
  private readonly failures = new Map<string, number>()
  private readonly accounts: Account[]
  private readonly employees: Employee[]
  private readonly attendance: AttRow[] = []
  private readonly requests: ReqRow[] = []
  /** P3.1 审批链历史，对应 hr_approval_log；UNIQUE(request_id, step) 由 pushApprovalLog 兜住。 */
  private readonly approvalLogs: ApprovalLogRow[] = []
  private readonly payrolls: PayRow[] = []
  private readonly performances: PerfRow[] = []
  /** 部门 / 岗位种子逐行取自 sql/init.sql 的 hr_department、hr_position（在职人数不写死，由 employees 现算）。 */
  private readonly departments: DeptSeed[] = [
    { id: 1, parentId: 0, deptName: '总经办', leaderName: '张明远', headcountLimit: 5, description: '公司战略决策与经营管理' },
    { id: 2, parentId: 1, deptName: '技术研发中心', leaderName: '李泽宇', headcountLimit: 50, description: '核心产品架构、仓颉后端与Web研发' },
    { id: 3, parentId: 1, deptName: '人力资源部', leaderName: '王静', headcountLimit: 10, description: '招聘配置、薪酬绩效与员工关系' },
    { id: 4, parentId: 1, deptName: '市场与产品部', leaderName: '赵晨', headcountLimit: 25, description: '产品规划、品牌推广与商业化' }
  ]
  private readonly positions: PosSeed[] = [
    { id: 1, posCode: 'POS-CIO', posName: '首席信息官', deptId: 1, levelRange: 'M4', minSalary: 25000, maxSalary: 45000, createdAt: '2023-01-10 10:00:00' },
    { id: 2, posCode: 'POS-DEV-CJ', posName: '仓颉后端工程师', deptId: 2, levelRange: 'P6-P8', minSalary: 15000, maxSalary: 32000, createdAt: '2023-01-10 10:00:00' },
    { id: 3, posCode: 'POS-DEV-FE', posName: '资深前端工程师', deptId: 2, levelRange: 'P6-P7', minSalary: 14000, maxSalary: 28000, createdAt: '2023-01-10 10:00:00' },
    { id: 4, posCode: 'POS-HRBP', posName: '资深 HRBP', deptId: 3, levelRange: 'P6-P7', minSalary: 10000, maxSalary: 18000, createdAt: '2023-06-01 10:00:00' },
    { id: 5, posCode: 'POS-PM', posName: '高级产品经理', deptId: 4, levelRange: 'P6-P8', minSalary: 16000, maxSalary: 30000, createdAt: '2024-02-01 10:00:00' }
  ]
  /**
   * 审计日志在真实后端里只由 audit_service.writeAuditLog 在写操作时追加，
   * mock 不模拟写入过程，只给一批结构与线上完全一致的静态行，
   * 用于钉住「列表 + 分页 + 按模块筛选」这条只读链路。
   */
  private readonly auditLogs: AuditSeed[] = [
    { id: 41, userId: 1, username: 'admin', module: '系统管理', action: '更新账号权限', detail: '账号 manager 角色由 EMPLOYEE 调整为 MANAGER，状态启用', createdAt: '2026-11-20 09:12:33' },
    { id: 42, userId: 2, username: 'hr', module: '薪酬管理', action: '一键核算薪资', detail: '月份 2026-10，生成/更新 5 条记录', createdAt: '2026-11-19 17:40:05' },
    { id: 43, userId: 3, username: 'manager', module: '假勤审批', action: '审批通过申请', detail: '申请单 #12 加班申请 3 小时，审批意见：同意', createdAt: '2026-11-18 11:02:47' },
    { id: 44, userId: 2, username: 'hr', module: '组织架构', action: '新增岗位', detail: '岗位 POS-PM 高级产品经理，所属部门 市场与产品部', createdAt: '2026-11-17 15:26:10' },
    { id: 45, userId: 1, username: 'admin', module: '员工管理', action: '新增员工', detail: '工号 EMP20260005 林小满，入职日期 2026-09-01', createdAt: '2026-11-16 10:08:52' },
    { id: 46, userId: 2, username: 'hr', module: '考勤管理', action: '修正考勤记录', detail: 'EMP20260004 2026-11-13 迟到，补卡说明：外勤堵车', createdAt: '2026-11-15 09:31:19' }
  ]
  private seq = 5000
  private renewToken: string | null = null

  constructor() {
    // 员工档案取自 sql/init.sql 的种子（id/工号/姓名/部门/岗位/月薪/年假/入职日/合同到期日）
    this.employees = [
      { id: 1, empNo: 'EMP20260001', name: '张明远', deptId: 1, deptName: '总经办', positionName: '首席信息官', baseSalary: 30000, annualLeaveBalance: 10, hireDate: '2023-01-10', contractEndDate: '2028-01-09', empStatus: 'ACTIVE', phone: '13800000001', email: 'zhangmy@hrms.demo' },
      { id: 2, empNo: 'EMP20260002', name: '王静', deptId: 3, deptName: '人力资源部', positionName: '资深 HRBP', baseSalary: 14000, annualLeaveBalance: 8, hireDate: '2023-06-01', contractEndDate: '2027-05-31', empStatus: 'ACTIVE', phone: '13800000002', email: 'wangj@hrms.demo' },
      { id: 3, empNo: 'EMP20260003', name: '李泽宇', deptId: 2, deptName: '技术研发中心', positionName: '研发总监', baseSalary: 26000, annualLeaveBalance: 10, hireDate: '2024-02-01', contractEndDate: '2027-01-31', empStatus: 'ACTIVE', phone: '13800000003', email: 'lizy@hrms.demo' },
      { id: 4, empNo: 'EMP20260004', name: '陈思远', deptId: 2, deptName: '技术研发中心', positionName: '仓颉后端工程师', baseSalary: 19000, annualLeaveBalance: 5, hireDate: '2025-07-01', contractEndDate: '2026-12-15', empStatus: 'ACTIVE', phone: '13800000004', email: 'chensy@hrms.demo' },
      { id: 5, empNo: 'EMP20260005', name: '林小满', deptId: 2, deptName: '技术研发中心', positionName: '资深前端工程师', baseSalary: 17500, annualLeaveBalance: 5, hireDate: '2026-09-01', contractEndDate: '2029-08-31', empStatus: 'PROBATION', phone: '13800000005', email: 'linxm@hrms.demo' }
    ]
    // sys_user 种子取自 backend-cangjie/src/main.cj 的 ensureDefaultAccounts；
    // lastLoginAt/createdAt 仅为让「系统与审计」页有真实形态的数据可渲染，不参与断言。
    this.accounts = [
      { userId: 1, username: 'admin', role: 'ADMIN', employeeId: 1, isActive: true, lastLoginAt: '2026-11-20 08:55:12', createdAt: '2023-01-10 10:00:00' },
      { userId: 2, username: 'hr', role: 'HR', employeeId: 2, isActive: true, lastLoginAt: '2026-11-20 09:31:40', createdAt: '2023-06-01 10:00:00' },
      { userId: 3, username: 'manager', role: 'MANAGER', employeeId: 3, isActive: true, lastLoginAt: '2026-11-19 18:02:57', createdAt: '2024-02-01 10:00:00' },
      { userId: 4, username: 'emp01', role: 'EMPLOYEE', employeeId: 4, isActive: true, lastLoginAt: '2026-11-20 09:05:21', createdAt: '2025-07-01 10:00:00' }
    ]
    this.seedPerformances()
    this.seedRequests()
    this.seedAttendance()
  }

  /* -------------------------------------------------------------- 种子数据 */

  private seedPerformances(): void {
    // 只有已 COMPLETED 的绩效才影响奖金：emp01 系数 0.9，admin 系数 1.0
    this.performances.push(
      { id: 1, employeeId: 4, status: 'COMPLETED', bonusRatio: 0.9 },
      { id: 2, employeeId: 1, status: 'COMPLETED', bonusRatio: 1.0 },
      { id: 3, employeeId: 3, status: 'SELF_EVAL', bonusRatio: 0.5 }
    )
  }

  private seedRequests(): void {
    // 落在 PAYROLL_MONTH 内的已审批加班/事假：这是「加班→加班费」「事假→考勤扣款」因果链的数据基础。
    this.pushRequest({
      employeeId: 4,
      category: 'OVERTIME',
      subType: 'WORKDAY',
      startTime: `${PAYROLL_MONTH}-12 19:00:00`,
      endTime: `${PAYROLL_MONTH}-12 22:00:00`,
      duration: 3,
      reason: '仓颉网关联调加班',
      status: 'APPROVED',
      approverId: 3,
      approverName: 'manager',
      approveRemark: '同意',
      approvedAt: nowStamp(-30)
    })
    this.pushRequest({
      employeeId: 4,
      category: 'LEAVE',
      subType: 'PERSONAL',
      startTime: `${PAYROLL_MONTH}-18 09:00:00`,
      endTime: `${PAYROLL_MONTH}-18 18:00:00`,
      duration: 1,
      reason: '家中有事请假一天',
      status: 'APPROVED',
      approverId: 3,
      approverName: 'manager',
      approveRemark: '准假',
      approvedAt: nowStamp(-25)
    })
    // 一条待审批年假单，让「审批工作台」在首个用例里就有活可干
    this.pushRequest({
      employeeId: 4,
      category: 'LEAVE',
      subType: 'ANNUAL',
      startTime: `${localDate(5)} 09:00:00`,
      endTime: `${localDate(5)} 18:00:00`,
      duration: 1,
      reason: '年假出行',
      status: 'PENDING',
      createdAt: nowStamp(-1)
    })
  }

  private seedAttendance(): void {
    // HISTORY_MONTH 是一个刻意远离「今天」和 PAYROLL_MONTH 的固定历史月份。
    // 两个必须遵守的约束（违反任何一条，套件就会「换个日期跑就红」）：
    // 1. 种子日期绝不能等于 localDate()（运行当天）。`onClockIn` 用
    //    `workDate === localDate()` 查 todayRow，一旦命中就返回 400
    //    「今日已完成上班打卡（…）」，签到用例必红。所以绝不能用 localDate(0/-1)
    //    这类偏移做种子，也不能用「当前月的第 05/06 号」——运行日正好是 5/6 号就撞车。
    // 2. 种子记录里绝不能出现 lateMinutes > 0（除下面显式的 PAYROLL_MONTH-11）。
    //    算薪只看分钟数，运行月份恰好等于 PAYROLL_MONTH 时墙钟月份会被并入统计，
    //    lateCnt 从 1 变 2，attendanceDeduction 浮动 50 元，金额断言随之漂移。
    this.pushAttendance({ employeeId: 4, workDate: `${HISTORY_MONTH}-05`, clockInTime: `${HISTORY_MONTH}-05 08:52:00`, clockOutTime: `${HISTORY_MONTH}-05 18:30:00`, lateMinutes: 0, status: 'NORMAL' })
    this.pushAttendance({ employeeId: 4, workDate: `${HISTORY_MONTH}-06`, clockInTime: `${HISTORY_MONTH}-06 08:55:00`, clockOutTime: `${HISTORY_MONTH}-06 18:05:00`, lateMinutes: 0, status: 'NORMAL' })
    // 与 PAYROLL_MONTH 对齐的考勤（决定迟到扣款），与运行日期无关
    this.pushAttendance({ employeeId: 4, workDate: `${PAYROLL_MONTH}-11`, clockInTime: `${PAYROLL_MONTH}-11 09:20:00`, clockOutTime: `${PAYROLL_MONTH}-11 18:10:00`, lateMinutes: 20, status: 'LATE' })
    this.pushAttendance({ employeeId: 4, workDate: `${PAYROLL_MONTH}-13`, clockInTime: `${PAYROLL_MONTH}-13 08:50:00`, clockOutTime: `${PAYROLL_MONTH}-13 18:00:00`, lateMinutes: 0, status: 'NORMAL' })
    // 其它人的历史记录，让「全员考勤监控」列表非空；
    // 注意 onAttendanceList 在不传 month 时不做月份过滤，所以历史月的记录同样可见，
    // 「按状态筛选=缺勤」只回 1 行的断言不依赖运行日期。
    this.pushAttendance({ employeeId: 3, workDate: `${HISTORY_MONTH}-06`, clockInTime: `${HISTORY_MONTH}-06 08:48:00`, clockOutTime: `${HISTORY_MONTH}-06 19:20:00`, lateMinutes: 0, status: 'NORMAL' })
    this.pushAttendance({ employeeId: 2, workDate: `${HISTORY_MONTH}-06`, clockInTime: '', clockOutTime: '', lateMinutes: 0, status: 'ABSENT', remark: '未打卡' })
  }

  /* ------------------------------------------------------------ 状态访问器 */

  employee(id: number): Employee {
    const e = this.employees.find((x) => x.id === id)
    if (!e) throw new Error(`mock: 员工 ${id} 不存在`)
    return e
  }

  account(username: DemoAccount): Account {
    const a = this.accounts.find((x) => x.username === username)
    if (!a) throw new Error(`mock: 账号 ${username} 不存在`)
    return a
  }

  /** 供测试直接读取年假余额，断言「审批通过后扣减」。 */
  leaveBalance(username: DemoAccount): number {
    return this.employee(this.account(username).employeeId).annualLeaveBalance
  }

  findRequestByReason(reason: string): ReqRow | undefined {
    return this.requests.find((r) => r.reason === reason)
  }

  /** 供测试断言「一级通过不扣、二级通过才扣」：返回该单据已落账的审批链步数。 */
  approvalSteps(reason: string): number {
    const row = this.findRequestByReason(reason)
    if (!row) return 0
    return this.approvalLogs.filter((l) => l.requestId === row.id).length
  }

  /** 该单据审批链的 (step, action, resultStatus) 序列，便于整链 pin。 */
  approvalChain(reason: string): Array<{ step: number; approverName: string; action: string; resultStatus: string }> {
    const row = this.findRequestByReason(reason)
    if (!row) return []
    return this.approvalLogs
      .filter((l) => l.requestId === row.id)
      .sort((a, b) => a.step - b.step)
      .map((l) => ({ step: l.step, approverName: l.approverName, action: l.action, resultStatus: l.resultStatus }))
  }

  payrollRow(employeeId: number, payMonth: string): PayRow | undefined {
    return this.payrolls.find((p) => p.employeeId === employeeId && p.payMonth === payMonth)
  }

  /**
   * 该账号「今天」是否已有种子考勤。
   *
   * 存在的唯一理由：`onClockIn` 与后端一样按 `workDate === localDate()` 判重，
   * 命中就返回 400「今日已完成上班打卡」。PAYROLL_MONTH 的两条记录日期是固定的，
   * 万一运行日正好撞上其中一天（2026-11-11 / 13），签到用例必须显式跳过而不是假红。
   */
  hasTodayRecord(username: DemoAccount): boolean {
    const empId = this.account(username).employeeId
    const today = localDate()
    return this.attendance.some((r) => r.employeeId === empId && r.workDate === today)
  }

  /** 打开后，下一个 /auth/me 会带 X-Renewed-Token，用于验证前端滑动续期分支。 */
  enableRenewToken(token: string): void {
    this.renewToken = token
  }

  /** 模拟服务端重启 / 密钥轮换：所有已签发 Token 立刻失效。 */
  invalidateTokens(): void {
    this.tokens.clear()
  }

  reset(): void {
    this.tokens.clear()
    this.failures.clear()
    this.unmatched.length = 0
    this.renewToken = null
  }

  /* ------------------------------------------------------------ 挂载与分发 */

  attach(target: Pick<BrowserContext, 'route'>): void {
    void target.route('**/api/v1/**', (route) => this.dispatch(route))
  }

  private nextId(): number {
    this.seq += 1
    return this.seq
  }

  private pushRequest(partial: Partial<ReqRow> & { employeeId: number; category: string; subType: string; startTime: string; endTime: string; duration: number; reason: string; status: string }): ReqRow {
    const e = this.employee(partial.employeeId)
    const row: ReqRow = {
      id: this.nextId(),
      employeeId: e.id,
      empNo: e.empNo,
      empName: e.name,
      deptName: e.deptName,
      category: partial.category,
      subType: partial.subType,
      startTime: partial.startTime,
      endTime: partial.endTime,
      duration: partial.duration,
      reason: partial.reason,
      status: partial.status,
      approverId: partial.approverId ?? 0,
      approverName: partial.approverName ?? '',
      approveRemark: partial.approveRemark ?? '',
      approvedAt: partial.approvedAt ?? '',
      createdAt: partial.createdAt ?? nowStamp(),
      // 与后端一致：这三项是「按查看者现算」的出参，落库前的占位值无意义
      currentLevel: reqCurrentLevel(partial.status),
      myAction: '',
      approvalTrail: []
    }
    this.requests.push(row)
    return row
  }

  /** 取某单据的审批链出参（对应 reqTrailJsonFor，按 step 升序）。 */
  private trailOf(reqId: number): ApprovalTrailItem[] {
    return this.approvalLogs
      .filter((l) => l.requestId === reqId)
      .sort((a, b) => a.step - b.step)
      .map((l) => ({
        step: l.step,
        approverName: l.approverName,
        approverRole: l.approverRole,
        action: l.action,
        resultStatus: l.resultStatus,
        remark: l.remark,
        at: l.createdAt
      }))
  }

  /**
   * 按当前查看者补出 currentLevel / myAction / approvalTrail 三键。
   *
   * 后端 handleRequestList 里 MANAGER 已被 SQL 限定为本部门，所以 sameDept 传 true；
   * handleRequestMy 则恒不给 myAction（本人不能审自己的单）。
   */
  private decorateRequest(row: ReqRow, account: Account, allowAct: boolean): ReqRow {
    return {
      ...row,
      currentLevel: reqCurrentLevel(row.status),
      myAction: allowAct && reqCanActStep(row.status, account.role, true) ? 'APPROVE' : '',
      approvalTrail: this.trailOf(row.id)
    }
  }

  private pushAttendance(partial: { employeeId: number; workDate: string; clockInTime: string; clockOutTime: string; lateMinutes: number; status: string; earlyMinutes?: number; remark?: string }): AttRow {
    const e = this.employee(partial.employeeId)
    const row: AttRow = {
      id: this.nextId(),
      employeeId: e.id,
      empNo: e.empNo,
      empName: e.name,
      deptName: e.deptName,
      workDate: partial.workDate,
      clockInTime: partial.clockInTime,
      clockOutTime: partial.clockOutTime,
      lateMinutes: partial.lateMinutes,
      earlyMinutes: partial.earlyMinutes ?? 0,
      status: partial.status,
      remark: partial.remark ?? ''
    }
    this.attendance.push(row)
    return row
  }

  private profile(a: Account): UserProfile {
    const e = this.employee(a.employeeId)
    // isActive 与后端 `auth_controller.cj:34` 的 `${r[4] == "1"}` 对齐，是布尔（缺陷 L-FE-3 已修）。
    return {
      id: a.userId,
      username: a.username,
      role: a.role,
      employeeId: e.id,
      isActive: a.isActive,
      name: e.name,
      empNo: e.empNo,
      deptId: e.deptId,
      deptName: e.deptName,
      positionName: e.positionName,
      phone: e.phone,
      email: e.email,
      empStatus: e.empStatus,
      annualLeaveBalance: e.annualLeaveBalance,
      hireDate: e.hireDate,
      contractEndDate: e.contractEndDate,
      baseSalary: e.baseSalary
    }
  }

  private dispatch(route: Route): void {
    const req = route.request()
    const url = new URL(req.url())
    const path = url.pathname.replace(/^\/api\/v1/, '')
    const method = req.method()
    // 注意：headerValue() 返回 Promise，dispatch 是同步分发，必须用同步的 headers()。
    const authHeader = req.headers()['authorization'] ?? ''
    const bearer = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : ''

    let account: Account | null = null
    let authFailure: string | null = null
    if (!bearer) {
      authFailure = '未登录或 Token 缺失'
    } else {
      const username = this.tokens.get(bearer)
      if (!username) {
        authFailure = '登录已过期或 Token 无效'
      } else {
        const found = this.accounts.find((a) => a.username === username) ?? null
        if (!found || !found.isActive) {
          authFailure = '账号已被禁用或不存在'
        } else {
          account = found
        }
      }
    }

    let body: Json = {}
    const raw = req.postData()
    if (raw) {
      try {
        const parsed: unknown = JSON.parse(raw)
        if (parsed && typeof parsed === 'object') body = parsed as Json
      } catch {
        this.reply(route, { status: 400, body: envelope(400, '请求体 JSON 格式错误', null) })
        return
      }
    }

    const call: Call = { method, path, query: url.searchParams, body, account, authFailure }
    const hit = this.route(call)
    if (!hit) {
      this.unmatched.push(`${method} ${url.pathname}${url.search}`)
      this.reply(route, { status: 404, body: envelope(404, `mock 未实现的接口：${method} ${path}`, null) })
      return
    }
    this.reply(route, hit)
  }

  private reply(route: Route, reply: Reply): void {
    void route
      .fulfill({
        status: reply.status,
        contentType: 'application/json; charset=utf-8',
        headers: reply.headers,
        body: JSON.stringify(reply.body)
      })
      .catch(() => {
        /* 页面导航导致请求被取消时忽略 */
      })
  }

  private route(call: Call): Reply | null {
    const { method, path } = call
    let m: RegExpMatchArray | null

    /* ---------- 认证 ---------- */
    if (method === 'POST' && path === '/auth/login') return this.onLogin(call)
    if (method === 'GET' && path === '/auth/me') return this.needAuth(call, () => this.onMe(call))
    if (method === 'PUT' && path === '/auth/password') return this.needAuth(call, () => this.onPassword(call))

    /* ---------- 工作台 ---------- */
    if (method === 'GET' && path === '/dashboard/overview') return this.needAuth(call, () => this.onOverview())

    /* ---------- 考勤 ---------- */
    if (method === 'GET' && path === '/attendance/today') return this.needAuth(call, () => this.onToday(call))
    if (method === 'POST' && path === '/attendance/clock-in') return this.needAuth(call, () => this.onClockIn(call))
    if (method === 'POST' && path === '/attendance/clock-out') return this.needAuth(call, () => this.onClockOut(call))
    if (method === 'GET' && path === '/attendance/my') return this.needAuth(call, () => this.onMyAttendance(call))
    if (method === 'GET' && path === '/attendance') return this.needRoles(call, ['ADMIN', 'HR', 'MANAGER'], () => this.onAttendanceList(call))
    // P2.4：精确路径必须排在 /^\/attendance\/(\d+)$/ 之前，否则 monthly-summary 会被当成 id 解析
    if (method === 'GET' && path === '/attendance/monthly-summary') return this.needRoles(call, ['ADMIN', 'HR', 'MANAGER'], () => this.onMonthlySummary(call))
    if (method === 'PUT' && (m = path.match(/^\/attendance\/(\d+)$/))) return this.needRoles(call, ['ADMIN', 'HR'], () => this.onAttendanceUpdate(call, Number((m as RegExpMatchArray)[1])))

    /* ---------- 假勤申请与审批 ---------- */
    if (method === 'POST' && path === '/requests') return this.needAuth(call, () => this.onCreateRequest(call))
    if (method === 'GET' && path === '/requests/my') return this.needAuth(call, () => this.onMyRequests(call))
    if (method === 'GET' && path === '/requests') return this.needRoles(call, ['ADMIN', 'HR', 'MANAGER'], () => this.onRequestList(call))
    if (method === 'POST' && (m = path.match(/^\/requests\/(\d+)\/cancel$/))) return this.needAuth(call, () => this.onCancelRequest(call, Number((m as RegExpMatchArray)[1])))
    if (method === 'POST' && (m = path.match(/^\/requests\/(\d+)\/approve$/))) return this.needRoles(call, ['ADMIN', 'HR', 'MANAGER'], () => this.onApproveRequest(call, Number((m as RegExpMatchArray)[1])))

    /* ---------- 薪酬 ---------- */
    if (method === 'POST' && path === '/payrolls/generate') return this.needRoles(call, ['ADMIN', 'HR'], () => this.onGenerate(call))
    if (method === 'POST' && path === '/payrolls/batch-pay') return this.needRoles(call, ['ADMIN', 'HR'], () => this.onBatchPay(call))
    if (method === 'GET' && path === '/payrolls/my') return this.needAuth(call, () => this.onMyPayrolls(call))
    if (method === 'GET' && path === '/payrolls') return this.needRoles(call, ['ADMIN', 'HR'], () => this.onPayrollList(call))
    if (method === 'POST' && (m = path.match(/^\/payrolls\/(\d+)\/pay$/))) return this.needRoles(call, ['ADMIN', 'HR'], () => this.onPaySingle(call, Number((m as RegExpMatchArray)[1])))
    if (method === 'PUT' && (m = path.match(/^\/payrolls\/(\d+)$/))) return this.needRoles(call, ['ADMIN', 'HR'], () => this.onPayrollUpdate(call, Number((m as RegExpMatchArray)[1])))

    /* ---------- 组织架构与系统管理（rbac-menu 用例触达，契约见 org_controller / system_controller） ---------- */
    if (method === 'GET' && path === '/departments/tree') return this.needAuth(call, () => this.onDeptTree())
    if (method === 'GET' && path === '/positions') return this.needAuth(call, () => this.onPositions(call))
    if (method === 'GET' && path === '/system/users') return this.needRoles(call, ['ADMIN'], () => this.onSystemUsers())
    if (method === 'GET' && path === '/system/audit-logs') return this.needRoles(call, ['ADMIN'], () => this.onAuditLogs(call))

    /* ---------- 员工档案与批量导入（import 用例触达，契约见 employee_controller） ---------- */
    if (method === 'GET' && path === '/employees') return this.needRoles(call, ['ADMIN', 'HR', 'MANAGER'], () => this.onEmployeeList(call))
    // 精确路径必须排在 /employees/{id} 之类的正则之前，否则 import 会被当成 id 解析
    if (method === 'POST' && path === '/employees/import') return this.needRoles(call, ['ADMIN', 'HR'], () => this.onEmployeeImport(call))

    return null
  }

  /* ------------------------------------------------------------ 守卫包装 */

  private needAuth(call: Call, next: () => Reply): Reply {
    if (call.authFailure) return err(401, call.authFailure)
    return next()
  }

  private needRoles(call: Call, roles: string[], next: () => Reply): Reply {
    if (call.authFailure) return err(401, call.authFailure)
    if (!roles.includes((call.account as Account).role)) return err(403, '权限不足，禁止访问该接口')
    return next()
  }

  /* ------------------------------------------------- 员工档案（列表 + 批量导入）
   *
   * 镜像 employee_controller.cj：employeeRowToJson 的 20 个输出字段、
   * doEmployeeImport 的解析/剔空行/表头匹配/逐行校验/整批事务语义。
   * 校验分支与错误文案逐字对齐（field 与 reason 都会被 E2E 断言）。
   * -------------------------------------------------------------- */

  /** 与后端 maskIdCard 同口径：前 6 后 4 保留，中间打星；<=10 字符原样返回。 */
  private maskIdCard(raw: string): string {
    const s = raw.trim()
    if (s.length <= 8) return s
    const chars = [...s]
    if (chars.length <= 10) return s
    return chars.map((c, i) => (i < 6 || i >= chars.length - 4 ? c : '*')).join('')
  }

  /** 输出字段名严格等于 employeeRowToJson；idCard 出参即已脱敏。 */
  private employeeRowJson(e: Employee) {
    return {
      id: e.id,
      empNo: e.empNo,
      name: e.name,
      gender: e.gender ?? 1,
      phone: e.phone,
      email: e.email ?? '',
      idCard: this.maskIdCard(e.idCard ?? ''),
      deptId: e.deptId,
      deptName: e.deptName,
      positionId: e.positionId ?? 0,
      positionName: e.positionName,
      baseSalary: e.baseSalary,
      annualLeaveBalance: e.annualLeaveBalance,
      hireDate: e.hireDate,
      probationEndDate: e.probationEndDate ?? '',
      contractEndDate: e.contractEndDate,
      resignDate: e.resignDate ?? '',
      resignReason: e.resignReason ?? '',
      status: e.empStatus,
      createdAt: e.createdAt ?? `${e.hireDate} 10:00:00`
    }
  }

  private onEmployeeList(call: Call): Reply {
    const account = call.account as Account
    const page0 = Number(call.query.get('page') ?? 1)
    const size0 = Number(call.query.get('pageSize') ?? 10)
    // 与后端一致：非法分页参数静默回落到默认值，而不是报错
    const page = page0 < 1 ? 1 : page0
    const pageSize = size0 < 1 || size0 > 100 ? 10 : size0
    const keyword = (call.query.get('keyword') ?? '').trim()
    const status = (call.query.get('status') ?? '').trim()
    const deptId = Number(call.query.get('deptId') ?? 0)

    let rows = [...this.employees]
    if (account.role === 'MANAGER') {
      // MANAGER 只看本部门，且请求里的 deptId 一律忽略（后端 elif 就是这个语义）
      rows = rows.filter((e) => e.deptId === this.employee(account.employeeId).deptId)
    } else if (deptId > 0) {
      rows = rows.filter((e) => e.deptId === deptId)
    }
    if (status) rows = rows.filter((e) => e.empStatus === status)
    if (keyword) {
      rows = rows.filter((e) => e.name.includes(keyword) || e.empNo.includes(keyword) || e.phone.includes(keyword))
    }
    rows.sort((a, b) => b.id - a.id)
    const total = rows.length
    return ok(pageData(rows.slice((page - 1) * pageSize, page * pageSize).map((e) => this.employeeRowJson(e)), total, page, pageSize))
  }

  /** 与 parseCsvInto/csvSplitRows 同语义：引号、"" 转义、引号内换行不分行、CRLF/CR/LF 均可。 */
  private parseCsv(text: string): { rows: string[][]; lines: number[] } {
    const rows: string[][] = []
    const lines: number[] = []
    let row: string[] = []
    let field = ''
    let inQuotes = false
    let line = 1
    let rowStart = 1
    // 后端剥 UTF-8 BOM，这里同口径，否则第一列表头永远匹配不上
    const body = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text
    for (let i = 0; i < body.length; i++) {
      const ch = body[i]
      if (ch === '\r' || ch === '\n') {
        const pair = ch === '\r' && body[i + 1] === '\n'
        if (inQuotes) {
          field += ch
          if (pair) {
            field += '\n'
            i += 1
          }
          line += 1
          continue
        }
        if (pair) i += 1
        row.push(field)
        rows.push(row)
        lines.push(rowStart)
        row = []
        field = ''
        line += 1
        rowStart = line
        continue
      }
      if (inQuotes) {
        if (ch === '"') {
          if (body[i + 1] === '"') {
            field += '"'
            i += 1
          } else {
            inQuotes = false
          }
        } else {
          field += ch
        }
        continue
      }
      if (ch === '"') inQuotes = true
      else if (ch === ',') {
        row.push(field)
        field = ''
      } else field += ch
    }
    if (field !== '' || row.length > 0) {
      row.push(field)
      rows.push(row)
      lines.push(rowStart)
    }
    return { rows, lines }
  }

  /** 与后端 empImportHeader 逐字一致。 */
  private importHeader(): string[] {
    return ['工号', '姓名', '性别', '手机号', '邮箱', '身份证号', '部门', '岗位', '基本薪资', '年假余额', '入职日期', '合同到期日期', '状态']
  }

  private cell(row: string[], idx: number): string {
    return idx < 0 || idx >= row.length ? '' : (row[idx] ?? '').trim()
  }

  private importGender(raw: string): number {
    const s = raw.trim().toUpperCase()
    if (s === '1' || s === '男' || s === 'M' || s === 'MALE') return 1
    if (s === '2' || s === '女' || s === 'F' || s === 'FEMALE') return 2
    return 0
  }

  private importStatus(raw: string): string {
    const s = raw.trim().toUpperCase()
    if (s === 'ACTIVE' || s === '在职') return 'ACTIVE'
    if (s === 'PROBATION' || s === '试用期') return 'PROBATION'
    if (s === 'RESIGNED' || s === '离职') return 'RESIGNED'
    return ''
  }

  private validYmd(s: string): boolean {
    return /^\d{4}-\d{2}-\d{2}$/.test(s)
  }

  private onEmployeeImport(call: Call): Reply {
    const csv = String(call.body.csv ?? '')
    const dryRun = Boolean(call.body.dryRun)
    if (!csv.trim()) return err(400, 'CSV 内容不能为空')
    const { rows: parsed, lines: allLines } = this.parseCsv(csv)
    if (parsed.length < 1) return err(400, 'CSV 至少需要表头与一条数据')
    // 后端 csvRowIsBlank：整行全空的记录直接剔掉，行号同步剔除，避免刷出成堆「不能为空」
    const rows: string[][] = []
    const lines: number[] = []
    for (let i = 0; i < parsed.length; i++) {
      if (!parsed[i].every((c) => c.trim() === '')) {
        rows.push(parsed[i])
        lines.push(allLines[i])
      }
    }
    const dataCount = Math.max(rows.length - 1, 0)
    if (dataCount === 0) return err(400, 'CSV 至少需要表头与一条数据')
    if (dataCount > 500) return err(400, `单次最多导入 500 行，当前 ${dataCount} 行`)

    const header = rows[0].map((h) => h.trim())
    const missing = this.importHeader().filter((c) => !header.includes(c))
    if (header.length < 13 && missing.length === 13) return err(400, '未匹配到任何模板列名，请使用系统提供的模板')
    const col = (name: string): number => header.indexOf(name)

    const deptNames = this.departments.map((d) => d.deptName)
    const existingEmpNos = this.employees.map((e) => e.empNo)
    const fileEmpNos: string[] = []
    const accepted: number[] = []
    const failed: { row: number; field: string; reason: string }[] = []

    for (let ridx = 1; ridx < rows.length; ridx++) {
      const row = rows[ridx]
      const lineNo = lines[ridx]
      const before = failed.length
      let okRow = true
      const push = (field: string, reason: string): void => {
        failed.push({ row: lineNo, field, reason })
        okRow = false
      }
      const empNo = this.cell(row, col('工号'))
      const name = this.cell(row, col('姓名'))
      const phone = this.cell(row, col('手机号'))
      const deptName = this.cell(row, col('部门'))
      const posName = this.cell(row, col('岗位'))
      const hireDate = this.cell(row, col('入职日期'))

      if (empNo === '') push('工号', '不能为空')
      else if ([...empNo].length > 32) push('工号', '长度超过 32 字符')
      else if (fileEmpNos.includes(empNo)) push('工号', `工号 ${empNo} 在本次文件内重复`)
      else if (existingEmpNos.includes(empNo)) push('工号', `工号 ${empNo} 已存在于系统，导入不覆盖已有档案`)

      if (name === '') push('姓名', '不能为空')
      else if ([...name].length > 64) push('姓名', '长度超过 64 字符')

      if (phone !== '' && !/^\d+$/.test(phone)) push('手机号', '手机号只能由数字组成')
      if (phone === '') push('手机号', '不能为空')

      if (deptName !== '' && !deptNames.includes(deptName)) push('部门', `部门「${deptName}」不存在，请先在组织架构中创建`)
      if (deptName === '') push('部门', '不能为空')

      if (posName === '') push('岗位', '不能为空')
      if (hireDate === '') push('入职日期', '不能为空')
      else if (!this.validYmd(hireDate)) push('入职日期', `日期格式应为 YYYY-MM-DD，实际为「${hireDate}」`)

      const genderRaw = this.cell(row, col('性别'))
      if (genderRaw !== '' && this.importGender(genderRaw) === 0) push('性别', '只接受 1/2 或 男/女')

      const salaryRaw = this.cell(row, col('基本薪资'))
      if (salaryRaw !== '' && !(Number(salaryRaw) >= 0)) push('基本薪资', '不是合法数字')

      const contractRaw = this.cell(row, col('合同到期日期'))
      if (contractRaw !== '' && !this.validYmd(contractRaw)) push('合同到期日期', `日期格式应为 YYYY-MM-DD，实际为「${contractRaw}」`)

      const statusRaw = this.cell(row, col('状态'))
      if (statusRaw !== '' && this.importStatus(statusRaw) === '') push('状态', '只接受 PROBATION/ACTIVE/RESIGNED 或 试用期/在职/离职')

      const idCard = this.cell(row, col('身份证号'))
      if (idCard !== '' && [...idCard].length !== 15 && [...idCard].length !== 18) push('身份证号', '长度应为 15 或 18 位')

      const email = this.cell(row, col('邮箱'))
      if (email !== '' && !email.includes('@')) push('邮箱', '缺少 @ 符号')

      // 后端契约：返回 false 必然写过至少一条错误，否则视为校验器内部异常
      if (!okRow && failed.length === before) push('整行', '校验器内部异常，请改用单条入职登记')
      if (okRow) {
        accepted.push(ridx)
        fileEmpNos.push(empNo)
      }
    }

    const failedRows = rows.length - 1 - accepted.length
    if (failedRows > 0) {
      return okMsg(`校验未通过 ${failedRows} 行，整批未写入`, {
        total: dataCount, successCount: accepted.length, failedCount: failedRows, imported: 0, dryRun, failed
      })
    }
    if (dryRun) {
      return okMsg(`试运行通过 ${accepted.length} 行，未写入`, {
        total: dataCount, successCount: accepted.length, failedCount: 0, imported: 0, dryRun, failed
      })
    }
    for (const ridx of accepted) {
      const row = rows[ridx]
      const empNo = this.cell(row, col('工号'))
      const deptName = this.cell(row, col('部门'))
      const dept = this.departments.find((d) => d.deptName === deptName) as DeptSeed
      const employee: Employee = {
        id: this.nextId(),
        empNo,
        name: this.cell(row, col('姓名')),
        deptId: dept.id,
        deptName,
        positionName: this.cell(row, col('岗位')),
        baseSalary: Number(this.cell(row, col('基本薪资')) || 8000),
        annualLeaveBalance: Number(this.cell(row, col('年假余额')) || 5),
        hireDate: this.cell(row, col('入职日期')),
        contractEndDate: this.cell(row, col('合同到期日期')),
        empStatus: this.importStatus(this.cell(row, col('状态'))) || 'PROBATION',
        phone: this.cell(row, col('手机号')),
        email: this.cell(row, col('邮箱')),
        gender: this.importGender(this.cell(row, col('性别'))) || 1,
        idCard: this.cell(row, col('身份证号'))
      }
      this.employees.push(employee)
    }
    // 后端 persistImport 还在同一事务里 INSERT INTO sys_user（按工号开通登录账号）并写审计日志。
    // 这两项在本页面对前端完全不可观测，而 this.accounts / this.auditLogs 的元素类型是
    // 4 个演示账号与静态审计行的封闭集合（username: DemoAccount），塞进导入出来的工号
    // 会同时破坏 GET /system/users 与 /system/audit-logs 既有用例的计数断言。
    // 故刻意不模拟，改由 api-smoke.ps1 的 112 个断言点在真实库上核对账号是否开通。
    return okMsg(`导入成功 ${accepted.length} 条`, {
      total: dataCount, successCount: accepted.length, failedCount: 0, imported: accepted.length, dryRun, failed
    })
  }

  /* -------------------------------------------------------------- 认证 */

  private onLogin(call: Call): Reply {
    const username = String(call.body.username ?? '').trim()
    const password = String(call.body.password ?? '')
    if (!username || !password) return err(400, '请输入账号和密码')

    const account = this.accounts.find((a) => a.username === username)
    const used = this.failures.get(username) ?? 0
    if (!account || password !== DEMO_PASSWORD) {
      const remain = Math.max(0, 5 - used - 1)
      this.failures.set(username, used + 1)
      return err(400, `账号或密码错误（剩余尝试 ${remain} 次）`)
    }
    if (!account.isActive) return err(403, '账号已被禁用，请联系管理员')

    this.failures.delete(username)
    this.tokens.set(`mock-jwt-${account.userId}`, username)
    return ok({ token: `mock-jwt-${account.userId}`, user: this.profile(account) })
  }

  private onMe(call: Call): Reply {
    const account = call.account as Account
    const body = envelope(200, 'success', this.profile(account))
    const headers: Record<string, string> = {}
    if (this.renewToken) {
      headers['X-Renewed-Token'] = this.renewToken
      this.tokens.set(this.renewToken, account.username)
      this.renewToken = null
    }
    return { status: 200, body, headers }
  }

  private onPassword(call: Call): Reply {
    const oldPwd = String(call.body.oldPassword ?? '')
    const newPwd = String(call.body.newPassword ?? '')
    if (!oldPwd || newPwd.length < 6) return err(400, '新密码长度不能少于 6 位')
    if (oldPwd !== DEMO_PASSWORD && oldPwd !== 'Newpass123') return err(400, '原密码不正确')
    return okMsg('密码修改成功', null)
  }

  /* -------------------------------------------------------------- 工作台 */

  private onOverview(): Reply {
    const today = localDate()
    const clockedIn = this.attendance.filter((r) => r.workDate === today && r.clockInTime).length
    const active = this.employees.filter((e) => e.empStatus !== 'RESIGNED')
    const expiring = [
      { empNo: 'EMP20260004', name: '陈思远', deptName: '技术研发中心', positionName: '仓颉后端工程师', contractEndDate: '2026-12-15', daysLeft: 22 }
    ]
    const deptMap = new Map<string, number>()
    const statusMap = new Map<string, number>()
    for (const e of active) {
      deptMap.set(e.deptName, (deptMap.get(e.deptName) ?? 0) + 1)
      statusMap.set(e.empStatus, (statusMap.get(e.empStatus) ?? 0) + 1)
    }
    return ok({
      kpis: {
        totalActiveEmployees: active.length,
        monthlyHires: 1,
        monthlyResigns: 0,
        todayClockedIn: clockedIn,
        todayAttendanceRate: active.length ? round2((clockedIn / active.length) * 100) : 0,
        pendingApprovals: this.requests.filter((r) => reqIsPendingLike(r.status)).length,
        expiringContractsCount: expiring.length
      },
      expiringContracts: expiring,
      deptDistribution: [...deptMap.entries()].map(([deptName, count]) => ({ deptName, count })),
      statusDistribution: [...statusMap.entries()].map(([status, count]) => ({ status, count })),
      attendanceTrend: [4, 3, 2, 1, 0].map((back) => ({
        date: localDate(-back),
        clockedIn: back === 0 ? clockedIn : 3,
        normalCount: back === 0 ? Math.max(0, clockedIn - 1) : 2
      })),
      payrollTrend: [
        { payMonth: '2026-09', totalNetSalary: 86000 },
        { payMonth: '2026-10', totalNetSalary: 91000 },
        { payMonth: PAYROLL_MONTH, totalNetSalary: round2(this.payrolls.filter((p) => p.payMonth === PAYROLL_MONTH).reduce((s, p) => s + p.netSalary, 0)) }
      ]
    })
  }

  /* -------------------------------------------------------------- 考勤 */

  private todayRow(call: Call): AttRow | undefined {
    const empId = (call.account as Account).employeeId
    return this.attendance.find((r) => r.employeeId === empId && r.workDate === localDate())
  }

  private onToday(call: Call): Reply {
    return ok(this.todayRow(call) ?? null)
  }

  private onClockIn(call: Call): Reply {
    const empId = (call.account as Account).employeeId
    const existing = this.todayRow(call)
    if (existing && existing.clockInTime) {
      return err(400, `今日已完成上班打卡（${existing.clockInTime}）`)
    }
    // 与后端一致：以 09:00 为界计算迟到分钟数，用运行时刻决定 NORMAL / LATE
    const now = new Date()
    const minutes = now.getHours() * 60 + now.getMinutes()
    const late = Math.max(0, minutes - 9 * 60)
    const stamp = `${localDate()} ${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`
    if (!existing) {
      this.pushAttendance({ employeeId: empId, workDate: localDate(), clockInTime: stamp, clockOutTime: '', lateMinutes: late, status: late > 0 ? 'LATE' : 'NORMAL' })
    } else {
      existing.clockInTime = stamp
      existing.lateMinutes = late
      existing.status = late > 0 ? 'LATE' : 'NORMAL'
    }
    return ok(this.todayRow(call) ?? null)
  }

  private onClockOut(call: Call): Reply {
    const empId = (call.account as Account).employeeId
    const row = this.todayRow(call)
    const now = new Date()
    const minutes = now.getHours() * 60 + now.getMinutes()
    const early = Math.max(0, 18 * 60 - minutes)
    const stamp = `${localDate()} ${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`
    if (!row) {
      // 后端允许「未签到直接签退」，会插一条只有签退时间的记录
      this.pushAttendance({ employeeId: empId, workDate: localDate(), clockInTime: '', clockOutTime: stamp, lateMinutes: 0, earlyMinutes: early, status: early > 0 ? 'EARLY_LEAVE' : 'NORMAL' })
    } else {
      row.clockOutTime = stamp
      row.earlyMinutes = early
      const late = row.lateMinutes > 0
      row.status = late && early > 0 ? 'LATE_AND_EARLY' : late ? 'LATE' : early > 0 ? 'EARLY_LEAVE' : 'NORMAL'
    }
    return ok(this.todayRow(call) ?? null)
  }

  /**
   * 迟到判定：分钟数 > 0 或状态标记为迟到。
   * 镜像 attendance_controller.cj 的 attMonthIsLate —— 「我的考勤」与「月度汇总」
   * 必须共用同一判定，否则同一条记录会在两个页面给出不同结论。
   */
  private attIsLate(lateMinutes: number, status: string): boolean {
    return lateMinutes > 0 || status === 'LATE' || status === 'LATE_AND_EARLY'
  }

  /** 早退判定：镜像 attMonthIsEarly，后端写的是 EARLY_LEAVE（不是前端旧代码里的 EARLY）。 */
  private attIsEarly(earlyMinutes: number, status: string): boolean {
    return earlyMinutes > 0 || status === 'EARLY_LEAVE' || status === 'LATE_AND_EARLY'
  }

  /** 出勤率（百分数）：镜像 attendanceRatePercent，应出勤 <= 0 归 0，超过 100% 封顶。 */
  private attRatePercent(attendDays: number, shouldDays: number): number {
    if (shouldDays <= 0) return 0
    const rate = (attendDays * 100) / shouldDays
    if (rate < 0) return 0
    if (rate > 100) return 100
    return round2(rate)
  }

  /** 镜像 isValidYearMonth：长度 7、第 5 位是 '-'、年首位 2、数字位全为 0-9、月份 01-12。 */
  private isYearMonth(s: string): boolean {
    return /^2\d{3}-(0[1-9]|1[0-2])$/.test(s)
  }

  private onMyAttendance(call: Call): Reply {
    const empId = (call.account as Account).employeeId
    const rawMonth = (call.query.get('month') || '').trim()
    const month = this.isYearMonth(rawMonth) ? rawMonth : utcMonth()
    const rows = this.attendance
      .filter((r) => r.employeeId === empId && r.workDate.slice(0, 7) === month)
      .sort((a, b) => (a.workDate < b.workDate ? 1 : a.workDate > b.workDate ? -1 : 0))
    let lateCount = 0
    let earlyCount = 0
    let attendDays = 0
    for (const r of rows) {
      if (this.attIsLate(r.lateMinutes, r.status)) lateCount += 1
      if (this.attIsEarly(r.earlyMinutes, r.status)) earlyCount += 1
      // 缺勤当天有记录，但不计入出勤，与月度汇总同口径。
      if (r.status !== 'ABSENT') attendDays += 1
    }
    const sum = (category: string) =>
      this.requests
        .filter((r) => r.employeeId === empId && r.category === category && r.status === 'APPROVED' && r.startTime.slice(0, 7) === month)
        .reduce((s, r) => s + r.duration, 0)
    return ok({
      list: rows,
      summary: {
        month,
        shouldAttendDays: ATT_SHOULD_ATTEND_DAYS,
        actualAttendDays: attendDays,
        lateCount,
        earlyCount,
        leaveDays: round2(sum('LEAVE')),
        overtimeHours: round2(sum('OVERTIME'))
      }
    })
  }

  /* -------------------------------------------------------- P2.4 月度汇总
   *
   * 逐条镜像 handleAttendanceMonthlySummary：
   * 1. 主表是「员工」而不是「考勤记录」——整月一次卡都没打的人必须以 0 天出勤出现在报表里，
   *    否则以考勤表为主表会把这类人整行隐藏，出勤率反而虚高。
   * 2. status = 'RESIGNED' 的员工不参与统计。
   * 3. ABSENT 有记录但不算出勤天数。
   * 4. 请假 / 加班只统计 APPROVED，且按 start_time 所在月归类。
   * 5. MANAGER 强制限定本部门，deptId 参数只对 ADMIN / HR 生效。
   * 6. 合计行由明细行累加得到（不是重新查一遍），保证「合计 = 明细之和」。
   * -------------------------------------------------------------- */

  private onMonthlySummary(call: Call): Reply {
    const account = call.account as Account
    const rawMonth = (call.query.get('month') || '').trim()
    const month = this.isYearMonth(rawMonth) ? rawMonth : utcMonth()
    const deptId = Number(call.query.get('deptId') || 0)

    let emps = this.employees.filter((e) => e.empStatus !== 'RESIGNED')
    if (account.role === 'MANAGER') {
      const myDept = this.employee(account.employeeId).deptId
      emps = emps.filter((e) => e.deptId === myDept)
    } else if (deptId > 0) {
      emps = emps.filter((e) => e.deptId === deptId)
    }

    const list = emps
      .map((e) => {
        const rows = this.attendance.filter((r) => r.employeeId === e.id && r.workDate.slice(0, 7) === month)
        let attendDays = 0
        let lateCount = 0
        let earlyCount = 0
        let lateMinutes = 0
        let earlyMinutes = 0
        for (const r of rows) {
          if (r.status !== 'ABSENT') attendDays += 1
          if (this.attIsLate(r.lateMinutes, r.status)) lateCount += 1
          if (this.attIsEarly(r.earlyMinutes, r.status)) earlyCount += 1
          lateMinutes += r.lateMinutes
          earlyMinutes += r.earlyMinutes
        }
        const sum = (category: string) =>
          this.requests
            .filter((r) => r.employeeId === e.id && r.category === category && r.status === 'APPROVED' && r.startTime.slice(0, 7) === month)
            .reduce((s, r) => s + r.duration, 0)
        const leaveDays = round2(sum('LEAVE'))
        const overtimeHours = round2(sum('OVERTIME'))
        return {
          employeeId: e.id,
          empNo: e.empNo,
          empName: e.name,
          deptName: e.deptName,
          attendDays,
          lateCount,
          earlyCount,
          lateMinutes,
          earlyMinutes,
          leaveDays,
          overtimeHours,
          attendanceRate: this.attRatePercent(attendDays, ATT_SHOULD_ATTEND_DAYS)
        }
      })
      // ORDER BY d.dept_name ASC, e.emp_no ASC
      .sort((a, b) => (a.deptName === b.deptName ? a.empNo.localeCompare(b.empNo) : a.deptName < b.deptName ? -1 : 1))

    const totals = {
      headcount: list.length,
      shouldAttendDays: ATT_SHOULD_ATTEND_DAYS,
      actualAttendDays: list.reduce((s, r) => s + r.attendDays, 0),
      lateCount: list.reduce((s, r) => s + r.lateCount, 0),
      earlyCount: list.reduce((s, r) => s + r.earlyCount, 0),
      lateMinutes: list.reduce((s, r) => s + r.lateMinutes, 0),
      earlyMinutes: list.reduce((s, r) => s + r.earlyMinutes, 0),
      leaveDays: round2(list.reduce((s, r) => s + r.leaveDays, 0)),
      overtimeHours: round2(list.reduce((s, r) => s + r.overtimeHours, 0)),
      attendanceRate: this.attRatePercent(
        list.reduce((s, r) => s + r.attendDays, 0),
        list.length * ATT_SHOULD_ATTEND_DAYS
      )
    }

    return ok({ month, shouldAttendDays: ATT_SHOULD_ATTEND_DAYS, summary: totals, list })
  }

  private onAttendanceList(call: Call): Reply {
    // 后端读的是 month（YYYY-MM）；前端旧代码传的是 date，属真实缺陷，见 FOLLOWUP_PLAN L-FE-2
    const month = (call.query.get('month') || '').trim()
    const status = (call.query.get('status') || '').trim()
    const keyword = (call.query.get('keyword') || '').trim()
    const deptId = Number(call.query.get('deptId') || 0)
    const page = Math.max(1, Number(call.query.get('page') || 1))
    let pageSize = Number(call.query.get('pageSize') || 10)
    if (pageSize < 1 || pageSize > 100) pageSize = 10

    const account = call.account as Account
    let rows = [...this.attendance]
    if (account.role === 'MANAGER') {
      const myDept = this.employee(account.employeeId).deptId
      rows = rows.filter((r) => this.employee(r.employeeId).deptId === myDept)
    } else if (deptId > 0) {
      rows = rows.filter((r) => this.employee(r.employeeId).deptId === deptId)
    }
    if (month) rows = rows.filter((r) => r.workDate.slice(0, 7) === month)
    if (status) rows = rows.filter((r) => r.status === status)
    if (keyword) rows = rows.filter((r) => r.empName.includes(keyword) || r.empNo.includes(keyword))
    rows.sort((a, b) => (a.workDate === b.workDate ? b.id - a.id : a.workDate < b.workDate ? 1 : -1))
    const total = rows.length
    return ok(pageData(rows.slice((page - 1) * pageSize, page * pageSize), total, page, pageSize))
  }

  private onAttendanceUpdate(call: Call, attId: number): Reply {
    const row = this.attendance.find((r) => r.id === attId)
    if (!row) return err(404, '考勤记录不存在')
    row.status = String(call.body.status ?? 'NORMAL').trim()
    row.lateMinutes = Number(call.body.lateMinutes ?? 0)
    row.earlyMinutes = Number(call.body.earlyMinutes ?? 0)
    row.remark = String(call.body.remark ?? '').trim()
    return ok(null)
  }

  /* -------------------------------------------------------- 申请与审批 */

  private onCreateRequest(call: Call): Reply {
    const empId = (call.account as Account).employeeId
    const category = String(call.body.category ?? 'LEAVE').trim()
    const subType = String(call.body.subType ?? '').trim()
    const startTime = String(call.body.startTime ?? '').trim()
    const endTime = String(call.body.endTime ?? '').trim()
    const duration = Number(call.body.duration ?? 0)
    const reason = String(call.body.reason ?? '').trim()
    if (!subType || !startTime || !endTime || !(duration > 0) || !reason) {
      return err(400, '类型、开始时间、结束时间、时长与事由均不能为空')
    }
    const emp = this.employee(empId)
    if (category === 'LEAVE' && subType === 'ANNUAL' && emp.annualLeaveBalance < duration) {
      return err(400, `剩余年假天数不足（当前剩余 ${emp.annualLeaveBalance.toFixed(2)} 天）`)
    }
    const row = this.pushRequest({
      employeeId: empId,
      category,
      subType,
      startTime,
      endTime,
      duration,
      reason,
      status: reqInitialStatus(category, duration)
    })
    return ok({ id: row.id, status: row.status, currentLevel: reqCurrentLevel(row.status) })
  }

  private onMyRequests(call: Call): Reply {
    const account = call.account as Account
    const empId = account.employeeId
    const category = (call.query.get('category') || '').trim()
    let rows = this.requests.filter((r) => r.employeeId === empId)
    if (category) rows = rows.filter((r) => r.category === category)
    // 本人不能审自己的单：allowAct 恒 false，与后端 handleRequestMy 传空 myAction 一致
    return ok([...rows].sort((a, b) => b.id - a.id).map((r) => this.decorateRequest(r, account, false)))
  }

  private onRequestList(call: Call): Reply {
    const category = (call.query.get('category') || '').trim()
    const status = (call.query.get('status') || '').trim()
    const page = Math.max(1, Number(call.query.get('page') || 1))
    let pageSize = Number(call.query.get('pageSize') || 10)
    if (pageSize < 1 || pageSize > 100) pageSize = 10

    const account = call.account as Account
    let rows = [...this.requests]
    if (account.role === 'MANAGER') {
      const myDept = this.employee(account.employeeId).deptId
      rows = rows.filter((r) => this.employee(r.employeeId).deptId === myDept)
    }
    if (category) rows = rows.filter((r) => r.category === category)
    // 与后端 reqStatusCondition 同口径：传 PENDING 表示「任何一级待处理」
    if (status === 'PENDING') rows = rows.filter((r) => reqIsPendingLike(r.status))
    else if (status) rows = rows.filter((r) => r.status === status)
    rows.sort((a, b) => b.id - a.id)
    const total = rows.length
    const list = rows.slice((page - 1) * pageSize, page * pageSize).map((r) => this.decorateRequest(r, account, true))
    return ok(pageData(list, total, page, pageSize))
  }

  private onCancelRequest(call: Call, reqId: number): Reply {
    const account = call.account as Account
    const row = this.requests.find((r) => r.id === reqId)
    if (!row) return err(404, '申请单不存在')
    if (row.employeeId !== account.employeeId && account.role !== 'ADMIN') return err(403, '只能撤回本人提交的申请')
    if (!reqIsPendingLike(row.status)) return err(400, '仅待审批状态（含长假一级/二级）可以撤回')
    row.status = 'CANCELLED'
    return ok(null)
  }

  private onApproveRequest(call: Call, reqId: number): Reply {
    const account = call.account as Account
    const row = this.requests.find((r) => r.id === reqId)
    if (!row) return err(404, '审批单不存在')
    const sameDept = this.employee(row.employeeId).deptId === this.employee(account.employeeId).deptId
    if (account.role === 'MANAGER' && !sameDept) return err(403, '部门主管仅可审批本部门申请')
    if (!reqIsPendingLike(row.status)) return err(400, '该申请单已处理，无法重复审批')

    let action = String(call.body.action ?? '').trim()
    if (!action) action = String(call.body.status ?? '').trim()
    if (action !== 'APPROVED' && action !== 'REJECTED') return err(400, '审批动作必须为 APPROVED 或 REJECTED')
    if (!reqCanActStep(row.status, account.role, sameDept)) {
      return err(403, reqActionDeniedMessage(row.status, account.role, sameDept))
    }

    const remark = String(call.body.approveRemark ?? '').trim()
    const next = reqNextStatus(row.status, action)
    const emp = this.employee(row.employeeId)
    // 年假只在终态通过时扣一次：长假一级通过（PENDING_HR）绝不扣减
    if (reqShouldDeductAnnual(row.category, row.subType, next)) {
      if (emp.annualLeaveBalance < row.duration) {
        return err(400, `员工剩余年假不足（当前 ${emp.annualLeaveBalance.toFixed(2)} 天），无法审批通过`)
      }
      emp.annualLeaveBalance = round2(emp.annualLeaveBalance - row.duration)
    }
    // 步数必须在状态被改写之前取，否则二级会记成 step=0
    const step = reqCurrentLevel(row.status)
    row.status = next
    row.approverId = account.userId
    row.approverName = account.username
    row.approveRemark = remark
    row.approvedAt = nowStamp()
    this.approvalLogs.push({
      requestId: row.id,
      step,
      approverId: account.userId,
      approverName: account.username,
      approverRole: account.role,
      action,
      resultStatus: next,
      remark,
      createdAt: nowStamp()
    })
    return ok({
      id: row.id,
      status: next,
      action,
      currentLevel: step,
      nextLevel: reqCurrentLevel(next)
    })
  }

  /* -------------------------------------------------------------- 薪酬 */

  private onGenerate(call: Call): Reply {
    let payMonth = String(call.body.payMonth ?? '').trim()
    if (!payMonth) payMonth = utcMonth()
    let generated = 0
    for (const emp of this.employees.filter((e) => e.empStatus === 'ACTIVE' || e.empStatus === 'PROBATION')) {
      const existing = this.payrollRow(emp.id, payMonth)
      if (existing && existing.status === 'PAID') continue

      const dailySalary = emp.baseSalary / 21.75
      const hourlySalary = dailySalary / 8
      const inMonth = (startOrDate: string) => startOrDate.slice(0, 7) === payMonth
      const otHours = this.requests
        .filter((r) => r.employeeId === emp.id && r.category === 'OVERTIME' && r.status === 'APPROVED' && inMonth(r.startTime))
        .reduce((s, r) => s + r.duration, 0)
      const overtimePay = round2(otHours * hourlySalary * 1.5)
      const lateCnt = this.attendance.filter((r) => r.employeeId === emp.id && inMonth(r.workDate) && r.lateMinutes > 0).length
      const earlyCnt = this.attendance.filter((r) => r.employeeId === emp.id && inMonth(r.workDate) && r.earlyMinutes > 0).length
      const personalDays = this.requests
        .filter((r) => r.employeeId === emp.id && r.category === 'LEAVE' && r.subType === 'PERSONAL' && r.status === 'APPROVED' && inMonth(r.startTime))
        .reduce((s, r) => s + r.duration, 0)
      const attendanceDeduction = round2((lateCnt + earlyCnt) * 50 + personalDays * dailySalary)
      const perf = [...this.performances].reverse().find((p) => p.employeeId === emp.id && p.status === 'COMPLETED')
      const bonus = perf ? round2(emp.baseSalary * 0.1 * perf.bonusRatio) : 0
      const socialSecurity = round2(emp.baseSalary * 0.185)
      const [tax, netSalary] = calculatePayrollValues(emp.baseSalary, bonus, overtimePay, attendanceDeduction, socialSecurity)

      if (existing && existing.status === 'DRAFT') {
        existing.baseSalary = emp.baseSalary
        existing.bonus = bonus
        existing.overtimePay = overtimePay
        existing.attendanceDeduction = attendanceDeduction
        existing.socialSecurity = socialSecurity
        existing.tax = tax
        existing.netSalary = netSalary
      } else {
        this.payrolls.push({
          id: this.nextId(),
          employeeId: emp.id,
          empNo: emp.empNo,
          empName: emp.name,
          deptName: emp.deptName,
          positionName: emp.positionName,
          payMonth,
          baseSalary: emp.baseSalary,
          bonus,
          overtimePay,
          attendanceDeduction,
          socialSecurity,
          tax,
          netSalary,
          status: 'DRAFT',
          paidAt: '',
          remark: ''
        })
      }
      generated += 1
    }
    return ok({ payMonth, generatedCount: generated })
  }

  private toPayrollJson(p: PayRow): Json {
    return { ...p }
  }

  private onPayrollList(call: Call): Reply {
    const payMonth = (call.query.get('payMonth') || '').trim()
    const status = (call.query.get('status') || '').trim()
    const keyword = (call.query.get('keyword') || '').trim()
    const page = Math.max(1, Number(call.query.get('page') || 1))
    let pageSize = Number(call.query.get('pageSize') || 20)
    if (pageSize < 1 || pageSize > 100) pageSize = 20

    let rows = [...this.payrolls]
    if (payMonth) rows = rows.filter((r) => r.payMonth === payMonth)
    if (status) rows = rows.filter((r) => r.status === status)
    if (keyword) rows = rows.filter((r) => r.empName.includes(keyword) || r.empNo.includes(keyword))
    rows.sort((a, b) => (a.payMonth === b.payMonth ? b.id - a.id : a.payMonth < b.payMonth ? 1 : -1))
    const total = rows.length
    return ok(pageData(rows.map((r) => this.toPayrollJson(r)), total, page, pageSize))
  }

  private onPayrollUpdate(call: Call, payrollId: number): Reply {
    const row = this.payrolls.find((p) => p.id === payrollId)
    if (!row) return err(404, '工资单不存在')
    if (row.status === 'PAID') return err(400, '已发放工资单不可修改')
    const bonus = Number(call.body.bonus ?? row.bonus)
    const overtimePay = Number(call.body.overtimePay ?? row.overtimePay)
    const attDeduction = Number(call.body.attendanceDeduction ?? row.attendanceDeduction)
    const remark = String(call.body.remark ?? row.remark).trim()
    const [tax, netSalary] = calculatePayrollValues(row.baseSalary, bonus, overtimePay, attDeduction, row.socialSecurity)
    row.bonus = bonus
    row.overtimePay = overtimePay
    row.attendanceDeduction = attDeduction
    row.remark = remark
    row.tax = tax
    row.netSalary = netSalary
    return ok({ id: row.id, tax, netSalary })
  }

  private onPaySingle(call: Call, payrollId: number): Reply {
    const row = this.payrolls.find((p) => p.id === payrollId)
    if (!row) return err(404, '工资单不存在')
    if (row.status === 'PAID') return err(400, '该工资单已发放')
    row.status = 'PAID'
    row.paidAt = nowStamp()
    return ok(null)
  }

  private onBatchPay(call: Call): Reply {
    const payMonth = String(call.body.payMonth ?? '').trim()
    if (!payMonth) return err(400, '请指定发薪月份 payMonth')
    const drafts = this.payrolls.filter((p) => p.payMonth === payMonth && p.status === 'DRAFT')
    for (const p of drafts) {
      p.status = 'PAID'
      p.paidAt = nowStamp()
    }
    return ok({ paidCount: drafts.length })
  }

  private onMyPayrolls(call: Call): Reply {
    const empId = (call.account as Account).employeeId
    const rows = this.payrolls
      .filter((p) => p.employeeId === empId && p.status === 'PAID')
      .sort((a, b) => (a.payMonth === b.payMonth ? b.id - a.id : a.payMonth < b.payMonth ? 1 : -1))
    return ok(rows.map((r) => this.toPayrollJson(r)))
  }

  /* ------------------------------------------------------ 组织架构（只读） */

  /**
   * 与 handleDepartmentsTree 逐字段一致：
   * 节点顺序按 id 升序，activeCount 是「非 RESIGNED」员工数（试用期计入），
   * children 为空时也必须输出 `[]` 而不是省略，否则前端 el-table 的树形展开会异常。
   */
  private onDeptTree(): Reply {
    const build = (parentId: number): Json[] =>
      this.departments
        .filter((d) => d.parentId === parentId)
        .sort((a, b) => a.id - b.id)
        .map((d) => ({
          id: d.id,
          parentId: d.parentId,
          deptName: d.deptName,
          leaderName: d.leaderName,
          headcountLimit: d.headcountLimit,
          description: d.description,
          activeCount: this.employees.filter((e) => e.deptId === d.id && e.empStatus !== 'RESIGNED').length,
          children: build(d.id)
        }))
    return ok(build(0))
  }

  /** handlePositionList：deptId 缺省或 <= 0 时不过滤，deptName 由部门表反查。 */
  private onPositions(call: Call): Reply {
    const deptId = Number(call.query.get('deptId') || 0)
    const rows = this.positions
      .filter((p) => deptId <= 0 || p.deptId === deptId)
      .sort((a, b) => a.id - b.id)
      .map((p) => ({
        id: p.id,
        posCode: p.posCode,
        posName: p.posName,
        deptId: p.deptId,
        deptName: this.departments.find((d) => d.id === p.deptId)?.deptName ?? '',
        levelRange: p.levelRange,
        minSalary: p.minSalary,
        maxSalary: p.maxSalary,
        createdAt: p.createdAt
      }))
    return ok(rows)
  }

  /* -------------------------------------------------- 系统管理与审计（只读） */

  /** handleSystemUsers：返回裸数组，isActive 是布尔（后端由 "1" 转布尔）。 */
  private onSystemUsers(): Reply {
    const rows = this.accounts
      .slice()
      .sort((a, b) => a.userId - b.userId)
      .map((a) => {
        const emp = this.employee(a.employeeId)
        return {
          id: a.userId,
          username: a.username,
          role: a.role,
          employeeId: a.employeeId,
          empName: emp.name,
          empNo: emp.empNo,
          deptName: emp.deptName,
          isActive: a.isActive,
          lastLoginAt: a.lastLoginAt,
          createdAt: a.createdAt
        }
      })
    return ok(rows)
  }

  /**
   * handleSystemAuditLogs：sendPage 信封（list/total/page/pageSize，不回显条件）。
   * pageSize 默认 15 且非 1..100 时回落 15，page < 1 归 1，排序 ORDER BY id DESC。
   */
  private onAuditLogs(call: Call): Reply {
    const moduleName = (call.query.get('module') || '').trim()
    const keyword = (call.query.get('keyword') || '').trim()
    const page = Math.max(1, Number(call.query.get('page') || 1))
    let pageSize = Number(call.query.get('pageSize') || 15)
    if (pageSize < 1 || pageSize > 100) pageSize = 15

    let rows = [...this.auditLogs]
    if (moduleName) rows = rows.filter((r) => r.module === moduleName)
    if (keyword) {
      rows = rows.filter((r) => r.username.includes(keyword) || r.action.includes(keyword) || r.detail.includes(keyword))
    }
    rows.sort((a, b) => b.id - a.id)
    const total = rows.length
    return ok(pageData(rows.slice((page - 1) * pageSize, page * pageSize), total, page, pageSize))
  }
}

/* ------------------------------------------------------------ 信封构造 */

function envelope(code: number, message: string, data: unknown): Json {
  return { code, message, data: data ?? null }
}

function ok(data: unknown): Reply {
  return { status: 200, body: envelope(200, 'success', data) }
}

function okMsg(message: string, data: unknown): Reply {
  return { status: 200, body: envelope(200, message, data) }
}

/** 与 sendErr 一致：HTTP 状态码与 code 同步变化，data 恒为 null。 */
function err(status: number, message: string): Reply {
  return { status, body: envelope(status, message, null) }
}

/** 与 sendPage 一致：data 只有 list/total/page/pageSize 四个键，不回显查询条件。 */
function pageData(list: unknown[], total: number, page: number, pageSize: number): Json {
  return { list, total, page, pageSize }
}
