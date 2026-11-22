<template>
  <div class="hrms-card p-5 space-y-4">
    <!-- Filter Bar -->
    <div class="flex flex-wrap items-center justify-between gap-3">
      <div class="flex flex-wrap items-center gap-3">
        <el-input
          v-model="filters.keyword"
          placeholder="搜索工号 / 姓名 / 手机号"
          clearable
          class="!w-56"
          @keyup.enter="handleSearch"
          @clear="handleSearch"
        />
        <el-select v-model="filters.deptId" clearable placeholder="全部部门" class="!w-44" @change="handleSearch">
          <el-option v-for="d in flatDepts" :key="d.id" :label="d.deptName" :value="d.id" />
        </el-select>
        <el-select v-model="filters.status" clearable placeholder="全部在职状态" class="!w-40" @change="handleSearch">
          <el-option label="试用期" value="PROBATION" />
          <el-option label="正式在职" value="ACTIVE" />
          <el-option label="已离职" value="RESIGNED" />
        </el-select>
        <el-button type="primary" plain icon="Search" @click="handleSearch">查询</el-button>
      </div>

      <el-button v-if="isHrOrAdmin" type="primary" icon="Plus" @click="openCreateDialog">
        办理入职
      </el-button>
    </div>

    <!-- Table -->
    <el-table :data="list" v-loading="loading" stripe border>
      <el-table-column prop="empNo" label="工号" width="130" />
      <el-table-column prop="name" label="姓名" width="110" />
      <el-table-column prop="deptName" label="部门" min-width="130" />
      <el-table-column prop="positionName" label="岗位" min-width="140" />
      <el-table-column prop="phone" label="手机号" width="130" />
      <el-table-column prop="baseSalary" label="基本月薪" width="110" />
      <el-table-column prop="annualLeaveBalance" label="剩余年假" width="95">
        <template #default="{ row }">{{ row.annualLeaveBalance }} 天</template>
      </el-table-column>
      <el-table-column prop="status" label="状态" width="100">
        <template #default="{ row }">
          <el-tag :type="statusTag(row.status)" size="small">{{ statusLabel(row.status) }}</el-tag>
        </template>
      </el-table-column>
      <el-table-column prop="hireDate" label="入职日期" width="115" />
      <el-table-column label="操作" width="250" fixed="right">
        <template #default="{ row }">
          <el-button link type="primary" size="small" @click="openDetail(row.id)">档案</el-button>
          <template v-if="isHrOrAdmin">
            <el-button link type="primary" size="small" @click="openEditDialog(row)">编辑</el-button>
            <el-button
              v-if="row.status !== 'RESIGNED'"
              link
              type="warning"
              size="small"
              @click="openTransferDialog(row)"
            >
              异动/调薪
            </el-button>
            <el-button
              v-if="row.status !== 'RESIGNED'"
              link
              type="danger"
              size="small"
              @click="openResignDialog(row)"
            >
              离职
            </el-button>
          </template>
        </template>
      </el-table-column>
    </el-table>

    <div class="flex justify-end pt-2">
      <el-pagination
        v-model:current-page="pagination.page"
        v-model:page-size="pagination.pageSize"
        :total="pagination.total"
        :page-sizes="[10, 20, 50]"
        layout="total, sizes, prev, pager, next"
        @current-change="loadList"
        @size-change="handleSearch"
      />
    </div>

    <!-- Create / Edit Employee Dialog -->
    <el-dialog v-model="empDialogVisible" :title="empForm.id ? '编辑员工档案' : '办理新员工入职'" width="620px" destroy-on-close>
      <el-form :model="empForm" label-width="100px" class="grid grid-cols-1 sm:grid-cols-2 gap-x-4">
        <el-form-item label="姓名" required>
          <el-input v-model="empForm.name" />
        </el-form-item>
        <el-form-item label="性别">
          <el-select v-model="empForm.gender" class="w-full">
            <el-option label="男" :value="1" />
            <el-option label="女" :value="2" />
          </el-select>
        </el-form-item>
        <el-form-item label="手机号">
          <el-input v-model="empForm.phone" />
        </el-form-item>
        <el-form-item label="邮箱">
          <el-input v-model="empForm.email" />
        </el-form-item>
        <el-form-item label="部门" required>
          <el-select v-model="empForm.deptId" class="w-full" placeholder="选择部门">
            <el-option v-for="d in flatDepts" :key="d.id" :label="d.deptName" :value="d.id" />
          </el-select>
        </el-form-item>
        <el-form-item label="岗位" required>
          <el-select v-model="empForm.positionId" class="w-full" placeholder="选择岗位">
            <el-option v-for="p in positions" :key="p.id" :label="`${p.posName} (${p.deptName})`" :value="p.id" />
          </el-select>
        </el-form-item>
        <el-form-item label="基本月薪">
          <el-input-number v-model="empForm.baseSalary" :min="0" :step="500" class="!w-full" />
        </el-form-item>
        <el-form-item label="在职状态">
          <el-select v-model="empForm.status" class="w-full">
            <el-option label="试用期" value="PROBATION" />
            <el-option label="正式在职" value="ACTIVE" />
          </el-select>
        </el-form-item>
        <el-form-item label="入职日期">
          <el-date-picker v-model="empForm.hireDate" type="date" value-format="YYYY-MM-DD" class="!w-full" />
        </el-form-item>
        <el-form-item label="合同到期日">
          <el-date-picker v-model="empForm.contractEndDate" type="date" value-format="YYYY-MM-DD" class="!w-full" />
        </el-form-item>
        <el-form-item v-if="!empForm.id" label="身份证号" class="sm:col-span-2">
          <el-input v-model="empForm.idCard" placeholder="18位身份证号（列表中自动脱敏显示）" />
        </el-form-item>
        <el-form-item v-if="!empForm.id" label="开通账号" class="sm:col-span-2">
          <div class="flex items-center gap-3 w-full">
            <el-checkbox v-model="empForm.createAccount">自动开通员工登录账号（默认密码 123456）</el-checkbox>
            <el-input v-if="empForm.createAccount" v-model="empForm.username" placeholder="登录用户名（选填）" class="!w-44" />
          </div>
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="empDialogVisible = false">取消</el-button>
        <el-button type="primary" :loading="submitLoading" @click="submitEmp">保存</el-button>
      </template>
    </el-dialog>

    <!-- Transfer / Regularize / Salary Adjust Dialog -->
    <el-dialog v-model="transferDialogVisible" :title="`人事异动 · ${transferTargetName}`" width="500px" destroy-on-close>
      <el-form :model="transferForm" label-width="96px">
        <el-form-item label="异动类型" required>
          <el-select v-model="transferForm.transferType" class="w-full">
            <el-option label="转正定级" value="REGULARIZE" />
            <el-option label="部门/岗位调动" value="TRANSFER" />
            <el-option label="薪资调整" value="SALARY_ADJUST" />
          </el-select>
        </el-form-item>
        <el-form-item label="调整后部门">
          <el-select v-model="transferForm.afterDeptId" class="w-full">
            <el-option v-for="d in flatDepts" :key="d.id" :label="d.deptName" :value="d.id" />
          </el-select>
        </el-form-item>
        <el-form-item label="调整后岗位">
          <el-select v-model="transferForm.afterPositionId" class="w-full" @change="onTransferPosChange">
            <el-option v-for="p in positions" :key="p.id" :label="p.posName" :value="p.id" />
          </el-select>
        </el-form-item>
        <el-form-item label="调整后月薪">
          <el-input-number v-model="transferForm.afterSalary" :min="0" :step="500" />
        </el-form-item>
        <el-form-item label="生效日期" required>
          <el-date-picker v-model="transferForm.effectiveDate" type="date" value-format="YYYY-MM-DD" />
        </el-form-item>
        <el-form-item label="异动备注">
          <el-input v-model="transferForm.remark" type="textarea" :rows="2" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="transferDialogVisible = false">取消</el-button>
        <el-button type="primary" :loading="submitLoading" @click="submitTransfer">确认异动</el-button>
      </template>
    </el-dialog>

    <!-- Resign Dialog -->
    <el-dialog v-model="resignDialogVisible" :title="`办理离职 · ${resignTargetName}`" width="440px" destroy-on-close>
      <el-form :model="resignForm" label-width="92px">
        <el-form-item label="离职日期" required>
          <el-date-picker v-model="resignForm.resignDate" type="date" value-format="YYYY-MM-DD" class="!w-full" />
        </el-form-item>
        <el-form-item label="离职原因">
          <el-input v-model="resignForm.resignReason" type="textarea" :rows="3" placeholder="请输入离职原因与交接备注" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="resignDialogVisible = false">取消</el-button>
        <el-button type="danger" :loading="submitLoading" @click="submitResign">确认离职</el-button>
      </template>
    </el-dialog>

    <!-- Employee 360 Detail Drawer -->
    <el-drawer v-model="detailVisible" title="员工 360° 全景档案" size="560px">
      <template v-if="detailData.employee">
        <el-descriptions :column="2" border size="small" class="mb-6">
          <el-descriptions-item label="工号">{{ detailData.employee.empNo }}</el-descriptions-item>
          <el-descriptions-item label="姓名">{{ detailData.employee.name }}</el-descriptions-item>
          <el-descriptions-item label="部门">{{ detailData.employee.deptName }}</el-descriptions-item>
          <el-descriptions-item label="岗位">{{ detailData.employee.positionName }}</el-descriptions-item>
          <el-descriptions-item label="手机号">{{ detailData.employee.phone }}</el-descriptions-item>
          <el-descriptions-item label="邮箱">{{ detailData.employee.email }}</el-descriptions-item>
          <el-descriptions-item label="身份证号">{{ detailData.employee.idCard || '-' }}</el-descriptions-item>
          <el-descriptions-item label="基本月薪">￥{{ detailData.employee.baseSalary }}</el-descriptions-item>
          <el-descriptions-item label="入职日期">{{ detailData.employee.hireDate }}</el-descriptions-item>
          <el-descriptions-item label="合同到期">{{ detailData.employee.contractEndDate || '-' }}</el-descriptions-item>
          <el-descriptions-item label="剩余年假">{{ detailData.employee.annualLeaveBalance }} 天</el-descriptions-item>
          <el-descriptions-item label="当前状态">
            <el-tag :type="statusTag(detailData.employee.status)" size="small">
              {{ statusLabel(detailData.employee.status) }}
            </el-tag>
          </el-descriptions-item>
        </el-descriptions>

        <h4 class="text-sm font-semibold text-slate-800 mb-3">职业成长与异动履历</h4>
        <el-empty v-if="!detailData.transfers?.length" description="暂无异动记录" :image-size="60" />
        <el-timeline v-else>
          <el-timeline-item
            v-for="t in detailData.transfers"
            :key="t.id"
            :timestamp="t.effectiveDate || t.createdAt"
            placement="top"
            type="primary"
          >
            <div class="rounded-lg border border-slate-200 p-3 bg-slate-50/70 text-xs space-y-1">
              <div class="font-semibold text-slate-800">{{ transferTypeLabel(t.transferType) }}</div>
              <div class="text-slate-600">部门：{{ t.beforeDeptName || '-' }} → {{ t.afterDeptName || '-' }}</div>
              <div class="text-slate-600">岗位：{{ t.beforePosition || '-' }} → {{ t.afterPosition || '-' }}</div>
              <div class="text-slate-600">月薪：￥{{ t.beforeSalary }} → ￥{{ t.afterSalary }}</div>
              <div v-if="t.remark" class="text-slate-500">备注：{{ t.remark }}</div>
            </div>
          </el-timeline-item>
        </el-timeline>
      </template>
    </el-drawer>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import {
  createEmployeeApi,
  getDeptTreeApi,
  getEmployeeDetailApi,
  getEmployeesApi,
  getPositionsApi,
  resignEmployeeApi,
  transferEmployeeApi,
  updateEmployeeApi
} from '@/api/hrms'
import { useAuthStore } from '@/stores/auth'

const auth = useAuthStore()
const isHrOrAdmin = computed(() => auth.hasRole(['ADMIN', 'HR']))

const loading = ref(false)
const submitLoading = ref(false)
const list = ref<any[]>([])
const deptTree = ref<any[]>([])
const positions = ref<any[]>([])

const filters = reactive({
  keyword: '',
  deptId: undefined as number | undefined,
  status: ''
})

const pagination = reactive({
  page: 1,
  pageSize: 10,
  total: 0
})

function flattenTree(nodes: any[]): any[] {
  const res: any[] = []
  for (const n of nodes) {
    res.push(n)
    if (n.children?.length) res.push(...flattenTree(n.children))
  }
  return res
}
const flatDepts = computed(() => flattenTree(deptTree.value))

const empDialogVisible = ref(false)
const empForm = reactive({
  id: 0,
  name: '',
  gender: 1,
  phone: '',
  email: '',
  idCard: '',
  deptId: undefined as number | undefined,
  positionId: undefined as number | undefined,
  baseSalary: 12000,
  status: 'PROBATION',
  hireDate: new Date().toISOString().slice(0, 10),
  contractEndDate: '',
  createAccount: true,
  username: ''
})

const transferDialogVisible = ref(false)
const transferTargetName = ref('')
const transferForm = reactive({
  employeeId: 0,
  transferType: 'REGULARIZE',
  afterDeptId: 1,
  afterPositionId: 1,
  afterPosition: '',
  afterSalary: 12000,
  effectiveDate: new Date().toISOString().slice(0, 10),
  remark: ''
})

const resignDialogVisible = ref(false)
const resignTargetName = ref('')
const resignForm = reactive({
  employeeId: 0,
  resignDate: new Date().toISOString().slice(0, 10),
  resignReason: ''
})

const detailVisible = ref(false)
const detailData = ref<{ employee: any; transfers: any[] }>({ employee: null, transfers: [] })

function statusLabel(s: string) {
  return s === 'ACTIVE' ? '正式在职' : s === 'PROBATION' ? '试用期' : s === 'RESIGNED' ? '已离职' : s
}

function statusTag(s: string): 'success' | 'warning' | 'info' {
  return s === 'ACTIVE' ? 'success' : s === 'PROBATION' ? 'warning' : 'info'
}

function transferTypeLabel(t: string) {
  if (t === 'REGULARIZE') return '试用期转正'
  if (t === 'TRANSFER') return '部门/岗位调动'
  if (t === 'SALARY_ADJUST') return '薪酬调整'
  return t
}

async function loadMeta() {
  const [depts, pos] = await Promise.all([getDeptTreeApi(), getPositionsApi()])
  deptTree.value = depts
  positions.value = pos
}

async function loadList() {
  loading.value = true
  try {
    const res = await getEmployeesApi({
      page: pagination.page,
      pageSize: pagination.pageSize,
      keyword: filters.keyword || undefined,
      deptId: filters.deptId || undefined,
      status: filters.status || undefined
    })
    list.value = res.list
    pagination.total = res.total
  } finally {
    loading.value = false
  }
}

function handleSearch() {
  pagination.page = 1
  loadList()
}

function openCreateDialog() {
  empForm.id = 0
  empForm.name = ''
  empForm.gender = 1
  empForm.phone = ''
  empForm.email = ''
  empForm.idCard = ''
  empForm.deptId = flatDepts.value[0]?.id
  empForm.positionId = positions.value[0]?.id
  empForm.baseSalary = 12000
  empForm.status = 'PROBATION'
  empForm.hireDate = new Date().toISOString().slice(0, 10)
  empForm.contractEndDate = ''
  empForm.createAccount = true
  empForm.username = ''
  empDialogVisible.value = true
}

function openEditDialog(row: any) {
  empForm.id = row.id
  empForm.name = row.name
  empForm.gender = Number(row.gender || 1)
  empForm.phone = row.phone || ''
  empForm.email = row.email || ''
  empForm.idCard = ''
  empForm.deptId = row.deptId
  empForm.positionId = row.positionId
  empForm.baseSalary = Number(row.baseSalary || 0)
  empForm.status = row.status
  empForm.hireDate = row.hireDate || ''
  empForm.contractEndDate = row.contractEndDate || ''
  empDialogVisible.value = true
}

async function submitEmp() {
  if (!empForm.name.trim() || !empForm.deptId || !empForm.positionId) {
    ElMessage.warning('请填写员工姓名、部门和岗位')
    return
  }
  submitLoading.value = true
  try {
    const payload: any = {
      name: empForm.name.trim(),
      gender: empForm.gender,
      phone: empForm.phone.trim(),
      email: empForm.email.trim(),
      deptId: empForm.deptId,
      positionId: empForm.positionId,
      baseSalary: empForm.baseSalary,
      status: empForm.status,
      hireDate: empForm.hireDate,
      contractEndDate: empForm.contractEndDate
    }
    if (empForm.id) {
      await updateEmployeeApi(empForm.id, payload)
      ElMessage.success('员工档案已更新')
    } else {
      payload.idCard = empForm.idCard.trim()
      payload.createAccount = empForm.createAccount
      payload.username = empForm.username.trim()
      const res = await createEmployeeApi(payload)
      ElMessage.success(`入职办理成功，工号 ${res.empNo}${res.accountUsername ? '，账号 ' + res.accountUsername : ''}`)
    }
    empDialogVisible.value = false
    await loadList()
  } finally {
    submitLoading.value = false
  }
}

function openTransferDialog(row: any) {
  transferTargetName.value = row.name
  transferForm.employeeId = row.id
  transferForm.transferType = row.status === 'PROBATION' ? 'REGULARIZE' : 'TRANSFER'
  transferForm.afterDeptId = row.deptId
  transferForm.afterPositionId = row.positionId
  transferForm.afterPosition = row.positionName
  transferForm.afterSalary = Number(row.baseSalary || 0)
  transferForm.effectiveDate = new Date().toISOString().slice(0, 10)
  transferForm.remark = ''
  transferDialogVisible.value = true
}

function onTransferPosChange(posId: number) {
  const found = positions.value.find((p) => p.id === posId)
  if (found) transferForm.afterPosition = found.posName
}

async function submitTransfer() {
  submitLoading.value = true
  try {
    await transferEmployeeApi(transferForm.employeeId, {
      transferType: transferForm.transferType,
      afterDeptId: transferForm.afterDeptId,
      afterPositionId: transferForm.afterPositionId,
      afterPosition: transferForm.afterPosition,
      afterSalary: transferForm.afterSalary,
      effectiveDate: transferForm.effectiveDate,
      remark: transferForm.remark
    })
    ElMessage.success('人事异动已生效')
    transferDialogVisible.value = false
    await loadList()
  } finally {
    submitLoading.value = false
  }
}

function openResignDialog(row: any) {
  resignTargetName.value = row.name
  resignForm.employeeId = row.id
  resignForm.resignDate = new Date().toISOString().slice(0, 10)
  resignForm.resignReason = ''
  resignDialogVisible.value = true
}

async function submitResign() {
  await ElMessageBox.confirm(`确认将员工「${resignTargetName.value}」办理离职并停用关联系统账号吗？`, '离职确认', {
    type: 'warning'
  })
  submitLoading.value = true
  try {
    await resignEmployeeApi(resignForm.employeeId, {
      resignDate: resignForm.resignDate,
      resignReason: resignForm.resignReason
    })
    ElMessage.success('离职手续已办理完成')
    resignDialogVisible.value = false
    await loadList()
  } finally {
    submitLoading.value = false
  }
}

async function openDetail(id: number) {
  detailData.value = await getEmployeeDetailApi(id)
  detailVisible.value = true
}

onMounted(() => {
  loadMeta()
  loadList()
})
</script>
