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
      <el-tabs v-model="activeTab" @tab-change="onTabChange">
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
              v-model="allFilters.month"
              type="month"
              value-format="YYYY-MM"
              placeholder="按月份筛选"
              clearable
              @change="searchAll"
            />
            <el-select v-model="allFilters.status" clearable placeholder="考勤状态" class="!w-36" @change="searchAll">
              <el-option label="正常" value="NORMAL" />
              <el-option label="迟到" value="LATE" />
              <el-option label="早退" value="EARLY_LEAVE" />
              <el-option label="迟到且早退" value="LATE_AND_EARLY" />
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

        <el-tab-pane v-if="canManageAttendance" label="月度汇总导出" name="summary">
          <div class="flex flex-wrap items-center gap-3 mb-4">
            <el-date-picker
              v-model="sumMonth"
              type="month"
              value-format="YYYY-MM"
              placeholder="选择月份"
              @change="loadMonthlySummary"
            />
            <el-select v-model="sumDeptId" placeholder="全部部门" clearable class="!w-44" @change="loadMonthlySummary">
              <el-option v-for="d in deptOptions" :key="d.id" :label="d.deptName" :value="d.id" />
            </el-select>
            <el-button type="primary" :loading="sumLoading" :disabled="sumList.length === 0" @click="exportSummaryCsv">
              一键导出 CSV
            </el-button>
            <span class="text-xs text-slate-400">
              应出勤 {{ sumShouldDays }} 天/人（固定口径，不含法定节假日）；出勤率超过 100% 按 100% 显示
            </span>
          </div>

          <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3 mb-4">
            <div class="hrms-card p-4">
              <div class="text-xs text-slate-400">统计人数</div>
              <div class="text-lg font-bold text-slate-800 mt-1">{{ sumTotals.headcount ?? 0 }} 人</div>
            </div>
            <div class="hrms-card p-4">
              <div class="text-xs text-slate-400">整体出勤率</div>
              <div class="text-lg font-bold text-blue-600 mt-1">{{ sumTotals.attendanceRate ?? 0 }}%</div>
            </div>
            <div class="hrms-card p-4">
              <div class="text-xs text-slate-400">合计出勤天数</div>
              <div class="text-lg font-bold text-slate-800 mt-1">{{ sumTotals.actualAttendDays ?? 0 }} 天</div>
            </div>
            <div class="hrms-card p-4">
              <div class="text-xs text-slate-400">迟到 / 早退次数</div>
              <div class="text-lg font-bold text-amber-600 mt-1">
                {{ sumTotals.lateCount ?? 0 }} / {{ sumTotals.earlyCount ?? 0 }}
              </div>
            </div>
            <div class="hrms-card p-4">
              <div class="text-xs text-slate-400">迟到 / 早退分钟</div>
              <div class="text-lg font-bold text-amber-600 mt-1">
                {{ sumTotals.lateMinutes ?? 0 }} / {{ sumTotals.earlyMinutes ?? 0 }}
              </div>
            </div>
            <div class="hrms-card p-4">
              <div class="text-xs text-slate-400">请假 / 加班（已批准）</div>
              <div class="text-lg font-bold text-emerald-600 mt-1">
                {{ sumTotals.leaveDays ?? 0 }} 天 / {{ sumTotals.overtimeHours ?? 0 }} h
              </div>
            </div>
          </div>

          <el-table :data="sumList" v-loading="sumLoading" stripe border max-height="460">
            <el-table-column prop="deptName" label="部门" min-width="120" />
            <el-table-column prop="empNo" label="工号" width="110" />
            <el-table-column prop="empName" label="姓名" width="120" />
            <el-table-column prop="attendDays" label="出勤天数" width="100" />
            <el-table-column prop="attendanceRate" label="出勤率(%)" width="110" />
            <el-table-column prop="lateCount" label="迟到次数" width="100" />
            <el-table-column prop="earlyCount" label="早退次数" width="100" />
            <el-table-column prop="lateMinutes" label="迟到(分)" width="100" />
            <el-table-column prop="earlyMinutes" label="早退(分)" width="100" />
            <el-table-column prop="leaveDays" label="请假(天)" width="100" />
            <el-table-column prop="overtimeHours" label="加班(h)" width="100" />
          </el-table>
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
            <el-option label="早退 EARLY_LEAVE" value="EARLY_LEAVE" />
            <el-option label="迟到且早退 LATE_AND_EARLY" value="LATE_AND_EARLY" />
            <el-option label="缺勤 ABSENT" value="ABSENT" />
          </el-select>
        </el-form-item>
        <el-form-item label="迟到(分)">
          <el-input-number v-model="fixForm.lateMinutes" :min="0" :max="1440" :step="5" class="!w-full" />
        </el-form-item>
        <el-form-item label="早退(分)">
          <el-input-number v-model="fixForm.earlyMinutes" :min="0" :max="1440" :step="5" class="!w-full" />
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
  getAttendanceMonthlySummaryApi,
  getDeptTreeApi,
  getMyAttendanceApi,
  getTodayAttendanceApi,
  updateAttendanceApi
} from '@/api/hrms'
import type { AttendanceSummaryRow, AttendanceSummaryTotals } from '@/api/hrms'
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
const allFilters = reactive({ keyword: '', month: '', status: '' })
const allPagination = reactive({ page: 1, pageSize: 10, total: 0 })

// P2.4 月度汇总（导出 CSV 与页面表格共用同一份 sumList / sumTotals，保证数字一致）
const sumLoading = ref(false)
const sumLoaded = ref(false)
const sumMonth = ref(myMonth.value)
const sumDeptId = ref<number | undefined>(undefined)
const sumList = ref<AttendanceSummaryRow[]>([])
const sumTotals = ref<Partial<AttendanceSummaryTotals>>({})
const sumShouldDays = ref(22)
const deptOptions = ref<{ id: number; deptName: string }[]>([])

const fixDialogVisible = ref(false)
const fixLoading = ref(false)
const fixForm = reactive({ id: 0, empName: '', status: 'NORMAL', lateMinutes: 0, earlyMinutes: 0, remark: '' })

function attStatusLabel(s: string) {
  const m: Record<string, string> = {
    NORMAL: '正常',
    LATE: '迟到',
    EARLY_LEAVE: '早退',
    LATE_AND_EARLY: '迟到且早退',
    // 历史遗留值：新数据不会再产生（请假走假勤审批模块），仅用于旧记录可读展示
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
      month: allFilters.month || undefined,
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

/** 部门树是递归结构，导出筛选只需要一层下拉，按「父在前、子在后」拍平并加缩进。 */
function flattenDeptTree(nodes: any[], depth: number, out: { id: number; deptName: string }[]) {
  for (const n of nodes) {
    out.push({ id: n.id, deptName: `${'　'.repeat(depth)}${n.deptName}` })
    if (Array.isArray(n.children) && n.children.length > 0) {
      flattenDeptTree(n.children, depth + 1, out)
    }
  }
}

async function loadMonthlySummary() {
  if (!canManageAttendance.value) return
  sumLoading.value = true
  try {
    const res = await getAttendanceMonthlySummaryApi({
      month: sumMonth.value || undefined,
      deptId: sumDeptId.value || undefined
    })
    sumList.value = res.list || []
    sumTotals.value = res.summary || {}
    sumShouldDays.value = res.shouldAttendDays || 22
    sumLoaded.value = true
  } finally {
    sumLoading.value = false
  }
}

function onTabChange(name: string | number) {
  if (name !== 'summary' || !canManageAttendance.value) return
  if (deptOptions.value.length === 0) {
    getDeptTreeApi()
      .then((nodes) => {
        const flat: { id: number; deptName: string }[] = []
        flattenDeptTree(nodes || [], 0, flat)
        deptOptions.value = flat
      })
      .catch(() => {
        // 部门列表只是筛选项，拉取失败不应阻断汇总本身
        deptOptions.value = []
      })
  }
  if (!sumLoaded.value) loadMonthlySummary()
}

/**
 * 签到 / 签退 / 补卡修正都会改变当月考勤，已加载过的汇总必须跟着刷新；
 * 否则「页面数字」和稍后导出的 CSV 会来自两次不同的数据快照。
 */
function refreshSummaryIfNeeded() {
  if (canManageAttendance.value && sumLoaded.value) loadMonthlySummary()
}

/**
 * CSV 单元格转义。姓名 / 部门是用户可编辑的自由文本，一旦含逗号或引号，
 * 不转义会让整行列错位（Excel 里表现为「加班小时数跑到了请假列」）。
 */
function csvCell(v: string | number | undefined | null): string {
  if (v === undefined || v === null) return ''
  const s = String(v)
  return /["\r\n,]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
}

/** 导出 CSV：数据源就是页面表格的 sumList/sumTotals，不做二次计算。 */
function exportSummaryCsv() {
  if (sumList.value.length === 0) {
    ElMessage.warning('没有可导出的汇总数据')
    return
  }
  const csvRow = (cells: (string | number | undefined | null)[]): string => cells.map(csvCell).join(',')
  const lines: string[] = []
  lines.push('部门,工号,姓名,出勤天数,应出勤天数,出勤率(%),迟到次数,早退次数,迟到(分钟),早退(分钟),请假(天),加班(小时)')
  for (const row of sumList.value) {
    lines.push(
      csvRow([
        row.deptName,
        row.empNo,
        row.empName,
        row.attendDays,
        sumShouldDays.value,
        row.attendanceRate,
        row.lateCount,
        row.earlyCount,
        row.lateMinutes,
        row.earlyMinutes,
        row.leaveDays,
        row.overtimeHours
      ])
    )
  }
  const t = sumTotals.value
  lines.push(
    csvRow([
      '合计',
      '',
      `${t.headcount ?? 0} 人`,
      t.actualAttendDays ?? 0,
      (t.headcount ?? 0) * sumShouldDays.value,
      t.attendanceRate ?? 0,
      t.lateCount ?? 0,
      t.earlyCount ?? 0,
      t.lateMinutes ?? 0,
      t.earlyMinutes ?? 0,
      t.leaveDays ?? 0,
      t.overtimeHours ?? 0
    ])
  )
  // BOM 头是给 Excel 看的：没有 \uFEFF，Excel 会把 UTF-8 中文按 GBK 打开成乱码
  const blob = new Blob([`\uFEFF${lines.join('\r\n')}`], { type: 'text/csv;charset=utf-8;' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = `考勤月度汇总_${sumMonth.value || 'all'}.csv`
  a.click()
  URL.revokeObjectURL(url)
  ElMessage.success(`已导出 ${sumList.value.length} 人的月度考勤汇总`)
}

async function handleClockIn() {
  clockLoading.value = true
  try {
    todayAtt.value = await clockInApi()
    ElMessage.success('签到成功')
    await loadMyAttendance()
    if (canManageAttendance.value) loadAllAttendance()
    refreshSummaryIfNeeded()
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
    refreshSummaryIfNeeded()
  } finally {
    clockLoading.value = false
  }
}

function openFixDialog(row: any) {
  fixForm.id = row.id
  fixForm.empName = row.empName
  fixForm.status = row.status
  // 后端 handleAttendanceUpdate 对 lateMinutes/earlyMinutes 取的是 getJsonInt(..., 0)，
  // 缺省即清零。原实现只回传 status/remark，会把已有的迟到/早退分钟数抹掉，
  // 进而让月度「迟到/早退次数」统计失真，所以必须先带入当前值再提交。
  fixForm.lateMinutes = Number(row.lateMinutes ?? 0)
  fixForm.earlyMinutes = Number(row.earlyMinutes ?? 0)
  fixForm.remark = row.remark || ''
  fixDialogVisible.value = true
}

async function submitFix() {
  fixLoading.value = true
  try {
    await updateAttendanceApi(fixForm.id, {
      status: fixForm.status,
      lateMinutes: fixForm.lateMinutes,
      earlyMinutes: fixForm.earlyMinutes,
      remark: fixForm.remark
    })
    ElMessage.success('考勤状态已修正')
    fixDialogVisible.value = false
    await loadAllAttendance()
    await loadMyAttendance()
    refreshSummaryIfNeeded()
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
