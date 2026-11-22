<template>
  <div class="hrms-card p-5 space-y-4">
    <!-- Filter & Stage Tabs -->
    <div class="flex flex-wrap items-center justify-between gap-3">
      <div class="flex flex-wrap items-center gap-2">
        <el-radio-group v-model="filters.stage" @change="loadList">
          <el-radio-button value="">全部</el-radio-button>
          <el-radio-button value="NEW">初筛 NEW</el-radio-button>
          <el-radio-button value="INTERVIEW">面试中 INTERVIEW</el-radio-button>
          <el-radio-button value="OFFER">已发Offer OFFER</el-radio-button>
          <el-radio-button value="HIRED">已入职 HIRED</el-radio-button>
          <el-radio-button value="REJECTED">已淘汰 REJECTED</el-radio-button>
        </el-radio-group>
        <el-input
          v-model="filters.keyword"
          placeholder="搜索姓名 / 应聘岗位"
          clearable
          class="!w-52 ml-2"
          @keyup.enter="loadList"
          @clear="loadList"
        />
      </div>

      <el-button type="primary" icon="Plus" @click="openCreateDialog">录入候选人</el-button>
    </div>

    <!-- Candidates Table -->
    <el-table :data="list" v-loading="loading" stripe border>
      <el-table-column prop="name" label="姓名" width="110" />
      <el-table-column prop="targetDeptName" label="目标部门" min-width="130" />
      <el-table-column prop="targetPosition" label="应聘岗位" min-width="150" />
      <el-table-column prop="expectedSalary" label="期望薪资" width="110">
        <template #default="{ row }">￥{{ row.expectedSalary }}</template>
      </el-table-column>
      <el-table-column prop="phone" label="联系电话" width="125" />
      <el-table-column prop="source" label="渠道" width="110" />
      <el-table-column prop="stage" label="招聘阶段" width="120">
        <template #default="{ row }">
          <el-tag :type="stageTag(row.stage)" size="small">{{ stageLabel(row.stage) }}</el-tag>
        </template>
      </el-table-column>
      <el-table-column prop="interviewNotes" label="面试评价" min-width="180" show-overflow-tooltip />
      <el-table-column label="操作" width="210" fixed="right">
        <template #default="{ row }">
          <el-button link type="primary" size="small" @click="openEditDialog(row)">推进 / 备注</el-button>
          <el-button
            v-if="row.stage !== 'HIRED' && row.stage !== 'REJECTED'"
            link
            type="success"
            size="small"
            @click="openHireDialog(row)"
          >
            一键转入职
          </el-button>
        </template>
      </el-table-column>
    </el-table>

    <!-- Create / Edit Candidate Dialog -->
    <el-dialog v-model="candDialogVisible" :title="candForm.id ? '推进招聘阶段与面评' : '新增候选人'" width="560px" destroy-on-close>
      <el-form :model="candForm" label-width="96px" class="grid grid-cols-1 sm:grid-cols-2 gap-x-4">
        <el-form-item label="姓名" required>
          <el-input v-model="candForm.name" />
        </el-form-item>
        <el-form-item label="性别">
          <el-select v-model="candForm.gender" class="w-full">
            <el-option label="男" :value="1" />
            <el-option label="女" :value="2" />
          </el-select>
        </el-form-item>
        <el-form-item label="手机号">
          <el-input v-model="candForm.phone" />
        </el-form-item>
        <el-form-item label="邮箱">
          <el-input v-model="candForm.email" />
        </el-form-item>
        <el-form-item label="目标部门">
          <el-select v-model="candForm.targetDeptId" class="w-full">
            <el-option v-for="d in flatDepts" :key="d.id" :label="d.deptName" :value="d.id" />
          </el-select>
        </el-form-item>
        <el-form-item label="应聘岗位" required>
          <el-input v-model="candForm.targetPosition" placeholder="如：仓颉后端工程师" />
        </el-form-item>
        <el-form-item label="期望薪资">
          <el-input-number v-model="candForm.expectedSalary" :min="0" :step="1000" class="!w-full" />
        </el-form-item>
        <el-form-item label="招聘渠道">
          <el-input v-model="candForm.source" placeholder="Boss直聘 / 猎头 / 内推" />
        </el-form-item>
        <el-form-item label="当前阶段" class="sm:col-span-2">
          <el-select v-model="candForm.stage" class="w-full">
            <el-option label="初筛 NEW" value="NEW" />
            <el-option label="面试中 INTERVIEW" value="INTERVIEW" />
            <el-option label="已发Offer OFFER" value="OFFER" />
            <el-option label="已淘汰 REJECTED" value="REJECTED" />
          </el-select>
        </el-form-item>
        <el-form-item label="面试评价" class="sm:col-span-2">
          <el-input v-model="candForm.interviewNotes" type="textarea" :rows="3" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="candDialogVisible = false">取消</el-button>
        <el-button type="primary" :loading="submitLoading" @click="submitCand">保存</el-button>
      </template>
    </el-dialog>

    <!-- Hire Candidate Dialog -->
    <el-dialog v-model="hireDialogVisible" :title="`一键办理入职 · ${hireForm.candName}`" width="450px" destroy-on-close>
      <div class="mb-4 rounded-lg bg-blue-50 p-3 text-xs text-blue-700">
        系统将自动把候选人转为正式员工档案、生成新工号并开通 EMPLOYEE 登录账号（默认密码 123456）。
      </div>
      <el-form :model="hireForm" label-width="96px">
        <el-form-item label="定薪月薪" required>
          <el-input-number v-model="hireForm.baseSalary" :min="0" :step="500" />
        </el-form-item>
        <el-form-item label="入职日期" required>
          <el-date-picker v-model="hireForm.hireDate" type="date" value-format="YYYY-MM-DD" />
        </el-form-item>
        <el-form-item label="员工状态">
          <el-select v-model="hireForm.status" class="w-full">
            <el-option label="试用期 PROBATION" value="PROBATION" />
            <el-option label="正式在职 ACTIVE" value="ACTIVE" />
          </el-select>
        </el-form-item>
        <el-form-item label="登录用户名">
          <el-input v-model="hireForm.username" placeholder="留空则按工号自动生成" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="hireDialogVisible = false">取消</el-button>
        <el-button type="success" :loading="submitLoading" @click="submitHire">确认录用并入职</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import {
  createCandidateApi,
  getCandidatesApi,
  getDeptTreeApi,
  hireCandidateApi,
  updateCandidateApi
} from '@/api/hrms'

const loading = ref(false)
const submitLoading = ref(false)
const list = ref<any[]>([])
const deptTree = ref<any[]>([])
const filters = reactive({ stage: '', keyword: '' })

function flattenTree(nodes: any[]): any[] {
  const res: any[] = []
  for (const n of nodes) {
    res.push(n)
    if (n.children?.length) res.push(...flattenTree(n.children))
  }
  return res
}
const flatDepts = computed(() => flattenTree(deptTree.value))

const candDialogVisible = ref(false)
const candForm = reactive({
  id: 0,
  name: '',
  gender: 1,
  phone: '',
  email: '',
  targetDeptId: undefined as number | undefined,
  targetPosition: '',
  expectedSalary: 18000,
  source: 'Boss直聘',
  stage: 'NEW',
  interviewNotes: ''
})

const hireDialogVisible = ref(false)
const hireForm = reactive({
  candId: 0,
  candName: '',
  baseSalary: 18000,
  hireDate: new Date().toISOString().slice(0, 10),
  status: 'PROBATION',
  username: ''
})

function stageLabel(s: string) {
  const m: Record<string, string> = {
    NEW: '初筛 NEW',
    INTERVIEW: '面试中',
    OFFER: '已发 Offer',
    HIRED: '已入职',
    REJECTED: '已淘汰'
  }
  return m[s] || s
}

function stageTag(s: string): 'info' | 'primary' | 'warning' | 'success' | 'danger' {
  if (s === 'HIRED') return 'success'
  if (s === 'OFFER') return 'warning'
  if (s === 'INTERVIEW') return 'primary'
  if (s === 'REJECTED') return 'danger'
  return 'info'
}

async function loadMeta() {
  deptTree.value = await getDeptTreeApi()
}

async function loadList() {
  loading.value = true
  try {
    list.value = await getCandidatesApi({
      stage: filters.stage || undefined,
      keyword: filters.keyword || undefined
    })
  } finally {
    loading.value = false
  }
}

function openCreateDialog() {
  candForm.id = 0
  candForm.name = ''
  candForm.gender = 1
  candForm.phone = ''
  candForm.email = ''
  candForm.targetDeptId = flatDepts.value[0]?.id
  candForm.targetPosition = ''
  candForm.expectedSalary = 18000
  candForm.source = 'Boss直聘'
  candForm.stage = 'NEW'
  candForm.interviewNotes = ''
  candDialogVisible.value = true
}

function openEditDialog(row: any) {
  candForm.id = row.id
  candForm.name = row.name
  candForm.gender = Number(row.gender || 1)
  candForm.phone = row.phone || ''
  candForm.email = row.email || ''
  candForm.targetDeptId = row.targetDeptId
  candForm.targetPosition = row.targetPosition || ''
  candForm.expectedSalary = Number(row.expectedSalary || 15000)
  candForm.source = row.source || ''
  candForm.stage = row.stage
  candForm.interviewNotes = row.interviewNotes || ''
  candDialogVisible.value = true
}

async function submitCand() {
  if (!candForm.name.trim() || !candForm.targetPosition.trim()) {
    ElMessage.warning('请填写候选人姓名和应聘岗位')
    return
  }
  submitLoading.value = true
  try {
    const payload = {
      name: candForm.name.trim(),
      gender: candForm.gender,
      phone: candForm.phone.trim(),
      email: candForm.email.trim(),
      targetDeptId: candForm.targetDeptId,
      targetPosition: candForm.targetPosition.trim(),
      expectedSalary: candForm.expectedSalary,
      source: candForm.source.trim(),
      stage: candForm.stage,
      interviewNotes: candForm.interviewNotes.trim()
    }
    if (candForm.id) {
      await updateCandidateApi(candForm.id, payload)
      ElMessage.success('候选人信息已更新')
    } else {
      await createCandidateApi(payload)
      ElMessage.success('候选人录入成功')
    }
    candDialogVisible.value = false
    await loadList()
  } finally {
    submitLoading.value = false
  }
}

function openHireDialog(row: any) {
  hireForm.candId = row.id
  hireForm.candName = row.name
  hireForm.baseSalary = Number(row.expectedSalary || 18000)
  hireForm.hireDate = new Date().toISOString().slice(0, 10)
  hireForm.status = 'PROBATION'
  hireForm.username = ''
  hireDialogVisible.value = true
}

async function submitHire() {
  submitLoading.value = true
  try {
    const res = await hireCandidateApi(hireForm.candId, {
      baseSalary: hireForm.baseSalary,
      hireDate: hireForm.hireDate,
      status: hireForm.status,
      username: hireForm.username.trim()
    })
    ElMessage.success(`入职成功！工号 ${res.empNo}，系统账号 ${res.username}`)
    hireDialogVisible.value = false
    await loadList()
  } finally {
    submitLoading.value = false
  }
}

onMounted(() => {
  loadMeta()
  loadList()
})
</script>
