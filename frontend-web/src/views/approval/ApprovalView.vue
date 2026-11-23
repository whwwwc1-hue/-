<template>
  <div class="hrms-card p-5">
    <el-tabs v-model="activeTab">
      <!-- My Requests -->
      <el-tab-pane label="我的申请记录" name="my">
        <div class="flex flex-wrap items-center justify-between gap-3 mb-4">
          <div class="flex items-center gap-3">
            <el-tag type="primary" size="large" effect="light">
              当前可用年假余额：<strong>{{ auth.user?.annualLeaveBalance ?? 0 }}</strong> 天
            </el-tag>
          </div>
          <el-button type="primary" icon="Plus" @click="openCreateDialog">发起请假 / 加班申请</el-button>
        </div>

        <el-table :data="myList" v-loading="myLoading" stripe border>
          <el-table-column prop="category" label="申请类别" width="100">
            <template #default="{ row }">
              <el-tag :type="row.category === 'LEAVE' ? 'primary' : 'warning'" size="small">
                {{ row.category === 'LEAVE' ? '请假' : '加班' }}
              </el-tag>
            </template>
          </el-table-column>
          <el-table-column prop="subType" label="类型" width="100">
            <template #default="{ row }">{{ subTypeLabel(row.subType) }}</template>
          </el-table-column>
          <el-table-column prop="startTime" label="开始时间" width="165" />
          <el-table-column prop="endTime" label="结束时间" width="165" />
          <el-table-column label="时长" width="90">
            <template #default="{ row }">{{ row.duration }} {{ row.category === 'LEAVE' ? '天' : '小时' }}</template>
          </el-table-column>
          <el-table-column prop="reason" label="事由" min-width="160" show-overflow-tooltip />
          <el-table-column prop="status" label="状态" width="100">
            <template #default="{ row }">
              <el-tag :type="reqTagType(row.status)" size="small">{{ reqStatusLabel(row.status) }}</el-tag>
            </template>
          </el-table-column>
          <el-table-column prop="approveRemark" label="审批意见" min-width="140" show-overflow-tooltip />
          <el-table-column label="操作" width="100" fixed="right">
            <template #default="{ row }">
              <el-button
                v-if="isPendingLike(row.status)"
                link
                type="danger"
                size="small"
                @click="handleCancel(row)"
              >
                撤回
              </el-button>
            </template>
          </el-table-column>
        </el-table>
      </el-tab-pane>

      <!-- Approval Workbench -->
      <el-tab-pane v-if="canApprove" label="审批工作台" name="approve">
        <div class="flex flex-wrap items-center gap-3 mb-4">
          <el-select v-model="allFilters.category" clearable placeholder="全部类别" class="!w-36" @change="searchAll">
            <el-option label="请假单" value="LEAVE" />
            <el-option label="加班单" value="OVERTIME" />
          </el-select>
          <el-select v-model="allFilters.status" clearable placeholder="全部状态" class="!w-36" @change="searchAll">
            <el-option label="待审批" value="PENDING" />
            <el-option label="已通过" value="APPROVED" />
            <el-option label="已驳回" value="REJECTED" />
            <el-option label="已撤回" value="CANCELLED" />
            <el-option label="待主管审批" value="PENDING_MGR" />
            <el-option label="待HR审批" value="PENDING_HR" />
          </el-select>
          <el-button type="primary" plain icon="Search" @click="searchAll">刷新</el-button>
        </div>

        <el-table :data="allList" v-loading="allLoading" stripe border>
          <el-table-column prop="empNo" label="工号" width="125" />
          <el-table-column prop="empName" label="申请人" width="100" />
          <el-table-column prop="deptName" label="部门" width="130" />
          <el-table-column prop="category" label="类别" width="85">
            <template #default="{ row }">
              <el-tag :type="row.category === 'LEAVE' ? 'primary' : 'warning'" size="small">
                {{ row.category === 'LEAVE' ? '请假' : '加班' }}
              </el-tag>
            </template>
          </el-table-column>
          <el-table-column prop="subType" label="细分类型" width="95">
            <template #default="{ row }">{{ subTypeLabel(row.subType) }}</template>
          </el-table-column>
          <el-table-column prop="startTime" label="开始时间" width="160" />
          <el-table-column prop="endTime" label="结束时间" width="160" />
          <el-table-column label="时长" width="85">
            <template #default="{ row }">{{ row.duration }} {{ row.category === 'LEAVE' ? '天' : 'h' }}</template>
          </el-table-column>
          <el-table-column prop="reason" label="事由" min-width="150" show-overflow-tooltip />
          <el-table-column prop="status" label="状态" width="95">
            <template #default="{ row }">
              <el-tag :type="reqTagType(row.status)" size="small">{{ reqStatusLabel(row.status) }}</el-tag>
            </template>
          </el-table-column>
          <el-table-column label="审批级次" width="92">
            <template #default="{ row }">
              <span class="text-xs">{{ levelText(row) }}</span>
            </template>
          </el-table-column>
          <el-table-column label="审批链" min-width="200">
            <template #default="{ row }">
              <div v-if="!row.approvalTrail || row.approvalTrail.length === 0" class="text-xs text-slate-400">
                暂无审批记录
              </div>
              <div v-for="(t, i) in row.approvalTrail || []" :key="i" class="text-xs leading-5">
                {{ i + 1 }}. {{ t.approverName }}（{{ roleLabel(t.approverRole) }}）{{ t.action === 'REJECTED' ? '驳回' : '通过' }}<span v-if="t.remark">：{{ t.remark }}</span>
              </div>
            </template>
          </el-table-column>
          <el-table-column label="审批操作" width="145" fixed="right">
            <template #default="{ row }">
              <template v-if="row.myAction === 'APPROVE'">
                <el-button link type="success" size="small" @click="openApproveDialog(row, 'APPROVED')">通过</el-button>
                <el-button link type="danger" size="small" @click="openApproveDialog(row, 'REJECTED')">驳回</el-button>
              </template>
              <span v-else class="text-xs text-slate-400">{{ row.approverName || fallbackActionText(row) }}</span>
            </template>
          </el-table-column>
        </el-table>

        <div class="flex justify-end pt-3">
          <el-pagination
            v-model:current-page="allPagination.page"
            v-model:page-size="allPagination.pageSize"
            :total="allPagination.total"
            layout="total, prev, pager, next"
            @current-change="loadAllRequests"
          />
        </div>
      </el-tab-pane>
    </el-tabs>

    <!-- Create Request Dialog -->
    <el-dialog v-model="createDialogVisible" title="发起假勤 / 加班申请" width="520px" destroy-on-close>
      <el-form :model="createForm" label-width="96px">
        <el-form-item label="申请类别" required>
          <el-radio-group v-model="createForm.category" @change="onCategoryChange">
            <el-radio-button value="LEAVE">请假申请</el-radio-button>
            <el-radio-button value="OVERTIME">加班申请</el-radio-button>
          </el-radio-group>
        </el-form-item>
        <el-form-item label="细分类型" required>
          <el-select v-model="createForm.subType" class="w-full">
            <template v-if="createForm.category === 'LEAVE'">
              <el-option label="年假 (扣减年假余额)" value="ANNUAL" />
              <el-option label="病假" value="SICK" />
              <el-option label="事假" value="PERSONAL" />
              <el-option label="婚假" value="MARRIAGE" />
            </template>
            <template v-else>
              <el-option label="工作日加班" value="WORKDAY" />
              <el-option label="周末加班" value="WEEKEND" />
              <el-option label="节假日加班" value="HOLIDAY" />
            </template>
          </el-select>
        </el-form-item>
        <el-form-item label="开始时间" required>
          <el-date-picker
            v-model="createForm.startTime"
            type="datetime"
            value-format="YYYY-MM-DD HH:mm:ss"
            class="!w-full"
          />
        </el-form-item>
        <el-form-item label="结束时间" required>
          <el-date-picker
            v-model="createForm.endTime"
            type="datetime"
            value-format="YYYY-MM-DD HH:mm:ss"
            class="!w-full"
          />
        </el-form-item>
        <el-form-item :label="createForm.category === 'LEAVE' ? '请假天数' : '加班小时'" required>
          <el-input-number v-model="createForm.duration" :min="0.5" :step="0.5" :max="365" />
        </el-form-item>
        <el-form-item v-if="isLongLeave" label="审批流程">
          <el-alert
            type="warning"
            :closable="false"
            show-icon
            title="请假超过 3 天将走两级审批：先由部门主管审批，再通过人力资源复核，年假余额仅在终态通过时扣减。"
          />
        </el-form-item>
        <el-form-item label="申请事由" required>
          <el-input v-model="createForm.reason" type="textarea" :rows="3" placeholder="请简述请假或加班事由" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="createDialogVisible = false">取消</el-button>
        <el-button type="primary" :loading="submitLoading" @click="submitCreate">提交审批</el-button>
      </template>
    </el-dialog>

    <!-- Approve / Reject Dialog -->
    <el-dialog
      v-model="approveDialogVisible"
      :title="approveForm.action === 'APPROVED' ? '确认审批通过' : '驳回申请'"
      width="420px"
      destroy-on-close
    >
      <el-form :model="approveForm" label-width="86px">
        <el-form-item label="申请人">{{ approveForm.empName }}</el-form-item>
        <el-form-item label="当前级次">第 {{ approveForm.currentLevel }} 级审批</el-form-item>
        <el-form-item label="审批意见">
          <el-input v-model="approveForm.approveRemark" type="textarea" :rows="3" placeholder="填写审批意见或驳回原因" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="approveDialogVisible = false">取消</el-button>
        <el-button
          :type="approveForm.action === 'APPROVED' ? 'primary' : 'danger'"
          :loading="submitLoading"
          @click="submitApprove"
        >
          {{ approveForm.action === 'APPROVED' ? '同意通过' : '确认驳回' }}
        </el-button>
      </template>
    </el-dialog>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import {
  approveRequestApi,
  cancelRequestApi,
  createRequestApi,
  getMyRequestsApi,
  getRequestListApi
} from '@/api/hrms'
import { useAuthStore } from '@/stores/auth'

const auth = useAuthStore()
const canApprove = computed(() => auth.hasRole(['ADMIN', 'HR', 'MANAGER']))

const activeTab = ref('my')
const myLoading = ref(false)
const myList = ref<any[]>([])

const allLoading = ref(false)
const allList = ref<any[]>([])
const allFilters = reactive({ category: '', status: 'PENDING' })
const allPagination = reactive({ page: 1, pageSize: 10, total: 0 })

const createDialogVisible = ref(false)
const submitLoading = ref(false)
const createForm = reactive({
  category: 'LEAVE',
  subType: 'ANNUAL',
  startTime: '',
  endTime: '',
  duration: 1.0,
  reason: ''
})

const approveDialogVisible = ref(false)
const approveForm = reactive({
  id: 0,
  empName: '',
  action: 'APPROVED',
  approveRemark: '',
  currentLevel: 1
})

function subTypeLabel(s: string) {
  const m: Record<string, string> = {
    ANNUAL: '年假',
    SICK: '病假',
    PERSONAL: '事假',
    MARRIAGE: '婚假',
    WORKDAY: '工作日加班',
    WEEKEND: '周末加班',
    HOLIDAY: '节假日加班'
  }
  return m[s] || s
}

function reqStatusLabel(s: string) {
  const m: Record<string, string> = {
    PENDING: '待审批',
    PENDING_MGR: '待主管审批',
    PENDING_HR: '待HR审批',
    APPROVED: '已通过',
    REJECTED: '已驳回',
    CANCELLED: '已撤回'
  }
  return m[s] || s
}

// P3.1：长假未终态有三档，撤回入口必须与后端 reqIsPendingLike 同口径
const PENDING_LIKE = ['PENDING', 'PENDING_MGR', 'PENDING_HR']
// 与后端 reqLongLeaveDays 一致：仅 LEAVE 且天数严格大于该阈值才走两级
const LONG_LEAVE_DAYS = 3

const isLongLeave = computed(
  () => createForm.category === 'LEAVE' && Number(createForm.duration) > LONG_LEAVE_DAYS
)

function isPendingLike(s: string) {
  return PENDING_LIKE.includes(s)
}

function roleLabel(r: string) {
  const m: Record<string, string> = {
    ADMIN: '系统管理员',
    HR: '人力资源',
    MANAGER: '部门主管',
    EMPLOYEE: '员工'
  }
  return m[r] || r
}

function levelText(row: any) {
  if (row.status === 'APPROVED' || row.status === 'REJECTED' || row.status === 'CANCELLED') {
    return '已终态'
  }
  return row.currentLevel === 2 ? '第二级 / HR' : '第一级'
}

// 无操作权限时给出的兜底说明，避免整列空白让人误以为接口出错
function fallbackActionText(row: any) {
  if (row.status === 'PENDING_MGR') return '待部门主管处理'
  if (row.status === 'PENDING_HR') return '待人力资源处理'
  if (row.status === 'PENDING') return '待处理'
  return '——'
}

function reqTagType(s: string): 'warning' | 'success' | 'danger' | 'info' {
  if (s === 'APPROVED') return 'success'
  if (s === 'REJECTED') return 'danger'
  if (s === 'CANCELLED') return 'info'
  return 'warning'
}

async function loadMyRequests() {
  myLoading.value = true
  try {
    myList.value = await getMyRequestsApi()
  } finally {
    myLoading.value = false
  }
}

async function loadAllRequests() {
  if (!canApprove.value) return
  allLoading.value = true
  try {
    const res = await getRequestListApi({
      page: allPagination.page,
      pageSize: allPagination.pageSize,
      category: allFilters.category || undefined,
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
  loadAllRequests()
}

function onCategoryChange(val: string) {
  createForm.subType = val === 'LEAVE' ? 'ANNUAL' : 'WORKDAY'
}

function openCreateDialog() {
  const today = new Date().toISOString().slice(0, 10)
  createForm.category = 'LEAVE'
  createForm.subType = 'ANNUAL'
  createForm.startTime = `${today} 09:00:00`
  createForm.endTime = `${today} 18:00:00`
  createForm.duration = 1.0
  createForm.reason = ''
  createDialogVisible.value = true
}

async function submitCreate() {
  if (!createForm.startTime || !createForm.endTime || !createForm.reason.trim()) {
    ElMessage.warning('请完整填写开始时间、结束时间和申请事由')
    return
  }
  submitLoading.value = true
  try {
    const res: any = await createRequestApi({
      category: createForm.category,
      subType: createForm.subType,
      startTime: createForm.startTime,
      endTime: createForm.endTime,
      duration: createForm.duration,
      reason: createForm.reason.trim()
    })
    // 长假进入双级链，提示语必须与后端返回的初始状态一致
    if (res?.status === 'PENDING_MGR') {
      ElMessage.success('申请已提交，超过 3 天的长假需主管与人力资源两级审批')
    } else {
      ElMessage.success('申请已提交')
    }
    createDialogVisible.value = false
    await loadMyRequests()
    if (canApprove.value) loadAllRequests()
  } finally {
    submitLoading.value = false
  }
}

async function handleCancel(row: any) {
  await ElMessageBox.confirm('确认撤回该待审批申请单吗？', '撤回确认', { type: 'warning' })
  await cancelRequestApi(row.id)
  ElMessage.success('已撤回申请')
  await loadMyRequests()
  if (canApprove.value) loadAllRequests()
}

function openApproveDialog(row: any, action: 'APPROVED' | 'REJECTED') {
  approveForm.id = row.id
  approveForm.empName = row.empName
  approveForm.action = action
  approveForm.approveRemark = action === 'APPROVED' ? '同意' : ''
  approveForm.currentLevel = row.currentLevel || 1
  approveDialogVisible.value = true
}

async function submitApprove() {
  if (approveForm.action === 'REJECTED') {
    await ElMessageBox.confirm(`确认驳回「${approveForm.empName}」的申请吗？`, '驳回确认', { type: 'warning' })
  }
  submitLoading.value = true
  try {
    const res: any = await approveRequestApi(approveForm.id, {
      action: approveForm.action,
      approveRemark: approveForm.approveRemark.trim()
    })
    if (approveForm.action === 'REJECTED') {
      ElMessage.success('已驳回该申请')
    } else if (res?.status === 'PENDING_HR') {
      // 长假一级通过只是把单据推给 HR，此刻既未生效也不扣年假，提示必须区分开
      ElMessage.success('一级审批通过，已转人力资源复核')
    } else {
      ElMessage.success('审批已通过')
    }
    approveDialogVisible.value = false
    await auth.refreshProfile()
    await loadAllRequests()
    await loadMyRequests()
  } finally {
    submitLoading.value = false
  }
}

onMounted(() => {
  loadMyRequests()
  if (canApprove.value) loadAllRequests()
})
</script>
