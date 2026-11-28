import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { getMeApi, type UserProfile } from '@/api/hrms'

const VALID_ROLES = ['ADMIN', 'HR', 'MANAGER', 'EMPLOYEE']

function loadStoredUser(): UserProfile | null {
  try {
    const raw = localStorage.getItem('hrms_user')
    if (!raw) return null
    const parsed = JSON.parse(raw)
    // 旧版本缓存、手工改库或历史遗留数据可能带着非法角色，
    // 这类数据会让路由守卫在「无权 -> 跳工作台 -> 工作台也无权」之间死循环，
    // 因此读缓存时就把它丢掉。
    if (!parsed || typeof parsed !== 'object' || !VALID_ROLES.includes(parsed.role)) {
      localStorage.removeItem('hrms_user')
      return null
    }
    return parsed as UserProfile
  } catch {
    return null
  }
}

export const useAuthStore = defineStore('auth', () => {
  const token = ref<string>(localStorage.getItem('hrms_token') || '')
  const user = ref<UserProfile | null>(loadStoredUser())

  const isAuthenticated = computed(() => Boolean(token.value))
  const role = computed(() => user.value?.role || '')
  const displayName = computed(() => user.value?.name || user.value?.username || '未登录')

  function setAuth(newToken: string, newUser: UserProfile) {
    token.value = newToken
    user.value = newUser
    localStorage.setItem('hrms_token', newToken)
    localStorage.setItem('hrms_user', JSON.stringify(newUser))
  }

  async function refreshProfile() {
    if (!token.value) return
    const profile = await getMeApi()
    user.value = profile
    localStorage.setItem('hrms_user', JSON.stringify(profile))
  }

  function logout() {
    token.value = ''
    user.value = null
    localStorage.removeItem('hrms_token')
    localStorage.removeItem('hrms_user')
  }

  function hasRole(allowedRoles?: string[]): boolean {
    if (!allowedRoles || allowedRoles.length === 0) return true
    if (!user.value) return false
    return allowedRoles.includes(user.value.role)
  }

  return {
    token,
    user,
    isAuthenticated,
    role,
    displayName,
    setAuth,
    refreshProfile,
    logout,
    hasRole
  }
})
