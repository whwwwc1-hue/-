<template>
  <div class="hrms-card p-5">
    <el-tabs v-model="activeTab">
      <!-- HR/Admin Payroll Calculation Workbench -->
      <el-tab-pane v-if="isHrOrAdmin" label="薪资核算中心" name="admin">
        <div class="flex flex-wrap items-center justify-between gap-3 mb-4">
          <div class="flex flex-wrap items-center gap-3">
            <el-date-picker
              v-model="filters.payMonth"
              type="month"
              value-format="YYYY-MM"
              placeholder="发薪月份"
              @change="handleSearch"
            />
            <el-input
              v-model="filters.keyword"
              placeholder="搜索姓名 / 工号"
              clearable
              class="!w-44"
              @keyup.enter="handleSearch"
            />
            <el-select v-model="filters.status" clearable placeholder="发放状态" class="!w-32" @change="handleSearch">
              <el-option label="草稿" value="DRAFT" />
              <el-option label="已发放" value="PAID" />
            </el-select>
            <el-button type="primary" plain icon="Search" @click="handleSearch">查询</el-button>
          </div>

          <div class="flex flex-wrap items-center gap-2.5">
            <el-button type="primary" icon="Cpu" :loading="opLoading" @click="handleGenerate">
              一键核算生成 {{ filters.payMonth }} 薪资
            </el-button>
            <el-button type="success" icon="Select" :loading="opLoading" @click="handleBatchPay">
              一键全部发放
            </el-button>
            <el-button plain icon="Download" @click="exportCsv">导出 CSV</el-button>
          </div>
        </div>

        <el-table :data="list" v-loading="loading" stripe border>
          <el-table-column prop="payMonth" label="发薪月" width="95" />
          <el-table-column prop="empNo" label="工号" width="125" />
          <el-table-column prop="empName" label="姓名" width="95" />
          <el-table-column prop="deptName" label="部门" min-width="120" />
          <el-table-column prop="baseSalary" label="基本工资" width="100" />
          <el-table-column prop="bonus" label="绩效奖金" width="100" />
          <el-table-column prop="overtimePay" label="加班补贴" width="95" />
          <el-table-column prop="attendanceDeduction" label="考勤扣款" width="95" />
          <el-table-column prop="socialSecurity" label="五险一金" width="100" />
          <el-table-column prop="tax" label="个税" width="85" />
          <el-table-column prop="netSalary" label="实发工资" width="110">
            <template #default="{ row }">
              <strong class="text-blue-600">￥{{ row.netSalary }}</strong>
            </template>
          </el-table-column>
          <el-table-column prop="status" label="状态" width="90">
            <template #default="{ row }">
              <el-tag :type="row.status === 'PAID' ? 'success' : 'warning'" size="small">
                {{ row.status === 'PAID' ? '已发放' : '草稿' }}
              </el-tag>
            </template>
          </el-table-column>
          <el-table-column label="操作" width="150" fixed="right">
            <template #default="{ row }">
              <template v-if="row.status === 'DRAFT'">
                <el-button link type="primary" size="small" @click="openEditDialog(row)">调项</el-button>
                <el-button link type="success" size="small" @click="handlePaySingle(row)">确认发放</el-button>
              </template>
              <span v-else class="text-xs text-slate-400">已发 {{ row.paidAt?.slice(0, 10) }}</span>
            </template>
          </el-table-column>
        </el-table>

        <div class="flex justify-end pt-3">
          <el-pagination
            v-model:current-page="pagination.page"
            v-model:page-size="pagination.pageSize"
            :total="pagination.total"
            layout="total, sizes, prev, pager, next"
            @current-change="loadList"
            @size-change="handleSearch"
          />
        </div>
      </el-tab-pane>

      <!-- My Payslips Tab -->
      <el-tab-pane label="我的工资条" name="my">
        <div class="text-sm text-slate-500 mb-4">仅展示已由 HR 正式发放的个人月度电子工资条</div>
        <el-table :data="myList" v-loading="myLoading" stripe border empty-text="暂无已发放工资条记录">
          <el-table-column prop="payMonth" label="发薪月份" width="110" />
          <el-table-column prop="baseSalary" label="基本工资" width="110" />
          <el-table-column prop="bonus" label="绩效奖金" width="110" />
          <el-table-column prop="overtimePay" label="加班补贴" width="105" />
          <el-table-column prop="attendanceDeduction" label="考勤扣款" width="105" />
          <el-table-column prop="socialSecurity" label="五险一金" width="110" />
          <el-table-column prop="tax" label="代扣个税" width="100" />
          <el-table-column prop="netSalary" label="实发到手" width="125">
            <template #default="{ row }">
              <strong class="text-emerald-600 text-base">￥{{ row.netSalary }}</strong>
            </template>
          </el-table-column>
          <el-table-column prop="paidAt" label="发放时间" width="170" />
          <el-table-column label="详情" width="100" fixed="right">
            <template #default="{ row }">
              <el-button link type="primary" size="small" @click="openSlipModal(row)">电子凭条</el-button>
            </template>
          </el-table-column>
        </el-table>
      </el-tab-pane>
    </el-tabs>

    <!-- Edit Draft Dialog -->
    <el-dialog v-model="editDialogVisible" :title="`调整薪资明细 · ${editForm.empName}`" width="440px" destroy-on-close>
      <el-form :model="editForm" label-width="92px">
        <el-form-item label="绩效奖金">
          <el-input-number v-model="editForm.bonus" :min="0" :step="100" :precision="2" />
        </el-form-item>
        <el-form-item label="加班补贴">
          <el-input-number v-model="editForm.overtimePay" :min="0" :step="100" :precision="2" />
        </el-form-item>
        <el-form-item label="考勤扣款">
          <el-input-number v-model="editForm.attendanceDeduction" :min="0" :step="50" :precision="2" />
        </el-form-item>
        <el-form-item label="调整备注">
          <el-input v-model="editForm.remark" type="textarea" :rows="2" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="editDialogVisible = false">取消</el-button>
        <el-button type="primary" :loading="opLoading" @click="submitEdit">重算并保存</el-button>
      </template>
    </el-dialog>

    <!-- Electronic Payslip Modal -->
    <el-dialog v-model="slipVisible" title="月度电子工资条明细" width="460px">
      <el-descriptions v-if="activeSlip" :column="1" border size="small">
        <el-descriptions-item label="发薪月份">{{ activeSlip.payMonth }}</el-descriptions-item>
        <el-descriptions-item label="员工姓名">{{ activeSlip.empName }} ({{ activeSlip.empNo }})</el-descriptions-item>
        <el-descriptions-item label="基本工资">￥{{ activeSlip.baseSalary }}</el-descriptions-item>
        <el-descriptions-item label="绩效奖金">￥{{ activeSlip.bonus }}</el-descriptions-item>
        <el-descriptions-item label="加班费补贴">￥{{ activeSlip.overtimePay }}</el-descriptions-item>
        <el-descriptions-item label="考勤扣款">-￥{{ activeSlip.attendanceDeduction }}</el-descriptions-item>
        <el-descriptions-item label="五险一金个人部分">-￥{{ activeSlip.socialSecurity }}</el-descriptions-item>
        <el-descriptions-item label="个人所得税">-￥{{ activeSlip.tax }}</el-descriptions-item>
        <el-descriptions-item label="实发净额">
          <span class="text-lg font-bold text-emerald-600">￥{{ activeSlip.netSalary }}</span>
        </el-descriptions-item>
        <el-descriptions-item label="备注">{{ activeSlip.remark || '-' }}</el-descriptions-item>
      </el-descriptions>
    </el-dialog>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import {
  batchPayPayrollApi,
  generatePayrollApi,
  getMyPayrollsApi,
  getPayrollsApi,
  paySinglePayrollApi,
  updatePayrollApi
} from '@/api/hrms'
import { useAuthStore } from '@/stores/auth'
import { confirmAction } from '@/utils/confirm'
import { formatMonth } from '@/utils/date'

const auth = useAuthStore()
const isHrOrAdmin = computed(() => auth.hasRole(['ADMIN', 'HR']))
const activeTab = ref(isHrOrAdmin.value ? 'admin' : 'my')

const loading = ref(false)
const myLoading = ref(false)
const opLoading = ref(false)

const list = ref<any[]>([])
const myList = ref<any[]>([])

const filters = reactive({
  payMonth: formatMonth(),
  keyword: '',
  status: ''
})

const pagination = reactive({
  page: 1,
  pageSize: 10,
  total: 0
})

const editDialogVisible = ref(false)
const editForm = reactive({
  id: 0,
  empName: '',
  bonus: 0,
  overtimePay: 0,
  attendanceDeduction: 0,
  remark: ''
})

const slipVisible = ref(false)
const activeSlip = ref<any>(null)

async function loadList() {
  if (!isHrOrAdmin.value) return
  loading.value = true
  try {
    const res = await getPayrollsApi({
      page: pagination.page,
      pageSize: pagination.pageSize,
      payMonth: filters.payMonth || undefined,
      keyword: filters.keyword || undefined,
      status: filters.status || undefined
    })
    list.value = res.list
    pagination.total = res.total
  } finally {
    loading.value = false
  }
}

async function loadMyPayrolls() {
  myLoading.value = true
  try {
    myList.value = await getMyPayrollsApi()
  } finally {
    myLoading.value = false
  }
}

function handleSearch() {
  pagination.page = 1
  loadList()
}

async function handleGenerate() {
  if (!filters.payMonth) {
    ElMessage.warning('请先选择发薪月份')
    return
  }
  opLoading.value = true
  try {
    const res = await generatePayrollApi({ payMonth: filters.payMonth })
    ElMessage.success(`${res.payMonth} 薪资核算完成，共生成/更新 ${res.generatedCount} 条记录`)
    await loadList()
  } finally {
    opLoading.value = false
  }
}

function openEditDialog(row: any) {
  editForm.id = row.id
  editForm.empName = row.empName
  editForm.bonus = Number(row.bonus || 0)
  editForm.overtimePay = Number(row.overtimePay || 0)
  editForm.attendanceDeduction = Number(row.attendanceDeduction || 0)
  editForm.remark = row.remark || ''
  editDialogVisible.value = true
}

async function submitEdit() {
  opLoading.value = true
  try {
    await updatePayrollApi(editForm.id, {
      bonus: editForm.bonus,
      overtimePay: editForm.overtimePay,
      attendanceDeduction: editForm.attendanceDeduction,
      remark: editForm.remark
    })
    ElMessage.success('明细已更新并重新计税')
    editDialogVisible.value = false
    await loadList()
  } finally {
    opLoading.value = false
  }
}

async function handlePaySingle(row: any) {
  const ok = await confirmAction(`确认向「${row.empName}」发放 ${row.payMonth} 工资 ￥${row.netSalary} 吗？`, '发薪确认')
  if (!ok) return
  opLoading.value = true
  try {
    await paySinglePayrollApi(row.id)
    ElMessage.success('发放成功')
    await loadList()
    await loadMyPayrolls()
  } finally {
    opLoading.value = false
  }
}

async function handleBatchPay() {
  if (!filters.payMonth) {
    ElMessage.warning('请先选择发薪月份')
    return
  }
  const ok = await confirmAction(`确认将 ${filters.payMonth} 所有草稿状态的薪资记录批量标记为「已发放」吗？`, '批量发薪确认')
  if (!ok) return
  opLoading.value = true
  try {
    const res = await batchPayPayrollApi({ payMonth: filters.payMonth })
    ElMessage.success(`批量发薪成功，共发放 ${res.paidCount} 笔`)
    await loadList()
    await loadMyPayrolls()
  } finally {
    opLoading.value = false
  }
}

function exportCsv() {
  if (!list.value.length) {
    ElMessage.info('当前列表暂无可导出数据')
    return
  }
  const headers = ['发薪月', '工号', '姓名', '部门', '基本工资', '绩效奖金', '加班补贴', '考勤扣款', '五险一金', '个税', '实发工资', '状态']
  const rows = list.value.map((r) => [
    r.payMonth,
    r.empNo,
    r.empName,
    r.deptName,
    r.baseSalary,
    r.bonus,
    r.overtimePay,
    r.attendanceDeduction,
    r.socialSecurity,
    r.tax,
    r.netSalary,
    r.status
  ])
  const csvContent = '\uFEFF' + [headers, ...rows].map((row) => row.map((v) => `"${String(v ?? '').replace(/"/g, '""')}"`).join(',')).join('\n')
  const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' })
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = `payroll_${filters.payMonth || 'export'}.csv`
  link.click()
  URL.revokeObjectURL(url)
}

function openSlipModal(row: any) {
  activeSlip.value = row
  slipVisible.value = true
}

onMounted(() => {
  if (isHrOrAdmin.value) loadList()
  loadMyPayrolls()
})
</script>
