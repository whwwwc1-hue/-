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
      // 记住当前页面，登录成功后回到原处，避免深链接失效后只能落在工作台。
      const current = `${window.location.pathname}${window.location.search}`
      window.location.href = `/login?redirect=${encodeURIComponent(current)}`
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

request.interceptors.response.use(
  (response) => {
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
