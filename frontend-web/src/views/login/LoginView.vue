<template>
  <div class="min-h-screen flex items-center justify-center bg-gradient-to-br from-slate-100 via-blue-50 to-indigo-100 p-4">
    <div class="w-full max-w-5xl rounded-2xl bg-white shadow-xl overflow-hidden grid grid-cols-1 lg:grid-cols-12 border border-slate-200/80">
      <!-- Left Hero Panel -->
      <div class="lg:col-span-5 bg-gradient-to-br from-[#1E3A8A] via-[#1E40AF] to-[#2563EB] p-8 text-white flex flex-col justify-between">
        <div>
          <div class="inline-flex items-center gap-2 rounded-full bg-white/15 px-3 py-1 text-xs font-medium mb-6">
            <span class="h-2 w-2 rounded-full bg-emerald-400"></span>
            <span>Cangjie 1.0.5 + Vue 3 全栈版</span>
          </div>
          <h1 class="text-2xl font-bold tracking-tight mb-3">企业级人力资源管理系统</h1>
          <p class="text-sm text-blue-100 leading-relaxed mb-8">
            集成组织架构、员工生命周期、智能考勤打卡、假勤审批流、绩效奖金系数联动、自动化薪资核算与招聘入职全链路能力。
          </p>

          <div class="space-y-3 text-sm text-blue-50">
            <div class="flex items-center gap-2.5">
              <el-icon class="text-emerald-300"><CircleCheckFilled /></el-icon>
              <span>四角色 RBAC 细粒度权限控制</span>
            </div>
            <div class="flex items-center gap-2.5">
              <el-icon class="text-emerald-300"><CircleCheckFilled /></el-icon>
              <span>绩效评级系数联动月度薪资个税算薪</span>
            </div>
            <div class="flex items-center gap-2.5">
              <el-icon class="text-emerald-300"><CircleCheckFilled /></el-icon>
              <span>高颜值 ECharts 人力数据分析看板</span>
            </div>
          </div>
        </div>

        <div class="mt-8 pt-4 border-t border-white/15 text-xs text-blue-200">
          © 2026 Cangjie HRMS · 端口 5173 / API 8080
        </div>
      </div>

      <!-- Right Login Card -->
      <div class="lg:col-span-7 p-8 sm:p-10 flex flex-col justify-between">
        <div>
          <h2 class="text-xl font-bold text-slate-800 mb-1">欢迎登录工作台</h2>
          <p class="text-sm text-slate-500 mb-6">请输入您的系统账号与密码，或使用下方测试账号一键填充</p>

          <el-form ref="formRef" :model="form" :rules="rules" size="large" @submit.prevent="handleLogin">
            <el-form-item prop="username">
              <el-input
                v-model="form.username"
                placeholder="请输入用户名（如 admin / hr / manager / emp01）"
                prefix-icon="User"
                clearable
              />
            </el-form-item>
            <el-form-item prop="password">
              <el-input
                v-model="form.password"
                type="password"
                show-password
                placeholder="请输入密码（默认 123456）"
                prefix-icon="Lock"
                @keyup.enter="handleLogin"
              />
            </el-form-item>
            <el-form-item>
              <el-button
                type="primary"
                class="w-full !h-11 !text-base !font-medium !rounded-lg"
                :loading="loading"
                @click="handleLogin"
              >
                立即登录
              </el-button>
            </el-form-item>
          </el-form>
        </div>

        <!-- 4 One-Click Demo Accounts -->
        <div class="mt-4 pt-5 border-t border-slate-100">
          <div class="flex items-center justify-between mb-3">
            <span class="text-xs font-medium text-slate-500 uppercase tracking-wider">测试账号一键填充（密码均为 123456）</span>
          </div>
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-2.5">
            <button
              v-for="acc in demoAccounts"
              :key="acc.username"
              type="button"
              class="flex flex-col items-start rounded-lg border border-slate-200 bg-slate-50/70 px-3 py-2 text-left hover:border-blue-400 hover:bg-blue-50/60 transition-colors"
              @click="quickFill(acc.username)"
            >
              <span class="text-xs font-semibold text-slate-800">{{ acc.label }}</span>
              <span class="text-[11px] text-slate-500 mt-0.5">{{ acc.username }} · {{ acc.desc }}</span>
            </button>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { reactive, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { ElMessage, type FormInstance, type FormRules } from 'element-plus'
import { loginApi } from '@/api/hrms'
import { useAuthStore } from '@/stores/auth'

const router = useRouter()
const route = useRoute()
const auth = useAuthStore()

const formRef = ref<FormInstance>()
const loading = ref(false)
const form = reactive({
  username: '',
  password: ''
})

const rules: FormRules = {
  username: [{ required: true, message: '请输入用户名', trigger: 'blur' }],
  password: [{ required: true, message: '请输入密码', trigger: 'blur' }]
}

const demoAccounts = [
  { username: 'admin', label: '管理员', desc: '全权限' },
  { username: 'hr', label: '人事主管', desc: 'HR业务' },
  { username: 'manager', label: '部门经理', desc: '部门审批' },
  { username: 'emp01', label: '普通员工', desc: '自助中心' }
]

function quickFill(username: string) {
  form.username = username
  form.password = '123456'
}

async function handleLogin() {
  if (!formRef.value) return
  const valid = await formRef.value.validate().catch(() => false)
  if (!valid) return

  loading.value = true
  try {
    const res = await loginApi({
      username: form.username.trim(),
      password: form.password
    })
    auth.setAuth(res.token, res.user)
    ElMessage.success(`欢迎回来，${res.user.name || res.user.username}`)
    // 登录前被 401 拦到登录页时带着 redirect，登录成功后回到原页面
    const redirect = typeof route.query.redirect === 'string' ? route.query.redirect : ''
    router.replace(redirect.startsWith('/') ? redirect : '/dashboard')
  } finally {
    loading.value = false
  }
}
</script>
