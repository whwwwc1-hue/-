import { ElMessageBox } from 'element-plus'

type ConfirmType = 'warning' | 'info' | 'error' | 'success'

/**
 * 统一的二次确认封装。
 *
 * Element Plus 的 ElMessageBox.confirm 在用户点「取消」时会以 'cancel'
 * 拒绝 Promise，直接 await 会在每个调用处产生一次未处理的 Promise 拒绝，
 * 控制台刷出红色错误栈，掩盖真正的异常。
 * 这里把它收敛成布尔值：确认返回 true，取消/关闭返回 false。
 */
export async function confirmAction(message: string, title = '操作确认', type: ConfirmType = 'warning'): Promise<boolean> {
  try {
    await ElMessageBox.confirm(message, title, {
      type,
      confirmButtonText: '确定',
      cancelButtonText: '取消'
    })
    return true
  } catch {
    return false
  }
}
