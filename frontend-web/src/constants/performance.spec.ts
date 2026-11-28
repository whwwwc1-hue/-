import { describe, expect, it } from 'vitest'
import { performanceGradeTagType, resolvePerformanceGrade } from './performance'

describe('resolvePerformanceGrade', () => {
  it('覆盖 S/A/B/C/D 五个评级与奖金系数区间边界', () => {
    expect(resolvePerformanceGrade(100)).toEqual({ grade: 'S', ratio: '1.20' })
    expect(resolvePerformanceGrade(90)).toEqual({ grade: 'S', ratio: '1.20' })
    expect(resolvePerformanceGrade(89.9)).toEqual({ grade: 'A', ratio: '1.10' })
    expect(resolvePerformanceGrade(80)).toEqual({ grade: 'A', ratio: '1.10' })
    expect(resolvePerformanceGrade(79.9)).toEqual({ grade: 'B', ratio: '1.00' })
    expect(resolvePerformanceGrade(70)).toEqual({ grade: 'B', ratio: '1.00' })
    expect(resolvePerformanceGrade(69.9)).toEqual({ grade: 'C', ratio: '0.80' })
    expect(resolvePerformanceGrade(60)).toEqual({ grade: 'C', ratio: '0.80' })
    expect(resolvePerformanceGrade(59.9)).toEqual({ grade: 'D', ratio: '0.50' })
    expect(resolvePerformanceGrade(0)).toEqual({ grade: 'D', ratio: '0.50' })
  })

  it('非法数值输入回退到 D 档', () => {
    expect(resolvePerformanceGrade(Number.NaN)).toEqual({ grade: 'D', ratio: '0.50' })
  })
})

describe('performanceGradeTagType', () => {
  it('返回对应的 Tag 配色且未知评级回退 info', () => {
    expect(performanceGradeTagType('S')).toBe('danger')
    expect(performanceGradeTagType('A')).toBe('success')
    expect(performanceGradeTagType('B')).toBe('warning')
    expect(performanceGradeTagType('C')).toBe('info')
    expect(performanceGradeTagType('D')).toBe('info')
    expect(performanceGradeTagType('UNKNOWN')).toBe('info')
  })
})
