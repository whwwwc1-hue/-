<template>
  <div class="space-y-5">
    <!-- Today Clock Card -->
    <div class="hrms-card p-5 flex flex-col md:flex-row md:items-center md:justify-between gap-4">
      <div class="space-y-1">
        <div class="text-xs font-medium text-blue-600 uppercase tracking-wider">今日考勤工作台</div>
        <div class="text-2xl font-bold text-slate-800">{{ currentClock }}</div>
        <div class="text-sm text-slate-500">标准班次：09:00 签到 · 18:00 签退</div>
      </div>

      <div class="flex flex-wrap items-center gap-4">
        <div class="rounded-lg bg-slate-50 border border-slate-200 px-4 py-2.5 text-sm">
          <div>
            签到时间：<strong class="text-slate-800">{{ todayAtt?.clockInTime || '未签到' }}</strong>
          </div>
          <div class="mt-1">
            签退时间：<strong class="text-slate-800">{{ todayAtt?.clockOutTime || '未签退' }}</strong>
          </div>
        </div>

        <el-tag v-if="todayAtt" :type="attTagType(todayAtt.status)" size="large">
          {{ attStatusLabel(todayAtt.status) }}
        </el-tag>

        <el-button
          type="primary"
          size="large"
          :loading="clockLoading"
          :disabled="Boolean(todayAtt?.clockInTime)"
          @click="handleClockIn"
        >
          {{ todayAtt?.clockInTime ? '已签到' : '上班签到' }}
        </el-button>
        <el-button
          type="success"
          size="large"
          :loading="clockLoading"
          :disabled="!todayAtt?.clockInTime"
          @click="handleClockOut"
        >
          下班签退
        </el-button>
      </div>
    </div>

    <!-- Monthly Personal Summary -->
    <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
      <div class="hrms-card p-4">
        <div class="text-xs text-slate-400">考核月份</div>
        <div class="text-lg font-bold text-slate-800 mt-1">{{ mySummary.month || myMonth }}</div>
      </div>
      <div class="hrms-card p-4">
        <div class="text-xs text-slate-400">应出勤天数</div>
        <div class="text-lg font-bold text-slate-800 mt-1">{{ mySummary.shouldAttendDays ?? 22 }} 天</div>
      </div>
      <div class="hrms-card p-4">
        <div class="text-xs text-slate-400">实际出勤</div>
        <div class="text-lg font-bold text-blue-600 mt-1">{{ mySummary.actualAttendDays ?? 0 }} 天</div>
      </div>
      <div class="hrms-card p-4">
        <div class="text-xs text-slate-400">迟到 / 早退次数</div>
        <div class="text-lg font-bold text-amber-600 mt-1">
          {{ mySummary.lateCount ?? 0 }} / {{ mySummary.earlyCount ?? 0 }}
        </div>
      </div>
      <div class="hrms-card p-4">
        <div class="text-xs text-slate-400">本月请假天数</div>
        <div class="text-lg font-bold text-slate-800 mt-1">{{ mySummary.leaveDays ?? 0 }} 天</div>
      </div>
      <div class="hrms-card p-4">
        <div class="text-xs text-slate-400">累计加班工时</div>
        <div class="text-lg font-bold text-emerald-600 mt-1">{{ mySummary.overtimeHours ?? 0 }} h</div>
      </div>
    </div>

    <!-- Tabs -->
    <div class="hrms-card p-5">
      <el-tabs v-model="activeTab">
        <el-tab-pane label="我的考勤记录" name="my">
          <div class="flex items-center justify-between mb-4">
            <el-date-picker
              v-model="myMonth"
              type="month"
              value-format="YYYY-MM"
              placeholder="选择月份"
              @change="loadMyAttendance"
            />
          </div>

          <el-table :data="myList" v-loading="myLoading" stripe border>
            <el-table-column prop="workDate" label="考勤日期" width="130" />
            <el-table-column prop="clockInTime" label="签到时间" width="180" />
            <el-table-column prop="clockOutTime" label="签退时间" width="180" />
            <el-table-column prop="lateMinutes" label="迟到(分)" width="100" />
            <el-table-column prop="earlyMinutes" label="早退(分)" width="100" />
            <el-table-column prop="status" label="状态" width="110">
              <template #default="{ row }">
                <el-tag :type="attTagType(row.status)" size="small">{{ attStatusLabel(row.status) }}</el-tag>
              </template>
            </el-table-column>
            <el-table-column prop="remark" label="备注" min-width="180" />
          </el-table>
        </el-tab-pane>

        <el-tab-pane v-if="canManageAttendance" label="全员考勤监控" name="all">
          <div class="flex flex-wrap items-center gap-3 mb-4">
            <el-input
              v-model="allFilters.keyword"
              placeholder="搜索姓名 / 工号"
              clearable
              class="!w-48"
              @keyup.enter="searchAll"
            />
            <el-date-picker
              v-model="allFilters.date"
              type="date"
              value-format="YYYY-MM-DD"
              placeholder="按日期筛选"
              clearable
              @change="searchAll"
            />
            <el-select v-model="allFilters.status" clearable placeholder="考勤状态" class="!w-36" @change="searchAll">
              <el-option label="正常" value="NORMAL" />
              <el-option label="迟到" value="LATE" />
              <el-option label="早退" value="EARLY" />
              <el-option label="迟到且早退" value="LATE_EARLY" />
              <el-option label="请假" value="LEAVE" />
              <el-option label="缺勤" value="ABSENT" />
            </el-select>
            <el-button type="primary" plain icon="Search" @click="searchAll">筛选</el-button>
          </div>

          <el-table :data="allList" v-loading="allLoading" stripe border>
            <el-table-column prop="empNo" label="工号" width="130" />
            <el-table-column prop="empName" label="姓名" width="110" />
            <el-table-column prop="deptName" label="部门" min-width="130" />
            <el-table-column prop="workDate" label="日期" width="120" />
            <el-table-column prop="clockInTime" label="签到" width="170" />
            <el-table-column prop="clockOutTime" label="签退" width="170" />
            <el-table-column prop="status" label="状态" width="115">
              <template #default="{ row }">
                <el-tag :type="attTagType(row.status)" size="small">{{ attStatusLabel(row.status) }}</el-tag>
              </template>
            </el-table-column>
            <el-table-column prop="remark" label="备注" min-width="150" show-overflow-tooltip />
            <el-table-column v-if="isHrOrAdmin" label="操作" width="120" fixed="right">
              <template #default="{ row }">
                <el-button link type="primary" size="small" @click="openFixDialog(row)">补卡/修正</el-button>
              </template>
            </el-table-column>
          </el-table>

          <div class="flex justify-end pt-3">
            <el-pagination
              v-model:current-page="allPagination.page"
              v-model:page-size="allPagination.pageSize"
              :total="allPagination.total"
              layout="total, prev, pager, next"
              @current-change="loadAllAttendance"
            />
          </div>
        </el-tab-pane>
      </el-tabs>
    </div>

    <!-- HR Fix Attendance Dialog -->
    <el-dialog v-model="fixDialogVisible" :title="`修正考勤记录 · ${fixForm.empName}`" width="440px" destroy-on-close>
      <el-form :model="fixForm" label-width="92px">
        <el-form-item label="考勤状态">
          <el-select v-model="fixForm.status" class="w-full">
            <el-option label="正常 NORMAL" value="NORMAL" />
            <el-option label="迟到 LATE" value="LATE" />
            <el-option label="早退 EARLY" value="EARLY" />
            <el-option label="请假 LEAVE" value="LEAVE" />
            <el-option label="缺勤 ABSENT" value="ABSENT" />
          </el-select>
        </el-form-item>
        <el-form-item label="备注说明">
          <el-input v-model="fixForm.remark" type="textarea" :rows="3" placeholder="如：忘记打卡，主管核实补卡" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="fixDialogVisible = false">取消</el-button>
        <el-button type="primary" :loading="fixLoading" @click="submitFix">确认修正</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import {
  clockInApi,
  clockOutApi,
  getAttendanceListApi,
  getMyAttendanceApi,
  getTodayAttendanceApi,
  updateAttendanceApi
} from '@/api/hrms'
import { useAuthStore } from '@/stores/auth'

const auth = useAuthStore()
const canManageAttendance = computed(() => auth.hasRole(['ADMIN', 'HR', 'MANAGER']))
const isHrOrAdmin = computed(() => auth.hasRole(['ADMIN', 'HR']))

const activeTab = ref('my')
const currentClock = ref(new Date().toLocaleString('zh-CN', { hour12: false }))
let timer: number | undefined

const todayAtt = ref<any>(null)
const clockLoading = ref(false)

const myMonth = ref(new Date().toISOString().slice(0, 7))
const myLoading = ref(false)
const myList = ref<any[]>([])
const mySummary = ref<any>({})

const allLoading = ref(false)
const allList = ref<any[]>([])
const allFilters = reactive({ keyword: '', date: '', status: '' })
const allPagination = reactive({ page: 1, pageSize: 10, total: 0 })

const fixDialogVisible = ref(false)
const fixLoading = ref(false)
const fixForm = reactive({ id: 0, empName: '', status: 'NORMAL', remark: '' })

function attStatusLabel(s: string) {
  const m: Record<string, string> = {
    NORMAL: '正常',
    LATE: '迟到',
    EARLY: '早退',
    LATE_EARLY: '迟到且早退',
    LEAVE: '请假',
    ABSENT: '缺勤'
  }
  return m[s] || s
}

function attTagType(s: string): 'success' | 'warning' | 'danger' | 'info' {
  if (s === 'NORMAL') return 'success'
  if (s === 'LEAVE') return 'info'
  if (s === 'ABSENT') return 'danger'
  return 'warning'
}

async function loadToday() {
  todayAtt.value = await getTodayAttendanceApi()
}

async function loadMyAttendance() {
  myLoading.value = true
  try {
    const res = await getMyAttendanceApi({ month: myMonth.value })
    myList.value = res.list
    mySummary.value = res.summary || {}
  } finally {
    myLoading.value = false
  }
}

async function loadAllAttendance() {
  if (!canManageAttendance.value) return
  allLoading.value = true
  try {
    const res = await getAttendanceListApi({
      page: allPagination.page,
      pageSize: allPagination.pageSize,
      keyword: allFilters.keyword || undefined,
      date: allFilters.date || undefined,
      status: allFilters.status || undefined
    })
    allList.value = res.list
    allPagination.total = res.total
  } finally {
    allLoading.value = false
  }
}

function searchAll() {
  allPagination.page = 1
  loadAllAttendance()
}

async function handleClockIn() {
  clockLoading.value = true
  try {
    todayAtt.value = await clockInApi()
    ElMessage.success('签到成功')
    await loadMyAttendance()
    if (canManageAttendance.value) loadAllAttendance()
  } finally {
    clockLoading.value = false
  }
}

async function handleClockOut() {
  clockLoading.value = true
  try {
    todayAtt.value = await clockOutApi()
    ElMessage.success('签退成功')
    await loadMyAttendance()
    if (canManageAttendance.value) loadAllAttendance()
  } finally {
    clockLoading.value = false
  }
}

function openFixDialog(row: any) {
  fixForm.id = row.id
  fixForm.empName = row.empName
  fixForm.status = row.status
  fixForm.remark = row.remark || ''
  fixDialogVisible.value = true
}

async function submitFix() {
  fixLoading.value = true
  try {
    await updateAttendanceApi(fixForm.id, {
      status: fixForm.status,
      remark: fixForm.remark
    })
    ElMessage.success('考勤状态已修正')
    fixDialogVisible.value = false
    await loadAllAttendance()
    await loadMyAttendance()
  } finally {
    fixLoading.value = false
  }
}

onMounted(() => {
  timer = window.setInterval(() => {
    currentClock.value = new Date().toLocaleString('zh-CN', { hour12: false })
  }, 1000)
  loadToday()
  loadMyAttendance()
  if (canManageAttendance.value) loadAllAttendance()
})

onBeforeUnmount(() => {
  if (timer) clearInterval(timer)
})
</script>
