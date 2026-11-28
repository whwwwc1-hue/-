/**
 * 考勤状态枚举单一来源。
 *
 * 后端 hr_attendance.status 实际写入的取值是
 * NORMAL / LATE / EARLY_LEAVE / LATE_AND_EARLY / LEAVE / ABSENT，
 * 前端所有下拉、筛选与标签映射都必须从这里取，避免再次出现
 * 「前端写 EARLY、后端存 EARLY_LEAVE，筛选永远查不到数据」的漂移问题。
 */
export interface AttendanceStatusOption {
  value: string
  label: string
}

export const ATTENDANCE_STATUS_OPTIONS: AttendanceStatusOption[] = [
  { value: 'NORMAL', label: '正常' },
  { value: 'LATE', label: '迟到' },
  { value: 'EARLY_LEAVE', label: '早退' },
  { value: 'LATE_AND_EARLY', label: '迟到且早退' },
  { value: 'LEAVE', label: '请假' },
  { value: 'ABSENT', label: '缺勤' }
]

const STATUS_LABEL_MAP: Record<string, string> = ATTENDANCE_STATUS_OPTIONS.reduce(
  (acc, item) => {
    acc[item.value] = item.label
    return acc
  },
  {} as Record<string, string>
)

export function attendanceStatusLabel(status: string): string {
  return STATUS_LABEL_MAP[status] || status
}

export function attendanceStatusTagType(status: string): 'success' | 'warning' | 'danger' | 'info' {
  if (status === 'NORMAL') return 'success'
  if (status === 'LEAVE') return 'info'
  if (status === 'ABSENT') return 'danger'
  return 'warning'
}
