export type PerformanceGrade = 'S' | 'A' | 'B' | 'C' | 'D'

export interface PerformanceGradeRule {
  grade: PerformanceGrade
  minScore: number
  ratio: string
  tagType: 'danger' | 'success' | 'warning' | 'info'
}

export const PERFORMANCE_GRADE_RULES: PerformanceGradeRule[] = [
  { grade: 'S', minScore: 90, ratio: '1.20', tagType: 'danger' },
  { grade: 'A', minScore: 80, ratio: '1.10', tagType: 'success' },
  { grade: 'B', minScore: 70, ratio: '1.00', tagType: 'warning' },
  { grade: 'C', minScore: 60, ratio: '0.80', tagType: 'info' },
  { grade: 'D', minScore: -Infinity, ratio: '0.50', tagType: 'info' }
]

/** 根据最终评分计算绩效等级与奖金系数，与后端 performance_controller 规则保持一致。 */
export function resolvePerformanceGrade(score: number): { grade: PerformanceGrade; ratio: string } {
  const numericScore = Number.isFinite(score) ? score : 0
  const matched = PERFORMANCE_GRADE_RULES.find((rule) => numericScore >= rule.minScore)
  const fallback = PERFORMANCE_GRADE_RULES[PERFORMANCE_GRADE_RULES.length - 1]
  const rule = matched ?? fallback
  return { grade: rule.grade, ratio: rule.ratio }
}

/** 绩效评级对应的 Element Plus Tag 颜色类型。 */
export function performanceGradeTagType(grade: string): 'danger' | 'success' | 'warning' | 'info' {
  const matched = PERFORMANCE_GRADE_RULES.find((rule) => rule.grade === grade)
  return matched ? matched.tagType : 'info'
}
