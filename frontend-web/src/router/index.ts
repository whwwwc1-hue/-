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

const DASHBOARD_ROLES = ['ADMIN', 'HR', 'MANAGER', 'EMPLOYEE']

router.beforeEach(async (to, _from, next) => {
  const auth = useAuthStore()
  if (to.path === '/login') {
    if (auth.isAuthenticated && auth.hasRole(DASHBOARD_ROLES)) {
      next((to.query.redirect as string) || '/dashboard')
    } else {
      next()
    }
    return
  }

  if (!auth.isAuthenticated) {
    next({ path: '/login', query: to.fullPath === '/' ? {} : { redirect: to.fullPath } })
    return
  }

  if (!auth.user) {
    try {
      await auth.refreshProfile()
    } catch {
      auth.logout()
      next('/login')
      return
    }
  }

  const allowedRoles = to.meta?.roles as string[] | undefined
  if (allowedRoles && !auth.hasRole(allowedRoles)) {
    ElMessage.warning('当前账号无权访问该模块')
    // 角色异常（缓存脏数据 / 账号被改成未知角色）时不能再往工作台跳，
    // 否则会在「无权 -> 工作台 -> 工作台也无权」之间无限重定向并白屏。
    if (!auth.hasRole(DASHBOARD_ROLES)) {
      auth.logout()
      next('/login')
      return
    }
    next('/dashboard')
    return
  }

  next()
})

export default router
