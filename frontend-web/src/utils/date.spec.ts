import { describe, expect, it } from 'vitest'
import { formatDate, formatMonth } from './date'

describe('formatDate', () => {
  it('按本地时区补零输出 YYYY-MM-DD', () => {
    // 月份从 0 开始：0 = 一月
    expect(formatDate(new Date(2026, 0, 5, 9, 30))).toBe('2026-01-05')
    expect(formatDate(new Date(2026, 10, 28, 23, 59))).toBe('2026-11-28')
  })

  it('凌晨时间不会被 UTC 转换拖到前一天', () => {
    // 东八区 00:30 用 toISOString() 会得到前一天的日期，这里必须保持当天
    expect(formatDate(new Date(2026, 2, 1, 0, 30))).toBe('2026-03-01')
  })

  it('跨年边界正确', () => {
    expect(formatDate(new Date(2026, 11, 31, 23, 59))).toBe('2026-12-31')
    expect(formatDate(new Date(2027, 0, 1, 0, 1))).toBe('2027-01-01')
  })
})

describe('formatMonth', () => {
  it('输出 YYYY-MM 并补零', () => {
    expect(formatMonth(new Date(2026, 0, 15))).toBe('2026-01')
    expect(formatMonth(new Date(2026, 10, 28))).toBe('2026-11')
  })

  it('月初凌晨不会退回上个月', () => {
    expect(formatMonth(new Date(2026, 5, 1, 0, 5))).toBe('2026-06')
  })
})
