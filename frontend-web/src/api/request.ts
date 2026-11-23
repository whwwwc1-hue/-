import axios from 'axios'
import { ElMessage } from 'element-plus'

const request = axios.create({
  baseURL: '/api/v1',
  timeout: 15000,
  headers: {
    'Content-Type': 'application/json; charset=utf-8'
  }
})

let redirectingToLogin = false

function clearAuthAndRedirect(msg: string) {
  localStorage.removeItem('hrms_token')
  localStorage.removeItem('hrms_user')
  if (!redirectingToLogin) {
    redirectingToLogin = true
    ElMessage.error(msg || '登录已过期，请重新登录')
    if (window.location.pathname !== '/login') {
      window.location.href = '/login'
    }
    setTimeout(() => {
      redirectingToLogin = false
    }, 1500)
  }
}

request.interceptors.request.use(
  (config) => {
    const token = localStorage.getItem('hrms_token')
    if (token) {
      config.headers.Authorization = `Bearer ${token}`
    }
    return config
  },
  (error) => Promise.reject(error)
)

// P0.3：后端在 /auth/me 里做滑动续期，新 token 通过响应头 X-Renewed-Token 回发。
// 这里统一拦截，任何响应带上该头就替换本地存储，用户无需重新登录。
function adoptRenewedToken(headers: Record<string, unknown> | undefined) {
  if (!headers) return
  const raw = headers['x-renewed-token'] ?? headers['X-Renewed-Token']
  if (typeof raw === 'string' && raw.length > 0) {
    localStorage.setItem('hrms_token', raw)
  }
}

request.interceptors.response.use(
  (response) => {
    adoptRenewedToken(response.headers as unknown as Record<string, unknown>)
    const res = response.data
    if (res && typeof res.code === 'number') {
      if (res.code === 200) {
        return res.data
      }
      if (res.code === 401) {
        clearAuthAndRedirect(res.message || '未登录或会话失效')
        return Promise.reject(new Error(res.message || 'Unauthorized'))
      }
      ElMessage.error(res.message || '请求失败')
      return Promise.reject(new Error(res.message || '请求失败'))
    }
    return res
  },
  (error) => {
    const status = error.response?.status
    const msg = error.response?.data?.message || error.message || '网络请求异常'
    if (status === 401 || error.response?.data?.code === 401) {
      clearAuthAndRedirect(msg)
    } else {
      ElMessage.error(msg)
    }
    return Promise.reject(error)
  }
)

export default request
