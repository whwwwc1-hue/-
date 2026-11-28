import { describe, expect, it } from 'vitest'
import {
  ATTENDANCE_STATUS_OPTIONS,
  attendanceStatusLabel,
  attendanceStatusTagType
} from './attendance'

describe('ATTENDANCE_STATUS_OPTIONS', () => {
  it('与后端 hr_attendance.status 取值保持一致', () => {
    expect(ATTENDANCE_STATUS_OPTIONS.map((o) => o.value)).toEqual([
      'NORMAL',
      'LATE',
      'EARLY_LEAVE',
      'LATE_AND_EARLY',
      'LEAVE',
      'ABSENT'
    ])
  })

  it('不包含历史上的错误取值 EARLY / LATE_EARLY', () => {
    const values = ATTENDANCE_STATUS_OPTIONS.map((o) => o.value)
    expect(values).not.toContain('EARLY')
    expect(values).not.toContain('LATE_EARLY')
  })
})

describe('attendanceStatusLabel', () => {
  it('把后端枚举翻译成中文', () => {
    expect(attendanceStatusLabel('NORMAL')).toBe('正常')
    expect(attendanceStatusLabel('EARLY_LEAVE')).toBe('早退')
    expect(attendanceStatusLabel('LATE_AND_EARLY')).toBe('迟到且早退')
  })

  it('未知取值原样返回，便于排查脏数据', () => {
    expect(attendanceStatusLabel('UNKNOWN')).toBe('UNKNOWN')
  })
})

describe('attendanceStatusTagType', () => {
  it('正常/请假/缺勤与异常状态使用不同的标签色', () => {
    expect(attendanceStatusTagType('NORMAL')).toBe('success')
    expect(attendanceStatusTagType('LEAVE')).toBe('info')
    expect(attendanceStatusTagType('ABSENT')).toBe('danger')
    expect(attendanceStatusTagType('LATE')).toBe('warning')
    expect(attendanceStatusTagType('EARLY_LEAVE')).toBe('warning')
  })
})
