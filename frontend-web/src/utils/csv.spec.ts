import { describe, expect, it } from 'vitest'
import { buildCsvContent, escapeCsvCell } from './csv'

describe('escapeCsvCell', () => {
  it('将 null 和 undefined 转为空字符串并加引号', () => {
    expect(escapeCsvCell(null)).toBe('""')
    expect(escapeCsvCell(undefined)).toBe('""')
  })

  it('正确转义双引号、逗号与换行符', () => {
    expect(escapeCsvCell('研发"核心"组')).toBe('"研发""核心""组"')
    expect(escapeCsvCell('100,200')).toBe('"100,200"')
    expect(escapeCsvCell('line1\nline2')).toBe('"line1\nline2"')
  })
})

describe('buildCsvContent', () => {
  it('生成带 UTF-8 BOM 的标准多行 CSV 内容', () => {
    const csv = buildCsvContent(
      ['姓名', '实发工资', '备注'],
      [
        ['陈思远', 16622, '含"S级"奖金'],
        ['林小满', 14000, null]
      ]
    )
    expect(csv.startsWith('\uFEFF')).toBe(true)
    expect(csv).toBe('\uFEFF"姓名","实发工资","备注"\n"陈思远","16622","含""S级""奖金"\n"林小满","14000",""')
  })
})
