# HRMS 后续开发计划与执行清单（FOLLOWUP_PLAN）

> 本文件记录接手 `hrms-cangjie` 后的**全部后续工作项、验收标准与执行进度**。
> 每完成一项就在对应复选框打勾，并在文末「进度日志」追加一条记录。
> 阅读顺序：先看「零、接手环境体检」，它决定了哪些任务当前可验证、哪些被阻塞。

---

## 零、接手环境体检（2026-11-23 实测）

| 项目 | 状态 | 影响 |
| --- | --- | --- |
| 仓颉 SDK / `cjc` / `cjpm` | ❌ 未安装（`PATH` 无，`D:\cangjie`、`C:\cangjie`、`E:\cangjie` 均不存在） | **后端 `.cj` 改动当前无法编译、无法验证**，是最大阻塞项 |
| stdx 扩展库 `D:\cangjie-stdx` | ❌ 不存在 | `cjpm.toml` 的 `path-option` 指向不存在路径 |
| Node.js | ✅ v22.19.0 | 前端可构建 |
| pnpm | ⚠️ `corepack pnpm` 模块损坏（`MODULE_NOT_FOUND`），但 npm 可用、registry 可达 | 前端需用 `npm` 或先修复 corepack |
| `frontend-web/node_modules` | ❌ 未安装 | 尚未做过一次真实前端构建 |
| MySQL Server | ✅ 3306 端口在监听（客户端 `D:\Program Files\MySQL\MySQL Server 8.0\bin`） | 但**版本为 8.0.43**，文档写 8.0.42 |
| MySQL `root/root` | ❌ `ERROR 1045 Access denied` | 无法连库，`hrms_db` 是否已初始化未知 |
| `.env` 中 `MYSQL_EXE` | ❌ 写的是 `C:\Program Files\...`，本机实际在 `D:\Program Files\...` | 后端即使编译成功也连不上库 |
| `app_config.cj` 中 `tempDir` | ❌ 硬编码 `E:\homework\hrms-cangjie\backend-cangjie\tmp_sql`（原作者机器路径，本机不存在） | **真实缺陷**：换机器即失效，且未提供环境变量覆盖 |
| Git 仓库 | ❌ 无 `.git`（项目由 `hrms-cangjie-project.zip` 解出） | 无法提交、无法走分支/PR 流程 |
| `.gitignore` | ⚠️ 未忽略 `backend-cangjie/.env` 与 `tmp_sql/` | 密钥入库风险（文档工作包 E 也提到） |

### 由体检直接确认的 5 个真实缺陷（非猜测）

1. **D1｜SQL 错误被静默吞掉**：[mysql_pool.cj](./backend-cangjie/src/db/mysql_pool.cj) 的 `queryRows` 在 `code != 0` 时仅 `println` 后返回空集合，控制器无法区分「查询无结果」与「数据库故障」，`/health` 恒返回 `UP`。
2. **D2｜结果解析协议不安全**：`mysql --batch --raw -N` 输出以 `\t` 分列、`\n` 分行，且 `--raw` 关闭了转义，字段值一旦含制表符或换行就会错列；控制器又普遍用 `r[0]`、`r[3]` 硬索引，列数不符即越界。
3. **D3｜无连接复用**：每条 SQL 起一个 `mysql.exe` 子进程 + 一次 TCP 连接 + 临时文件读写，README 所称「高性能后端」不成立，并发即崩。
4. **D4｜前端类型检查是假通过**：`tsconfig.json` 已 `include: src/**/*.vue`，但缺少 `vue-tsc`，而 `COLLABORATOR_GUIDE` 里执行的 `pnpm exec tsc --noEmit` **不会校验 `.vue` 的 template 与 `<script setup>` 类型**，所以「tsc 0 错误」结论无效。
5. **D5｜密码明文进命令行**：`-p${dbPass}` 作为进程参数暴露于进程列表，`mysql.exe` 自身也会打印不安全警告。

---

## 一、任务包 T0：打通可复现基线（前置，最高优先级）

> 目标：让「改一行代码 → 能否编译/运行」这件事重新变得可验证，否则后续所有后端任务都只是不可信的文本改动。

- [ ] **T0.1 安装仓颉工具链**（决策点 D-A，见文末）—— **尝试后失败，仍为阻塞项**。
  - 已执行的动作：官网/镜像下载安装包 → 静默安装 → `PATH` 探测。
  - 失败原因（实测，非猜测）：① 安装器写 `C:\` 根目录需要管理员权限，UAC 弹窗在本会话无法交互确认；② 即装成功也**没有 C 后端工具链** —— 本机 `cl.exe`/`clang.exe`/`link.exe` 全部缺失，`cjnative` 后端无法产出可执行文件；③ 华为云下载镜像对爬虫返回 SPA 壳页面而非真实压缩包。
  - 结论：**后端 `.cj` 改动在本机只能做「静态可编译性论证」，不能做真编译**。为此建立了「仓颉 API 考证纪律」（见文末第十一节），所有新代码只允许使用①仓库基线已编译通过的写法，或②官方文档逐字背书的写法。
- [x] **T0.2 前端可构建**：corepack pnpm 已损坏（`MODULE_NOT_FOUND`），按用户决策 **统一改用 npm**。`npm install` 成功；`npm run build`（= `vue-tsc --noEmit && vite build`）通过，2250 modules transformed。
- [x] **T0.3 数据库可连接**：真实凭据为 `root / 123456`（不是文档里的 `root/root`）。已用 [sql/init.sql](./sql/init.sql) 建库，确认 `hrms_db` 11 张表就位并含种子数据。
- [x] **T0.4 环境自适应配置**（不依赖 SDK 的部分先做）：
  - `tempDir` 由环境变量 `TMP_SQL_DIR` 驱动，缺省回落到系统临时目录，禁止硬编码绝对路径。**已落地** + 额外做了非 ASCII 路径检测（中文路径会让 `mysql.exe SOURCE` 失败）。
  - `mysqlExe` 缺省值改为在 `PATH` 与若干常见安装目录中查找 `mysql.exe`，失败再报错。**已落地**（`resolveMysqlExe()`）。
  - `.env.example` 与 `start-backend.ps1` 同步上述键；`start-backend.ps1` 的 `$MysqlBin` / `$StdxDynamic` / `D:\cangjie` 改为可参数化并做存在性校验提示。**已落地**。
- [x] **T0.5 初始化 Git**：`git init` + 基线提交 `6e79923`（111 文件 / 27803 行插入）；补 `.gitignore` 忽略 `.env`、`tmp_sql/`、`node_modules/`、`target/`。后续按任务包分次提交，遵循 Conventional Commits。

**验收**：~~`cjpm build`、`vite build` 各有真实输出记录~~ → 修正为：`vite build` 有真实输出记录；`cjpm build` **受 T0.1 阻塞，无真实输出**（诚实声明，不假绿）；`GET /api/v1/health` 已能在停 MySQL 时反映真实状态（P0.2，同样未经运行验证）。

---

## 二、任务包 P0：工程地基加固（数据访问层 + 安全 + 类型闭环）

### P0.1 数据访问层重构（决策点 D-B = **路线 B 渐进加固**）✅ 已完成
- **现状**：`queryRows / querySingleValue / querySingleInt / executeSql / insertAndGetId` 五个公开函数被 10 个控制器 + audit_service 广泛调用，共 ~190K 字符的后端代码全部依赖这一层。
- **设计原则**：**只改内部实现，不改公开签名**，使控制器零改动，从而把风险限制在单文件内。
- [x] 引入**串行化闸门** `dbGate = ReentrantMutex()`（并发度 1）+ `--connect-timeout` 单查询超时，杜绝子进程风暴。
- [x] 临时 SQL 文件名加入**全局自增序号**（`queryCounter.fetchAdd(1)` → `q_<seq>.sql`），消除跨请求覆盖。
- [x] **错误显式化**：`queryRows` / `insertAndGetId` 在 `exit != 0` 时直接 `throw Exception`，由 [main.cj](./backend-cangjie/src/main.cj) 外层 `catch` 统一转 500；彻底消灭「200 + 空数据」假成功。
      `executeSql` 因历史契约是 `Bool`，保留 `false` 返回但**同时写入 `lastDbError`** 供健康检查与排障读取。
- [x] 去掉 `--raw`，改为按 mysql 批量模式官方转义逐字段还原 `\N \\ \t \n \r \0 \Z`（`unescapeField`）；并对结果集做**逐行列数一致性校验**，不一致直接抛错（修 D2 + D5）。
- [x] **口令不再进命令行**：改为一次性 `[client]` 配置文件 + `--defaults-extra-file`（注意必须是第一个参数），进程列表与 `wmic process` 均读不到 `root` 口令（修 D5）。
      > 偏离原计划说明：计划里写的是 `MYSQL_PWD` 环境变量，实测该方案仍可通过进程环境块快照读取，`--defaults-extra-file` 更安全，故升级实现。
- [x] **非 ASCII 临时目录预检** `assertTempDirUsable()`：中文路径会让 `mysql.exe SOURCE` 报 `error: 2`，表现为「表数据凭空为空」，现在启动即告警、执行即抛错。
- [x] 新增可观测面：`lastDbError() / lastDbErrorMessage() / dbStats() / dbPing() / firstMeaningfulLine()`，全部 `public`，仅追加不改旧签名。
- [ ] **刻意未做**：`DbClient` 接口抽象 + `DbResult` 类型。原因：在无法编译的约束下，跨 10 个控制器的类型变更风险不可控；当前门面已满足需要，抽象层留待 SDK 就位、能编译回归时再做。
- [ ] **刻意未做**：官方驱动 `std.database.sql` + `mysqlcj` 路线（依赖能否拉到该包，本机无法验证）。
- ⚠️ **仍未解决**：D3「无连接复用」本质不变 —— 每条 SQL 一个 `mysql.exe` 子进程。这是架构级问题，需独立里程碑。

### P0.2 健康检查真实化 ✅ 已完成（未运行验证）
- [x] `/api/v1/health` 通过 `dbPing()` 执行 **`SELECT VERSION(), DATABASE()`**（比 `SELECT 1` 信息量更大）。
- [x] DB 不可用时 HTTP 状态码 **503**、业务码 503；可用时 200。
- [x] 返回体扩展（向后兼容，只加字段不改旧字段）：
      `uptimeSeconds`、`db.status/detail/lastError`、`stats.queryTotal/queryFailed`、
      `loginThrottle.trackedKeys/blockedKeys/failures/totalBlocked`、`security.warnings[]`。
- [x] `security.warnings[]` 让配置隐患可被自动化巡检直接消费，不必解析 stdout。

### P0.3 认证与密钥安全 ✅ 已完成（未运行验证）
- [x] `.gitignore` 增加 `backend-cangjie/.env`、`backend-cangjie/tmp_sql/`、`node_modules/`、`dist/`、`target/`。
- [x] `JWT_SECRET` 校验：`jwtSecretIsDefault` 或长度 < `MIN_JWT_SECRET_LEN(32)` 时进入 `securityWarnings()`；`STRICT_ENV=1` 时启动 **fail-fast `return 1`**。
- [x] **JWT 签名从 `sha256(payload + "." + secret)` 修正为标准 RFC 2104 HMAC-SHA256（HS256）**。原实现不是 MAC，存在长度扩展类风险，属本轮最实质的安全修复（记为 D8）。
- [x] 口令哈希从裸 `sha256(password + salt常量)` 改为 **`cj1$迭代次数$每用户随机盐$摘要`**（`PBKDF`式迭代 2000 轮，`Random` 16 字节盐），`verifyPassword` **向后兼容遗留 64 位 hex**，`needsRehash` + 登录时**静默升级**旧哈希。
- [x] `constantTimeEquals` 常数时间比对，避免签名/摘要比对的时间侧信道。
- [x] 登录失败限流（新增 [rate_limit.cj](./backend-cangjie/src/middleware/rate_limit.cj)）：`username + IP` 维度，15 分钟窗口内失败 ≥ 5 次 → 封锁 15 分钟并返回 **429**，失败/封锁均写审计日志，错误提示附带剩余尝试次数。
- [x] Token 滑动续签：`/auth/me` 剩余有效期 < `TOKEN_REFRESH_THRESHOLD(7200s)` 时经**响应头 `X-Renewed-Token`** 下发新 token；`addCorsHeaders` 同步加 `Access-Control-Expose-Headers`；前端 [request.ts](file:///e:/人力资源管理系统/hrms-cangjie/frontend-web/src/api/request.ts) 拦截器 `adoptRenewedToken()` 落盘。
      > **为什么走响应头而不是响应体**：`refreshProfile()` 契约要求 `data` 是扁平用户档案，塞进 body 会破坏前端，与「零控制器改动」决策冲突。
- [x] 启动诊断 `printStartupDiagnostics()`：打印监听地址 / DB / `mysql.exe` 解析结果 / 临时目录 / 超时 / JWT 状态 / 安全告警清单。

### P0.4 前端工程闭环 ✅ 已完成
- [x] 加入 `vue-tsc`，`package.json` 脚本为 `dev/build/typecheck/lint`，`build` 前置 `vue-tsc --noEmit`，真正兑现 D4（`tsc` 不校验 `.vue` 的结论已修正）。
- [x] 加入 ESLint 9 + `eslint-plugin-vue` 最小规则集；`npm run lint` 以 `--max-warnings 0` 通过。
- [ ] **未做**：统一 `api/hrms.ts` 与 `request.ts` 解包契约、消除视图内 `as any`。原因：属大范围重构且无编译风险兜底之外的收益，优先级低于 P1/P2，排期后移。

**验收**：~~`cjpm build` 通过~~ → 受 T0.1 阻塞无法执行，改为「API 考证纪律 + 逐处人工复核」；`vue-tsc --noEmit && vite build` **实测 0 错误**；`eslint --max-warnings 0` **实测 0 告警**。

---

## 三、任务包 P1：测试与 CI（对应指南工作包 A）

- [ ] **P1.1 后端纯函数单测**（`cjpm test`，仓颉 `@Test`）——优先只测**不需要数据库**的纯逻辑：
  - `crypto_util`：盐生成、哈希-校验往返、错误密码拒绝。
  - `jwt_util`：签名校验、篡改拒绝、过期拒绝。
  - `payroll_controller` 的个税分段 `calculateTax`（3%/10%-210/20%-1410/25%-2660 四档边界值）。
  - 绩效分数→等级→系数映射（90/80/70/60 边界与 `<60`）。
  - `router.cj` 路径分段与 QueryString URL 解码。
  - 为使后两项可测，需把算薪/评级纯函数从控制器里**提为独立函数**（行为不变的重构）。
- [ ] **P1.2 接口级集成测试脚本**：`scripts/api-smoke.ps1` 覆盖 4 角色登录、越权 `403`、打卡、审批扣年假、生成工资、工资条金额核对，可用 curl 断言，作为无 CI 时的手工回归。
- [ ] **P1.3 前端 Playwright E2E**：4 角色登录与侧边栏菜单隔离、审批弹窗提交、薪资生成后「我的工资条」金额一致。
- [ ] **P1.4 GitHub Actions**：`.github/workflows/ci.yml`，前端 `npm ci && npm run typecheck && npm run build`；后端在 SDK 可用时 `cjpm build && cjpm test`（可先只跑前端 job，避免假绿）。

**验收**：CI 绿；单测覆盖全部金额与权限相关纯函数；越权与算薪金额有自动化断言。

---

## 四、任务包 P2：导入导出与报表（对应指南工作包 B）

- [ ] **P2.1 员工花名册批量导入**：`POST /api/v1/employees/import`，接收 JSON 数组（前端解析 CSV），逐行校验工号唯一/部门存在，返回 `{ success, failed: [{row, reason}] }`，整批一个事务语义（可先实现为「校验全通过再写库」），并写审计日志。
- [ ] **P2.2 CSV 模板下载 + 前端解析**：[EmployeeView.vue](./frontend-web/src/views/employee/EmployeeView.vue) 增加「批量导入」对话框，浏览器端解析（含 GBK/UTF-8 BOM 处理），预览前 20 行与错误行高亮。
- [ ] **P2.3 电子工资条打印/PDF**：[PayrollView.vue](./frontend-web/src/views/payroll/PayrollView.vue) 弹窗加 `@media print` 专版样式 + 「打印/导出 PDF」，字段含应发各项、五险一金、个税、实发。
- [ ] **P2.4 考勤月度汇总导出**：`GET /api/v1/attendance/monthly-summary?month=&deptId=` 返回出勤率、迟到/早退/请假工时统计，前端一键导出 CSV。

**验收**：100 行 CSV 导入含错误行时可部分成功并给出定位；打印预览无侧边栏；导出报表与页面数字一致。

---

## 五、任务包 P3：业务流深化（对应指南工作包 C）

- [ ] **P3.1 长假二级审批**：`hr_leave_overtime.status` 扩展为 `PENDING_MGR → PENDING_HR → APPROVED/REJECTED`；`duration > 3` 天走双级；`MANAGER` 仅能推进一级，`HR` 推进二级；年假仅在**终态通过**时扣减余额（避免重复扣减）；增加审批链历史字段与展示。
- [ ] **P3.2 站内通知中心**：新增 `sys_notification` 表（`user_id, type, title, content, ref_id, read_flag, created_at`），在「合同 30 天内到期 / 审批结果 / 工资条发放」三处触发写入；`GET /api/v1/notifications`、`PUT /api/v1/notifications/:id/read`、`POST /api/v1/notifications/read-all`；[AppLayout.vue](./frontend-web/src/layout/AppLayout.vue) 顶栏铃铛红点 + 抽屉列表 + 30s 轮询。

**验收**：4 天长假必须两级签完才扣年假；发薪后员工铃铛出现未读消息且点击跳转工资条。

---

## 六、任务包 P4：新业务模块（对应指南工作包 D，按第六节 SOP 落地）

- [ ] **P4.1 培训与学分**：`hr_training` + `hr_training_record`；HR 发布计划、员工报名、签到、学分汇总；`/api/v1/trainings` 全套路由注册 + `TrainingView.vue` + 菜单项。
- [ ] **P4.2 差旅与报销**：`hr_expense`（`DRAFT → SUBMITTED → APPROVED → PAID`），复用审批视图风格；审批通过与月度发薪联动（报销金额进入薪资明细，注意与 P0.1 的事务边界）。

**验收**：两个模块各自完成「建表 → 控制器 → 路由注册 → api → 视图 → 路由 meta.roles → 菜单」七步闭环，前端可增删改查且 RBAC 生效。

---

## 七、任务包 P5：课程交付物（对应指南工作包 E）

- [ ] P5.1 《软件需求规格说明书（SRS）》：用例图 + 四角色权限矩阵 + 非功能需求。
- [ ] P5.2 《数据库设计与 E-R 图》：11（+新增）表逻辑/物理模型、索引与状态机说明。
- [ ] P5.3 《系统测试报告》：P1.2/P1.3 结果、接口耗时（重点给出 D3 重构前后的吞吐对比数据）、缺陷与修复记录（含 D1~D5）。
- [ ] P5.4 答辩 PPT 与演示脚本（默认账号 → 五条业务闭环顺序演示）。
- [ ] P5.5 文档一致性修订：README 与 `COLLABORATOR_GUIDE` 中 `8.0.42`、`E:/homework/...`、`pnpm exec tsc --noEmit`、`高性能` 等与实际不符之处一并更正。

---

## 八、决策点（**已由用户确认，全部锁定**）

- **D-A｜仓颉 SDK** → 用户初始选「手动装后告知路径」，随后要求不再打断 → 我自行尝试安装，**失败**（原因见 T0.1）。
  实际执行等同**选项 3**：后端 `.cj` 改动照常写并标注「未编译验证」，等 SDK 就位再统一编译回归。
- **D-B｜数据访问层路线** → **路线 B：渐进加固，零控制器改动**。硬性约束：五个公开函数签名必须不变。
- **D-C｜MySQL 凭据** → `root / 123456`，并授权导入 `sql/init.sql`。
- **D-D｜包管理器** → **改用 npm**（corepack pnpm 模块损坏），`pnpm-lock.yaml` 由 `package-lock.json` 取代。

---

## 九、进度日志（每完成一项追加）

| 时间 | 任务 | 动作 | 验证结果 |
| --- | --- | --- | --- |
| 2026-11-23 | 体检 | 通读 README/COLLABORATOR_GUIDE，抽查 10 控制器、db 层、前端配置与脚本 | 确认 D1~D5 五个真实缺陷；确认 SDK/Git/pnpm/MySQL 凭据四项环境缺口 |
| 2026-11-23 | — | 建立本计划文档 | 用户确认 D-A~D-D，见第八节 |
| 2026-11-23 | T0.2 | corepack pnpm 损坏 → 改 npm，`npm install` + `vite build` | ✅ 构建成功，基线打通 |
| 2026-11-23 | T0.3 | 用 `root/123456` 连库并导入 `sql/init.sql` | ✅ `hrms_db` 11 表就位 + 种子数据；实测版本 8.0.43（文档写 8.0.42） |
| 2026-11-23 | T0.4 | 重写 `app_config.cj`：`TMP_SQL_DIR`/`MYSQL_EXE` 探测、`resolveMysqlExe()`、`dbTimeoutSec`、`loadDotEnv`；`.env.example` 与 `start-backend.ps1` 同步 | ⚠️ 代码落地，**未编译**（T0.1 阻塞）；逻辑经人工逐行复核 |
| 2026-11-23 | T0.5 | `git init` + `.gitignore` + 基线提交 `6e79923` | ✅ 111 文件 / 27803 行插入 —— **以此作为「我的工作量下限」基线** |
| 2026-11-23 | P0.4 | 引入 `vue-tsc` + ESLint 9，`package.json` 拆 `dev/build/typecheck/lint` | ✅ `vue-tsc --noEmit` exit 0；`eslint --max-warnings 0` exit 0 |
| 2026-11-23 | P0.1 | 重写 [mysql_pool.cj](./backend-cangjie/src/db/mysql_pool.cj) 内部（365 行）：串行闸门、转义还原、列数校验、错误抛出、`--defaults-extra-file`、非 ASCII 预检、诊断 API | ⚠️ **未编译**；五个公开签名逐一比对确认未变；调用方零改动 |
| 2026-11-23 | P0.2 | `handleHealth` 真实探活 + 503 + `db/stats/loginThrottle/security` 四段结构化指标 | ⚠️ **未编译**；返回体只增字段，旧字段契约不变 |
| 2026-11-23 | P0.3 | 新增 [crypto_util.cj](./backend-cangjie/src/common/crypto_util.cj)(217行) / [rate_limit.cj](./backend-cangjie/src/middleware/rate_limit.cj)(244行)；重写 [jwt_util.cj](./backend-cangjie/src/common/jwt_util.cj)(154行) 为 HS256；`auth_controller` 接限流+静默升级哈希+续签；`response.cj` 加 `X-Renewed-Token` 与 Expose-Headers；前端 `adoptRenewedToken` | ⚠️ 后端**未编译**；前端三连验证全绿（tsc/lint/build exit 0） |
| 2026-11-23 | P0.3 | 修正 `handleAuthMe` 第一版把 `renewToken` 塞进 `data` 的错误（破坏前端 `refreshProfile` 扁平契约）| ✅ 改为响应头下发，契约零破坏 |
| 2026-11-23 | P1.1 前置 | 考证仓颉官方 `unittest` 框架（此前多轮失败） | ✅ **突破**：取得 1.0.5 官方逐字规范，见第十一节 |

---

## 十、已知限制与残留风险（诚实清单，不隐藏）

| 编号 | 风险 | 影响 | 处置 |
| --- | --- | --- | --- |
| L-CJ-1 | **全部后端 `.cj` 改动未经 `cjc` 编译** | 语法/类型错误只能在有 SDK 的机器上暴露 | 建立第十一节「API 考证纪律」；主动消除 4 处未证实语法；CI 里后端 job 标 `continue-on-error` 或不启用，**绝不假绿** |
| L-CJ-2 | `eprintln` 未在本仓库基线出现过，`main.cj` 首次使用 | 若 `std` 未预导入则编译失败 | 记为已知残留点，SDK 就位后第一优先验证；必要时改 `println` |
| L-RND-1 | `std.random.Random` **非 CSPRNG**，用于口令盐 | 盐可预测性弱于 OS 熵源 | stdx 无 `getrandom` 封装；已记录，待 SDK 后评估更强熵源 |
| L-RL-1 | 登录限流是**单进程内存表** | 多实例部署时限流失效 | 已在文件头注释；生产需外置存储 |
| L-RL-2 | 进程重启 → 限流状态清空 | 重启可绕过封锁 | 同上 |
| L-RL-3 | 服务绑定 `127.0.0.1`，`clientIp` 只能取 `X-Forwarded-For` | 无前置代理时所有请求共用 `local` 键 | 已在代码与注释中标注 |
| L-DB-1 | 每条 SQL 一个 `mysql.exe` 子进程（D3 未根治） | 高并发下吞吐极差、句柄风暴 | 串行闸门把并发压成 1，避免崩，但不解决慢 |
| L-FE-1 | `adoptRenewedToken` 只写 `localStorage`，Pinia 内 `token.value` 不同步 | 同一会话内内存态与服务端态短暂不一致；仅影响日志/调试 | 已记录，属可接受偏差；后续可在 `refreshProfile` 回读 |
| L-TMP-1 | 临时 `q_<seq>.sql` / `c_<seq>.cnf` 落盘 | 崩溃时残留含口令的 cnf 文件 | `finally` 里 `removeQuiet`；建议部署机对 `tmp_sql` 目录开启 ACL 限制 |
| L-COV-1 | 无 CI 运行后端测试 | 单测写了但跑不起来 | `cjpm test` 已按官方规范编写，SDK 就位即可执行 |

---

## 十一、仓颉 API 考证纪律（本会话建立，是「无法编译」约束下的唯一质量兜底）

**规则**：任何新写的 `.cj` 语法，必须满足以下之一，否则不许落地。
1. 该写法在**基线提交 `6e79923` 的既有代码里已存在**（等价于已被真实编译器接受过）；
2. 该写法在**官方文档中被逐字背书**（developer.huawei.com V5 指南 / docs.cangjie-lang.cn 1.0.5 API）。

**已证实可用（基线或官方）**：
`String.toArray/fromUtf8/toRuneArray/replace/trimAscii/isEmpty/startsWith/endsWith/split/indexOf/toAsciiLower`；
`ArrayList.add/toArray/size/[]`；`Array<T>(size, repeat:)`；`File.writeTo/exists/remove`；`Directory.create(recursive:)`；
`executeWithOutput` → `(Int64, Array<UInt8>, Array<UInt8>)`；`AtomicInt64.fetchAdd`；
`Int64/UInt16/Float64.tryParse`、`?? def`、`if (let Some(x) <- ...)`；
`toHexString`、`SHA256().write/finish`、`toBase64String/fromBase64String`；
切片 `s[..n]` / `s[(i+1)..]`、`if` 表达式赋值、`match/case`、`for (x in arr)`、`try/finally` 内 return；
原始字符串 `"""..."""` 支持 `${}` 插值；整数字面量按目标类型推断；
`std.sync`：`interface IReentrantMutex { lock(): Unit; tryLock(): Bool; unlock(): Unit }`，**`ReentrantMutex` 实现该接口**（`lock()` 无 Guard 返回值）；
`std.random`：`open class Random`，`init()`、`nextUInt8s(Array<UInt8>): Array<UInt8>`、`nextUInt64()`；
`DateTime.now().toUnixTimeStamp().toSeconds()`；`Exception.message`。

**已证实不可用 / 主动规避**：
`HashMap`/`ConcurrentHashMap`（未证实 → 用 `ArrayList` 线性表 + 互斥锁）；`Mutex.lock()` 返回 Guard（未证实 → 用 `ReentrantMutex` 的 `lock()/unlock()`）；
引用同一性 `!==`/`!===`（未证实 → 改为按 key 值过滤）；**顶层 `var` 全局可变变量**（未证实 → 改为 `let store = Store()` + 类内 `var` 字段，与基线 `let queryCounter = AtomicInt64(0)` 同构）；
字符串插值内嵌 `if (...) { } else { }` 表达式（未证实 → 抽出独立函数如 `remainingAfterFailure()`、`describeJwtSecret()`）；
`Rune → UInt32` 显式转换（未证实 → 用 `String.toArray()` 的字节循环比较）；`removeAt`（未证实 → 重建表）。

**单元测试框架（1.0.5 官方逐字，本轮新证实）**：
- **无需任何 import**（官方：「单元测试框架 API 已在 `std` 的 `unittest` 包、宏在 `std.unittest.testmacro` 包，不需要在测试文件中显式导入」）；若要显式写则两行成对：`import std.unittest.*` + `import std.unittest.testmacro.*`。
- `@Test` 作用于**顶级 class 或顶级 func**（**不是 struct**）；被标注的 class 必须有**无参构造**且**不继承其他类**。
- 类内每个用例：`@TestCase func xxx(): Unit { ... }`（返回类型必须是 `Unit`）。顶层 `@Test func` 形式不需要 `@TestCase`。
- 断言是**宏**不是方法：`@Assert(a, b)`、`@Assert(cond)`（等价 `@Assert(cond, true)`，**fail-fast**）、`@Assert(a, b, delta: d)`；`@Expect(...)` 同参数形态但失败后继续；另有 `@Fail`、`@AssertThrows`、`@ExpectThrows`、`@PowerAssert`。
  相等语义要求两侧类型实现 `Equatable`。函数式 API 为 `std.unittest` 的 `assertEqual/expectEqual/fail/failExpect`。
- 测试文件：**与被测源码同目录、同 `package`，文件名必须以 `_test.cj` 结尾**（无 `src-test/`、无 `test/` 约定）。
- `cjpm test` **按文件名自动发现**，无需 `--test` 选项；正常构建不含这些文件；产物 `target/release/unittest_bin`；前提是项目能 `build` 成功；`--filter/--parallel/--timeout-each` 是**测试二进制运行期**选项，不是 `cjpm test` 选项。

> 反面教材：本仓库 `.claude/skills/cangjie-lang/examples/09_unit_test.cj` 中的 `@Test class` + `@Assert(...)` 写法**是编造的伪语法**（文件自带「假设测试框架提供」注释），**不可作为 API 依据**。凡本地 skill 文档与官方文档冲突，一律以官方为准。

**`cjc` 编译选项**：`cjc --test` 使程序入口由 `main` 变为宏生成的 `test_entry`（来源：V5 `compile_options_ohos`）。
