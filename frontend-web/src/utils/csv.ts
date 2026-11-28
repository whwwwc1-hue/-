/** 对单个 CSV 单元格做 RFC 4180 转义并用双引号包裹。 */
export function escapeCsvCell(value: unknown): string {
  const str = String(value ?? '')
  return `"${str.replace(/"/g, '""')}"`
}

/** 拼接带 UTF-8 BOM 的 CSV 文本，避免 Excel 打开中文乱码。 */
export function buildCsvContent(headers: string[], rows: unknown[][]): string {
  const lines = [headers, ...rows].map((row) => row.map((cell) => escapeCsvCell(cell)).join(','))
  return `\uFEFF${lines.join('\n')}`
}

/** 在浏览器中触发 CSV 文件下载。 */
export function downloadCsv(filename: string, headers: string[], rows: unknown[][]): void {
  const csvContent = buildCsvContent(headers, rows)
  const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' })
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = filename
  link.click()
  URL.revokeObjectURL(url)
}
