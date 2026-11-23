# 协作者交接与二次开发详尽指南（Cangjie + Vue 3 企业级人力资源管理系统）

> 本文档面向 **`软件工程职业实践项目作业`** 仓库的后续协作者与课程答辩组成员编写。阅读本文档后，协作者可在 **15 分钟内** 独立完成 Windows 开发环境搭建、代码编译运行、二次业务开发、测试与团队 Git 协作提交。

---

## 一、项目当前完成度与整体架构总览

本项目已完成 **全栈 MVP 至生产级完整闭环**：基于华为 **仓颉（Cangjie `1.0.5` + `stdx 1.0.5.1`）** 编写高性能 RESTful 后端服务，使用 **MySQL 8.0** 存储 11 张核心业务表，并通过 **Vue 3 + TypeScript + Vite 5 + Element Plus + Tailwind CSS + ECharts 5** 实现企业级响应式 Web 端管理后台。

### 1.1 系统逻辑架构

```text
+-----------------------------------------------------------------------+
|  Browser (http://127.0.0.1:5173)                                      |
|  Vue 3.5 + TS + Pinia + Vue Router 4 + Element Plus + ECharts 5       |
+-----------------------------------+-----------------------------------+
                                    | Vite Dev Proxy (/api -> :8080)
                                    v
+-----------------------------------------------------------------------+
|  Cangjie Backend (http://127.0.0.1:8080, stdx.net.http.ServerBuilder) |
|  ├── middleware/cors.cj       跨域预检与响应头                         |
|  ├── middleware/auth.cj       HS256 JWT 验签 + 四角色 RBAC 拦截        |
|  ├── common/crypto_util.cj    SHA-256 随机盐密码哈希                   |
|  ├── service/audit_service.cj 操作审计日志记录                         |
|  └── controller/ (10 个模块)  认证/组织/员工/考勤/审批/绩效/薪酬/招聘/看板/系统 |
+-----------------------------------+-----------------------------------+
                                    | UTF-8 SQL File + SOURCE 执行
                                    v
+-----------------------------------------------------------------------+
|  MySQL 8.0.42 (127.0.0.1:3306, utf8mb4_unicode_ci, hrms_db)           |
|  11 张表：部门/岗位/员工/异动/用户/考勤/假勤/绩效/薪资/招聘/审计日志      |
+-----------------------------------------------------------------------+
```

### 1.2 已通过的端到端验收闭环

- [x] **认证与 RBAC 越权拦截**：普通员工访问全员薪资列表（`GET /api/v1/payrolls`）稳定返回 `403`，HR 放行 `200`。
- [x] **招聘转入职链路**：候选人阶段流转及一键转入职（自动生成工号 `EMP2026xxxx`、创建系统账号、写审计日志）。
- [x] **智能考勤与异常补卡**：员工上下班实时签到/签退（按 `09:00` / `18:00` 判别迟到/早退），HR 异常修正状态为 `NORMAL`。
- [x] **假勤审批与年假余额联动**：`ANNUAL` 年假审批通过后，自动从 `hr_employee.annual_leave_balance` 扣减对应天数。
- [x] **绩效评级联动月度算薪**：`S/A/B/C/D` 自动映射奖金系数 `1.20/1.10/1.00/0.80/0.50`，自动计算加班补贴、考勤扣款、五险一金与超额累进个税，确认发薪后员工在「我的工资条」可查电子凭条。
- [x] **前后端联合渲染**：`cjpm build`、`tsc --noEmit`、`vite build` 均 0 错误；浏览器实测 43 个请求 0 报错、ECharts 四表渲染正常。

---

## 二、Windows 本地开发环境从零搭建指南（避坑完整版）

> **重要提醒**：本仓库已通过 `.gitignore` 排除了 `*.zip`（仓颉 SDK 压缩包）、`mysql-data/`、`node_modules/`、`dist/` 与 `target/`，因此协作者拉取代码后需按本节准备本地工具链。

### 2.1 前置软件清单

| 工具 | 推荐版本 | 说明 |
| --- | --- | --- |
| 仓颉 SDK | `cangjie-sdk-windows-x64-1.0.5.zip` | 解压至无空格路径，如 `D:\cangjie` |
| 仓颉扩展库 | `cangjie-stdx-windows-x64-1.0.5.1.zip` | 解压至无空格路径，如 `D:\cangjie-stdx` |
| MySQL | `MySQL Server 8.0.x` | 端口 `3306`，字符集 `utf8mb4` |
| Node.js + pnpm | `Node 20+/22+`、`pnpm 10+/12+` | 用于构建与启动 `frontend-web` |

### 2.2 配置仓颉与 `stdx` 路径（关键）

1. 将 SDK 与扩展库分别解压到 `D:\cangjie` 与 `D:\cangjie-stdx`（**路径禁止包含中文或空格**）。
2. 检查 [backend-cangjie/cjpm.toml](./backend-cangjie/cjpm.toml) 中的动态库路径是否与本机一致（默认配置如下）：

   ```toml
   [target.x86_64-w64-mingw32]
     [target.x86_64-w64-mingw32.bin-dependencies]
       path-option = ["D:\\cangjie-stdx\\windows_x86_64_cjnative\\dynamic\\stdx"]
   ```

   如果您的 `cangjie-stdx` 放在其他盘符（例如 `C:\cangjie-stdx`），请对应修改该路径及 [start-backend.ps1](./start-backend.ps1) 中的 `$StdxDynamic` 变量。
3. 在 PowerShell 中加载环境：

   ```powershell
   . "D:\cangjie\envsetup.ps1"
   $env:PATH = "D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx;" + $env:PATH
   cjpm -v
   cjc -v
   ```

### 2.3 【核心避坑】Windows 11 24H2/25H2 下 `libcangjie-runtime.dll` 启动闪退修复

在 **Windows 11 Build 26100 / 26200（24H2 / 25H2）** 系统上，原版 Cangjie `1.0.5` 运行时的 `WinModuleManager::ReadWinModuleAtInitEv` 存在上游兼容性缺陷（Issue #920，访问违例 `0xC0000005`），会导致 `cjpm` 或编译产物静默崩溃退出。

验证方式：运行 `cjc -v`。若输出完整版本但运行自定义仓颉可执行文件直接异常退出（非 `0` 退出码，无输出），需对 `D:\cangjie\runtime\lib\windows_x86_64_cjnative\libcangjie-runtime.dll` 做如下两点指令修补（先备份 `.bak`）：

- 偏移 `0x19267..0x1926a`：将 `4c 8b 68 20`（`mov 0x20(%rax), %r13`）替换为 `4c 8d 68 20`（`lea 0x20(%rax), %r13`）
- 偏移 `0x1928a..0x1928b`：将 `eb 11` 替换为 `90 90`

> 仅在先验证字节与上述原始字节完全一致时执行替换，并务必保留 `.bak` 备份。

### 2.4 初始化 MySQL 8.0 数据库

如果本机已有可登录的 MySQL 8.0 服务，直接导入结构与种子数据即可；若遇到 Windows 服务权限受限（`Access is denied`），可参考仓库根目录 [start-backend.ps1](./start-backend.ps1) 中的做法使用独立 `--defaults-file` 目录启动用户态 `mysqld.exe`。

执行建库建表与种子数据导入：

```powershell
& "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe" --default-character-set=utf8mb4 -h 127.0.0.1 -P 3306 -u root -proot -e "SOURCE E:/homework/hrms-cangjie/sql/init.sql;"
```

检查后端环境变量文件 [backend-cangjie/.env](./backend-cangjie/.env)（模板见 [.env.example](./backend-cangjie/.env.example)）：

```env
DB_HOST=127.0.0.1
DB_PORT=3306
DB_USER=root
DB_PASS=root
DB_NAME=hrms_db
JWT_SECRET=hrms_cangjie_jwt_secret_key_2026
SERVER_PORT=8080
MYSQL_EXE=C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe
```

### 2.5 安装并构建后端与前端

1. **编译并运行后端**：

   ```powershell
   cd backend-cangjie
   cjpm build
   # 或直接从根目录运行一键脚本（自动检查 MySQL 与环境变量并构建启动）
   cd ..
   .\start-backend.ps1 -Rebuild
   ```

   验证健康检查：`curl.exe http://127.0.0.1:8080/api/v1/health` 应返回 `{"code":200,"message":"success","data":{"status":"UP"}}`。

2. **安装并启动前端**：

   ```powershell
   cd frontend-web
   pnpm approve-builds -y esbuild vue-demi   # pnpm 10+/12+ 需允许 esbuild 与 vue-demi 执行 postinstall
   pnpm install
   pnpm exec tsc --noEmit
   pnpm build
   pnpm dev                                  # 启动于 http://127.0.0.1:5173
   ```

   或直接在仓库根目录运行 `.\start-frontend.ps1`。

---

## 三、工程目录结构与核心技术机制剖析

### 3.1 仓库文件树

```text
.
├── .gitignore                        # 排除依赖、编译产物、mysql-data、zip 与可执行文件
├── COLLABORATOR_GUIDE.md             # 本文档：协作者完整接手与二次开发指南
├── HRMS_AI_MASTER_GUIDE.md           # 原始总体开发设计规范文档
├── README.md                         # 项目快速介绍与演示账号说明
├── start-backend.ps1                 # 一键检测/启动 MySQL、编译并运行仓颉后端
├── start-frontend.ps1                # 一键启动 Vite 前端服务
├── sql/
│   └── init.sql                      # 11 张表 DDL 与 4 部门/5 岗位/5 员工/2 候选人种子数据
├── backend-cangjie/
│   ├── cjpm.toml                     # cjc-version = "1.0.5"，链接 stdx 动态库
│   ├── .env / .env.example           # 数据库与端口配置（注意：仓库含默认本地开发值）
│   └── src/
│       ├── main.cj                   # 启动 HTTP Server、初始化 4 个默认用户、路由分发
│       ├── config/app_config.cj      # 读取 .env 并初始化全局配置 globalConfig
│       ├── db/mysql_pool.cj          # MySQL UTF-8 查询与 SQL 转义工具封装
│       ├── common/
│       │   ├── crypto_util.cj        # 随机盐生成 + SHA-256 密码哈希与校验
│       │   ├── jwt_util.cj           # HS256 JWT 生成与过期/签名验证
│       │   ├── response.cj           # 统一响应 sendOk/sendPage/sendErr + JSON 读取工具
│       │   └── router.cj             # URL Path 分段与 QueryString 解析（支持 URL 解码）
│       ├── middleware/
│       │   ├── cors.cj               # 允许跨域与 OPTIONS 预检响应
│       │   └── auth.cj               # requireAuth / requireRoles 权限校验与部门作用域辅助
│       ├── service/audit_service.cj  # writeAuditLog 统一审计日志落库
│       └── controller/               # 10 个核心业务控制器（详见第五节）
└── frontend-web/
    ├── vite.config.ts                # 127.0.0.1:5173，代理 /api -> http://127.0.0.1:8080
    ├── pnpm-workspace.yaml           # onlyBuiltDependencies: esbuild, vue-demi
    └── src/
        ├── api/request.ts            # Axios 拦截器（自动带 Bearer Token、401 清态跳转登录）
        ├── api/hrms.ts               # 全量接口函数与 TypeScript 类型
        ├── stores/auth.ts            # Pinia AuthStore（持久化 token 与 user）
        ├── router/index.ts           # RBAC 路由 meta.roles 动态守卫
        ├── layout/AppLayout.vue      # 侧边栏角色过滤 + 顶栏个人信息 + 改密弹窗
        └── views/                    # 10 个核心业务页面（Login/Dashboard/Org/.../System）
```

### 3.2 协作者必须掌握的 4 个核心机制

1. **仓颉后端中文 UTF-8 与防 SQL 注入机制（`src/db/mysql_pool.cj`）**
   - Windows 控制台传参易受 GBK 编码影响，因此 `mysql_pool.cj` 将每条 SQL 写入临时 UTF-8 文件并执行 `mysql.exe --default-character-set=utf8mb4` + `SOURCE`，同时以分隔符读取结果行。
   - **开发守则**：拼装 SQL 时**严禁直接插值用户输入**，字符串参数必须经过 `sqlStr(val)` 或 `sqlNullableStr(val)`（内部调用 `sqlEscape` 转义反斜杠、单引号、换行符等）。
2. **自定义轻量路由器与参数提取（`src/main.cj`、`src/common/router.cj`）**
   - 在 `dispatchRequest(ctx: HttpContext)` 中按路径与 HTTP Method 进行精确或分段匹配（`parsePathSegments(path)`），新增接口后**必须在 `main.cj` 显式注册路由**。
   - 提取 Body JSON 字符串/数值时复用 `common/response.cj` 提供的 `parseJsonObject`、`getJsonStr`、`getJsonInt`、`getJsonFloat`、`getJsonBool`。
3. **认证与四角色 RBAC 矩阵（`src/middleware/auth.cj`）**
   - `requireAuth(ctx)`：任何已登录用户放行，返回 `AuthUser`（含 `userId`, `username`, `role`, `employeeId`）。
   - `requireRoles(ctx, ["ADMIN", "HR"])`：仅放行指定角色，否则统一返回 HTTP `403`。
   - 数据隔离原则：`MANAGER` 角色在员工列表、考勤、假勤审批、绩效评分中默认限定为**本部门数据**（通过 `getUserDeptId(u)` 查询所属部门）；`EMPLOYEE` 仅可看本人数据。
4. **前端接口解包契约（`src/api/request.ts`）**
   - 后端统一返回 `{ code: 200, message: "success", data: ... }`。
   - Axios 响应拦截器已自动解包 `res.data.data`！因此在 `src/views/*.vue` 中调用 `hrms.ts` API 函数后，拿到的**直接就是 `data` 对象或分页对象 `{ list, total, page, pageSize }`**，无需再写 `.data.data`。

---

## 四、数据库 11 张核心表字典与状态机

| 表名 | 中文名 | 关键唯一键 / 索引 | 核心状态枚举 |
| --- | --- | --- | --- |
| `hr_department` | 组织部门表 | `idx_parent_id` | 树形结构（`parent_id=0` 为顶级） |
| `hr_position` | 岗位职级表 | `UNIQUE(pos_code)` | 关联 `dept_id` 与薪资带宽 |
| `hr_employee` | 员工档案主表 | `UNIQUE(emp_no)` | `PROBATION` / `ACTIVE` / `RESIGNED` |
| `hr_emp_transfer` | 员工异动历史表 | `idx_transfer_emp` | `REGULARIZE` / `TRANSFER` / `SALARY_ADJUST` / `RESIGN` |
| `sys_user` | 系统账号表 | `UNIQUE(username)` | `ADMIN` / `HR` / `MANAGER` / `EMPLOYEE` |
| `hr_attendance` | 考勤打卡表 | `UNIQUE(employee_id, work_date)` | `NORMAL` / `LATE` / `EARLY` / `LATE_EARLY` / `LEAVE` / `ABSENT` |
| `hr_leave_overtime` | 假勤与加班表 | `idx_lo_emp_status` | `PENDING` -> `APPROVED` / `REJECTED` / `CANCELLED` |
| `hr_performance` | 绩效考核表 | `UNIQUE(cycle_name, employee_id)` | `SELF_EVAL` -> `REVIEWING` -> `COMPLETED` |
| `hr_payroll` | 月度薪资核算表 | `UNIQUE(employee_id, pay_month)` | `DRAFT` -> `PAID` |
| `hr_recruitment_candidate` | 招聘候选人表 | `idx_cand_stage` | `NEW` / `INTERVIEW` / `OFFER` / `HIRED` / `REJECTED` |
| `sys_audit_log` | 安全审计日志表 | `idx_audit_time` | 记录关键写操作与登录记录 |

> **默认演示账号**（首次启动后端自动初始化，密码均为 `123456`）：
> `admin`（员工 ID 1，总经办）、`hr`（员工 ID 2，人力资源部）、`manager`（员工 ID 3，技术研发中心）、`emp01`（员工 ID 4，技术研发中心）。

---

## 五、全量 API 速查与核心核算公式

### 5.1 接口路径前缀 `/api/v1`

| 模块 | 接口路由 | 权限角色 | 返回形态 |
| --- | --- | --- | --- |
| 健康检查 | `GET /health` | 公开 | `{ status: "UP" }` |
| 登录认证 | `POST /auth/login`、`GET /auth/me`、`PUT /auth/password` | 公开 / 已登录 | Token + 用户档案 |
| 数据看板 | `GET /dashboard/overview` | 全部已登录 | KPIs + 合同预警 + 4 类图表序列 |
| 部门岗位 | `GET /departments/tree`、`POST/PUT/DELETE /departments...`、`GET/POST/PUT/DELETE /positions...` | 查公开/增删改 `ADMIN/HR` | 树数组 / 岗位数组 |
| 员工档案 | `GET /employees`、`GET/PUT /employees/:id`、`POST /employees`、`POST /employees/:id/{transfer\|resign}` | `ADMIN/HR/MANAGER`（写限 `ADMIN/HR`） | 分页 `{ list, total, page, pageSize }` |
| 考勤管理 | `POST /attendance/{clock-in\|clock-out}`、`GET /attendance/{today\|my}`、`GET /attendance`、`PUT /attendance/:id` | 个人全部 / 全员管理 `ADMIN/HR/MANAGER` / 修正 `ADMIN/HR` | 记录 / `{ list, summary }` / 分页 |
| 假勤审批 | `POST /requests`、`GET /requests/my`、`POST /requests/:id/cancel`、`GET /requests`、`POST /requests/:id/approve` | 个人全部 / 审批 `ADMIN/HR/MANAGER` | 数组 / 分页 |
| 绩效考核 | `POST /performances/init-cycle`、`GET /performances`、`PUT /performances/:id/{self-eval\|review}` | 初始化 `ADMIN/HR` / 评分 `ADMIN/HR/MANAGER` | 绩效数组 |
| 薪酬核算 | `POST /payrolls/{generate\|batch-pay}`、`GET /payrolls`、`PUT /payrolls/:id`、`POST /payrolls/:id/pay`、`GET /payrolls/my` | 核算发放 `ADMIN/HR` / 个人工资条全部 | 分页 / 个人数组 |
| 招聘管理 | `GET/POST /candidates`、`PUT /candidates/:id`、`POST /candidates/:id/hire` | `ADMIN/HR` | 候选人数组 |
| 系统审计 | `GET /system/users`、`PUT /system/users/:id`、`GET /system/audit-logs` | `ADMIN` | 用户数组 / 审计分页 |

### 5.2 核心业务核算公式（位于 `controller/performance_controller.cj` 与 `payroll_controller.cj`）

1. **绩效等级与奖金系数**：
   - `finalScore >= 90` -> `S` (`1.20`)
   - `80 <= finalScore < 90` -> `A` (`1.10`)
   - `70 <= finalScore < 80` -> `B` (`1.00`)
   - `60 <= finalScore < 70` -> `C` (`0.80`)
   - `finalScore < 60` -> `D` (`0.50`)
2. **月度薪资自动化核算**：
   - `日薪 = 基本月薪 / 21.75`；`时薪 = 日薪 / 8.0`
   - `加班补贴 overtimePay = 已审批加班工时 × 时薪 × 1.5`
   - `考勤扣款 attendanceDeduction = (迟到次数 + 早退次数) × 50.0 + 已审批事假天数 × 日薪`
   - `绩效奖金 bonus = 基本月薪 × 0.1 × 最近已完成考核 bonusRatio`
   - `五险一金个人部分 socialSecurity = 基本月薪 × 0.185`
   - `应纳税所得额 = 基本月薪 + 奖金 + 加班补贴 - 考勤扣款 - 五险一金 - 5000`
   - `个人所得税 tax`：按 `<=3000 (3%)`、`<=12000 (10%-210)`、`<=25000 (20%-1410)`、`>25000 (25%-2660)` 四档简化超额计算
   - `实发工资 netSalary = 基本月薪 + 奖金 + 加班补贴 - 考勤扣款 - 五险一金 - 个税`

---

## 六、如何新增或扩展业务模块（二次开发标准 SOP）

下面以新增「员工培训管理（`/api/v1/trainings`）」为例演示标准接入手顺：

1. **数据库变更**：在 [sql/init.sql](./sql/init.sql) 末尾追加建表语句并同步到当前本地 MySQL：

   ```sql
   CREATE TABLE IF NOT EXISTS hr_training (
       id BIGINT PRIMARY KEY AUTO_INCREMENT,
       title VARCHAR(128) NOT NULL,
       trainer VARCHAR(64) NOT NULL,
       train_date DATE NOT NULL,
       dept_id BIGINT DEFAULT 0,
       status VARCHAR(20) NOT NULL DEFAULT 'PLANNED',
       created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
   ) ENGINE=InnoDB COMMENT='员工培训计划表';
   ```

2. **新增仓颉控制器**：创建 `backend-cangjie/src/controller/training_controller.cj`，务必声明 `package hrms_backend.controller` 并复用 `requireRoles`、`queryRows`、`sqlStr`、`sendOk`、`writeAuditLog`：

   ```cangjie
   package hrms_backend.controller

   import std.collection.*
   import stdx.net.http.*
   import hrms_backend.common.*
   import hrms_backend.db.*
   import hrms_backend.middleware.*
   import hrms_backend.service.*

   public func handleTrainingList(ctx: HttpContext): Unit {
       match (requireAuth(ctx)) {
           case None => return
           case Some(_) =>
               let rows = queryRows("SELECT id, title, trainer, DATE_FORMAT(train_date, '%Y-%m-%d'), status FROM hr_training ORDER BY id DESC")
               let list = ArrayList<String>()
               for (r in rows) {
                   list.add("{\"id\":${r[0]},\"title\":${jsonStr(r[1])},\"trainer\":${jsonStr(r[2])},\"trainDate\":${jsonStr(r[3])},\"status\":${jsonStr(r[4])}}")
               }
               sendOk(ctx, "[" + String.join(list.toArray(), delimiter: ",") + "]")
       }
   }
   ```

3. **注册路由**：在 [backend-cangjie/src/main.cj](./backend-cangjie/src/main.cj) 的 `dispatchRequest` 中加入路由分发：

   ```cangjie
   if (path == "/api/v1/trainings" && method == "GET") { handleTrainingList(ctx); return }
   ```

4. **编排前端接口与页面**：
   - 在 [frontend-web/src/api/hrms.ts](./frontend-web/src/api/hrms.ts) 导出 `getTrainingsApi`。
   - 新建 `frontend-web/src/views/training/TrainingView.vue`。
   - 在 [frontend-web/src/router/index.ts](./frontend-web/src/router/index.ts) 添加路由 `{ path: 'training', meta: { title: '培训中心', roles: ['ADMIN', 'HR', 'EMPLOYEE'] } }`。
   - 在 [frontend-web/src/layout/AppLayout.vue](./frontend-web/src/layout/AppLayout.vue) 的 `menuItems` 数组加入对应导航项（侧边栏将按角色自动过滤）。
5. **编译与自测**：分别执行 `cjpm build` 与 `pnpm exec tsc --noEmit && pnpm build`。

---

## 七、后续可继续推进的研发任务清单（分工建议）

其余协作者可按以下 5 个独立工作包认领继续迭代，互相之间耦合度较低，适合并行开发与提交 PR：

### 工作包 A：自动化测试与 CI/CD（测试/工程化方向）
- [ ] **后端单元测试**：在 `backend-cangjie/src/` 下使用仓颉 `@Test` 框架补充 `jwt_util` 签名校验、个税分段算薪函数 `calculateTax`、绩效评级映射测试，跑通 `cjpm test`。
- [ ] **前端 Playwright E2E 测试**：覆盖四大角色登录、菜单隔离、弹窗提交表单、薪资生成与工资条核对自动化脚本。
- [ ] **GitHub Actions CI**：在 `.github/workflows/` 增加前端 `pnpm install && pnpm exec tsc --noEmit && pnpm build` 自动检查流水线。

### 工作包 B：数据导入导出与文档打印（前端体验增强）
- [ ] **员工花名册 Excel/CSV 批量导入**：前端解析 `.csv` / `.xlsx` 后批量调用或新增 `POST /api/v1/employees/import` 批量入库。
- [ ] **电子工资条 PDF 导出 / 打印样式**：在 [PayrollView.vue](./frontend-web/src/views/payroll/PayrollView.vue) 的「电子凭条」弹窗加入 `@media print` 专版样式或 PDF 导出按钮。
- [ ] **考勤月度汇总报表导出**：按部门导出月度出勤率、迟到早退、请假工时统计表。

### 工作包 C：多级审批与通知提醒中心（业务流深化）
- [ ] **请假长假二级审批**：当请假 `duration > 3` 天时，需先由 `MANAGER` 初审、再由 `HR` 复审后生效（扩展 `hr_leave_overtime.status` 状态机为 `PENDING_MGR -> PENDING_HR -> APPROVED`）。
- [ ] **站内消息通知中心**：新增 `sys_notification` 表，在合同 30 天内到期、审批通过/驳回、月度工资条发放时自动生成未读红点消息，在 `AppLayout.vue` 顶栏展示通知铃铛抽屉。

### 工作包 D：新 HR 业务子模块扩展（全栈功能扩展）
- [ ] **培训与课程学分管理（`hr_training` / `hr_training_record`）**：支持 HR 发布培训、员工报名签到、学分统计。
- [ ] **员工差旅与报销审批（`hr_expense`）**：复用 `ApprovalView` 审批风格完成报销提交、财务/HR 审批及与月度发薪联动发放。

### 工作包 E：课程文档与答辩交付整理（文档方向）
- [ ] 基于 [HRMS_AI_MASTER_GUIDE.md](./HRMS_AI_MASTER_GUIDE.md) 与实际实现整理《软件需求规格说明书（SRS）》、《数据库 E-R 图与详细设计报告》、《系统测试报告（含接口耗时与截图）》以及答辩演示 PPT。
- [ ] （安全加固建议）若后续正式部署至线上服务器，请将 [backend-cangjie/.env](./backend-cangjie/.env) 移出 Git 版本控制并换用强随机 `JWT_SECRET` 与生产数据库密码。

---

## 八、团队 Git 协作规范（Fork / Branch / Pull Request 流程）

为避免代码冲突或误覆盖他人提交，请协作者严格遵守如下分支协作流程：

1. **拉取最新主干**：
   ```powershell
   git remote add upstream https://github.com/whwwwc1-hue/-.git
   git fetch upstream
   git checkout -b feat/your-module upstream/main
   ```
   > 若您尚未成为 `whwwwc1-hue/-` 的协作者（或邀请已过期），请先点击仓库右上角 **Fork**，再从自己的 Fork 推送并在 GitHub 上提交 **Pull Request** 给 `whwwwc1-hue/-`。
2. **提交信息规范（Conventional Commits）**：
   - `feat(payroll): ...` 新增功能
   - `fix(attendance): ...` 缺陷修复
   - `docs: ...` 文档补充
   - `test: ...` 测试用例
3. **推送与发起 PR 前检查清单**：
   - 确认没有把 `mysql-data/`、`node_modules/`、`dist/`、`target/`、`*.exe` 提交进版本库（可执行 `git status` 检查）。
   - 修改过 `.cj` 文件必须执行过 `cjpm build` 确认通过。
   - 修改过 `.ts`/`.vue` 文件必须执行过 `pnpm exec tsc --noEmit && pnpm build` 确认通过。
4. **发起 Pull Request**：在 PR 描述中写明改动模块、涉及新增 SQL（若有）以及本地自测截图或命令结果，由仓库负责人 Review 后 Merge 至 `main`。
