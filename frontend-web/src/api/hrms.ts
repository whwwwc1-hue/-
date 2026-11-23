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

export const getTodayAttendanceApi = () => request.get<unknown, any>('/attendance/today')
export const clockInApi = () => request.post<unknown, any>('/attendance/clock-in', {})
export const clockOutApi = () => request.post<unknown, any>('/attendance/clock-out', {})
export const getMyAttendanceApi = (params?: { month?: string }) =>
  request.get<unknown, { list: any[]; summary: any }>('/attendance/my', { params })
export const getAttendanceListApi = (params: any) => request.get<unknown, PageResult<any>>('/attendance', { params })
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
