<template>
  <div class="hrms-card p-5">
    <el-tabs v-model="activeTab">
      <!-- Users Management -->
      <el-tab-pane label="账号与角色权限" name="users">
        <div class="flex items-center justify-between mb-4">
          <div class="text-sm text-slate-500">管理系统登录账号、RBAC 角色分配、账号启停与密码重置</div>
          <el-button plain icon="Refresh" @click="loadUsers">刷新</el-button>
        </div>

        <el-table :data="users" v-loading="usersLoading" stripe border>
          <el-table-column prop="id" label="ID" width="70" />
          <el-table-column prop="username" label="登录用户名" width="130" />
          <el-table-column prop="empName" label="关联员工" width="110">
            <template #default="{ row }">{{ row.empName || '-' }}</template>
          </el-table-column>
          <el-table-column prop="deptName" label="所属部门" min-width="130" />
          <el-table-column prop="role" label="RBAC 角色" width="130">
            <template #default="{ row }">
              <el-tag :type="roleTag(row.role)" size="small">{{ row.role }}</el-tag>
            </template>
          </el-table-column>
          <el-table-column prop="isActive" label="账号状态" width="100">
            <template #default="{ row }">
              <el-tag :type="row.isActive ? 'success' : 'danger'" size="small">
                {{ row.isActive ? '启用中' : '已停用' }}
              </el-tag>
            </template>
          </el-table-column>
          <el-table-column prop="lastLoginAt" label="最近登录" width="170" />
          <el-table-column label="操作" width="210" fixed="right">
            <template #default="{ row }">
              <el-button link type="primary" size="small" @click="openEditUser(row)">配置权限</el-button>
              <el-button link type="warning" size="small" @click="handleResetPwd(row)">重置密码</el-button>
            </template>
          </el-table-column>
        </el-table>
      </el-tab-pane>

      <!-- Audit Logs -->
      <el-tab-pane label="安全审计日志" name="logs">
        <div class="flex flex-wrap items-center gap-3 mb-4">
          <el-input
            v-model="logFilters.module"
            placeholder="按模块筛选，如 招聘管理 / 薪酬管理"
            clearable
            class="!w-64"
            @keyup.enter="searchLogs"
            @clear="searchLogs"
          />
          <el-button type="primary" plain icon="Search" @click="searchLogs">查询日志</el-button>
        </div>

        <el-table :data="logs" v-loading="logsLoading" stripe border>
          <el-table-column prop="id" label="ID" width="75" />
          <el-table-column prop="username" label="操作人" width="120" />
          <el-table-column prop="module" label="业务模块" width="130" />
          <el-table-column prop="action" label="操作行为" width="140" />
          <el-table-column prop="detail" label="详细内容" min-width="260" show-overflow-tooltip />
          <el-table-column prop="createdAt" label="操作时间" width="175" />
        </el-table>

        <div class="flex justify-end pt-3">
          <el-pagination
            v-model:current-page="logPagination.page"
            v-model:page-size="logPagination.pageSize"
            :total="logPagination.total"
            :page-sizes="[15, 30, 50]"
            layout="total, sizes, prev, pager, next"
            @current-change="loadLogs"
            @size-change="searchLogs"
          />
        </div>
      </el-tab-pane>
    </el-tabs>

    <!-- Edit User Dialog -->
    <el-dialog v-model="userDialogVisible" :title="`配置账号权限 · ${userForm.username}`" width="420px" destroy-on-close>
      <el-form :model="userForm" label-width="92px">
        <el-form-item label="系统角色">
          <el-select v-model="userForm.role" class="w-full">
            <el-option label="ADMIN (系统管理员)" value="ADMIN" />
            <el-option label="HR (人事主管)" value="HR" />
            <el-option label="MANAGER (部门经理)" value="MANAGER" />
            <el-option label="EMPLOYEE (普通员工)" value="EMPLOYEE" />
          </el-select>
        </el-form-item>
        <el-form-item label="启用状态">
          <el-switch v-model="userForm.isActive" :active-value="1" :inactive-value="0" active-text="启用" inactive-text="停用" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="userDialogVisible = false">取消</el-button>
        <el-button type="primary" :loading="submitLoading" @click="submitUserUpdate">保存配置</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { getAuditLogsApi, getSystemUsersApi, updateSystemUserApi } from '@/api/hrms'
import { confirmAction } from '@/utils/confirm'

const activeTab = ref('users')
const usersLoading = ref(false)
const logsLoading = ref(false)
const submitLoading = ref(false)

const users = ref<any[]>([])
const logs = ref<any[]>([])
const logFilters = reactive({ module: '' })
const logPagination = reactive({ page: 1, pageSize: 15, total: 0 })

const userDialogVisible = ref(false)
const userForm = reactive({ id: 0, username: '', role: 'EMPLOYEE', isActive: 1 })

function roleTag(r: string): 'danger' | 'primary' | 'warning' | 'success' {
  if (r === 'ADMIN') return 'danger'
  if (r === 'HR') return 'primary'
  if (r === 'MANAGER') return 'warning'
  return 'success'
}

async function loadUsers() {
  usersLoading.value = true
  try {
    users.value = await getSystemUsersApi()
  } finally {
    usersLoading.value = false
  }
}

async function loadLogs() {
  logsLoading.value = true
  try {
    const res = await getAuditLogsApi({
      page: logPagination.page,
      pageSize: logPagination.pageSize,
      module: logFilters.module || undefined
    })
    logs.value = res.list
    logPagination.total = res.total
  } finally {
    logsLoading.value = false
  }
}

function searchLogs() {
  logPagination.page = 1
  loadLogs()
}

function openEditUser(row: any) {
  userForm.id = row.id
  userForm.username = row.username
  userForm.role = row.role
  userForm.isActive = Number(row.isActive ?? 1)
  userDialogVisible.value = true
}

async function submitUserUpdate() {
  submitLoading.value = true
  try {
    await updateSystemUserApi(userForm.id, {
      role: userForm.role,
      isActive: userForm.isActive
    })
    ElMessage.success('账号配置已更新')
    userDialogVisible.value = false
    await loadUsers()
  } finally {
    submitLoading.value = false
  }
}

async function handleResetPwd(row: any) {
  const ok = await confirmAction(`确认将账号「${row.username}」的登录密码重置为 123456 吗？`, '重置密码确认')
  if (!ok) return
  await updateSystemUserApi(row.id, { resetPassword: true })
  ElMessage.success(`账号 ${row.username} 密码已重置为 123456`)
}

onMounted(() => {
  loadUsers()
  loadLogs()
})
</script>
