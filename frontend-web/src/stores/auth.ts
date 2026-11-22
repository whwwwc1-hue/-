import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import { getMeApi, type UserProfile } from '@/api/hrms'

function loadStoredUser(): UserProfile | null {
  try {
    const raw = localStorage.getItem('hrms_user')
    return raw ? JSON.parse(raw) : null
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
