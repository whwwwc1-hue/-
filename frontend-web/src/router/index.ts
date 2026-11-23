import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router'
import { ElMessage } from 'element-plus'
import { useAuthStore } from '@/stores/auth'

export interface AppRouteMeta {
  title: string
  icon?: string
  roles?: string[]
  hidden?: boolean
}

const routes: RouteRecordRaw[] = [
  {
    path: '/login',
    name: 'Login',
    component: () => import('@/views/login/LoginView.vue'),
    meta: { title: '登录', hidden: true }
  },
  {
    path: '/',
    component: () => import('@/layout/AppLayout.vue'),
    redirect: '/dashboard',
    children: [
      {
        path: 'dashboard',
        name: 'Dashboard',
        component: () => import('@/views/dashboard/DashboardView.vue'),
        meta: { title: '工作台概览', icon: 'DataBoard', roles: ['ADMIN', 'HR', 'MANAGER', 'EMPLOYEE'] }
      },
      {
        path: 'organization',
        name: 'Organization',
        component: () => import('@/views/organization/OrganizationView.vue'),
        meta: { title: '组织与岗位', icon: 'OfficeBuilding', roles: ['ADMIN', 'HR'] }
      },
      {
        path: 'employee',
        name: 'Employee',
        component: () => import('@/views/employee/EmployeeView.vue'),
        meta: { title: '员工花名册', icon: 'UserFilled', roles: ['ADMIN', 'HR', 'MANAGER'] }
      },
      {
        path: 'attendance',
        name: 'Attendance',
        component: () => import('@/views/attendance/AttendanceView.vue'),
        meta: { title: '考勤打卡', icon: 'Timer', roles: ['ADMIN', 'HR', 'MANAGER', 'EMPLOYEE'] }
      },
      {
        path: 'approval',
        name: 'Approval',
        component: () => import('@/views/approval/ApprovalView.vue'),
        meta: { title: '假勤审批', icon: 'Checked', roles: ['ADMIN', 'HR', 'MANAGER', 'EMPLOYEE'] }
      },
      {
        path: 'performance',
        name: 'Performance',
        component: () => import('@/views/performance/PerformanceView.vue'),
        meta: { title: '绩效评估', icon: 'TrendCharts', roles: ['ADMIN', 'HR', 'MANAGER', 'EMPLOYEE'] }
      },
      {
        path: 'payroll',
        name: 'Payroll',
        component: () => import('@/views/payroll/PayrollView.vue'),
        meta: { title: '薪酬与工资条', icon: 'WalletFilled', roles: ['ADMIN', 'HR', 'MANAGER', 'EMPLOYEE'] }
      },
      {
        path: 'recruitment',
        name: 'Recruitment',
        component: () => import('@/views/recruitment/RecruitmentView.vue'),
        meta: { title: '招聘管理', icon: 'Avatar', roles: ['ADMIN', 'HR'] }
      },
      {
        path: 'system',
        name: 'System',
        component: () => import('@/views/system/SystemView.vue'),
        meta: { title: '系统与审计', icon: 'Setting', roles: ['ADMIN'] }
      }
    ]
  },
  {
    path: '/:pathMatch(.*)*',
    redirect: '/dashboard'
  }
]

const router = createRouter({
  history: createWebHistory(),
  routes
})

/**
 * 冷启动画像同步开关（缺陷 L-FE-5）。
 *
 * auth.user 初始化自 localStorage.hrms_user，是**登录那一刻**的快照。原守卫只在
 * `!auth.user` 时才回源 /auth/me，于是整页刷新后：管理员刚被改角色仍按旧角色放行、
 * 员工审批通过的年假已扣但页面仍显示旧余额。所以每次整页加载后首次进入受保护路由
 * 必须做一次权威同步；模块级变量天然随整页加载重置，无需持久化。
 */
let profileSynced = false

router.beforeEach(async (to, from, next) => {
  const auth = useAuthStore()
  if (to.path === '/login') {
    if (auth.isAuthenticated) {
      next('/dashboard')
    } else {
      next()
    }
    return
  }

  if (!auth.isAuthenticated) {
    next('/login')
    return
  }

  if (!auth.user) {
    try {
      await auth.refreshProfile()
      profileSynced = true
    } catch {
      auth.logout()
      next('/login')
      return
    }
  } else if (!profileSynced) {
    profileSynced = true
    // 刚从登录页 replace 过来时画像就是 /auth/login 的返回，无需再打一次
    if (from.path !== '/login') {
      try {
        await auth.refreshProfile()
      } catch {
        // 401 已由响应拦截器清鉴权并整页跳转 /login；其它异常保留本地画像，不打断导航。
      }
    }
  }

  const allowedRoles = to.meta?.roles as string[] | undefined
  if (allowedRoles && !auth.hasRole(allowedRoles)) {
    ElMessage.warning('当前账号无权访问该模块')
    next('/dashboard')
    return
  }

  next()
})

export default router
