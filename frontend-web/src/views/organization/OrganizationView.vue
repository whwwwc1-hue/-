<template>
  <div class="hrms-card p-5">
    <el-tabs v-model="activeTab">
      <!-- Departments Tree Tab -->
      <el-tab-pane label="组织部门架构" name="dept">
        <div class="flex items-center justify-between mb-4">
          <div class="text-sm text-slate-500">管理公司多级部门架构、负责人与人数编制</div>
          <el-button type="primary" icon="Plus" @click="openDeptDialog(null)">新增顶级部门</el-button>
        </div>

        <el-table
          :data="deptTree"
          v-loading="deptLoading"
          row-key="id"
          default-expand-all
          :tree-props="{ children: 'children' }"
          border
        >
          <el-table-column prop="deptName" label="部门名称" min-width="200" />
          <el-table-column prop="leaderName" label="负责人" width="130">
            <template #default="{ row }">{{ row.leaderName || '-' }}</template>
          </el-table-column>
          <el-table-column label="在职 / 编制" width="140">
            <template #default="{ row }">
              <el-tag :type="row.activeCount > row.headcountLimit ? 'danger' : 'info'" size="small">
                {{ row.activeCount ?? 0 }} / {{ row.headcountLimit }} 人
              </el-tag>
            </template>
          </el-table-column>
          <el-table-column prop="description" label="部门职责说明" min-width="200" show-overflow-tooltip />
          <el-table-column label="操作" width="240" fixed="right">
            <template #default="{ row }">
              <el-button link type="primary" size="small" @click="openDeptDialog(null, row.id)">+ 子部门</el-button>
              <el-button link type="primary" size="small" @click="openDeptDialog(row)">编辑</el-button>
              <el-button link type="danger" size="small" @click="handleDeleteDept(row)">删除</el-button>
            </template>
          </el-table-column>
        </el-table>
      </el-tab-pane>

      <!-- Positions Tab -->
      <el-tab-pane label="岗位与职级体系" name="pos">
        <div class="flex flex-wrap items-center justify-between gap-3 mb-4">
          <div class="flex items-center gap-3">
            <el-select v-model="posFilterDeptId" clearable placeholder="按部门筛选岗位" class="!w-52" @change="loadPositions">
              <el-option v-for="d in flatDepts" :key="d.id" :label="d.deptName" :value="d.id" />
            </el-select>
          </div>
          <el-button type="primary" icon="Plus" @click="openPosDialog(null)">新增岗位</el-button>
        </div>

        <el-table :data="positions" v-loading="posLoading" stripe border>
          <el-table-column prop="posCode" label="岗位编码" width="130" />
          <el-table-column prop="posName" label="岗位名称" min-width="160" />
          <el-table-column prop="deptName" label="所属部门" min-width="150" />
          <el-table-column prop="levelRange" label="职级范围" width="120">
            <template #default="{ row }">
              <el-tag effect="plain" size="small">{{ row.levelRange }}</el-tag>
            </template>
          </el-table-column>
          <el-table-column label="薪资带宽（元）" width="180">
            <template #default="{ row }">{{ row.minSalary }} ~ {{ row.maxSalary }}</template>
          </el-table-column>
          <el-table-column label="操作" width="150" fixed="right">
            <template #default="{ row }">
              <el-button link type="primary" size="small" @click="openPosDialog(row)">编辑</el-button>
              <el-button link type="danger" size="small" @click="handleDeletePos(row)">删除</el-button>
            </template>
          </el-table-column>
        </el-table>
      </el-tab-pane>
    </el-tabs>

    <!-- Department Dialog -->
    <el-dialog v-model="deptDialogVisible" :title="deptForm.id ? '编辑部门' : '新增部门'" width="480px" destroy-on-close>
      <el-form :model="deptForm" label-width="96px">
        <el-form-item label="上级部门">
          <el-select v-model="deptForm.parentId" class="w-full">
            <el-option label="无（顶级部门）" :value="0" />
            <el-option
              v-for="d in flatDepts"
              :key="d.id"
              :label="d.deptName"
              :value="d.id"
              :disabled="d.id === deptForm.id"
            />
          </el-select>
        </el-form-item>
        <el-form-item label="部门名称" required>
          <el-input v-model="deptForm.deptName" placeholder="如：技术研发中心" />
        </el-form-item>
        <el-form-item label="负责人">
          <el-input v-model="deptForm.leaderName" placeholder="部门负责人姓名" />
        </el-form-item>
        <el-form-item label="编制人数">
          <el-input-number v-model="deptForm.headcountLimit" :min="1" :max="9999" />
        </el-form-item>
        <el-form-item label="职责说明">
          <el-input v-model="deptForm.description" type="textarea" :rows="3" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="deptDialogVisible = false">取消</el-button>
        <el-button type="primary" :loading="submitLoading" @click="submitDept">保存</el-button>
      </template>
    </el-dialog>

    <!-- Position Dialog -->
    <el-dialog v-model="posDialogVisible" :title="posForm.id ? '编辑岗位' : '新增岗位'" width="480px" destroy-on-close>
      <el-form :model="posForm" label-width="96px">
        <el-form-item label="岗位编码" required>
          <el-input v-model="posForm.posCode" placeholder="如 POS-DEV-03" :disabled="Boolean(posForm.id)" />
        </el-form-item>
        <el-form-item label="岗位名称" required>
          <el-input v-model="posForm.posName" placeholder="如：前端开发工程师" />
        </el-form-item>
        <el-form-item label="所属部门" required>
          <el-select v-model="posForm.deptId" class="w-full" placeholder="请选择部门">
            <el-option v-for="d in flatDepts" :key="d.id" :label="d.deptName" :value="d.id" />
          </el-select>
        </el-form-item>
        <el-form-item label="职级范围">
          <el-input v-model="posForm.levelRange" placeholder="P5-P7" />
        </el-form-item>
        <el-form-item label="最低月薪">
          <el-input-number v-model="posForm.minSalary" :min="0" :step="500" />
        </el-form-item>
        <el-form-item label="最高月薪">
          <el-input-number v-model="posForm.maxSalary" :min="0" :step="1000" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="posDialogVisible = false">取消</el-button>
        <el-button type="primary" :loading="submitLoading" @click="submitPos">保存</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import {
  createDeptApi,
  createPositionApi,
  deleteDeptApi,
  deletePositionApi,
  getDeptTreeApi,
  getPositionsApi,
  updateDeptApi,
  updatePositionApi
} from '@/api/hrms'
import { confirmAction } from '@/utils/confirm'

const activeTab = ref('dept')
const deptLoading = ref(false)
const posLoading = ref(false)
const submitLoading = ref(false)

const deptTree = ref<any[]>([])
const positions = ref<any[]>([])
const posFilterDeptId = ref<number | undefined>(undefined)

function flattenTree(nodes: any[], prefix = ''): any[] {
  const res: any[] = []
  for (const n of nodes) {
    res.push({ ...n, displayName: prefix + n.deptName })
    if (n.children && n.children.length) {
      res.push(...flattenTree(n.children, prefix + n.deptName + ' / '))
    }
  }
  return res
}

const flatDepts = computed(() => flattenTree(deptTree.value))

const deptDialogVisible = ref(false)
const deptForm = reactive({
  id: 0,
  parentId: 0,
  deptName: '',
  leaderName: '',
  headcountLimit: 20,
  description: ''
})

const posDialogVisible = ref(false)
const posForm = reactive({
  id: 0,
  posCode: '',
  posName: '',
  deptId: undefined as number | undefined,
  levelRange: 'P5-P7',
  minSalary: 8000,
  maxSalary: 20000
})

async function loadDepts() {
  deptLoading.value = true
  try {
    deptTree.value = await getDeptTreeApi()
  } finally {
    deptLoading.value = false
  }
}

async function loadPositions() {
  posLoading.value = true
  try {
    positions.value = await getPositionsApi(posFilterDeptId.value ? { deptId: posFilterDeptId.value } : undefined)
  } finally {
    posLoading.value = false
  }
}

function openDeptDialog(row: any, presetParentId = 0) {
  if (row) {
    deptForm.id = row.id
    deptForm.parentId = row.parentId || 0
    deptForm.deptName = row.deptName
    deptForm.leaderName = row.leaderName || ''
    deptForm.headcountLimit = Number(row.headcountLimit || 20)
    deptForm.description = row.description || ''
  } else {
    deptForm.id = 0
    deptForm.parentId = presetParentId
    deptForm.deptName = ''
    deptForm.leaderName = ''
    deptForm.headcountLimit = 20
    deptForm.description = ''
  }
  deptDialogVisible.value = true
}

async function submitDept() {
  if (!deptForm.deptName.trim()) {
    ElMessage.warning('请输入部门名称')
    return
  }
  submitLoading.value = true
  try {
    const payload = {
      parentId: deptForm.parentId,
      deptName: deptForm.deptName.trim(),
      leaderName: deptForm.leaderName.trim(),
      headcountLimit: deptForm.headcountLimit,
      description: deptForm.description.trim()
    }
    if (deptForm.id) {
      await updateDeptApi(deptForm.id, payload)
      ElMessage.success('部门更新成功')
    } else {
      await createDeptApi(payload)
      ElMessage.success('部门创建成功')
    }
    deptDialogVisible.value = false
    await loadDepts()
  } finally {
    submitLoading.value = false
  }
}

async function handleDeleteDept(row: any) {
  const ok = await confirmAction(`确认删除部门「${row.deptName}」吗？若存在子部门或员工将无法删除。`, '删除确认')
  if (!ok) return
  await deleteDeptApi(row.id)
  ElMessage.success('部门已删除')
  await loadDepts()
}

function openPosDialog(row: any) {
  if (row) {
    posForm.id = row.id
    posForm.posCode = row.posCode
    posForm.posName = row.posName
    posForm.deptId = row.deptId
    posForm.levelRange = row.levelRange || 'P5-P7'
    posForm.minSalary = Number(row.minSalary || 8000)
    posForm.maxSalary = Number(row.maxSalary || 20000)
  } else {
    posForm.id = 0
    posForm.posCode = ''
    posForm.posName = ''
    posForm.deptId = flatDepts.value[0]?.id
    posForm.levelRange = 'P5-P7'
    posForm.minSalary = 8000
    posForm.maxSalary = 20000
  }
  posDialogVisible.value = true
}

async function submitPos() {
  if (!posForm.posCode.trim() || !posForm.posName.trim() || !posForm.deptId) {
    ElMessage.warning('请填写完整的岗位编码、名称和所属部门')
    return
  }
  submitLoading.value = true
  try {
    const payload = {
      posCode: posForm.posCode.trim(),
      posName: posForm.posName.trim(),
      deptId: posForm.deptId,
      levelRange: posForm.levelRange.trim(),
      minSalary: posForm.minSalary,
      maxSalary: posForm.maxSalary
    }
    if (posForm.id) {
      await updatePositionApi(posForm.id, payload)
      ElMessage.success('岗位更新成功')
    } else {
      await createPositionApi(payload)
      ElMessage.success('岗位创建成功')
    }
    posDialogVisible.value = false
    await loadPositions()
  } finally {
    submitLoading.value = false
  }
}

async function handleDeletePos(row: any) {
  const ok = await confirmAction(`确认删除岗位「${row.posName}」吗？`, '删除确认')
  if (!ok) return
  await deletePositionApi(row.id)
  ElMessage.success('岗位已删除')
  await loadPositions()
}

onMounted(() => {
  loadDepts()
  loadPositions()
})
</script>
