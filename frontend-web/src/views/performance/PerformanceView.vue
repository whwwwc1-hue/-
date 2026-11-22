<template>
  <div class="hrms-card p-5 space-y-4">
    <!-- Toolbar -->
    <div class="flex flex-wrap items-center justify-between gap-3">
      <div class="flex flex-wrap items-center gap-3">
        <el-input
          v-model="filters.cycleName"
          placeholder="考核周期，如 2026-Q4"
          class="!w-48"
          clearable
          @keyup.enter="loadList"
        />
        <el-select v-model="filters.status" clearable placeholder="全部考核状态" class="!w-40" @change="loadList">
          <el-option label="待自评" value="SELF_EVAL" />
          <el-option label="待主管评" value="REVIEWING" />
          <el-option label="已完成" value="COMPLETED" />
        </el-select>
        <el-button type="primary" plain icon="Search" @click="loadList">查询</el-button>
      </div>

      <el-button v-if="isHrOrAdmin" type="primary" icon="Plus" @click="openInitDialog">
        发起考核周期
      </el-button>
    </div>

    <!-- Performance Grade Legend -->
    <div class="rounded-lg bg-blue-50/70 border border-blue-100 px-4 py-2.5 text-xs text-slate-600 flex flex-wrap gap-4">
      <span><strong>奖金系数规则：</strong></span>
      <span>S (≥90分)：1.2倍</span>
      <span>A (80~89分)：1.1倍</span>
      <span>B (70~79分)：1.0倍</span>
      <span>C (60~69分)：0.8倍</span>
      <span>D (&lt;60分)：0.5倍</span>
    </div>

    <el-table :data="list" v-loading="loading" stripe border>
      <el-table-column prop="cycleName" label="考核周期" width="115" />
      <el-table-column prop="empNo" label="工号" width="125" />
      <el-table-column prop="empName" label="姓名" width="100" />
      <el-table-column prop="deptName" label="部门" min-width="130" />
      <el-table-column prop="positionName" label="岗位" min-width="130" />
      <el-table-column prop="selfScore" label="自评分" width="85" />
      <el-table-column prop="finalScore" label="终评分" width="85" />
      <el-table-column prop="grade" label="评级" width="80">
        <template #default="{ row }">
          <el-tag v-if="row.grade" :type="gradeTagType(row.grade)" size="small" effect="dark">{{ row.grade }}</el-tag>
          <span v-else class="text-slate-400">-</span>
        </template>
      </el-table-column>
      <el-table-column prop="bonusRatio" label="奖金系数" width="95">
        <template #default="{ row }">{{ row.bonusRatio }}x</template>
      </el-table-column>
      <el-table-column prop="status" label="阶段状态" width="105">
        <template #default="{ row }">
          <el-tag :type="perfTagType(row.status)" size="small">{{ perfStatusLabel(row.status) }}</el-tag>
        </template>
      </el-table-column>
      <el-table-column label="操作" width="180" fixed="right">
        <template #default="{ row }">
          <el-button
            v-if="row.employeeId === auth.user?.employeeId && row.status !== 'COMPLETED'"
            link
            type="primary"
            size="small"
            @click="openSelfEvalDialog(row)"
          >
            {{ row.status === 'SELF_EVAL' ? '填写自评' : '修改自评' }}
          </el-button>
          <el-button
            v-if="canReview"
            link
            type="warning"
            size="small"
            @click="openReviewDialog(row)"
          >
            主管评分
          </el-button>
        </template>
      </el-table-column>
    </el-table>

    <!-- Init Cycle Dialog -->
    <el-dialog v-model="initDialogVisible" title="发起全员绩效考核周期" width="420px" destroy-on-close>
      <el-form :model="initForm" label-width="92px">
        <el-form-item label="周期名称" required>
          <el-input v-model="initForm.cycleName" placeholder="例如：2026-Q4" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="initDialogVisible = false">取消</el-button>
        <el-button type="primary" :loading="submitLoading" @click="submitInit">确认生成</el-button>
      </template>
    </el-dialog>

    <!-- Self Eval Dialog -->
    <el-dialog v-model="selfDialogVisible" title="员工绩效自评" width="520px" destroy-on-close>
      <el-form :model="selfForm" label-width="92px">
        <el-form-item label="考核周期">{{ selfForm.cycleName }}</el-form-item>
        <el-form-item label="自评分数" required>
          <el-input-number v-model="selfForm.selfScore" :min="0" :max="100" />
        </el-form-item>
        <el-form-item label="工作总结" required>
          <el-input v-model="selfForm.selfSummary" type="textarea" :rows="4" placeholder="请总结本周期重点交付与成果" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="selfDialogVisible = false">取消</el-button>
        <el-button type="primary" :loading="submitLoading" @click="submitSelfEval">提交自评</el-button>
      </template>
    </el-dialog>

    <!-- Manager Review Dialog -->
    <el-dialog v-model="reviewDialogVisible" :title="`主管绩效评定 · ${reviewForm.empName}`" width="520px" destroy-on-close>
      <el-form :model="reviewForm" label-width="92px">
        <el-form-item label="员工自评">
          <div class="rounded bg-slate-50 p-2.5 text-xs text-slate-600 w-full border border-slate-200">
            <div>自评分：<strong>{{ reviewForm.selfScore }}</strong> 分</div>
            <div class="mt-1">自评总结：{{ reviewForm.selfSummary || '暂未填写' }}</div>
          </div>
        </el-form-item>
        <el-form-item label="最终得分" required>
          <div class="flex items-center gap-3">
            <el-input-number v-model="reviewForm.finalScore" :min="0" :max="100" />
            <el-tag :type="gradeTagType(previewGrade.grade)" effect="dark">
              预计评级 {{ previewGrade.grade }} · 奖金系数 {{ previewGrade.ratio }}x
            </el-tag>
          </div>
        </el-form-item>
        <el-form-item label="主管评语">
          <el-input v-model="reviewForm.reviewerComment" type="textarea" :rows="3" placeholder="请输入绩效面谈与评定意见" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="reviewDialogVisible = false">取消</el-button>
        <el-button type="primary" :loading="submitLoading" @click="submitReview">确认终评</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import {
  getPerformancesApi,
  initPerformanceCycleApi,
  submitReviewApi,
  submitSelfEvalApi
} from '@/api/hrms'
import { useAuthStore } from '@/stores/auth'

const auth = useAuthStore()
const isHrOrAdmin = computed(() => auth.hasRole(['ADMIN', 'HR']))
const canReview = computed(() => auth.hasRole(['ADMIN', 'HR', 'MANAGER']))

const loading = ref(false)
const submitLoading = ref(false)
const list = ref<any[]>([])
const filters = reactive({ cycleName: '2026-Q4', status: '' })

const initDialogVisible = ref(false)
const initForm = reactive({ cycleName: '2026-Q4' })

const selfDialogVisible = ref(false)
const selfForm = reactive({ id: 0, cycleName: '', selfScore: 85, selfSummary: '' })

const reviewDialogVisible = ref(false)
const reviewForm = reactive({
  id: 0,
  empName: '',
  selfScore: 0,
  selfSummary: '',
  finalScore: 90,
  reviewerComment: ''
})

const previewGrade = computed(() => {
  const s = Number(reviewForm.finalScore || 0)
  if (s >= 90) return { grade: 'S', ratio: '1.20' }
  if (s >= 80) return { grade: 'A', ratio: '1.10' }
  if (s >= 70) return { grade: 'B', ratio: '1.00' }
  if (s >= 60) return { grade: 'C', ratio: '0.80' }
  return { grade: 'D', ratio: '0.50' }
})

function perfStatusLabel(s: string) {
  if (s === 'SELF_EVAL') return '待自评'
  if (s === 'REVIEWING') return '待主管评'
  if (s === 'COMPLETED') return '已完成'
  return s
}

function perfTagType(s: string): 'warning' | 'primary' | 'success' {
  if (s === 'COMPLETED') return 'success'
  if (s === 'REVIEWING') return 'primary'
  return 'warning'
}

function gradeTagType(g: string): 'danger' | 'warning' | 'success' | 'info' {
  if (g === 'S') return 'danger'
  if (g === 'A') return 'success'
  if (g === 'B') return 'warning'
  return 'info'
}

async function loadList() {
  loading.value = true
  try {
    list.value = await getPerformancesApi({
      cycleName: filters.cycleName || undefined,
      status: filters.status || undefined
    })
  } finally {
    loading.value = false
  }
}

function openInitDialog() {
  initForm.cycleName = filters.cycleName || '2026-Q4'
  initDialogVisible.value = true
}

async function submitInit() {
  if (!initForm.cycleName.trim()) {
    ElMessage.warning('请输入考核周期名称')
    return
  }
  submitLoading.value = true
  try {
    const res = await initPerformanceCycleApi({ cycleName: initForm.cycleName.trim() })
    ElMessage.success(`考核周期已初始化，共覆盖 ${res.count} 名员工`)
    filters.cycleName = initForm.cycleName.trim()
    initDialogVisible.value = false
    await loadList()
  } finally {
    submitLoading.value = false
  }
}

function openSelfEvalDialog(row: any) {
  selfForm.id = row.id
  selfForm.cycleName = row.cycleName
  selfForm.selfScore = Number(row.selfScore || 85)
  selfForm.selfSummary = row.selfSummary || ''
  selfDialogVisible.value = true
}

async function submitSelfEval() {
  if (!selfForm.selfSummary.trim()) {
    ElMessage.warning('请填写自评工作总结')
    return
  }
  submitLoading.value = true
  try {
    await submitSelfEvalApi(selfForm.id, {
      selfScore: selfForm.selfScore,
      selfSummary: selfForm.selfSummary.trim()
    })
    ElMessage.success('自评提交成功')
    selfDialogVisible.value = false
    await loadList()
  } finally {
    submitLoading.value = false
  }
}

function openReviewDialog(row: any) {
  reviewForm.id = row.id
  reviewForm.empName = row.empName
  reviewForm.selfScore = Number(row.selfScore || 0)
  reviewForm.selfSummary = row.selfSummary || ''
  reviewForm.finalScore = Number(row.finalScore || row.selfScore || 85)
  reviewForm.reviewerComment = row.reviewerComment || ''
  reviewDialogVisible.value = true
}

async function submitReview() {
  submitLoading.value = true
  try {
    const res = await submitReviewApi(reviewForm.id, {
      finalScore: reviewForm.finalScore,
      reviewerComment: reviewForm.reviewerComment.trim()
    })
    ElMessage.success(`评定完成：评级 ${res.grade}，系数 ${res.bonusRatio}`)
    reviewDialogVisible.value = false
    await loadList()
  } finally {
    submitLoading.value = false
  }
}

onMounted(loadList)
</script>
