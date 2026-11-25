import request from './request'

export interface UserProfile {
  id: number
  username: string
  role: 'ADMIN' | 'HR' | 'MANAGER' | 'EMPLOYEE'
  employeeId: number
  /**
   * 后端 `auth_controller.cj:34` 出参是 `"isActive":${r[4] == "1"}`，即**布尔**；
   * 此处原先标成 number，任何 `user.isActive === 1` 的写法都会静默恒假（缺陷 L-FE-3）。
   */
  isActive: boolean
  name: string
  empNo: string
  deptId: number
  deptName: string
  positionName: string
  phone: string
  email: string
  empStatus: string
  annualLeaveBalance: number
  hireDate: string
  contractEndDate: string
  baseSalary: number
}

export interface PageResult<T> {
  list: T[]
  total: number
  page: number
  pageSize: number
}

export const loginApi = (data: { username: string; password: string }) =>
  request.post<unknown, { token: string; user: UserProfile }>('/auth/login', data)

export const getMeApi = () => request.get<unknown, UserProfile>('/auth/me')

export const updatePasswordApi = (data: { oldPassword: string; newPassword: string }) =>
  request.put<unknown, null>('/auth/password', data)

export const getDashboardOverviewApi = () => request.get<unknown, any>('/dashboard/overview')

export const getDeptTreeApi = () => request.get<unknown, any[]>('/departments/tree')
export const createDeptApi = (data: any) => request.post<unknown, { id: number }>('/departments', data)
export const updateDeptApi = (id: number, data: any) => request.put<unknown, { id: number }>(`/departments/${id}`, data)
export const deleteDeptApi = (id: number) => request.delete<unknown, null>(`/departments/${id}`)

export const getPositionsApi = (params?: { deptId?: number }) => request.get<unknown, any[]>('/positions', { params })
export const createPositionApi = (data: any) => request.post<unknown, { id: number }>('/positions', data)
export const updatePositionApi = (id: number, data: any) => request.put<unknown, { id: number }>(`/positions/${id}`, data)
export const deletePositionApi = (id: number) => request.delete<unknown, null>(`/positions/${id}`)

export const getEmployeesApi = (params: any) => request.get<unknown, PageResult<any>>('/employees', { params })
export const getEmployeeDetailApi = (id: number) => request.get<unknown, { employee: any; transfers: any[] }>(`/employees/${id}`)
export const createEmployeeApi = (data: any) => request.post<unknown, any>('/employees', data)
export const updateEmployeeApi = (id: number, data: any) => request.put<unknown, any>(`/employees/${id}`, data)
export const transferEmployeeApi = (id: number, data: any) => request.post<unknown, null>(`/employees/${id}/transfer`, data)
export const resignEmployeeApi = (id: number, data: any) => request.post<unknown, null>(`/employees/${id}/resign`, data)

/* 批量导入（P2.1 后端 / P2.2 前端）—— 字段名逐字对齐
 * backend-cangjie/src/controller/employee_controller.cj：
 *   importFailJson(row, field, reason) → { row, field, reason }
 *   importResultJson(...)              → { total, successCount, failedCount, imported, dryRun, failed }
 * body 是 { csv, dryRun }（csv 为纯文本，不是 multipart 上传），故编码兜底必须在前端做。 */
export interface EmployeeImportFailure {
  row: number
  field: string
  reason: string
}

export interface EmployeeImportResult {
  total: number
  successCount: number
  failedCount: number
  imported: number
  dryRun: boolean
  failed: EmployeeImportFailure[]
}

// 后端把整批拼成一条 SQL 交给 mysql.exe 子进程执行，500 行远慢于全局 15s 超时；
// 单独放宽这一次请求，否则「前端先报请求失败、后端却仍在写库」这种最难查的假故障会出现。
export const importEmployeesApi = (data: { csv: string; dryRun: boolean }) =>
  request.post<unknown, EmployeeImportResult>('/employees/import', data, { timeout: 60000 })

export const getTodayAttendanceApi = () => request.get<unknown, any>('/attendance/today')
export const clockInApi = () => request.post<unknown, any>('/attendance/clock-in', {})
export const clockOutApi = () => request.post<unknown, any>('/attendance/clock-out', {})
export const getMyAttendanceApi = (params?: { month?: string }) =>
  request.get<unknown, { list: any[]; summary: any }>('/attendance/my', { params })
export const getAttendanceListApi = (params: any) => request.get<unknown, PageResult<any>>('/attendance', { params })

// P2.4 考勤月度汇总：后端一次返回全量明细 + 合计行，前端「一键导出 CSV」直接复用这份数据，
// 因此页面表格与导出文件天然同源（验收项「导出报表与页面数字一致」）。
export interface AttendanceSummaryRow {
  employeeId: number
  empNo: string
  empName: string
  deptName: string
  attendDays: number
  lateCount: number
  earlyCount: number
  lateMinutes: number
  earlyMinutes: number
  leaveDays: number
  overtimeHours: number
  attendanceRate: number
}

export interface AttendanceSummaryTotals {
  headcount: number
  shouldAttendDays: number
  actualAttendDays: number
  lateCount: number
  earlyCount: number
  lateMinutes: number
  earlyMinutes: number
  leaveDays: number
  overtimeHours: number
  attendanceRate: number
}

export const getAttendanceMonthlySummaryApi = (params?: { month?: string; deptId?: number }) =>
  request.get<unknown, { month: string; shouldAttendDays: number; summary: AttendanceSummaryTotals; list: AttendanceSummaryRow[] }>(
    '/attendance/monthly-summary',
    { params }
  )
export const updateAttendanceApi = (id: number, data: any) => request.put<unknown, null>(`/attendance/${id}`, data)

export const createRequestApi = (data: any) => request.post<unknown, any>('/requests', data)
export const getMyRequestsApi = (params?: any) => request.get<unknown, any[]>('/requests/my', { params })
export const cancelRequestApi = (id: number) => request.post<unknown, null>(`/requests/${id}/cancel`, {})
export const getRequestListApi = (params: any) => request.get<unknown, PageResult<any>>('/requests', { params })
export const approveRequestApi = (id: number, data: { action: string; approveRemark?: string }) =>
  request.post<unknown, any>(`/requests/${id}/approve`, data)

export const initPerformanceCycleApi = (data: { cycleName: string }) =>
  request.post<unknown, any>('/performances/init-cycle', data)
export const getPerformancesApi = (params?: { cycleName?: string; status?: string }) =>
  request.get<unknown, any[]>('/performances', { params })
export const submitSelfEvalApi = (id: number, data: { selfSummary: string; selfScore: number }) =>
  request.put<unknown, any>(`/performances/${id}/self-eval`, data)
export const submitReviewApi = (id: number, data: { finalScore: number; reviewerComment?: string }) =>
  request.put<unknown, any>(`/performances/${id}/review`, data)

export const generatePayrollApi = (data: { payMonth: string }) => request.post<unknown, any>('/payrolls/generate', data)
export const getPayrollsApi = (params: any) => request.get<unknown, PageResult<any>>('/payrolls', { params })
export const updatePayrollApi = (id: number, data: any) => request.put<unknown, any>(`/payrolls/${id}`, data)
export const paySinglePayrollApi = (id: number) => request.post<unknown, null>(`/payrolls/${id}/pay`, {})
export const batchPayPayrollApi = (data: { payMonth: string }) => request.post<unknown, any>('/payrolls/batch-pay', data)
export const getMyPayrollsApi = () => request.get<unknown, any[]>('/payrolls/my')

export const getCandidatesApi = (params?: { stage?: string; keyword?: string }) =>
  request.get<unknown, any[]>('/candidates', { params })
export const createCandidateApi = (data: any) => request.post<unknown, { id: number }>('/candidates', data)
export const updateCandidateApi = (id: number, data: any) => request.put<unknown, { id: number }>(`/candidates/${id}`, data)
export const hireCandidateApi = (id: number, data: any) => request.post<unknown, any>(`/candidates/${id}/hire`, data)

export const getSystemUsersApi = () => request.get<unknown, any[]>('/system/users')
export const updateSystemUserApi = (id: number, data: any) => request.put<unknown, null>(`/system/users/${id}`, data)
export const getAuditLogsApi = (params: any) => request.get<unknown, PageResult<any>>('/system/audit-logs', { params })

// ==================== P3.2 站内通知中心 ====================
// 后端把 typeLabel 一起下发（见 notification_controller.notifRowToJson），
// 前端不再维护第二份映射表，避免「加了新 type 忘记改前端」这类漂移。
export interface NotificationItem {
  id: number
  type: string
  typeLabel: string
  title: string
  content: string
  refId: string
  isRead: boolean
  createdAt: string
}

export interface NotificationListResult {
  list: NotificationItem[]
  unread: number
  total: number
}

export const getNotificationsApi = (params?: { readFlag?: string; limit?: number }) =>
  request.get<unknown, NotificationListResult>('/notifications', { params })
export const getUnreadCountApi = () => request.get<unknown, { unread: number }>('/notifications/unread-count')
export const readNotificationApi = (id: number) =>
  request.put<unknown, { id: number; changed: number; unread?: number }>(`/notifications/${id}/read`, {})
export const readAllNotificationsApi = () => request.post<unknown, { changed: number; unread: number }>('/notifications/read-all', {})
