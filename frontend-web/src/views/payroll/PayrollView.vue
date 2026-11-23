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
          <el-table-column label="操作" width="205" fixed="right">
            <template #default="{ row }">
              <template v-if="row.status === 'DRAFT'">
                <el-button link type="primary" size="small" @click="openEditDialog(row)">调项</el-button>
                <el-button link type="success" size="small" @click="handlePaySingle(row)">确认发放</el-button>
              </template>
              <span v-else class="text-xs text-slate-400">已发 {{ row.paidAt?.slice(0, 10) }}</span>
              <!-- P2.3：HR 也能代员工预览/打印。草稿态同样可出单，纸质件「发放状态」一栏会如实标注「草稿（尚未发放）」，
                   避免员工不在场时 HR 只能改数据、无法先出条。 -->
              <el-button link type="info" size="small" @click="openSlipModal(row)">电子凭条</el-button>
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
      <template #footer>
        <el-button @click="slipVisible = false">关闭</el-button>
        <el-button type="primary" icon="Printer" @click="printSlip">打印 / 存为 PDF</el-button>
      </template>
    </el-dialog>

    <!-- ==========================================================================
      P2.3 打印专版（纯前端，零 PDF 依赖）
      屏幕上它自身体积为 0（.hrms-print-root { display: none }），纸质/ PDF 里它是唯一内容：
      @media print 会把 #app、遮罩层、加载层、全局提示全部隐藏（样式见 src/style.css）。
      之所以「另存为 PDF」不引入 jsPDF / html2canvas：那两类库把版式交给 canvas 截图，
      生成的 PDF 是不可选型的位图，金额无法复制检索，对工资条这种凭据类文档是倒退。
      ======================================================================== -->
    <Teleport to="body">
      <div v-if="activeSlip" class="hrms-print-root" data-testid="payslip-print-root">
        <div class="hrms-print-head">
          <div class="hrms-print-title">Cangjie HRMS 月度电子工资条</div>
          <div class="hrms-print-meta">
            <span>发薪月份：{{ activeSlip.payMonth }}</span>
            <span>单据编号：{{ slipNo }}</span>
            <span>渲染时间：{{ printStamp }}</span>
          </div>
        </div>

        <table class="hrms-print-sheet">
          <tbody>
            <tr>
              <th class="is-label">姓名</th>
              <td>{{ activeSlip.empName }}</td>
              <th class="is-label">工号</th>
              <td>{{ activeSlip.empNo }}</td>
            </tr>
            <tr>
              <th class="is-label">部门</th>
              <td>{{ activeSlip.deptName || '—' }}</td>
              <th class="is-label">岗位</th>
              <td>{{ activeSlip.positionName || '—' }}</td>
            </tr>
            <tr>
              <th class="is-label">发放状态</th>
              <td>{{ activeSlip.status === 'PAID' ? '已发放' : '草稿（尚未发放）' }}</td>
              <th class="is-label">发放时间</th>
              <td>{{ activeSlip.paidAt || '—' }}</td>
            </tr>
          </tbody>
        </table>

        <table class="hrms-print-sheet">
          <tbody>
            <tr>
              <th class="is-section" colspan="2">应发项目</th>
            </tr>
            <tr>
              <td>基本工资</td>
              <td class="is-amount">{{ money(activeSlip.baseSalary) }}</td>
            </tr>
            <tr>
              <td>绩效奖金</td>
              <td class="is-amount">{{ money(activeSlip.bonus) }}</td>
            </tr>
            <tr>
              <td>加班补贴</td>
              <td class="is-amount">{{ money(activeSlip.overtimePay) }}</td>
            </tr>
            <tr>
              <td class="is-total">应发合计</td>
              <td class="is-amount is-total">{{ money(slipCheck.gross) }}</td>
            </tr>
            <tr>
              <th class="is-section" colspan="2">代扣项目</th>
            </tr>
            <tr>
              <td>考勤扣款</td>
              <td class="is-amount">-{{ money(activeSlip.attendanceDeduction) }}</td>
            </tr>
            <tr>
              <td>五险一金（个人部分）</td>
              <td class="is-amount">-{{ money(activeSlip.socialSecurity) }}</td>
            </tr>
            <tr>
              <td>个人所得税</td>
              <td class="is-amount">-{{ money(activeSlip.tax) }}</td>
            </tr>
            <tr>
              <td class="is-total">代扣合计</td>
              <td class="is-amount is-total">-{{ money(slipCheck.deductions) }}</td>
            </tr>
            <tr>
              <td class="is-net">实发金额</td>
              <td class="is-amount is-net">{{ money(slipCheck.net) }}</td>
            </tr>
          </tbody>
        </table>

        <table class="hrms-print-sheet">
          <tbody>
            <tr>
              <th class="is-label">备注</th>
              <td colspan="3">{{ activeSlip.remark || '—' }}</td>
            </tr>
          </tbody>
        </table>

        <div :class="slipCheck.matched ? 'hrms-print-verify' : 'hrms-print-warn'" data-testid="payslip-verify">
          {{ slipVerifyText }}
        </div>

        <div class="hrms-print-foot">
          本单由前端打印专版渲染，可用于浏览器「打印」或选择「另存为 PDF」；金额口径与后端
          payroll_controller 一致：实发 = 应发合计 −（考勤扣款 + 五险一金 + 个税）。纸质件不带电子签章，
          争议处理以系统记录为准。
        </div>
      </div>
    </Teleport>
  </div>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import {
  batchPayPayrollApi,
  generatePayrollApi,
  getMyPayrollsApi,
  getPayrollsApi,
  paySinglePayrollApi,
  updatePayrollApi
} from '@/api/hrms'
import { useAuthStore } from '@/stores/auth'

const auth = useAuthStore()
const isHrOrAdmin = computed(() => auth.hasRole(['ADMIN', 'HR']))
const activeTab = ref(isHrOrAdmin.value ? 'admin' : 'my')

const loading = ref(false)
const myLoading = ref(false)
const opLoading = ref(false)

const list = ref<any[]>([])
const myList = ref<any[]>([])

const filters = reactive({
  payMonth: '2026-11',
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

/* ---------------------------------------------------------------------------
 * P2.3 打印 / 存为 PDF
 * ------------------------------------------------------------------------- */

/** 挂在 <html> 上的打印模式类，src/style.css 的 @media print 规则以它为开关。 */
const PRINT_MODE_CLASS = 'hrms-payslip-print-mode'

/** 与后端 common/response.cj round2 同口径：绝对值 *100+0.5 后截断，再补符号。 */
function round2(v: number): number {
  const sign = v < 0 ? -1 : 1
  return (sign * Math.trunc(Math.abs(v) * 100 + 0.5)) / 100
}

function num(v: unknown): number {
  const n = Number(v ?? 0)
  return Number.isFinite(n) ? n : 0
}

/** 金额展示统一两位小数，纸质件不会出现 19000 / 19000.0 / 19000.00 三种写法。 */
function money(v: unknown): string {
  return `￥${num(v).toFixed(2)}`
}

/** 固定格式的渲染时间戳，不用 toLocaleString：ICU 与 locale 会随运行环境变，E2E 无法稳定断言。 */
function stampNow(): string {
  const d = new Date()
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`
}

const slipNo = computed(() => {
  const s = activeSlip.value
  return s ? `PS-${s.id}-${s.payMonth}` : ''
})

const printStamp = ref('')

/**
 * 客户端独立复算（第十一节规则③：前端不得只信后端算好的净额）。
 * net 用「先分别合计再相减」，与后端 round2(base+bonus+overtime-deduction-social-tax)
 * 是两条不同的取整路径；各项均为两位小数时两者恒等，一旦后端某天改了舍入口径，
 * 这里就会不一致并拒绝出「看起来正常」的工资条。
 */
const slipCheck = computed(() => {
  const s = activeSlip.value
  if (!s) return { gross: 0, deductions: 0, net: 0, stated: 0, matched: false }
  const gross = round2(num(s.baseSalary) + num(s.bonus) + num(s.overtimePay))
  const deductions = round2(num(s.attendanceDeduction) + num(s.socialSecurity) + num(s.tax))
  const net = round2(gross - deductions)
  const stated = round2(num(s.netSalary))
  return { gross, deductions, net, stated, matched: net === stated }
})

const slipVerifyText = computed(() => {
  const c = slipCheck.value
  return c.matched
    ? `复算校验：应发合计 ${money(c.gross)} − 代扣合计 ${money(c.deductions)} = 实发 ${money(c.net)}，与本单记账实发 ${money(c.stated)} 一致。`
    : `复算校验不一致：按同口径重算实发应为 ${money(c.net)}，本单记账为 ${money(c.stated)}，差额 ${money(round2(Math.abs(c.net - c.stated)))}。请暂缓发放并联系人力资源部核对。`
})

function printSlip() {
  if (!activeSlip.value) return
  printStamp.value = stampNow()
  window.print()
}

watch(slipVisible, (visible) => {
  document.documentElement.classList.toggle(PRINT_MODE_CLASS, visible)
  // 刻意不清空 activeSlip：el-dialog 关闭有淡出动画，清空会让凭条正文在动画期间先消失；
  // 专版在屏幕上本就 display:none，且模式类已摘除，Ctrl+P 也只会打印正常页面。
  if (visible) printStamp.value = stampNow()
})

// 路由离开时 el-dialog 直接卸载，watch 不会被触发，模式类会残留到下一个页面。
onBeforeUnmount(() => {
  document.documentElement.classList.remove(PRINT_MODE_CLASS)
})

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
  await ElMessageBox.confirm(`确认向「${row.empName}」发放 ${row.payMonth} 工资 ￥${row.netSalary} 吗？`, '发薪确认', {
    type: 'warning'
  })
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
  await ElMessageBox.confirm(`确认将 ${filters.payMonth} 所有草稿状态的薪资记录批量标记为「已发放」吗？`, '批量发薪确认', {
    type: 'warning'
  })
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

async function exportCsv() {
  // 之前直接导出 list.value，而 list.value 只是当前页：后端把 pageSize>100 夹回 20
  // （payroll_controller.cj:124），所以超过一页的公司导出的文件里只有屏幕上那几行。
  // 这里按 100 条一页把全量捞齐，导出的行数与筛选条件命中的 total 一致。
  const pageSize = 100
  const rows: any[] = []
  let page = 1
  try {
    for (;;) {
      const res = await getPayrollsApi({
        page,
        pageSize,
        payMonth: filters.payMonth || undefined,
        keyword: filters.keyword || undefined,
        status: filters.status || undefined
      })
      const batch = res.list ?? []
      rows.push(...batch)
      if (batch.length < pageSize || rows.length >= (res.total ?? 0)) break
      page += 1
    }
  } catch {
    ElMessage.error('导出失败：薪资数据拉取不完整')
    return
  }
  if (!rows.length) {
    ElMessage.info('当前列表暂无可导出数据')
    return
  }
  const headers = ['发薪月', '工号', '姓名', '部门', '基本工资', '绩效奖金', '加班补贴', '考勤扣款', '五险一金', '个税', '实发工资', '状态']
  const dataRows = rows.map((r) => [
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
  const csvContent = '\uFEFF' + [headers, ...dataRows].map((row) => row.map((v) => `"${String(v ?? '').replace(/"/g, '""')}"`).join(',')).join('\n')
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
