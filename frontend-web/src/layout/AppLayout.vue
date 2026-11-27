<template>
  <div class="flex h-screen w-screen overflow-hidden bg-[#F5F7FA]">
    <!-- Sidebar -->
    <aside
      :class="[
        'flex flex-col bg-gradient-to-b from-[#1E3A8A] to-[#1E40AF] text-white transition-all duration-200 shrink-0 shadow-lg',
        collapsed ? 'w-[72px]' : 'w-[228px]'
      ]"
    >
      <div class="flex h-16 items-center justify-between px-4 border-b border-blue-700/60">
        <div class="flex items-center gap-2.5 overflow-hidden">
          <div class="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-white/15 font-bold text-lg">
            CJ
          </div>
          <div v-if="!collapsed" class="leading-tight truncate">
            <div class="text-sm font-semibold tracking-wide">Cangjie HRMS</div>
            <div class="text-[11px] text-blue-200">人力资源管理系统</div>
          </div>
        </div>
      </div>

      <nav class="flex-1 overflow-y-auto px-2.5 py-4 space-y-1">
        <router-link
          v-for="item in visibleMenus"
          :key="item.path"
          :to="item.path"
          class="flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium transition-colors"
          :class="
            route.path === item.path
              ? 'bg-white text-[#1E40AF] shadow-sm'
              : 'text-blue-100 hover:bg-white/10 hover:text-white'
          "
        >
          <el-icon :size="18" class="shrink-0">
            <component :is="item.icon" />
          </el-icon>
          <span v-if="!collapsed" class="truncate">{{ item.title }}</span>
        </router-link>
      </nav>

      <div class="border-t border-blue-700/60 p-3 text-xs text-blue-200">
        <div v-if="!collapsed" class="flex items-center justify-between">
          <span>仓颉 1.0.5 后端驱动</span>
          <span class="inline-block h-2 w-2 rounded-full bg-emerald-400" title="服务在线"></span>
        </div>
      </div>
    </aside>

    <!-- Main Container -->
    <div class="flex flex-1 flex-col min-w-0 overflow-hidden">
      <!-- Topbar -->
      <header class="flex h-16 items-center justify-between bg-white px-6 border-b border-slate-200 shrink-0">
        <div class="flex items-center gap-4">
          <el-button text circle @click="collapsed = !collapsed" title="切换侧边栏">
            <el-icon :size="18"><Fold v-if="!collapsed" /><Expand v-else /></el-icon>
          </el-button>
          <div>
            <h1 class="text-base font-semibold text-slate-800">{{ currentTitle }}</h1>
          </div>
        </div>

        <div class="flex items-center gap-4">
          <el-badge :value="unreadCount" :hidden="unreadCount === 0" :max="99" data-testid="notif-badge">
            <el-button text circle data-testid="notif-bell" title="站内通知" @click="openNotificationDrawer">
              <el-icon :size="18"><Bell /></el-icon>
            </el-button>
          </el-badge>
          <el-tag :type="roleTagType" effect="light" round>
            {{ roleLabel }}
          </el-tag>
          <el-dropdown trigger="click" @command="handleCommand">
            <div class="flex items-center gap-2 cursor-pointer rounded-lg px-2.5 py-1.5 hover:bg-slate-100">
              <el-avatar :size="32" class="bg-blue-600 text-white font-semibold">
                {{ auth.displayName.slice(0, 1) }}
              </el-avatar>
              <div class="text-left leading-tight hidden sm:block">
                <div class="text-sm font-medium text-slate-800">{{ auth.displayName }}</div>
                <div class="text-xs text-slate-400">{{ auth.user?.deptName || '总部' }} · {{ auth.user?.empNo || auth.user?.username }}</div>
              </div>
              <el-icon class="text-slate-400"><ArrowDown /></el-icon>
            </div>
            <template #dropdown>
              <el-dropdown-menu>
                <el-dropdown-item command="password">修改密码</el-dropdown-item>
                <el-dropdown-item divided command="logout">退出登录</el-dropdown-item>
              </el-dropdown-menu>
            </template>
          </el-dropdown>
        </div>
      </header>

      <!-- Workspace Content -->
      <main class="flex-1 overflow-y-auto p-6">
        <router-view />
      </main>
    </div>

    <!-- Change Password Modal -->
    <el-dialog v-model="pwdDialogVisible" title="修改登录密码" width="420px" destroy-on-close>
      <el-form :model="pwdForm" label-width="92px">
        <el-form-item label="当前密码">
          <el-input v-model="pwdForm.oldPassword" type="password" show-password placeholder="请输入当前密码" />
        </el-form-item>
        <el-form-item label="新密码">
          <el-input v-model="pwdForm.newPassword" type="password" show-password placeholder="至少6位字符" />
        </el-form-item>
        <el-form-item label="确认新密码">
          <el-input v-model="pwdForm.confirmPassword" type="password" show-password placeholder="再次输入新密码" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="pwdDialogVisible = false">取消</el-button>
        <el-button type="primary" :loading="pwdLoading" @click="submitPassword">确认修改</el-button>
      </template>
    </el-dialog>

    <!--
      P3.2 站内通知抽屉。
      刻意关掉组件自带的 header：el-drawer 的标题行渲染成语义 <header>，
      而布局自身的顶栏也是一个 <header>，两者并存会让所有按 `locator('header')`
      取顶栏的用例撞上 strict mode（rbac-menu / auth 都有）。
      标题改由正文首行自绘，视觉与可访问名（aria-label 仍取 title）都不丢。
    -->
    <el-drawer v-model="notifVisible" title="站内通知" size="420px" :with-header="false">
      <div data-testid="notif-drawer">
        <div class="mb-3 flex items-center justify-between">
          <span class="text-base font-semibold text-slate-800">站内通知</span>
          <el-button link size="small" data-testid="notif-close" @click="notifVisible = false">关闭</el-button>
        </div>

        <div class="mb-3 flex items-center justify-between">
          <el-radio-group v-model="notifFilter" size="small" data-testid="notif-filter" @change="loadNotifications">
            <el-radio-button value="all">全部</el-radio-button>
            <el-radio-button value="0">未读</el-radio-button>
          </el-radio-group>
          <el-button link type="primary" size="small" data-testid="notif-read-all" @click="markAllRead">
            全部已读
          </el-button>
        </div>

        <div v-if="unreadCount > 0" class="mb-2 text-xs text-slate-400" data-testid="notif-unread-text">
          你有 {{ unreadCount }} 条未读通知
        </div>

        <div v-loading="notifLoading" class="space-y-2">
          <div
            v-for="n in notifications"
            :key="n.id"
            data-testid="notif-item"
            class="cursor-pointer rounded-lg border px-3 py-2.5 transition-colors hover:bg-slate-50"
            :class="n.isRead ? 'border-slate-200 bg-white' : 'border-blue-200 bg-blue-50/70'"
            @click="openNotification(n)"
          >
            <div class="flex items-center justify-between gap-2">
              <span
                data-testid="notif-type"
                class="rounded px-1.5 py-0.5 text-[11px] font-medium"
                :class="n.isRead ? 'bg-slate-100 text-slate-500' : 'bg-blue-100 text-blue-700'"
              >{{ n.typeLabel }}</span>
              <span class="shrink-0 text-[11px] text-slate-400">{{ n.createdAt.slice(5, 16) }}</span>
            </div>
            <div class="mt-1.5 text-sm font-medium text-slate-800" data-testid="notif-title">{{ n.title }}</div>
            <div v-if="n.content" class="mt-0.5 text-xs leading-relaxed text-slate-500">{{ n.content }}</div>
          </div>

          <el-empty v-if="!notifLoading && notifications.length === 0" description="暂无通知" :image-size="80" />
        </div>
      </div>
    </el-drawer>
  </div>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { ElMessage } from 'element-plus'
import { useAuthStore } from '@/stores/auth'
import {
  getNotificationsApi,
  getUnreadCountApi,
  readAllNotificationsApi,
  readNotificationApi,
  updatePasswordApi,
  type NotificationItem
} from '@/api/hrms'

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()

const collapsed = ref(false)
const pwdDialogVisible = ref(false)
const pwdLoading = ref(false)
const pwdForm = reactive({
  oldPassword: '',
  newPassword: '',
  confirmPassword: ''
})

const menuItems = [
  { path: '/dashboard', title: '工作台概览', icon: 'DataBoard', roles: ['ADMIN', 'HR', 'MANAGER', 'EMPLOYEE'] },
  { path: '/organization', title: '组织与岗位', icon: 'OfficeBuilding', roles: ['ADMIN', 'HR'] },
  { path: '/employee', title: '员工花名册', icon: 'UserFilled', roles: ['ADMIN', 'HR', 'MANAGER'] },
  { path: '/attendance', title: '考勤打卡', icon: 'Timer', roles: ['ADMIN', 'HR', 'MANAGER', 'EMPLOYEE'] },
  { path: '/approval', title: '假勤审批', icon: 'Checked', roles: ['ADMIN', 'HR', 'MANAGER', 'EMPLOYEE'] },
  { path: '/performance', title: '绩效评估', icon: 'TrendCharts', roles: ['ADMIN', 'HR', 'MANAGER', 'EMPLOYEE'] },
  { path: '/payroll', title: '薪酬与工资条', icon: 'WalletFilled', roles: ['ADMIN', 'HR', 'MANAGER', 'EMPLOYEE'] },
  { path: '/recruitment', title: '招聘管理', icon: 'Avatar', roles: ['ADMIN', 'HR'] },
  // 顺序必须与 router children 一致，菜单与侧栏高亮/面包屑才不会和路由表脱节
  { path: '/training', title: '培训与学分', icon: 'Reading', roles: ['ADMIN', 'HR', 'MANAGER', 'EMPLOYEE'] },
  { path: '/system', title: '系统与审计', icon: 'Setting', roles: ['ADMIN'] }
]

const visibleMenus = computed(() => menuItems.filter((m) => auth.hasRole(m.roles)))
const currentTitle = computed(() => (route.meta?.title as string) || '工作台概览')

const roleMap: Record<string, { label: string; type: 'danger' | 'primary' | 'warning' | 'success' }> = {
  ADMIN: { label: '系统管理员 ADMIN', type: 'danger' },
  HR: { label: '人事主管 HR', type: 'primary' },
  MANAGER: { label: '部门经理 MANAGER', type: 'warning' },
  EMPLOYEE: { label: '普通员工 EMPLOYEE', type: 'success' }
}

const roleLabel = computed(() => roleMap[auth.role]?.label || auth.role)
const roleTagType = computed(() => roleMap[auth.role]?.type || 'info')

function handleCommand(cmd: string) {
  if (cmd === 'password') {
    pwdForm.oldPassword = ''
    pwdForm.newPassword = ''
    pwdForm.confirmPassword = ''
    pwdDialogVisible.value = true
  } else if (cmd === 'logout') {
    auth.logout()
    router.replace('/login')
  }
}

async function submitPassword() {
  if (!pwdForm.oldPassword || pwdForm.newPassword.length < 6) {
    ElMessage.warning('请填写当前密码，新密码至少6位')
    return
  }
  if (pwdForm.newPassword !== pwdForm.confirmPassword) {
    ElMessage.warning('两次输入的新密码不一致')
    return
  }
  pwdLoading.value = true
  try {
    await updatePasswordApi({
      oldPassword: pwdForm.oldPassword,
      newPassword: pwdForm.newPassword
    })
    ElMessage.success('密码修改成功')
    pwdDialogVisible.value = false
  } finally {
    pwdLoading.value = false
  }
}

// ==================== P3.2 站内通知中心 ====================
const notifVisible = ref(false)
const notifLoading = ref(false)
const notifFilter = ref<'all' | '0'>('all')
const notifications = ref<NotificationItem[]>([])
const unreadCount = ref(0)
const NOTIF_POLL_MS = 30000
let notifTimer: ReturnType<typeof setInterval> | null = null

// 后端 5 种 type 各自的落地页；未知 type 不跳转，只标已读，
// 这样以后端新增 type 时前端不会因为映射表缺项而报错。
const notifRoutes: Record<string, { path: string; query?: Record<string, string> }> = {
  PAYROLL_PAID: { path: '/payroll', query: { tab: 'my' } },
  LEAVE_NEXT_LEVEL: { path: '/approval', query: { tab: 'approve' } },
  LEAVE_APPROVED: { path: '/approval' },
  LEAVE_REJECTED: { path: '/approval' },
  CONTRACT_EXPIRING: { path: '/employee' },
  // 培训发布通知面向全员，落到「可报名培训」而不是培训计划，员工点开就能报名
  TRAINING_PUBLISHED: { path: '/training', query: { tab: 'available' } }
}

async function refreshUnreadCount() {
  try {
    const data = await getUnreadCountApi()
    unreadCount.value = data?.unread ?? 0
  } catch {
    // 轮询失败保持上一次的计数：网络抖动不该把红点抹掉
  }
}

async function loadNotifications() {
  notifLoading.value = true
  try {
    const data = await getNotificationsApi({
      readFlag: notifFilter.value === '0' ? '0' : '',
      limit: 20
    })
    notifications.value = data?.list ?? []
    if (typeof data?.unread === 'number') unreadCount.value = data.unread
  } finally {
    notifLoading.value = false
  }
}

function openNotificationDrawer() {
  notifVisible.value = true
  loadNotifications()
}

async function openNotification(item: NotificationItem) {
  if (!item.isRead) {
    const res = await readNotificationApi(item.id)
    item.isRead = true
    if (typeof res?.unread === 'number') unreadCount.value = res.unread
    else unreadCount.value = Math.max(0, unreadCount.value - 1)
  }
  const target = notifRoutes[item.type]
  notifVisible.value = false
  if (target && target.path !== route.path) router.push(target)
}

async function markAllRead() {
  const res = await readAllNotificationsApi()
  const changed = res?.changed ?? 0
  unreadCount.value = res?.unread ?? 0
  ElMessage.success(changed > 0 ? `已标记 ${changed} 条通知为已读` : '没有未读通知')
  loadNotifications()
}

onMounted(() => {
  refreshUnreadCount()
  notifTimer = setInterval(refreshUnreadCount, NOTIF_POLL_MS)
})

onBeforeUnmount(() => {
  if (notifTimer !== null) {
    clearInterval(notifTimer)
    notifTimer = null
  }
})
</script>
