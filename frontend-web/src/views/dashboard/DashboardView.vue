<template>
  <div class="space-y-5" v-loading="loading">
    <!-- Quick Welcome & Attendance Widget -->
    <div class="hrms-card p-5 flex flex-col md:flex-row md:items-center md:justify-between gap-4 bg-gradient-to-r from-white to-blue-50/50">
      <div>
        <div class="text-lg font-bold text-slate-800">
          {{ greetingText }}，{{ auth.displayName }}
        </div>
        <div class="text-sm text-slate-500 mt-1 flex flex-wrap items-center gap-3">
          <span>部门：{{ auth.user?.deptName || '总部' }}</span>
          <span>岗位：{{ auth.user?.positionName || '系统管理' }}</span>
          <span>剩余年假：<strong class="text-blue-600">{{ auth.user?.annualLeaveBalance ?? 5 }}</strong> 天</span>
        </div>
      </div>

      <div class="flex items-center gap-3">
        <div class="text-right mr-2 hidden sm:block">
          <div class="text-xs text-slate-400">今日打卡状态</div>
          <div class="text-sm font-medium text-slate-700 mt-0.5">
            <template v-if="todayAtt">
              签到 {{ formatTime(todayAtt.clockInTime) }}
              <span v-if="todayAtt.clockOutTime"> · 签退 {{ formatTime(todayAtt.clockOutTime) }}</span>
            </template>
            <template v-else>今日尚未签到</template>
          </div>
        </div>
        <el-button
          v-if="!todayAtt || !todayAtt.clockInTime"
          type="primary"
          :loading="clockLoading"
          @click="handleQuickClock('in')"
        >
          立即签到
        </el-button>
        <el-button
          v-else-if="!todayAtt.clockOutTime"
          type="success"
          :loading="clockLoading"
          @click="handleQuickClock('out')"
        >
          下班签退
        </el-button>
        <el-tag v-else type="success" size="large" effect="light">今日考勤已完成</el-tag>
      </div>
    </div>

    <!-- 6 KPI Cards -->
    <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6 gap-4">
      <div v-for="kpi in kpiCards" :key="kpi.label" class="hrms-card p-4">
        <div class="flex items-center justify-between text-xs text-slate-500">
          <span>{{ kpi.label }}</span>
          <el-icon :size="16" :class="kpi.iconClass"><component :is="kpi.icon" /></el-icon>
        </div>
        <div class="mt-2.5 text-2xl font-bold text-slate-800">{{ kpi.value }}</div>
        <div class="mt-1 text-xs text-slate-400">{{ kpi.sub }}</div>
      </div>
    </div>

    <!-- 4 ECharts Panels -->
    <div class="grid grid-cols-1 lg:grid-cols-2 gap-5">
      <div class="hrms-card p-5">
        <div class="flex items-center justify-between mb-3">
          <h3 class="text-sm font-semibold text-slate-800">部门人数分布</h3>
          <span class="text-xs text-slate-400">在职员工口径</span>
        </div>
        <div ref="deptChartRef" class="w-full h-72"></div>
      </div>

      <div class="hrms-card p-5">
        <div class="flex items-center justify-between mb-3">
          <h3 class="text-sm font-semibold text-slate-800">员工在职状态统计</h3>
          <span class="text-xs text-slate-400">全员档案状态</span>
        </div>
        <div ref="statusChartRef" class="w-full h-72"></div>
      </div>

      <div class="hrms-card p-5">
        <div class="flex items-center justify-between mb-3">
          <h3 class="text-sm font-semibold text-slate-800">近期出勤趋势</h3>
          <span class="text-xs text-slate-400">打卡与正常人数</span>
        </div>
        <div ref="attendanceChartRef" class="w-full h-72"></div>
      </div>

      <div class="hrms-card p-5">
        <div class="flex items-center justify-between mb-3">
          <h3 class="text-sm font-semibold text-slate-800">月度实发薪资趋势</h3>
          <span class="text-xs text-slate-400">单位：元（RMB）</span>
        </div>
        <div ref="payrollChartRef" class="w-full h-72"></div>
      </div>
    </div>

    <!-- 30-Day Expiring Contracts Table -->
    <div class="hrms-card p-5">
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center gap-2">
          <h3 class="text-sm font-semibold text-slate-800">30天内劳动合同到期预警</h3>
          <el-tag type="warning" size="small" round>{{ expiringContracts.length }} 份即将到期</el-tag>
        </div>
        <el-button v-if="auth.hasRole(['ADMIN', 'HR'])" link type="primary" @click="router.push('/employee')">
          前往员工档案处理 →
        </el-button>
      </div>
      <el-table :data="expiringContracts" stripe size="small" empty-text="未来30天内暂无即将到期的劳动合同">
        <el-table-column prop="empNo" label="工号" width="130" />
        <el-table-column prop="name" label="姓名" width="120" />
        <el-table-column prop="deptName" label="所属部门" min-width="140" />
        <el-table-column prop="positionName" label="岗位" min-width="140" />
        <el-table-column prop="contractEndDate" label="合同到期日" width="130" />
        <el-table-column prop="daysLeft" label="剩余天数" width="110">
          <template #default="{ row }">
            <el-tag :type="row.daysLeft <= 7 ? 'danger' : 'warning'" size="small">
              {{ row.daysLeft }} 天
            </el-tag>
          </template>
        </el-table-column>
      </el-table>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { ElMessage } from 'element-plus'
import * as echarts from 'echarts'
import {
  clockInApi,
  clockOutApi,
  getDashboardOverviewApi,
  getTodayAttendanceApi
} from '@/api/hrms'
import { useAuthStore } from '@/stores/auth'

const router = useRouter()
const auth = useAuthStore()

const loading = ref(false)
const clockLoading = ref(false)
const overview = ref<any>({
  kpis: {
    totalActiveEmployees: 0,
    monthlyHires: 0,
    monthlyResigns: 0,
    todayClockedIn: 0,
    todayAttendanceRate: 0,
    pendingApprovals: 0,
    expiringContractsCount: 0
  },
  expiringContracts: [],
  deptDistribution: [],
  statusDistribution: [],
  attendanceTrend: [],
  payrollTrend: []
})
const todayAtt = ref<any>(null)

const deptChartRef = ref<HTMLElement>()
const statusChartRef = ref<HTMLElement>()
const attendanceChartRef = ref<HTMLElement>()
const payrollChartRef = ref<HTMLElement>()

let charts: echarts.ECharts[] = []

const greetingText = computed(() => {
  const h = new Date().getHours()
  if (h < 12) return '上午好'
  if (h < 18) return '下午好'
  return '晚上好'
})

const expiringContracts = computed(() => overview.value.expiringContracts || [])

const kpiCards = computed(() => {
  const k = overview.value.kpis || {}
  return [
    { label: '在职总人数', value: k.totalActiveEmployees ?? 0, sub: '正式 + 试用期', icon: 'UserFilled', iconClass: 'text-blue-600' },
    { label: '本月新入职', value: k.monthlyHires ?? 0, sub: '团队人才增量', icon: 'CirclePlus', iconClass: 'text-emerald-600' },
    { label: '本月离职数', value: k.monthlyResigns ?? 0, sub: '人员异动流失', icon: 'Remove', iconClass: 'text-rose-500' },
    { label: '今日已打卡', value: k.todayClockedIn ?? 0, sub: `出勤率 ${k.todayAttendanceRate ?? 0}%`, icon: 'Timer', iconClass: 'text-indigo-600' },
    { label: '待审批单据', value: k.pendingApprovals ?? 0, sub: '请假与加班', icon: 'Checked', iconClass: 'text-amber-500' },
    { label: '合同到期预警', value: k.expiringContractsCount ?? 0, sub: '未来30天内', icon: 'Warning', iconClass: 'text-orange-600' }
  ]
})

function formatTime(dt?: string) {
  if (!dt) return '--:--'
  return dt.length >= 16 ? dt.slice(11, 16) : dt
}

const statusLabelMap: Record<string, string> = {
  PROBATION: '试用期',
  ACTIVE: '正式在职',
  RESIGNED: '已离职'
}

function renderCharts() {
  charts.forEach((c) => c.dispose())
  charts = []

  if (deptChartRef.value) {
    const c = echarts.init(deptChartRef.value)
    const data = (overview.value.deptDistribution || []).map((d: any) => ({
      name: d.deptName || '未分配',
      value: Number(d.count || 0)
    }))
    c.setOption({
      tooltip: { trigger: 'item' },
      legend: { bottom: 0, type: 'scroll' },
      color: ['#2563EB', '#0EA5E9', '#10B981', '#F59E0B', '#8B5CF6', '#EC4899'],
      series: [
        {
          name: '人数',
          type: 'pie',
          radius: ['42%', '70%'],
          center: ['50%', '45%'],
          itemStyle: { borderRadius: 6, borderColor: '#fff', borderWidth: 2 },
          data: data.length ? data : [{ name: '暂无数据', value: 0 }]
        }
      ]
    })
    charts.push(c)
  }

  if (statusChartRef.value) {
    const c = echarts.init(statusChartRef.value)
    const rows = overview.value.statusDistribution || []
    c.setOption({
      tooltip: { trigger: 'axis' },
      grid: { left: 40, right: 20, top: 20, bottom: 30 },
      xAxis: {
        type: 'category',
        data: rows.map((r: any) => statusLabelMap[r.status] || r.status)
      },
      yAxis: { type: 'value', minInterval: 1 },
      series: [
        {
          type: 'bar',
          barWidth: 36,
          itemStyle: { color: '#2563EB', borderRadius: [6, 6, 0, 0] },
          data: rows.map((r: any) => Number(r.count || 0))
        }
      ]
    })
    charts.push(c)
  }

  if (attendanceChartRef.value) {
    const c = echarts.init(attendanceChartRef.value)
    const rows = overview.value.attendanceTrend || []
    c.setOption({
      tooltip: { trigger: 'axis' },
      legend: { bottom: 0 },
      grid: { left: 40, right: 20, top: 20, bottom: 40 },
      xAxis: { type: 'category', data: rows.map((r: any) => r.date) },
      yAxis: { type: 'value', minInterval: 1 },
      series: [
        {
          name: '打卡人数',
          type: 'line',
          smooth: true,
          itemStyle: { color: '#2563EB' },
          areaStyle: { color: 'rgba(37,99,235,0.12)' },
          data: rows.map((r: any) => Number(r.clockedIn || 0))
        },
        {
          name: '正常出勤',
          type: 'line',
          smooth: true,
          itemStyle: { color: '#10B981' },
          data: rows.map((r: any) => Number(r.normalCount || 0))
        }
      ]
    })
    charts.push(c)
  }

  if (payrollChartRef.value) {
    const c = echarts.init(payrollChartRef.value)
    const rows = overview.value.payrollTrend || []
    c.setOption({
      tooltip: { trigger: 'axis' },
      grid: { left: 60, right: 20, top: 20, bottom: 30 },
      xAxis: { type: 'category', data: rows.map((r: any) => r.payMonth) },
      yAxis: { type: 'value' },
      series: [
        {
          name: '月度实发总额',
          type: 'bar',
          barWidth: 36,
          itemStyle: { color: '#0EA5E9', borderRadius: [6, 6, 0, 0] },
          data: rows.map((r: any) => Number(r.totalNetSalary || 0))
        }
      ]
    })
    charts.push(c)
  }
}

function handleResize() {
  charts.forEach((c) => c.resize())
}

async function loadData() {
  loading.value = true
  try {
    const [ov, today] = await Promise.all([getDashboardOverviewApi(), getTodayAttendanceApi()])
    overview.value = ov
    todayAtt.value = today
    await nextTick()
    renderCharts()
  } finally {
    loading.value = false
  }
}

async function handleQuickClock(type: 'in' | 'out') {
  clockLoading.value = true
  try {
    todayAtt.value = type === 'in' ? await clockInApi() : await clockOutApi()
    ElMessage.success(type === 'in' ? '签到成功' : '签退成功')
    overview.value = await getDashboardOverviewApi()
    await nextTick()
    renderCharts()
  } finally {
    clockLoading.value = false
  }
}

onMounted(() => {
  loadData()
  window.addEventListener('resize', handleResize)
})

onBeforeUnmount(() => {
  window.removeEventListener('resize', handleResize)
  charts.forEach((c) => c.dispose())
  charts = []
})
</script>
