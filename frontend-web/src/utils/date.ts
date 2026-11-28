function pad(value: number): string {
  return value < 10 ? `0${value}` : `${value}`
}

/**
 * 本地时区的日期（YYYY-MM-DD）。
 *
 * 不能用 new Date().toISOString().slice(0, 10)：它取的是 UTC 日期，
 * 东八区 00:00-07:59 会得到「昨天」，导致入职日期、离职生效日、考勤
 * 筛选月份等默认值整体偏移一天/一个月。
 */
export function formatDate(date: Date = new Date()): string {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
}

/** 本地时区的月份（YYYY-MM）。 */
export function formatMonth(date: Date = new Date()): string {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}`
}
