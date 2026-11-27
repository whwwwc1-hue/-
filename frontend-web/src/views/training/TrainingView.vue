<template>
  <div class="hrms-card p-5">
    <el-tabs v-model="activeTab" @tab-change="onTabChange">
      <!-- ==================== 培训计划（ADMIN / HR）==================== -->
      <el-tab-pane v-if="canManage" label="培训计划" name="plans">
        <div class="flex flex-wrap items-center justify-between gap-3 mb-4">
          <div class="flex flex-wrap items-center gap-3">
            <el-select v-model="filters.status" clearable placeholder="培训状态" class="!w-32" @change="loadPlans">
              <el-option label="草稿" value="DRAFT" />
              <el-option label="已发布" value="PUBLISHED" />
              <el-option label="已结课" value="DONE" />
              <el-option label="已取消" value="CANCELLED" />
            </el-select>
            <el-select v-model="filters.category" clearable placeholder="课程类别" class="!w-32" @change="loadPlans">
              <el-option v-for="c in CATEGORY_OPTIONS" :key="c.value" :label="c.label" :value="c.value" />
            </el-select>
            <el-input
              v-model="filters.keyword"
              placeholder="搜索主题 / 讲师 / 地点"
              clearable
              class="!w-56"
              @keyup.enter="loadPlans"
              @clear="loadPlans"
            />
            <el-button type="primary" plain icon="Search" @click="loadPlans">查询</el-button>
            <el-button plain icon="RefreshLeft" @click="resetFilters">重置</el-button>
          </div>

          <el-button type="primary" icon="Plus" @click="openCreateDialog">新建培训</el-button>
        </div>

        <el-table :data="plans" v-loading="planLoading" stripe border empty-text="暂无培训计划">
          <el-table-column prop="title" label="主题" min-width="190" show-overflow-tooltip />
          <el-table-column prop="categoryLabel" label="类别" width="100" />
          <el-table-column prop="trainer" label="讲师" width="100" />
          <el-table-column prop="deptName" label="适用部门" min-width="130" show-overflow-tooltip />
          <el-table-column prop="startTime" label="开课时间" width="165" />
          <el-table-column prop="endTime" label="结课时间" width="165" />
          <el-table-column prop="credit" label="学分" width="75">
            <template #default="{ row }">{{ numOrDash(row.credit) }}</template>
          </el-table-column>
          <el-table-column label="报名" width="95">
            <!-- capacity=0 在后端语义里是「不限名额」，直接写 0 会被读成「一个名额都没有」 -->
            <template #default="{ row }">
              {{ row.signedCount }}/{{ row.capacity > 0 ? row.capacity : '不限' }}
            </template>
          </el-table-column>
          <el-table-column prop="status" label="状态" width="95">
            <template #default="{ row }">
              <el-tag :type="planTag(row.status)" size="small">{{ row.statusLabel }}</el-tag>
            </template>
          </el-table-column>
          <el-table-column label="操作" width="210" fixed="right">
            <template #default="{ row }">
              <template v-if="row.status === 'DRAFT'">
                <el-button link type="primary" size="small" @click="openEditDialog(row)">编辑</el-button>
                <el-button link type="success" size="small" @click="changePlanStatus(row, 'PUBLISHED')">发布</el-button>
              </template>
              <template v-else-if="row.status === 'PUBLISHED'">
                <el-button link type="primary" size="small" @click="openEditDialog(row)">编辑</el-button>
                <el-button link type="info" size="small" @click="openRoster(row)">花名册</el-button>
                <el-button link type="success" size="small" @click="changePlanStatus(row, 'DONE')">结课</el-button>
                <el-button link type="danger" size="small" @click="changePlanStatus(row, 'CANCELLED')">取消</el-button>
              </template>
              <!-- DONE / CANCELLED 是终态：只剩查名册（已结课仍允许补录成绩，名册按钮必须给） -->
              <el-button v-else link type="info" size="small" @click="openRoster(row)">花名册</el-button>
            </template>
          </el-table-column>
        </el-table>
      </el-tab-pane>

      <!-- ==================== 可报名培训（全角色）==================== -->
      <el-tab-pane label="可报名培训" name="available">
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
          <div class="hrms-card p-4">
            <div class="text-xs text-slate-400">累计学分</div>
            <div class="text-lg font-bold text-blue-600 mt-1">{{ numOrDash(offerSummary.credit) }}</div>
          </div>
          <div class="hrms-card p-4">
            <div class="text-xs text-slate-400">已报名</div>
            <div class="text-lg font-bold text-slate-800 mt-1">{{ offerSummary.enrolled ?? 0 }}</div>
          </div>
          <div class="hrms-card p-4">
            <div class="text-xs text-slate-400">已出勤</div>
            <div class="text-lg font-bold text-emerald-600 mt-1">{{ offerSummary.attended ?? 0 }}</div>
          </div>
          <div class="hrms-card p-4">
            <div class="text-xs text-slate-400">累计学时</div>
            <div class="text-lg font-bold text-slate-800 mt-1">{{ numOrDash(offerSummary.hours) }} h</div>
          </div>
        </div>

        <el-table :data="offers" v-loading="offerLoading" stripe border empty-text="暂无可报名的培训">
          <el-table-column prop="title" label="主题" min-width="190" show-overflow-tooltip />
          <el-table-column prop="categoryLabel" label="类别" width="100" />
          <el-table-column prop="trainer" label="讲师" width="100" />
          <el-table-column prop="startTime" label="开课时间" width="165" />
          <el-table-column prop="location" label="地点" min-width="130" show-overflow-tooltip />
          <el-table-column prop="credit" label="学分" width="75">
            <template #default="{ row }">{{ numOrDash(row.credit) }}</template>
          </el-table-column>
          <el-table-column label="剩余名额" width="95">
            <!-- capacityLeft<0 由后端 trainingCapacityLeft 表示「不限」，与数字 0（满员）含义相反 -->
            <template #default="{ row }">
              <span :class="row.capacityLeft === 0 ? 'text-red-500 font-semibold' : ''">
                {{ row.capacityLeft < 0 ? '不限' : row.capacityLeft }}
              </span>
            </template>
          </el-table-column>
          <el-table-column prop="myStatus" label="我的状态" width="100">
            <template #default="{ row }">
              <el-tag :type="recordTag(row.myStatus)" size="small">{{ row.myStatusLabel }}</el-tag>
            </template>
          </el-table-column>
          <el-table-column label="操作" width="230" fixed="right">
            <template #default="{ row }">
              <el-button v-if="row.canSignup" link type="primary" size="small" @click="handleSignup(row)">报名</el-button>
              <el-button v-if="row.canCheckin" link type="success" size="small" @click="handleCheckin(row)">签到</el-button>
              <el-button v-if="row.canUnsignup" link type="danger" size="small" @click="handleUnsignup(row)">取消报名</el-button>
              <!-- blockReason 是后端算好的唯一口径（未发布 / 名额已满 / 不在受众范围 / 已开课），
                   前端只负责展示，绝不再自己拼一句理由，否则两处规则迟早漂移。 -->
              <el-tooltip v-if="!row.canSignup && row.blockReason" :content="row.blockReason" placement="top">
                <span class="text-xs text-amber-600">{{ row.blockReason }}</span>
              </el-tooltip>
            </template>
          </el-table-column>
        </el-table>
      </el-tab-pane>

      <!-- ==================== 我的培训（全角色）==================== -->
      <el-tab-pane label="我的培训" name="my">
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
          <div class="hrms-card p-4">
            <div class="text-xs text-slate-400">累计学分</div>
            <div class="text-lg font-bold text-blue-600 mt-1">{{ numOrDash(mySummary.totalCredit) }}</div>
          </div>
          <div class="hrms-card p-4">
            <div class="text-xs text-slate-400">已报名</div>
            <div class="text-lg font-bold text-slate-800 mt-1">{{ mySummary.enrolledCount ?? 0 }}</div>
          </div>
          <div class="hrms-card p-4">
            <div class="text-xs text-slate-400">已出勤</div>
            <div class="text-lg font-bold text-emerald-600 mt-1">{{ mySummary.attendedCount ?? 0 }}</div>
          </div>
          <div class="hrms-card p-4">
            <div class="text-xs text-slate-400">累计学时</div>
            <div class="text-lg font-bold text-slate-800 mt-1">{{ numOrDash(mySummary.totalHours) }} h</div>
          </div>
        </div>

        <el-table :data="myRecords" v-loading="myLoading" stripe border empty-text="你还没有报名任何培训">
          <el-table-column prop="title" label="主题" min-width="190" show-overflow-tooltip />
          <el-table-column prop="categoryLabel" label="类别" width="100" />
          <el-table-column prop="trainer" label="讲师" width="100" />
          <el-table-column prop="startTime" label="开课时间" width="165" />
          <el-table-column label="考核分" width="95">
            <!-- score 为 null 是「未考核」，和考了 0 分是两回事，必须显示「—」而不是 0 -->
            <template #default="{ row }">{{ numOrDash(row.score) }}</template>
          </el-table-column>
          <el-table-column label="学分" width="95">
            <template #default="{ row }">
              {{ numOrDash(row.credit) }}
              <span v-if="Number(row.credit) < Number(row.courseCredit)" class="text-xs text-slate-400">
                / {{ numOrDash(row.courseCredit) }}
              </span>
            </template>
          </el-table-column>
          <el-table-column prop="status" label="状态" width="95">
            <template #default="{ row }">
              <el-tag :type="recordTag(row.status)" size="small">{{ row.statusLabel }}</el-tag>
            </template>
          </el-table-column>
          <el-table-column label="签到时间" width="165">
            <template #default="{ row }">{{ row.checkinAt || '—' }}</template>
          </el-table-column>
        </el-table>
      </el-tab-pane>

      <!-- ==================== 学分统计（ADMIN / HR）==================== -->
      <el-tab-pane v-if="canManage" label="学分统计" name="stats">
        <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-3 mb-4">
          <div class="hrms-card p-4">
            <div class="text-xs text-slate-400">培训总数</div>
            <div class="text-lg font-bold text-slate-800 mt-1">{{ statsOverview.total ?? 0 }}</div>
          </div>
          <div class="hrms-card p-4">
            <div class="text-xs text-slate-400">已发布</div>
            <div class="text-lg font-bold text-emerald-600 mt-1">{{ statsOverview.published ?? 0 }}</div>
          </div>
          <div class="hrms-card p-4">
            <div class="text-xs text-slate-400">累计学时</div>
            <div class="text-lg font-bold text-blue-600 mt-1">{{ numOrDash(statsOverview.totalHours) }} h</div>
          </div>
          <div class="hrms-card p-4">
            <div class="text-xs text-slate-400">平均分</div>
            <div class="text-lg font-bold text-amber-600 mt-1">{{ numOrDash(statsOverview.avgScore) }}</div>
          </div>
          <div class="hrms-card p-4">
            <div class="text-xs text-slate-400">覆盖人数</div>
            <div class="text-lg font-bold text-slate-800 mt-1">{{ statsOverview.coveredEmployees ?? 0 }} 人</div>
          </div>
        </div>

        <div class="grid grid-cols-1 xl:grid-cols-2 gap-4">
          <div>
            <div class="text-sm font-semibold text-slate-700 mb-2">学分排行</div>
            <el-table :data="creditRank" v-loading="statsLoading" stripe border max-height="420" empty-text="暂无学分数据">
              <el-table-column label="排名" width="80">
                <template #default="{ $index }">{{ $index + 1 }}</template>
              </el-table-column>
              <el-table-column prop="name" label="姓名" width="120" />
              <el-table-column prop="deptName" label="部门" min-width="130" show-overflow-tooltip />
              <el-table-column prop="credit" label="学分" width="100">
                <template #default="{ row }">
                  <strong class="text-blue-600">{{ numOrDash(row.credit) }}</strong>
                </template>
              </el-table-column>
            </el-table>
          </div>

          <div>
            <div class="text-sm font-semibold text-slate-700 mb-2">课程统计</div>
            <el-table :data="courseStats" v-loading="statsLoading" stripe border max-height="420" empty-text="暂无课程数据">
              <el-table-column prop="title" label="主题" min-width="170" show-overflow-tooltip />
              <el-table-column prop="avgScore" label="平均分" width="95">
                <template #default="{ row }">{{ numOrDash(row.avgScore) }}</template>
              </el-table-column>
              <el-table-column prop="signedCount" label="报名" width="80" />
              <el-table-column prop="attendedCount" label="出勤" width="80" />
              <el-table-column prop="creditTotal" label="学分合计" width="105">
                <template #default="{ row }">{{ numOrDash(row.creditTotal) }}</template>
              </el-table-column>
            </el-table>
          </div>
        </div>
      </el-tab-pane>
    </el-tabs>

    <!-- ==================== 新建 / 编辑培训计划 ==================== -->
    <el-dialog v-model="planDialogVisible" :title="planForm.id ? '编辑培训计划' : '新建培训计划'" width="640px" destroy-on-close>
      <el-form ref="planFormRef" :model="planForm" :rules="planRules" label-width="92px" class="grid grid-cols-1 sm:grid-cols-2 gap-x-4">
        <el-form-item label="主题" prop="title" class="sm:col-span-2">
          <el-input v-model="planForm.title" maxlength="120" show-word-limit placeholder="如：仓颉语言实战训练营" />
        </el-form-item>
        <el-form-item label="类别">
          <el-select v-model="planForm.category" class="w-full">
            <el-option v-for="c in CATEGORY_OPTIONS" :key="c.value" :label="c.label" :value="c.value" />
          </el-select>
        </el-form-item>
        <el-form-item label="讲师" prop="trainer">
          <el-input v-model="planForm.trainer" maxlength="64" placeholder="讲师姓名" />
        </el-form-item>
        <el-form-item label="适用部门">
          <el-select v-model="planForm.deptId" class="w-full">
            <el-option label="全员培训" :value="0" />
            <el-option v-for="d in deptOptions" :key="d.id" :label="d.deptName" :value="d.id" />
          </el-select>
        </el-form-item>
        <el-form-item label="地点">
          <el-input v-model="planForm.location" maxlength="120" placeholder="培训室 / 线上会议链接" />
        </el-form-item>
        <!-- value-format 必须与后端 DATETIME 逐字对齐：handler 用 TIMESTAMPDIFF 直接吃这个串，
             格式不对（如默认的 ISO 带 T 与毫秒）会让时间校验静默失败并报「格式须为 YYYY-MM-DD HH:MM:SS」 -->
        <el-form-item label="开课时间" prop="startTime">
          <el-date-picker
            v-model="planForm.startTime"
            type="datetime"
            value-format="YYYY-MM-DD HH:mm:ss"
            placeholder="选择开课时间"
            class="!w-full"
          />
        </el-form-item>
        <el-form-item label="结课时间" prop="endTime">
          <el-date-picker
            v-model="planForm.endTime"
            type="datetime"
            value-format="YYYY-MM-DD HH:mm:ss"
            placeholder="选择结课时间"
            class="!w-full"
          />
        </el-form-item>
        <el-form-item label="名额">
          <el-input-number v-model="planForm.capacity" :min="0" :max="500" :step="10" class="!w-full" />
        </el-form-item>
        <el-form-item label="学分">
          <el-input-number v-model="planForm.credit" :min="0" :max="10" :step="0.5" :precision="1" class="!w-full" />
        </el-form-item>
        <el-form-item label="课程说明" class="sm:col-span-2">
          <el-input v-model="planForm.description" type="textarea" :rows="3" maxlength="500" show-word-limit />
        </el-form-item>
        <div class="sm:col-span-2 -mt-1 text-xs text-slate-400">
          名额填 0 表示不限名额；学分为本课程满分值，出勤且考核合格后按后端规则折算。
        </div>
      </el-form>
      <template #footer>
        <el-button @click="planDialogVisible = false">取消</el-button>
        <el-button type="primary" :loading="planSubmitting" @click="submitPlan">保存</el-button>
      </template>
    </el-dialog>

    <!-- ==================== 花名册 + 录入结果 ==================== -->
    <el-dialog v-model="rosterVisible" :title="`培训花名册 · ${roster.title}`" width="900px" destroy-on-close>
      <div class="mb-3 flex flex-wrap items-center gap-3 text-sm text-slate-500">
        <span>
          当前状态：<el-tag :type="planTag(roster.status)" size="small">{{ planStatusLabel(roster.status) }}</el-tag>
        </span>
        <span>名册共 {{ roster.rows.length }} 人</span>
        <el-button link type="primary" size="small" icon="Refresh" @click="loadRoster">刷新名册</el-button>
      </div>

      <el-table :data="roster.rows" v-loading="rosterLoading" stripe border max-height="460" empty-text="该培训暂无报名记录">
        <el-table-column prop="name" label="姓名" width="110" />
        <el-table-column prop="empNo" label="工号" width="125" />
        <el-table-column prop="deptName" label="部门" min-width="130" show-overflow-tooltip />
        <el-table-column prop="status" label="状态" width="95">
          <template #default="{ row }">
            <el-tag :type="recordTag(row.status)" size="small">{{ row.statusLabel }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="签到时间" width="165">
          <template #default="{ row }">{{ row.checkinAt || '—' }}</template>
        </el-table-column>
        <el-table-column label="考核分" width="90">
          <template #default="{ row }">{{ numOrDash(row.score) }}</template>
        </el-table-column>
        <el-table-column label="学分" width="85">
          <template #default="{ row }">{{ numOrDash(row.credit) }}</template>
        </el-table-column>
        <el-table-column label="操作" width="110" fixed="right">
          <template #default="{ row }">
            <el-button link type="primary" size="small" @click="openResultDialog(row)">录入结果</el-button>
          </template>
        </el-table-column>
      </el-table>
    </el-dialog>

    <el-dialog v-model="resultVisible" :title="`录入培训结果 · ${resultForm.name}`" width="440px" append-to-body destroy-on-close>
      <el-form :model="resultForm" label-width="92px">
        <el-form-item label="是否出勤">
          <el-switch v-model="resultForm.attended" active-text="出勤" inactive-text="缺席" />
        </el-form-item>
        <el-form-item label="考核得分">
          <el-input-number v-model="resultForm.score" :min="0" :max="100" :step="5" :precision="1" class="!w-full" />
        </el-form-item>
        <el-form-item label="备注">
          <el-input v-model="resultForm.remark" maxlength="255" placeholder="如：缺席原因 / 补录说明" />
        </el-form-item>
        <div class="-mt-1 pl-[92px] text-xs text-slate-400">考核得分留空表示本课程无考核，按出勤情况折算学分。</div>
      </el-form>
      <template #footer>
        <el-button @click="resultVisible = false">取消</el-button>
        <el-button type="primary" :loading="resultSubmitting" @click="submitResult">保存结果</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { useRoute } from 'vue-router'
import { ElMessage, ElMessageBox, type FormInstance, type FormRules } from 'element-plus'
import {
  getDeptTreeApi,
  trainingAvailableApi,
  trainingCheckinApi,
  trainingCreateApi,
  trainingListApi,
  trainingMyApi,
  trainingResultApi,
  trainingRosterApi,
  trainingSignupApi,
  trainingStatsApi,
  trainingUnsignupApi,
  trainingUpdateApi,
  type TrainingCourseStat,
  type TrainingOffer,
  type TrainingPlan,
  type TrainingRankRow,
  type TrainingRecord,
  type TrainingRosterRow
} from '@/api/hrms'
import { useAuthStore } from '@/stores/auth'

const auth = useAuthStore()
const route = useRoute()

/**
 * 培训计划与学分统计共用这一个判定：后端 /trainings、/trainings/stats 虽然也放行 MANAGER
 * （名册按部门范围过滤），但新建 / 修改 / 发布 / 录结果一律 ADMIN+HR。
 * 两个 tab 挂在同一个 canManage 上，既不会出现「主管能看到表格却一个按钮都点不动」，
 * 也不会在别处再写一份角色清单导致两边漂移。
 */
const canManage = computed(() => auth.hasRole(['ADMIN', 'HR']))

type TabName = 'plans' | 'available' | 'my' | 'stats'
const TAB_NAMES: TabName[] = ['plans', 'available', 'my', 'stats']

/**
 * 员工进页面必须落在一个他有权限且能直接操作的 tab 上，否则首屏就是一片空白；
 * ADMIN / HR 则以管理视角（培训计划）开局。通知中心的「培训新课上线」带 ?tab=available，
 * 命中时优先跟随通知意图。
 */
function initialTab(): TabName {
  const q = typeof route.query.tab === 'string' ? route.query.tab : ''
  if (TAB_NAMES.includes(q as TabName) && (q === 'available' || q === 'my' || canManage.value)) {
    return q as TabName
  }
  return canManage.value ? 'plans' : 'available'
}

const activeTab = ref<TabName>(initialTab())

// 与后端 trainingIsValidCategory / trainingCategoryLabel 白名单逐字对齐（含中文文案），
// 后端已经下发 categoryLabel，这里只用于「筛选下拉」与「表单候选」两处输入侧。
const CATEGORY_OPTIONS = [
  { value: 'INTERNAL', label: '内部培训' },
  { value: 'ONLINE', label: '在线课程' },
  { value: 'EXTERNAL', label: '外部课程' },
  { value: 'COMPLIANCE', label: '合规必修' }
]

const planLoading = ref(false)
const offerLoading = ref(false)
const myLoading = ref(false)
const statsLoading = ref(false)
const planSubmitting = ref(false)

const plans = ref<TrainingPlan[]>([])
const offers = ref<TrainingOffer[]>([])
const myRecords = ref<TrainingRecord[]>([])
const creditRank = ref<TrainingRankRow[]>([])
const courseStats = ref<TrainingCourseStat[]>([])
const offerSummary = ref<Record<string, number>>({})
const mySummary = ref<Record<string, number>>({})
const statsOverview = ref<Record<string, number>>({})
const filters = reactive({ status: '', category: '', keyword: '' })

/**
 * tab 数据按需加载 + 脏标记：培训域四个 tab 共用同一批后端数据，任何一个写操作都会同时
 * 影响别的 tab（报名成功 → 我的培训、学分统计、计划报名数都要变）。逐个 await 会把一次
 * 点击变成四次请求，所以只立刻刷新当前可见 tab，其余打脏、切过去时再拉。
 */
const tabLoaded = reactive<Record<TabName, boolean>>({ plans: false, available: false, my: false, stats: false })
const loaders: Record<TabName, () => Promise<void>> = {
  plans: loadPlans,
  available: loadOffers,
  my: loadMyRecords,
  stats: loadStats
}

function onTabChange(name: string | number) {
  ensureTab(String(name) as TabName)
}

function ensureTab(name: TabName) {
  if (tabLoaded[name]) return
  void loaders[name]()
}

function invalidateTabs(affected: TabName[]) {
  for (const name of affected) {
    if (name === activeTab.value) void loaders[name]()
    else tabLoaded[name] = false
  }
}

/** 后端 DECIMAL 列经 CAST(x AS CHAR) 拼进 JSON，异常行可能是空串；统一兜成「—」比兜成 0 诚实。 */
function numOrDash(v: number | string | null | undefined): string {
  if (v === null || v === undefined || v === '') return '—'
  const n = Number(v)
  return Number.isFinite(n) ? String(n) : '—'
}

function planTag(status: string): 'info' | 'success' | 'warning' | 'danger' {
  if (status === 'PUBLISHED') return 'success'
  if (status === 'DONE') return 'info'
  if (status === 'CANCELLED') return 'danger'
  return 'warning'
}

function recordTag(status: string): 'info' | 'success' | 'warning' | 'danger' {
  if (status === 'ATTENDED') return 'success'
  if (status === 'ABSENT') return 'danger'
  if (status === 'CANCELLED') return 'info'
  return 'warning'
}

// 计划状态标签由后端 statusLabel 下发，只有名册头部需要前端自己取一次（名册接口只回 status）。
function planStatusLabel(status: string): string {
  const m: Record<string, string> = { DRAFT: '草稿', PUBLISHED: '已发布', DONE: '已结课', CANCELLED: '已取消' }
  return m[status] || status
}

function toPlanPayload(row: TrainingPlan) {
  return {
    title: row.title,
    category: row.category,
    trainer: row.trainer,
    deptId: row.deptId,
    startTime: row.startTime,
    endTime: row.endTime,
    capacity: Number(row.capacity) || 0,
    credit: Number(row.credit) || 0,
    location: row.location || '',
    description: row.description || ''
  }
}

async function loadPlans() {
  planLoading.value = true
  try {
    plans.value = await trainingListApi({
      status: filters.status || undefined,
      category: filters.category || undefined,
      keyword: filters.keyword || undefined
    })
    tabLoaded.plans = true
  } catch {
    // 失败提示由 request 拦截器统一弹出后端 message；这里只把表格复位，
    // 并保持「未加载」状态，用户切走再切回来可以重试。
    plans.value = []
  } finally {
    planLoading.value = false
  }
}

async function loadOffers() {
  offerLoading.value = true
  try {
    const res = await trainingAvailableApi()
    offers.value = res.list || []
    offerSummary.value = res.summary || {}
    tabLoaded.available = true
  } catch {
    offers.value = []
  } finally {
    offerLoading.value = false
  }
}

async function loadMyRecords() {
  myLoading.value = true
  try {
    const res = await trainingMyApi()
    myRecords.value = res.list || []
    mySummary.value = {
      totalCredit: res.totalCredit,
      enrolledCount: res.enrolledCount,
      attendedCount: res.attendedCount,
      totalHours: res.totalHours
    }
    tabLoaded.my = true
  } catch {
    myRecords.value = []
  } finally {
    myLoading.value = false
  }
}

async function loadStats() {
  statsLoading.value = true
  try {
    const res = await trainingStatsApi()
    statsOverview.value = res.overview || {}
    creditRank.value = res.creditRank || []
    courseStats.value = res.courseStats || []
    tabLoaded.stats = true
  } catch {
    creditRank.value = []
    courseStats.value = []
  } finally {
    statsLoading.value = false
  }
}

function resetFilters() {
  filters.status = ''
  filters.category = ''
  filters.keyword = ''
  loadPlans()
}

// ==================== 新建 / 编辑培训计划 ====================
const deptOptions = ref<{ id: number; deptName: string }[]>([])
const planDialogVisible = ref(false)
const planFormRef = ref<FormInstance>()
const planForm = reactive({
  id: 0,
  title: '',
  category: 'INTERNAL',
  trainer: '',
  deptId: 0,
  startTime: '',
  endTime: '',
  capacity: 0,
  credit: 1,
  location: '',
  description: ''
})
// rules 只挡「必填」这一类前端能确定的事；结课必须晚于开课、时间格式等口径
// 后端 trainingTimeOk / trainingValidateForm 各有一份，前端再算一遍就是第二份真相。
const planRules: FormRules = {
  title: [{ required: true, message: '请填写培训主题', trigger: 'blur' }],
  trainer: [{ required: true, message: '请填写讲师姓名', trigger: 'blur' }],
  startTime: [{ required: true, message: '请选择开课时间', trigger: 'change' }],
  endTime: [{ required: true, message: '请选择结课时间', trigger: 'change' }]
}

/** 部门树是递归的，下拉只要一层：按「父在前、子在后」拍平并加缩进，与考勤页保持同一观感。 */
function flattenDeptTree(nodes: any[], depth: number, out: { id: number; deptName: string }[]) {
  for (const n of nodes) {
    out.push({ id: n.id, deptName: `${'　'.repeat(depth)}${n.deptName}` })
    if (Array.isArray(n.children) && n.children.length > 0) {
      flattenDeptTree(n.children, depth + 1, out)
    }
  }
}

async function loadDeptOptions() {
  if (deptOptions.value.length > 0) return
  try {
    const flat: { id: number; deptName: string }[] = []
    flattenDeptTree((await getDeptTreeApi()) || [], 0, flat)
    deptOptions.value = flat
  } catch {
    // 部门只是「适用部门」下拉的候选，拉取失败不该挡住建课；后端默认 deptId=0（全员）
    deptOptions.value = []
  }
}

function openCreateDialog() {
  planForm.id = 0
  planForm.title = ''
  planForm.category = 'INTERNAL'
  planForm.trainer = ''
  planForm.deptId = 0
  planForm.startTime = ''
  planForm.endTime = ''
  planForm.capacity = 0
  planForm.credit = 1
  planForm.location = ''
  planForm.description = ''
  planDialogVisible.value = true
  loadDeptOptions()
}

function openEditDialog(row: TrainingPlan) {
  planForm.id = row.id
  planForm.title = row.title
  planForm.category = row.category
  planForm.trainer = row.trainer
  planForm.deptId = Number(row.deptId) || 0
  planForm.startTime = row.startTime
  planForm.endTime = row.endTime
  planForm.capacity = Number(row.capacity) || 0
  planForm.credit = Number(row.credit) || 0
  planForm.location = row.location || ''
  planForm.description = row.description || ''
  planDialogVisible.value = true
  loadDeptOptions()
}

async function submitPlan() {
  if (!planFormRef.value) return
  const passed = await planFormRef.value.validate().catch(() => false)
  if (!passed) return
  planSubmitting.value = true
  try {
    const payload = {
      title: planForm.title.trim(),
      category: planForm.category,
      trainer: planForm.trainer.trim(),
      deptId: planForm.deptId,
      startTime: planForm.startTime,
      endTime: planForm.endTime,
      capacity: planForm.capacity,
      credit: planForm.credit,
      location: planForm.location.trim(),
      description: planForm.description.trim()
    }
    if (planForm.id) {
      await trainingUpdateApi(planForm.id, payload)
      ElMessage.success('培训计划已更新')
    } else {
      // 后端新建固定落 DRAFT，发布是另一次状态流转，提示里要说清楚，否则 HR 会以为课已经上线
      await trainingCreateApi(payload)
      ElMessage.success('培训计划已创建（草稿），点「发布」后员工才能报名')
    }
    planDialogVisible.value = false
    invalidateTabs(['plans', 'available', 'my', 'stats'])
  } catch {
    // 后端 message（如「已有出勤记录，学分不能再修改」）已由拦截器弹出
  } finally {
    planSubmitting.value = false
  }
}

// ==================== 状态流转：发布 / 结课 / 取消 ====================
const STATUS_ACTION: Record<string, string> = { PUBLISHED: '发布', DONE: '结课', CANCELLED: '取消' }

async function changePlanStatus(row: TrainingPlan, next: 'PUBLISHED' | 'DONE' | 'CANCELLED') {
  const action = STATUS_ACTION[next]
  let tip = `确认${action}培训计划「${row.title}」吗？`
  if (next === 'PUBLISHED') tip = `确认发布「${row.title}」吗？发布后会向适用部门的在职员工推送站内通知，员工即可报名。`
  if (next === 'DONE') tip = `确认对「${row.title}」结课吗？系统将把已报名未签到的记录置为缺席，已出勤未考核的按全额学分入账，且课程不可再回退。`
  if (next === 'CANCELLED') tip = `确认取消「${row.title}」吗？取消后员工无法再报名或签到，名册与已录入结果仍会保留。`
  try {
    await ElMessageBox.confirm(tip, `${action}确认`, { type: 'warning', confirmButtonText: '确认', cancelButtonText: '再想想' })
  } catch {
    return // 用户点「再想想」/ 关闭弹窗，ElMessageBox 以 reject 表达，不是异常
  }
  planLoading.value = true
  try {
    // 必须连同内容一起 PUT：handleTrainingUpdate 会先跑 trainingValidateForm 再判状态机，
    // 只传 { status } 时 title 取默认空串，会被「培训主题必填」直接挡下（400）。
    // 回填列表行的原值等于「内容不变、只推进状态」。
    await trainingUpdateApi(row.id, { ...toPlanPayload(row), status: next })
    ElMessage.success(`已${action}`)
    invalidateTabs(['plans', 'available', 'my', 'stats'])
  } catch {
    // 状态机拒绝（如「开课时间已过，无法发布」）的文案由后端给，拦截器已展示
    planLoading.value = false
  }
}

// ==================== 员工自助：报名 / 签到 / 取消报名 ====================
async function handleSignup(row: TrainingOffer) {
  try {
    const res = await trainingSignupApi(row.id)
    const left = Number(res.capacityLeft) < 0 ? '不限' : res.capacityLeft
    ElMessage.success(`报名成功，剩余名额 ${left}`)
    invalidateTabs(['plans', 'available', 'my', 'stats'])
  } catch {
    // 名额已满 / 不在受众范围 / 课程未发布等理由由后端给出
  }
}

async function handleCheckin(row: TrainingOffer) {
  try {
    await trainingCheckinApi(row.id)
    ElMessage.success('签到成功')
    invalidateTabs(['plans', 'available', 'my', 'stats'])
  } catch {
    // 不在开课时窗内时后端返回具体原因
  }
}

async function handleUnsignup(row: TrainingOffer) {
  try {
    await ElMessageBox.confirm(`确认取消报名「${row.title}」吗？开课后就不能再取消了。`, '取消报名确认', {
      type: 'warning',
      confirmButtonText: '确认取消',
      cancelButtonText: '保留'
    })
  } catch {
    return
  }
  try {
    await trainingUnsignupApi(row.id)
    ElMessage.success('已取消报名')
    invalidateTabs(['plans', 'available', 'my', 'stats'])
  } catch {
    // 开课时间已过等场景由后端 message 说明
  }
}

// ==================== 花名册与结果录入 ====================
const rosterVisible = ref(false)
const rosterLoading = ref(false)
const roster = reactive({ id: 0, title: '', status: '', rows: [] as TrainingRosterRow[] })

const resultVisible = ref(false)
const resultSubmitting = ref(false)
const resultForm = reactive({
  employeeId: 0,
  name: '',
  attended: true,
  // undefined = 未填（无考核）。el-input-number 的 modelValue 只接受 number | undefined，
  // 用 null 会在开发态触发 prop 类型告警，提交时再用 ?? -1 归一化成后端哨兵值。
  score: undefined as number | undefined,
  remark: ''
})

function openRoster(row: TrainingPlan) {
  roster.id = row.id
  roster.title = row.title
  roster.status = row.status
  roster.rows = []
  rosterVisible.value = true
  // 名册按课实时变化（同事可能刚录完成绩），每次打开都强制重拉，不走 tabLoaded 缓存
  loadRoster()
}

async function loadRoster() {
  rosterLoading.value = true
  try {
    const res = await trainingRosterApi(roster.id)
    roster.rows = res.list || []
    roster.status = res.status || roster.status
    roster.title = res.title || roster.title
  } catch {
    roster.rows = []
  } finally {
    rosterLoading.value = false
  }
}

function openResultDialog(row: TrainingRosterRow) {
  resultForm.employeeId = row.employeeId
  resultForm.name = row.name
  resultForm.attended = row.status === 'ATTENDED'
  resultForm.score = row.score ?? undefined
  resultForm.remark = row.remark || ''
  resultVisible.value = true
}

async function submitResult() {
  resultSubmitting.value = true
  try {
    const res = await trainingResultApi(roster.id, {
      employeeId: resultForm.employeeId,
      attended: resultForm.attended,
      // 留空必须回落 -1：后端 getJsonFloat(obj, 'score', -1.0) 把负数当「无考核」哨兵，
      // 传 0 会被当成「考了 0 分」，两种语义折算出的学分完全不同。
      score: resultForm.score ?? -1,
      remark: resultForm.remark.trim()
    })
    // 学分由后端按出勤 + 考核分折算，前端不做二次计算，直接把入账值回显给 HR
    ElMessage.success(`已记录${resultForm.attended ? '出勤' : '缺席'}，本次折算学分 ${numOrDash(res.credit)}`)
    resultVisible.value = false
    loadRoster()
    invalidateTabs(['plans', 'available', 'my', 'stats'])
  } catch {
    // 计划已取消（trainingResultDenied）等拒绝理由由后端给，弹窗里不再另写一套文案
  } finally {
    resultSubmitting.value = false
  }
}

onMounted(() => {
  if (canManage.value) loadDeptOptions()
  ensureTab(activeTab.value)
})
</script>
