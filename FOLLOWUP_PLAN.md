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

- [x] **P1.1 后端纯函数单测**（`cjpm test`，仓颉 `@Test`）—— **已完成 7 个测试文件 / 188 个 `@TestCase`，清单与期望值见第十二节 12.9**。
      ⚠️ 因本机无 SDK（L-CJ-1），这 188 个用例**从未被真正执行过**；质量靠两条纪律兜底：
      ①新语法必须先 `git grep` 基线同款用法；②数值断言逐条手算，取整未知处一律降级为容差或量尺（12.5）。
      优先只测**不需要数据库**的纯逻辑：
  - `crypto_util`：盐生成、哈希-校验往返、错误密码拒绝。
  - `jwt_util`：签名校验、篡改拒绝、过期拒绝。
  - `payroll_controller` 的个税分段 `calculateTax`（3%/10%-210/20%-1410/25%-2660 四档边界值）。
  - 绩效分数→等级→系数映射（90/80/70/60 边界与 `<60`）。
  - `router.cj` 路径分段与 QueryString URL 解码。
  - 为使后两项可测，需把算薪/评级纯函数从控制器里**提为独立函数**（行为不变的重构）。
- [x] **P1.2 接口级集成测试脚本**：`scripts/api-smoke.ps1` 覆盖 4 角色登录、越权 `403`、打卡、审批扣年假、生成工资、工资条金额核对，作为无 CI 时的手工回归。✅ **已完成并经桩验证**：8 个章节 / **112 个断言点**，对「正确后端」桩跑出 `112 通过 / 0 失败 / 0 跳过`（exit 0）；对 5 类人为注入的错误**全部变红**（exit 1）；服务未启动时 exit 2 并给出可操作提示。详见第九节与 `scripts/api-smoke.ps1` 文件头说明。
- [x] **P1.3 前端 Playwright E2E**：4 角色登录与侧边栏菜单隔离、审批弹窗提交、薪资生成后「我的工资条」金额一致。
      ✅ **已完成并经真实浏览器验证**：5 个 spec（auth 10 / rbac-menu 9 / attendance 8 / payroll 8 / approval 7）= **42 用例**，`--workers=1` 下 **42 passed (1.1m)**；`typecheck` / `eslint --max-warnings 0` / `build` 三连 exit 0。
      拦截层是**有状态内存 mock**（29 个接口，逐字段回 `backend-cangjie/src` 源码取契约），fixture teardown 断言 `unmatched == []` —— 前端发起但 mock 未实现的请求会直接让用例失败，这是防「测试通过但契约已漂移」的闸门。
      金额一致性实证：emp01 生成后「我的工资条」实发 `￥15796.54`，调项后 `￥16620.26`，与核算中心列表逐分对齐（非硬编码，由 mock 按 `calculateTax` 同口径现算）。
      过程中修掉一个**真实前端缺陷**（L-FE-5 冷启动画像过期）并消除一个**既存假绿**（payroll 精确数组断言），详见第九、十节。
- [x] **P1.4 GitHub Actions**：`.github/workflows/ci.yml`，前端 `npm ci && npm run typecheck && npm run build`；后端在 SDK 可用时 `cjpm build && cjpm test`（可先只跑前端 job，避免假绿）。
      ✅ **已完成**：[.github/workflows/ci.yml](./.github/workflows/ci.yml)（已用 js-yaml 解析校验，3 个 job）。
      `frontend`：`npm ci` → `typecheck` → `eslint --max-warnings 0` → `build` → 上传 `dist`。
      `e2e`：`npm ci` → `playwright install --with-deps chromium` → `npx playwright test`，失败时上传 `playwright-report`/`test-results`。
      `backend`：**默认 skipped**，`if: vars.BACKEND_CI_ENABLED == 'true'`。刻意不写未经核实的 SDK 下载地址、也不用 `continue-on-error` —— 两者都会把「后端无 CI」伪装成绿。文件内已逐条写明排除理由与启用前置条件。
      ⚠️ 关键实证：CI 用 `E2E_CHANNEL=chromium` 而非本地默认的 `msedge`。这条**已在本机按 CI 等价条件跑过**（`CI=true` ⇒ `workers=2` + `reuseExistingServer:false` 自建 vite dev + Playwright 自带 chromium）：**42 passed (38.8s)**。

**验收**：前端 CI 绿；单测覆盖全部金额与权限相关纯函数；越权与算薪金额有自动化断言。
      ⚠️ 诚实修正原验收口径：「CI 绿」目前**只覆盖前端**（typecheck/lint/build/42 个 E2E）。后端 188 个 `@TestCase` 与 `api-smoke.ps1` 的 112 个断言点**仍无执行环境**（L-CJ-1），对应 job 呈 skipped 而非 passed。

---

## 四、任务包 P2：导入导出与报表（对应指南工作包 B）

- [x] **P2.1 员工花名册批量导入**：`POST /api/v1/employees/import`，逐行校验工号唯一/部门存在，返回 `{ total, successCount, failedCount, imported, dryRun, failed: [{row, field, reason}] }`，整批一个事务语义（实现为「校验全通过再写库」），并写审计日志。**⚠️ 与计划有 2 处有意偏离，见下方「P2.1 契约」与 L-IMP-2。**

**P2.1 契约（已落地，P2.2 前端必须按此实现，勿再按上面那句旧描述写）**
- 请求：`POST /api/v1/employees/import`，body = `{"csv": "<CSV 纯文本>", "dryRun": <bool>}`。
  **CSV 解析放后端**，原因：校验口径必须只有一个权威；若前端解析、后端只收 JSON 数组，
  则「什么算一行」「引号怎么转义」「空行算不算数据」有两套实现，必然漂移。
  前端只做预览，不拥有判定权。（附带原因：stdx JSON 的数组 API 在基线零先例，见第十一节。）
- 表头 13 列固定名（顺序无关，按列名匹配）：`工号,姓名,性别,手机号,邮箱,身份证号,部门,岗位,基本薪资,年假余额,入职日期,合同到期日期,状态`。
- 状态接受 `ACTIVE/在职`、`PROBATION/试用期`、`RESIGNED/离职`；性别接受 `1/2/0`、`男/女/M/F/MALE/FEMALE`（大小写不敏感）。
- 整批 ≤ 500 行；任一行为空则**整批不写库**（`imported: 0`），错误行全量回显；`dryRun` 只校验不落库。
- 写库：一条 SQL 文本内 `START TRANSACTION` + 多值 `INSERT hr_employee` + `INSERT ... SELECT` 建 `sys_user`（初始口令统一 `123456` 的哈希）+ `COMMIT`。
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
| 2026-11-23 | P0.3 自查 | 写单测前对新增 `.cj` 做静态可编译性复核，发现并修复 **3 个真实缺陷** | ✅ ① `crypto_util.cj` 用了 `String.fromUtf8`/`Int64.tryParse` 却漏 `import std.convert.*`（基线原版不需要，重写后必然编译失败）→ 补 import；② `hashPassword` 的 `"cj1$${X}$..."` 裸 `$` 字面量属未证实词法 → 改为 `String.fromUtf8(Array<UInt8>(1, repeat: 0x24))` 构造 `PWD_SEP` + `+` 拼接；③ `str(PWD_ITERATIONS)` 用了未经证实的 `str()` → 改插值 `"${...}"` |
| 2026-11-23 | P0.3 自查 | 用 `git grep -E '\$[^{]' 6e79923 -- backend-cangjie/src` 反查基线 | ✅ **返回空集** → 证明基线中 `$` 永远紧跟 `{`，故裸 `$` 字面量确属未证实写法。据此建立「拿不准就用 `git grep <写法> 6e79923` 反查基线」的固定手法 |
| 2026-11-23 | L-CJ-2 | `main.cj` 9 处 `eprintln(` → `println(` | ✅ 风险关闭（`println` 为基线大量使用的已证实 API） |
| 2026-11-23 | 事故 | PowerShell `(Get-Content -Raw) -replace ... \| Set-Content -Encoding utf8` 给 `main.cj` **加了 UTF-8 BOM**（Windows PowerShell 5.1 的 `utf8` = 带 BOM），BOM 位于 `package` 之前会破坏词法分析 | ✅ 用 `[IO.File]::ReadAllText` + `Substring(1)` + `UTF8Encoding($false)` 去 BOM，复验首 4 字节 = `112,97,99,107`（"pack"）。**纪律：含 CJK 的源文件一律用 .NET `WriteAllText` + 无 BOM 编码，禁用 `Set-Content -Encoding utf8`** |
| 2026-11-23 | L-CJ-3 复核 | `git grep -n -e '\${if (' 6e79923 -- backend-cangjie/src` | ✅ **推翻上一轮结论**：基线有 **4 处**同写法而非 1 处，属「已证实可用」→ 判定为**误报**，决定**不回改基线**（零收益 + 有回归风险）。第十一节相应条目已从「不可用」移入「已证实可用」 |
| 2026-11-23 | 取证 | 用 .NET `SHA256`/`HMACSHA256` 离线算出全部测试期望值 | ✅ 拒绝凭记忆写常量；但**本轮发现期望值表本身有错**，见下两行 |
| 2026-11-23 | 取证纠错 | `WebFetch` RFC 4231 原文逐字核对 HMAC 用例 | 🔴 **推翻自己上一轮的记录**：RFC 4231 **只有 7 个 Case**，此前按记忆写的「Case7 = …Hash Key First」实为 **Case 6**；而所谓「Case8 = `6355ac22…`」**纯属编造，官方无此用例**，已从所有待写入代码中删除。正确 Case 7 = 131×`0xaa` key + 152 字节长句 data → `9b09ffa7…`。**教训：标准用例集必须从原文取，绝不能凭记忆** |
| 2026-11-23 | ★ 算法等价性验证 | 用 PowerShell **逐行复刻** [crypto_util.cj](./backend-cangjie/src/common/crypto_util.cj) 的 `hmacSha256`（含 `key.size > 64 → SHA-256 压缩后取前 32 字节` 分支、ipad/opad 构造），与 .NET `HMACSHA256` 标准实现在 RFC 4231 **Case 1/2/3/4/6/7** 上逐用例比对 | ✅✅ **6/6 全等**。这是 L-CJ-1「后端全程无法编译」约束下**第一次、也是目前唯一一次对后端算法做出的真实正确性证据** —— 不依赖编译器，直接证明 HMAC 构造在算法层无误（含长 key 压缩分支）。期望值表见第十二节 |
| 2026-11-23 | 取证 | 读 `app_config.cj` 全文确认 `globalConfig` 能否在测试进程内安全初始化 | ✅ `loadDotEnv`/`resolveMysqlExe` 全程 `try/catch(_:Exception){}` + `exists` 短路，无 `.env` 时仅回落默认值 → `cjpm test` 不会因配置加载抛异常，测试可安全引用 `globalConfig.jwtSecret` |
| 2026-11-23 | 取证 | 用 PowerShell 复刻 `round2`/`formatNum2` 校验期望值 | ⚠️ **发现语义陷阱**：PowerShell `[long]$x` 是 round-half-to-even，仓颉 `Int64(Float64)` 官方教程仅证实 `Int64(1024.1024)→1024`（截断方向），`.5` 边界无法证实。据此定下**测试策略：纯整数级金额做精确断言，凡落在 `.5`/二进制不可精确表示的浮点一律用 `@Assert(a, b, delta: 0.011)`** |
| 2026-11-23 | P1.1 | 落地 7 个测试文件共 **188 个 `@TestCase`**：crypto(22) / jwt(26) / response(26) / router(13) / payroll(32) / performance(30) / rate_limit(39) | ⚠️ **仍未编译**；`@Test`/`@TestCase` 逐行分列、import 成对、同包同名 `_test.cj` 全部按第十一节官方规范自查 |
| 2026-11-23 | P1.1 收口 | `payroll_controller_test.cj` 里旧量尺 `payCentResidue`（依赖 `Int64` 截断方向）全部替换为语义无关的 `payCentDistance(v) <= 0.01` | ✅ `git grep payCentResidue` 零命中；并按 IEEE-754 double 间距论证 `99999.99+0.01` 精确舍入为 `100000.0` → `tax 21090.00 / net 78910.00` 落在整数分上，新阈值可达 |
| 2026-11-23 | 取证 | 反查 `_ = expr`（丢弃非 Unit 返回值）在基线中的先例 | 🔴 **零先例**：基线只存在 `auth_controller.cj:96` 那种「调用返回 Unit 的函数」作语句。据此把 `rate_limit_test.cj` 里 **24 处** `_ = recordLoginFailure(...)` / `_ = rlFailNTimes(...)` 全部改为「先 `let` 绑定再断言返回值」，循环内改为累加进具名 `var` —— 既消除未证实语法，又净增约 20 条真实断言 |
| 2026-11-23 | 取证 | 反查 `let (a, _, c) = tuple` 与 `return if (c) {x} else {y}` | ✅ 均有基线先例（`mysql_pool.cj:322`、`crypto_util.cj:206/222`；`rate_limit.cj:47`、`response.cj:181`）→ 判定可用，写入第十一节「已证实可用」清单 |
| 2026-11-23 | 自查 | `performance_controller_test.cj` 中 `perfNullSrc`/`perfRatioText` 写在 `@Test class` **之后** | ✅ 顶层声明的「前向引用是否可用」未获基线证实 → 整体搬至 class 之前并删除尾部重复副本；`rate_limit_test.cj` 的 `rlItoa` 同病同治 |
| 2026-11-23 | 防假红 | 复核 `testBlockedSecondsWithinBlockWindow` 的 `s >= LOGIN_BLOCK_SECONDS - 1` | ✅ 放宽为 `- 5`：触封时刻与读取时刻之间若宿主机卡顿 >1s，旧断言会把**环境问题报成代码缺陷**。同类：全表状态机用例统一「首行 `resetLoginThrottle()` + `rl-<用例名>` 唯一键」双重隔离 |
| 2026-11-23 | 取证 | 为写冒烟脚本，逐条回源码校准响应字段名（**不靠想象、不靠桩自证**） | ✅ 4 个 controller 的 JSON 拼接段全部 Read 核实：`attendanceRowToJson`(`clockInTime/clockOutTime/lateMinutes/earlyMinutes/status`)、`attendance/my` 的 `{list, summary{month, shouldAttendDays:22, actualAttendDays, lateCount, earlyCount, leaveDays, overtimeHours}}`、`dashboard/overview` 的 7 个 KPI + 5 个数组字段、`auth/me` 的 16 字段 userJson、`payrolls/generate` 的 `{payMonth, generatedCount}`。**教训：搜仓颉源码里的 JSON 字段名必须搜裸标识符** —— 源码写成 `"\"clockInTime\":${jsonStr(r[6])}"`，用 `jsonStr\("clockInTime"` 这类模式**零命中**，会误判为「接口没这字段」 |
| 2026-11-23 | P1.2 | 落地 [scripts/api-smoke.ps1](./scripts/api-smoke.ps1)（约 660 行，8 章节，112 断言点）：①探活 ②4 角色登录 + 4 种 401 + 改密 ③RBAC 12 条 403 / 9 条 200 / 404 / 方法不匹配 ④看板 KPI ⑤打卡幂等 ⑥请假审批扣年假 + 撤回 ⑦绩效自评 ⑧薪酬生成**逐行金额复算** + batch-pay 缺参 400 + 审计日志 | ⚠️ 编写完成；`[Parser]::ParseFile` 零错误；UTF-8 **with BOM**（`.ps1` 含 CJK 必需，与 `.cj`/`.md` 相反，见第十一节） |
| 2026-11-23 | P1.2 验证 | 写一次性 node 桩（**不入库**）建模「完全正确的后端」，按源码契约复刻统一信封 `{code,message,data}`、路由 404、`Bearer ` 前缀 401、角色 403、年假扣减状态机、同日重复打卡 400 | ✅ 首跑 `9 通过 / 34 失败` → 定位为**桩自身 bug**（`/auth/login` 误标为需鉴权）→ 修复后 `112 通过 / 0 失败 / 0 跳过`，`exit 0` |
| 2026-11-23 | P1.2 反检 | **反向自检**：给桩加 `SABOTAGE` 开关注入 5 类真实缺陷，逐一验证脚本必须变红（防止「桩与脚本同时写错而自洽」的假绿） | ✅✅ 5/5 全部捕获且 `exit 1`：`tax`→个税分档 + 实发口径 2 处失败；`rbac`→18 条越权失守；`leaveskip`→`审批通过扣减年假 1 天（5 -> 5）`；`clockdup`→同日二次打卡未拒；`audit`→日志无本轮动作痕迹 |
| 2026-11-23 | P1.2 边界 | 退出码与降级路径实测 | ✅ 无服务：`exit 2` + 提示「请先启动后端：`powershell -File .\start-backend.ps1`」（本轮作废，不计通过）；`-SkipMutating`：`63 通过 / 0 失败 / 5 跳过`，`exit 0`（写操作正确降级为 SKIP 而非假绿） |
| 2026-11-23 | P1.2 修 bug | 隔离实验定位「看板数组非空」两条假红 | ✅ 根因是 **PowerShell 输出流自动解包**：`Get-JsonArray` 里 `return @($Value)` 在单元素时退化成标量 `PSCustomObject`，其 `.Count` 求值为**空**（不是 1），`-ge 1` 判假。三处 return 改一元逗号 `return , @($Value)`。已把该坑写进函数注释与第十一节纪律 |
| 2026-11-23 | P1.2 防假绿 | 重构第 5 节年假守卫：原实现 `/auth/me` 失败时把余额读成 0 并**静默降级为事假**，会把「鉴权整体挂了」渲染成「用例通过」 | ✅ 改为 `[double]::NaN` 哨兵 + `IsNaN / ANNUAL / 其它` 三分支；SKIP 只在断言点记一次（避免重复计数），守卫处只打 WARN |
| 2026-11-23 | P1.2 防自崩 | 断言的**详细消息参数先于断言本身求值**，`"...$($resp.Data.GetType().Name)"` 在 `Data` 为 null 时抛异常→trap→`exit 2`，把「接口契约不符」错报成「脚本崩溃」 | ✅ 该处改为对原始报文做正则判定：`$myPay.Text -match '"data"\s*:\s*\['`。纪律固化进第十一节 |
| 2026-11-23 | P1.3 契约取证 | 为给 mock 补接口，`Read` 逐字段核实 4 个后端 handler 与 `main.cj` 的路由注册（**不靠记忆、不靠前端 TS 类型反推**）：`handleDepartmentsTree` / `handlePositionList` / `handleSystemUsers` / `handleSystemAuditLogs` | ✅ 取得权威口径：`activeCount` 是「`status != 'RESIGNED'`」**含试用期**；`children` 空集必须输出 `[]`；`isActive` 后端由字符串 `"1"` 转**布尔**出参；`sendPage` 信封固定 `{list,total,page,pageSize}` **不回显查询条件**；`pageSize` 非 `1..100` 一律回落 15；`/system/*` 是 `requireRoles(["ADMIN"])` 而 `tree`/`positions` 只 `requireAuth` |
| 2026-11-23 | P1.3 | mock 后端从 25 个接口扩到 **29 个**：新增 4 条路由 + 4 个 handler，并给 `Account` 补 `lastLoginAt`/`createdAt` 两字段以贴合 `sys_user` 列 | ✅ rbac-menu 用例的 unmatched 闸门由红转绿 |
| 2026-11-23 | P1.3 根因 | 3 例用例（approval:62 / approval:74 / payroll:72）登录 `waitForURL` 30s 超时 | ✅ 根因**不是断言写错**，是 **Playwright fixture 惰性**：只有被用例解构到的 fixture 才 setup，凡 `async ({ page }) => {}` 的写法 `mock` 根本没初始化 → `context.route` 从未挂载 → 登录穿过 vite 代理打到不存在的 8080。修法是把 `mock` 声明成 **auto fixture**（`[fn, { auto: true }]`），副作用是 unmatched 闸门对**所有**用例生效 |
| 2026-11-23 | ★ L-FE-5 修复 | 2 例年假余额假红（期望 4 得 5、期望 0 得 5）→ 定位为**真实前端缺陷**：`auth.user` 初始化自 `localStorage.hrms_user` 是登录那一刻的快照，旧守卫只在 `!auth.user` 时 `refreshProfile` ⇒ 整页刷新**永不**回源 `/auth/me`，改角色/审批扣假后页面长期显示过期画像 | ✅ **改前端而非弱化断言**：[router/index.ts](./frontend-web/src/router/index.ts) 加模块级 `profileSynced` 开关，每次整页加载后首次进入受保护路由强制同步一次（`from.path === '/login'` 时跳过，避免刚登录多打一次）。`approval.spec.ts:158` 的 `page.reload()` 后断言余额 `4` 通过，等于用 E2E 钉住了这个缺陷的回归 |
| 2026-11-23 | P1.3 闸门见效 | 守卫新增 `/auth/me` 后 rbac-menu 报越权请求 | ✅ 把 `/api/v1/auth/me` 加进 `trackProtectedApi` 白名单并**在注释里写清理由**：它发生在目标组件挂载之前，属导航守卫的画像同步，不是越权模块偷跑数据 |
| 2026-11-23 | ★ 抓出既存假绿 | 修完守卫后 `payroll.spec.ts:82` 反而变红：收到 `['/api/v1/payrolls', '/api/v1/payrolls/my']` | ✅ 读 `PayrollView.vue` 确认这是**设计如此**（「我的工资条」pane 对 HR 无 `v-if`，`onMounted` 无条件 `loadMyPayrolls()`）；旧断言 `toEqual(['/api/v1/payrolls'])` 一直靠「请求恰好早于监听器」而**假绿**，新加的 `await /auth/me` 改变时序才把它揭穿。**改测试、保留严格意图**：断言换成「非 payrolls 路径为空集」+ `toContain('/api/v1/payrolls')`，并注释警告勿再退化成精确数组 |
| 2026-11-23 | P1.3 收口 | 复跑全量 + 三连静态检查 | ✅ `42 passed (1.1m)`（`--workers=1`）；`npm run typecheck` / `npx eslint . --max-warnings 0` / `npm run build` 全 exit 0（build 的 chunk >500kB 警告系既存，非本轮引入） |
| 2026-11-23 | 文档回填 | 回填 P1.3 时反查代码注释里引用过的编号，发现**注释与风险表脱节**：`L-FE-2`/`L-FE-4` 已被 `attendance.spec.ts` 引用、`L-FE-5` 已被 `router/index.ts` 与 `rbac-menu.spec.ts` 引用，但第十节只有 `L-FE-1` | ✅ 第十节补齐 `L-FE-2`~`L-FE-5`（已修项用删除线 + 标注回归锁位置）并新增 `L-MOCK-1`/`L-MOCK-2`/`L-E2E-1`/`L-E2E-2` 四条诚实清单。**纪律：代码注释引用风险编号时，该编号必须在第十节存在**，否则引用悬空 |
| 2026-11-23 | L-FE-3 顺手修 | 登记 `UserProfile.isActive: number` 时回源码确认 `auth_controller.cj:34` 出参为 `${r[4] == "1"}`（布尔），且 `git grep isActive` 证明**当前无消费方** | ✅ 类型改 `boolean` + 注释标出处；删掉 mock 里为此而写的 `true as unknown as number` 强转（强转即该偏差的化石证据）。改后 `typecheck` exit 0，零运行时行为变化 |
| 2026-11-23 | P1.4 前置取证 | 发现 `playwright.config.ts` 的 `channel` 默认 `'msedge'`（为迁就本机无 Chrome 而设），GitHub runner 上的 msedge 是否可用**未经证实** → 不赌，改为 CI 显式 `E2E_CHANNEL=chromium` + `playwright install --with-deps chromium` | ⚠️ 先静态查 `types.d.ts`：`channel?: string`（自由字符串，无类型约束），`coreBundle.js` 里只在 CDP 连接分支见到 `channel === "chromium"` 判断 → **静态无法定论**，遂转为实测（见下一行） |
| 2026-11-23 | ★ P1.4 实证 | 本机 `npx playwright install chromium` 后，用**与 CI 完全等价的条件**复跑：`E2E_CHANNEL=chromium` + `CI=true`（后者同时触发 `workers=2`、`github` reporter、`reuseExistingServer:false` 自建 vite dev） | ✅✅ **42 passed (38.8s)**，`exit 0`。`channel: 'chromium'` 在 Playwright 1.65.1 下确实解析为自带 Chromium，此前的静态存疑被实测消除。**且比 msedge 快了近一倍**（1.1m → 38.8s） |
| 2026-11-23 | P1.4 | 落地 [.github/workflows/ci.yml](./.github/workflows/ci.yml)：`frontend`（`npm ci`/typecheck/eslint/build/上传 dist）+ `e2e`（install chromium → `playwright test`，失败上传 report）+ `backend`（`if: vars.BACKEND_CI_ENABLED == 'true'`，**默认 skipped**）；带 `concurrency` 取消旧运行、`timeout-minutes`、`permissions: contents: read`、`npm ci` 而非 `install` | ✅ 用仓库内已有的 `js-yaml` 解析校验通过（3 job / 步骤数与 `if` 表达式均符合预期）。**后端 SDK 安装步骤刻意留空并注明「需人工核实」**：宁缺毋伪，不写没核实过的下载地址，也不用 `continue-on-error` 把「后端无 CI」伪装成绿 |
| 2026-11-23 | P1.4 反假绿 | `backend` 作业里的 `api-smoke` 步骤**故意 `exit 1`** | ✅ 该步骤需要「已启动的后端 + `hrms_db`」，CI 里两样都还没接入。若此处静默跳过，一旦有人启用 `BACKEND_CI_ENABLED`，就会看到「build+test+smoke 全绿」的假象。改为明确 `::error::` + `exit 1`，把「没接线」暴露成刺眼的红 |
| 2026-11-23 | ★ P1 提交前自审 | 提交前把**无法编译的后端改动**逐处回基线取证（`git grep <pat> 6e79923` 是这里唯一的武器）：① `case X =>` 后接多条语句 —— 基线 `jwt_util.cj:85-87` 正是此形 ✅；② `Array<UInt8>(1, repeat:)` —— 构造式来自基线 `router.cj:9 Array<Byte>(4096, repeat: 0)`，`UInt8` 本身另有官方文档取证（本文件 286 行）✅；③ 元组 `_` 解构 —— 基线确有，但注释里的**行号引用是错的**（写 126，实际 322） | ✅ 修正该行号。**教训**：文档里刚立完「注释引用风险编号必须存在于风险表」的纪律，自己的代码注释就有一条行号失效 —— 引用一旦写进注释就必须可核验，否则它比没有引用更坏 |
| 2026-11-23 | P1 提交前清理 | `.gitignore` 的 Playwright 段落里 `frontend-web/playwright-report/` 被重复写了两遍（本会话两轮各自加过一次，互不知情） | ✅ 去重并给 `.pw-browsers/` 补上「仅当把 `PLAYWRIGHT_BROWSERS_PATH` 指进仓库时才会出现」的说明；`*.log` 早已在忽略列表内，故历史 `e2e-run-*.log` 从未进过暂存区（`git status -uall` 复核通过） |
| 2026-11-23 | **P2.1** | 后端落地员工批量导入：`employee_controller.cj` +约 530 行（`parseCsvInto` 手写 RFC4180 子集 / `csvSplitRows` / `csvStripBom` / `csvRowIsBlank` / `csvColIndex` / `csvCell` / `strRuneLen` / `isAllDigits` / `strHas` / `isValidYmd` / `empImportGender` / `empImportStatus` / `validateImportRow` / `importFailJson` / `empImportHeader` / `empImportCols` / `handleEmployeeImport` / `doEmployeeImport` / `importResultJson` / `persistImport`），`main.cj` 注册 `POST /api/v1/employees/import`（**必须排在 `segs.size == 4` 的员工详情分支之前**） | ⚠️ 代码完成；无 SDK，未编译未运行（L-IMP-1） |
| 2026-11-23 | P2.1 契约取证 | 写实现前先把**能用的 API 边界**钉死：`queryRows` 只有 1 个参数、`match` 必须写 `case Some(x) =>`、`String.size` 对非 ASCII 无基线样本、`String.contains` / `JsonKind.JsArray` / `asArray` / `ArrayList` 下标赋值 / 数组字面量构造 / 单引号字符串 / `\|>` 管道 在基线**零先例** | ✅ 一律改走已确证构造：子串存在性用 `replace` 长度差（`strHas`）、字节串用 `String.fromUtf8(ArrayList<UInt8>.toArray())`、特殊字符用命名字节常量、长度一律 `toRuneArray().size` |
| 2026-11-23 | ★ P2.1 抓到真实缺陷 | 初版长度校验写成 `empNo.size > 32` / `name.size > 64` | ✅ `String.size` 是 **UTF-8 字节数**（`truncateUtf8` 正是靠它做字节截断），中文姓名 1 字 3 字节 ⇒ 64 的上限实际只允许 **21 个汉字**，MySQL `VARCHAR(64)` 却按字符计长。全部改走 `strRuneLen()`，并在单测里用 `"张三".toArray().size == 6` 把这条口径钉住 |
| 2026-11-23 | P2.1 单测 | 新建 `employee_import_test.cj`：**35 个 `@TestCase`**、只测纯函数（不碰 HttpContext/DB），辅助函数刻意**不复用被测解析器**（`impSplit` 手写扫描而非 `String.split`，避免循环论证），风格对齐 `payroll_controller_test.cj` | ⚠️ 未运行；期望值全部经 node 独立复算 |
| 2026-11-23 | ★ P2.1 期望值复核 | 用 node **按同一算法复刻** `parseCsvInto/csvSplitRows/csvStripBom`，对 18 组输入逐条打印 `rows/counts/lines`，再回填断言 | ✅ 当场纠出 **5 处错断言**：`impParse("\r\n")` 实为 1 行（空行本身是记录）、`"a\r\n\r\nb\r\n"` 实为 3 行、`He said "hi"` 是 12 字符不是 11、缺列时报错数是 11 不是 12、`csvColIndex` 只 trim 表头不 trim 列名（`" 岗位 "` 应为 -1）。**教训：无法编译时，「我以为的语义」与「代码的语义」的偏差只能靠独立实现去撞，肉眼读第二遍几乎全绿** |
| 2026-11-23 | P2.1 结构自检 | 写临时 node 脚本做 3 项静态体检：`.cj` 无 BOM 且 UTF-8 可往返、花括号配平（跳过字符串/注释）、测试文件里每个被调用的标识符都有定义处 | ✅ 35 用例 / 括号 depth=0 min=0 / 类体内 `let·var` 成员 0 处 / 未定义调用仅剩 std 方法（`fromUtf8·toArray·toRuneArray·toString`，均已取证） |
| 2026-11-23 | P2.1 行为决策 | 解析器忠实 RFC4180 会把空行变成「1 个空字段的记录」，直接送去校验会刷出 6 条必填错误 | ✅ 新增 `csvRowIsBlank`，在 `doEmployeeImport` 里**先剔空行再算 `total` 与 500 上限**，且行号仍取自原始 `rowLines`（剔除后第 3 行照旧报 3）。语义与策略分离：解析器不改，策略在调用方 |

---

## 十、已知限制与残留风险（诚实清单，不隐藏）

| 编号 | 风险 | 影响 | 处置 |
| --- | --- | --- | --- |
| L-CJ-1 | **全部后端 `.cj` 改动未经 `cjc` 编译** | 语法/类型错误只能在有 SDK 的机器上暴露 | 建立第十一节「API 考证纪律」；主动消除 4 处未证实语法；CI 里后端 job 标 `continue-on-error` 或不启用，**绝不假绿**。**部分缓解**：已用 PowerShell 复刻 `hmacSha256` 与 .NET 标准实现逐用例比对（6/6 全等），在不依赖编译器的前提下证明了核心密码学算法的**逻辑**正确性（注意：这只覆盖算法语义，**不覆盖语法/类型**） |
| ~~L-CJ-2~~ | ~~`eprintln` 未在基线出现过，`main.cj` 首次使用~~ | ~~若 `std` 未预导入则编译失败~~ | ✅ **已关闭**：`main.cj` 9 处 `eprintln(` 全部改为基线已证实的 `println(` |
| ~~L-CJ-3~~ | ~~「字符串插值内嵌 `if` 表达式」`"${if (...) { "null" } else { r[8] }}"` 是未证实语法，且是基线里唯一一处~~ | ~~若不支持则整个后端编译失败~~ | ✅ **经考证为误报，不改基线**：`git grep -n -e '\${if (' 6e79923 -- backend-cangjie/src` 命中 **4 处**（`performance_controller.cj:34,35`、`attendance_controller.cj:153,154`），按第十一节规则 1「基线已存在即已证实」直接放行；为零收益改动原作者可编译代码属过度工程 |
| L-RND-1 | `std.random.Random` **非 CSPRNG**，用于口令盐 | 盐可预测性弱于 OS 熵源 | stdx 无 `getrandom` 封装；已记录，待 SDK 后评估更强熵源 |
| L-RL-1 | 登录限流是**单进程内存表** | 多实例部署时限流失效 | 已在文件头注释；生产需外置存储 |
| L-RL-2 | 进程重启 → 限流状态清空 | 重启可绕过封锁 | 同上 |
| L-RL-3 | 服务绑定 `127.0.0.1`，`clientIp` 只能取 `X-Forwarded-For` | 无前置代理时所有请求共用 `local` 键 | 已在代码与注释中标注 |
| L-DB-1 | 每条 SQL 一个 `mysql.exe` 子进程（D3 未根治） | 高并发下吞吐极差、句柄风暴 | 串行闸门把并发压成 1，避免崩，但不解决慢 |
| L-FE-1 | `adoptRenewedToken` 只写 `localStorage`，Pinia 内 `token.value` 不同步 | 同一会话内内存态与服务端态短暂不一致；仅影响日志/调试 | 已记录，属可接受偏差；后续可在 `refreshProfile` 回读 |
| ~~L-FE-2~~ | ~~「考勤全员监控」把月份作为 `date` 参数发出，而后端只读 `month`~~ | ~~「按月份筛选」形同虚设，界面看着能用其实一直在查全量~~ | ✅ **已修 + 已加回归锁**：[attendance.spec.ts](./frontend-web/e2e/attendance.spec.ts) 中「筛选月份要按后端契约发 `month`」一条直接断言出站查询串；mock 侧同步只认 `month`（写错立刻 unmatched/筛选失效） |
| ~~L-FE-3~~ | ~~`UserProfile.isActive` 在 TS 里标成 `number`，而 `auth_controller.cj:34` 出参是 `${r[4] == "1"}`（**布尔**）~~ | ~~任何 `user.isActive === 1` 的写法静默恒假，且 `vue-tsc` 不会报错~~ | ✅ **已修**：类型改为 `boolean` 并注释标明后端出处；mock 里原有的 `true as unknown as number` 强转一并删除（该强转本身就是这个偏差的化石证据）。当前无消费方，属**消除陷阱**而非修复线上故障 |
| ~~L-FE-4~~ | ~~考勤「修正」弹窗只回传 `status`/`remark`，后端对 `lateMinutes`/`earlyMinutes` 取 `getJsonInt(..., 0)`~~ | ~~一次修正即把迟到分钟数清零，进而让「迟到/早退次数」与算薪扣款失真~~ | ✅ **已修 + 已加回归锁**：[attendance.spec.ts:144](./frontend-web/e2e/attendance.spec.ts) 「修正考勤不得抹掉迟到分钟数」钉住回传当前分钟数这一行为 |
| ~~L-FE-5~~ | ~~`auth.user` 只从 `localStorage.hrms_user` 水合（登录那一刻的快照），旧守卫仅在 `!auth.user` 时回源 `/auth/me` ⇒ **整页刷新永不刷新画像**~~ | ~~管理员被改角色后仍按旧角色放行菜单；审批通过的年假已扣但页面显示旧余额；账号被禁用仍停留在已登录视图~~ | ✅ **已修**：[router/index.ts](./frontend-web/src/router/index.ts) 增加模块级 `profileSynced`，每次整页加载后首次进入受保护路由强制 `refreshProfile()` 一次（来源为 `/login` 时跳过）。回归由 `approval.spec.ts` 的三处年假余额断言（含 `page.reload()` 后仍为 `4`）钉死。**注意**：该守卫的 `catch` 对 401 以外的异常**保留本地画像放行**，这是刻意取舍——不能让后端抖动把已登录用户踢下线，代价是极端情况下仍可能短暂看到旧数据 |
| L-MOCK-1 | E2E 的 29 个接口由**有状态内存 mock** 提供，`E2E_REAL=1` 直连真实后端的路径**从未跑过**（无 SDK，后端起不来） | 「42 passed」证明的是**前端逻辑 + 前端对契约的理解**自洽，不等于**后端实现无缺陷** | 与 `L-SMOKE-1` 同性质。所有 mock 契约均逐字段 `Read` 自 `backend-cangjie/src`（第九节有取证行），SDK 就位后首件事是 `E2E_REAL=1` 复跑；届时失败**默认判为 mock 与后端的漂移**，以源码为准修 mock |
| L-MOCK-2 | mock 是「按我读到的源码写的」，存在**读错字段**的残余风险 | 字段名/口径同时写错时 mock 与 spec 会自洽假绿 | 缓解手段是 teardown 的 `unmatched == []` 闸门（前端发起而 mock 未实现的接口必红）+ 分页/鉴权分支照抄后端语义；**根治手段只有 `E2E_REAL=1`**，见 L-MOCK-1 |
| L-E2E-1 | 整页加载后的 `page.on('request')` 监听器**只能在导航之后挂载**，早于监听器完成的请求采不到 | 对采到的请求做 `toEqual([精确数组])` 会退化成**计时器**，随机假绿/假红（`payroll.spec.ts` 的旧断言就假绿了若干轮才被揭穿） | 纪律固化：**导航后一律断言「不该出现的为空集」+ `toContain(关键项)`，禁止精确数组**；确需精确计数时改用 `page.route` 侧计数（拦截点必然全采） |
| L-E2E-2 | `--workers` 在本终端默认取到 `2`（`CI` 环境变量为真） | 与本地 `vite` 单实例预览服务并发时偶发抖动，报错形态像用例问题 | 本地复跑显式 `--workers=1`；CI 里由 Playwright 自己起 preview，不受此影响 |
| L-CI-1 | `ci.yml` 的**前端两个 job 尚未在 GitHub runner 上真跑过**（本机只能做到「等价条件复现」：`CI=true` + `E2E_CHANNEL=chromium` + 自建 dev server，42 passed） | runner 镜像差异（apt 依赖、Node 22 预装版本、`npm ci` 跨平台可选依赖）仍可能造成首跑失败 | 首次推送后**必须去看一眼 Actions 的实际结果**，失败即回来修 workflow，不许默认它绿。已尽量降低风险：浏览器不依赖 runner 预装（显式 `playwright install --with-deps chromium`）、依赖用 `npm ci` 锁死、`node-version: '22'` 与本机同大版本 |
| L-CI-2 | `backend` job 默认 `skipped`，且其 SDK 安装步骤是**空的**（只有 `command -v cjpm` 检查）；`api-smoke` 步骤**故意 `exit 1`** | 仓库里看不到后端 CI 信号；若误开 `BACKEND_CI_ENABLED` 会直接红 | 这是**有意的**。禁止用 `continue-on-error`/写死未核实下载地址来凑绿；真正启用需要：①核实并补上 SDK 安装 ②在 job 内起 MySQL 并导入 `sql/init.sql` ③拉起 8080 后再摘掉 smoke 的 `exit 1`。三步缺一不可 |
| L-TMP-1 | 临时 `q_<seq>.sql` / `c_<seq>.cnf` 落盘 | 崩溃时残留含口令的 cnf 文件 | `finally` 里 `removeQuiet`；建议部署机对 `tmp_sql` 目录开启 ACL 限制 |
| L-COV-1 | 无 CI 运行后端测试 | 单测写了但跑不起来 | `cjpm test` 已按官方规范编写，SDK 就位即可执行 |
| L-SMOKE-1 | `scripts/api-smoke.ps1` **只对本地桩执行过，从未对真实后端跑过**（无 SDK，后端起不来） | 「112 通过」证明的是**脚本逻辑自洽且能抓错**，不等于**当前后端实现无缺陷** | 已在脚本文件头显式声明此前提；SDK 就位后首件事即 `powershell -File scripts\api-smoke.ps1` 对真实 8080 复跑，届时若出现失败，**默认判为后端缺陷**（脚本的反检能力已由 5 类注错证明） |
| L-SMOKE-2 | 用于验证脚本的 node 桩**刻意不入库** | 无自动化回归网可长期复用 | 桩是「按我读到的源码写的」，若字段名记错会与脚本**同时错而自洽**；长期 fixture 更会与真实 API 漂移并反过来误导。故只在会话内使用、验毕即删，契约的唯一权威来源是 `backend-cangjie/src` 源码本身 |
| L-SMOKE-3 | 脚本对**打卡幂等 / 登录限流 / 余额不足**等状态相关分支采取「宽容 + SKIP」策略 | 这些路径不会稳定产出断言，覆盖率有水分 | 宁可 SKIP 也不假绿；SKIP 数在汇总里单独打印，便于识别「本次实际验证了多少」 |
| L-IMP-1 | **P2.1 的导入接口与其 35 个单测同样未经 `cjc` 编译/运行**（无 SDK） | 语法或类型错误只在有 SDK 的机器上暴露；「单测全绿」目前只是**静态期望值一致**，不是执行结果 | 缓解：①每个断言的期望值都用 node 按同一算法**独立复算**过（解析器/行号/字节长度逐条核对）；②只使用基线已出现过的语法构造；③新增 API 依赖（`String.replace`/`toRuneArray`/`toArray`/`String.fromUtf8`）均回基线取证。根治：SDK 就位后 `cjpm test` 首跑 |
| L-IMP-2 | 导入的**传输契约偏离了第四节的原始描述**（CSV 文本交后端解析，而非前端解析后传 JSON 数组） | 若后来者按第四节旧文实现前端，会打出后端不认的 body 结构 | 已在第四节就地改写契约 + 在 `employee_controller.cj` 的 P2.1 段头注释里写明理由；P2.2 必须以「P2.1 契约」小节为唯一依据 |
| L-IMP-3 | 批量写库把 `START TRANSACTION` / 多值 `INSERT` / `INSERT…SELECT` / `COMMIT` 拼成**一条 SQL 文本**交给 `executeSql` | 依赖 mysql 客户端对多语句批处理的默认行为；若服务端配置（如 `NO_BACKSLASH_ESCAPES`）异常，可能整批失败或字段错位 | 失败路径返回 500 + `lastDbErrorMessage()` 且**不落半批**；`sqlStr`/`sqlNullableStr` 沿用基线同一转义口径，未新造转义逻辑 |
| L-IMP-4 | 导入时**静默跳过全空行**（不计入 `total`，也不报错） | 用户若想确认「模板里有多少空行」得不到提示 | 有意取舍：Excel 另存为常带尾随空行，若按数据行校验会一次报出 6 条必填错误并淹没真错误。判据 `csvRowIsBlank` 已单独建单测锁住语义 |

---

## 十一、仓颉 API 考证纪律（本会话建立，是「无法编译」约束下的唯一质量兜底）

**规则**：任何新写的 `.cj` 语法，必须满足以下之一，否则不许落地。
1. 该写法在**基线提交 `6e79923` 的既有代码里已存在**（等价于已被真实编译器接受过）；
2. 该写法在**官方文档中被逐字背书**（developer.huawei.com V5 指南 / docs.cangjie-lang.cn 1.0.5 API）。

**已证实可用（基线或官方）**：
`String.toArray/fromUtf8/toRuneArray/replace/trimAscii/isEmpty/startsWith/endsWith/split/indexOf/toAsciiLower`；
`ArrayList.add/toArray/size/[]`；`Array<T>(size, repeat: value)` —— **本轮双重背书**：① 官方 std.core 文档原文「该构造函数**不会拷贝 `repeat`**，如果 `repeat` 是一个引用类型，构造后数组的每一个元素都将指向相同的引用」；② 官方社区可运行示例 `Array<Int64>(3, repeat: 1)`。此前一度因搜索结果把另一重载渲染成 `init(size: Int64, item!: T)` 而误判 `repeat:` 是错参数名，追加查证后确认**参数名就是 `repeat`**，`crypto_util.cj`/`rate_limit.cj` 的写法无需改动；`File.writeTo/exists/remove`；`Directory.create(recursive:)`；
`executeWithOutput` → `(Int64, Array<UInt8>, Array<UInt8>)`；`AtomicInt64.fetchAdd`；
`Int64/UInt16/Float64.tryParse`、`?? def`、`if (let Some(x) <- ...)`；
`toHexString`、`SHA256().write/finish`、`toBase64String/fromBase64String`；
切片 `s[..n]` / `s[(i+1)..]`、`if` 表达式赋值、`match/case`、`for (x in arr)`、`try/finally` 内 return；
**多语句 `match` 臂**（`case Some(x) =>` 后跟整段缩进块、块内再嵌 `match`）、**元组解构 `let (a, b) = f()`**（基线 `payroll_controller.cj:98,186`、`performance_controller.cj:171`、`mysql_pool.cj:61,84,126,136`）；
**元组解构中的 `_` 占位**（`let (code, _, errStr) = runMysqlFile(sql)`、`let (_, iter, saltHex, digestHex) = stored`；基线 `mysql_pool.cj:322`、`crypto_util.cj:206/222`，多 `_` 的四元组亦实证可用）；
**`return if (c) { a } else { b }`（if 表达式直接作为 return 的值）**（基线 `rate_limit.cj:47`、`response.cj:181`）；
**字符串插值内嵌 `if (...) { } else { }` 表达式**（基线 4 处实证：`performance_controller.cj:34,35`、`attendance_controller.cj:153,154`）—— 已证实可用，但**新代码仍优先用独立函数**（可读性 + 便于单测），不为此回改基线；
原始字符串 `"""..."""` 支持 `${}` 插值；整数字面量按目标类型推断；
`std.sync`：`interface IReentrantMutex { lock(): Unit; tryLock(): Bool; unlock(): Unit }`，**`ReentrantMutex` 实现该接口**（`lock()` 无 Guard 返回值）；
`std.random`：`open class Random`，`init()`、`nextUInt8s(Array<UInt8>): Array<UInt8>`、`nextUInt64()`；
`DateTime.now().toUnixTimeStamp().toSeconds()`；`Exception.message`。

**已证实不可用 / 主动规避**：
`HashMap`/`ConcurrentHashMap`（未证实 → 用 `ArrayList` 线性表 + 互斥锁）；`Mutex.lock()` 返回 Guard（未证实 → 用 `ReentrantMutex` 的 `lock()/unlock()`）；
引用同一性 `!==`/`!===`（未证实 → 改为按 key 值过滤）；**顶层 `var` 全局可变变量**（未证实 → 改为 `let store = Store()` + 类内 `var` 字段，与基线 `let queryCounter = AtomicInt64(0)` 同构）；
`Rune → UInt32` 显式转换（未证实 → 用 `String.toArray()` 的字节循环比较）；`removeAt`（未证实 → 重建表）；
**顶层函数的声明顺序**：基线所有 `.cj` 都把 helper 写在被调用点**之前**，未出现任何「后定义前调用」的实例
  ⇒ 无法证实前向引用可用，纪律定为「测试文件的顶层 helper 一律放在 `@Test class` 之前」；
**丢弃非 `Unit` 返回值**：`_ = f()` / `let _ = f()` 在基线中**零先例**（唯一近似形态是 `auth_controller.cj:96`
  那种调用返回 `Unit` 的 `clearLoginFailures(tkey)` 作语句）⇒ 禁用，改为先 `let` 绑定再拿去断言。
**含裸 `$` 的字符串字面量**（如 `"$"`、`"a$b"`）与 **`"$${X}"` 试图转义 `$` 的写法** —— 已用 `git grep -E '\$[^{]' 6e79923 -- backend-cangjie/src` 证实**基线里 `$` 后面永远紧跟 `{`**，即整个仓库从未出现过一个不启动插值的 `$`。因无法排除仓颉支持 `"$ident"` 简写插值，这类写法词法风险不可控 → 需要裸 `$` 时用 `String.fromUtf8(Array<UInt8>(1, repeat: 0x24))` 逐字节构造（见 `crypto_util.cj` 的 `PWD_SEP`）；
**`str(x)` 转字符串函数**（未证实存在 → 一律用插值 `"${x}"`）；
**`eprintln`**（基线未出现 → 统一 `println`）。

**P2.1 新增的 5 条取证结论（本轮 `git grep` 基线 `6e79923` 所得，非推测）**：
- **`ArrayList` 下标赋值**（`arr[i] = v`）与 **`arr.set(i, v)`**：基线**零先例**。
  基线唯一的下标赋值只出现在 `Array<UInt8>` 上（`crypto_util.cj:72,96,105`、`jwt_util.cj:264-266`），
  而 `Array` 与 `ArrayList` 是两个类型，前者的能力不能推给后者 ⇒ 一律禁用，改为**逐个 `add`** 造定长表。
- **构造特殊字节串的标准做法**：`ArrayList<UInt8>()` + `add()` + `.toArray()` + `String.fromUtf8(...)`
  有基线先例（`employee_controller.cj:480`、`mysql_pool.cj:241`）；命名字节常量写法见
  `mysql_pool.cj:228-232`（`let byteDollar: UInt8 = 0x24`）⇒ 测试造 BOM / 全角数字一律走这条路径。
- **`String.split` 的「空分段是否保留」无佐证样本**：基线两处调用（`jwt_util.cj:93`、`crypto_util.cj:180`）
  的输入分段**必然非空**，语义悬而未决 ⇒ 尺子类函数（`impSplit`）改手写 `toRuneArray()` 扫描；
  被测代码里凡依赖 split 空段语义的判断（如 `email.split("@").size < 2`）一律替换为
  `strHas(s, sub)`（用 `s.replace(sub, "").size != s.size` 表达，两侧均为已证实 API）。
- **`String.size` 对非 ASCII 究竟是字节数还是字符数，基线无可佐证断言** ⇒
  字节口径只用 `"x".toArray().size`（`Array<UInt8>` 元素数 = 字节数，`truncateUtf8` 已确证同口径），
  字符口径只用 `strRuneLen()` = `toRuneArray().size`；**长度校验必须走 rune 口径**
  （MySQL `VARCHAR(n)` 按字符计长，按字节会把中文姓名上限缩水约 1/3）。
- **`String.contains` 零先例** ⇒ 子串存在性统一走上述 `strHas`。

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

### 11.1 PowerShell 5.1 脚本侧纪律（P1.2 建立，每条都是**现场踩过**的，不是抄来的）

> 与仓颉侧同理：本项目唯一的 Windows shell 是 Windows PowerShell 5.1，它对编码和输出流的处理有多处
> 与「直觉」相反的行为。下列 7 条中，前 3 条各直接导致过一次**假红或脚本崩解**，已在 `api-smoke.ps1` 里修掉。

1. **`return @($x)` 会被输出流自动解包（最阴险，制造假红）**
   函数返回单元素数组时，PowerShell 把数组解包成那个**标量元素**本身。于是标量 `PSCustomObject` 的 `.Count`
   求值为**空**（不是 1），`(...).Count -ge 1` 直接判假 —— 明明数据在，断言却红。
   ✅ 必须写一元逗号：`return , @($Value)` / `return , $Value`。
   （外包 `@(Get-JsonArray $v).Count` 能得 1，这正是定位根因的隔离实验：内层 `.Count` 空、外层 1 ⇒ 问题在返回处。）
2. **含 CJK 的 `.ps1` 必须存成 UTF-8 *with* BOM**（注意：与 `.cj`/`.ts`/`.md` 的「一律无 BOM」纪律**正好相反**）
   PS 5.1 无 BOM 时按 ANSI 代码页解析 → 中文注释/字符串变 `閫氳繃` → 全角括号 `）` 的字节序列破坏引号配对 →
   **解析器直接报 `Unexpected token`**。本仓库的实证：一次性反检脚本首次运行即以这种方式崩解，加 BOM 后正常。
   ✅ 落盘用 `[IO.File]::WriteAllText($p, $s, (New-Object System.Text.UTF8Encoding $true))`；校验用 `[Parser]::ParseFile`。
3. **断言的详细消息参数**先于断言本身**求值**
   `Assert-True (cond) "标题" "实际=$($resp.Data.GetType().Name)"` —— 当 `Data` 为 null 时，第三个参数**先抛异常**，
   触发脚本级 `trap` → `exit 2`，把「接口契约不符」（应为 exit 1 的失败）渲染成「脚本自身崩溃」（本轮作废）。
   ✅ 消息里禁止访问可能为 null 的成员；类型判定改走原始报文正则 `$resp.Text -match '"data"\s*:\s*\['`。
4. **`$null -eq @()` 为 `True`** ⇒ 绝不能用 `$null -ne $Data` 判断「是不是数组」，也不能用 `$null -eq $Data` 判断
   「是不是空数组」。✅ 统一经 `Get-JsonArray` 规整后用 `.Count` 判空，「字段缺失」另用原始文本断言。
5. **参数绑定会把显式 `$null` 转成 `""`**：`param([string] $Body = $null)` 收到 `-Body $null` 时实参是空串。
   ⇒ 不能用 `$null -ne $Body` 区分「没传」与「传了空体」。✅ 用 `[string]::IsNullOrWhiteSpace()` 或改用哨兵值。
6. **HTTP 层**：`Invoke-WebRequest` 必须 `-UseBasicParsing`（否则依赖 IE 引擎）；非 2xx 会抛异常，须
   `catch [System.Net.WebException]` 后从 `GetResponseStream()` 按 **UTF-8** 读响应体，才能拿到服务端返回的中文 `message`；
   请求体保持**纯 ASCII**，避免 PS 5.1 出站编码把中文写成乱码而污染数据库。
7. **不用 `Set-StrictMode -Version Latest`**：被测接口缺字段会让脚本自己崩（等同坑 3 的后果）。
   ✅ 改用脚本级 `trap { 打印 FATAL; exit 2 }`，并明确退出码语义：**0 全通过 / 1 有断言失败 / 2 环境不可用或脚本自身异常（本轮作废，不计通过）**。

**验证方法论（比上面 7 条更重要）**：桩**不能自证契约**。桩是按读到的源码写的，字段名若记错，会出现
「桩与脚本同时错而自洽」的假绿。因此：① 断言里的每个字段名都必须回 `backend-cangjie/src` 用 grep/Read 校准；
② 必须做**反向自检** —— 往桩里注入 N 类真实缺陷，逐类确认脚本**必然变红**，否则该断言等于没写；
③ 客户端**独立复算**业务口径（如个税 `Get-ExpectedTax` 与后端 `calculateTax` 同规则、不同实现），
防「前后端在同一处逻辑上写错却互相印证」。

---

## 十二、测试期望值（ground truth）固化表

> 全部数值**由本机 .NET `SHA256`/`HMACSHA256` 实算**，不使用任何「凭记忆」的常量。
> HMAC 用例集已用 `WebFetch` 拉取 **RFC 4231 原文**逐字核对（此前的 Case 编号错位已纠正，编造的 Case8 已删除）。

### 12.1 SHA-256

| 输入 | 十六进制摘要 |
| --- | --- |
| `""` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `"abc"` | `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad` |

### 12.2 HMAC-SHA256（RFC 4231；★ 自研实现与 .NET 标准实现 6/6 全等）

| Case | key | data | 期望 MAC |
| --- | --- | --- | --- |
| 1 | 20×`0x0b` | `"Hi There"` | `b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7` |
| 2 | `"Jefe"` | `"what do ya want for nothing?"` | `5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843` |
| 3 | 20×`0xaa` | 50×`0xdd` | `773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe` |
| 4 | `0102…19`（25 字节） | 50×`0xcd` | `82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b` |
| 6 | 131×`0xaa` | `"Test Using Larger Than Block-Size Key - Hash Key First"`（54 字节） | `60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54` |
| 7 | 131×`0xaa` | `"This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."`（152 字节） | `9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2` |

> Case 6/7 覆盖 `key.size > 64 → 先 SHA-256 压缩` 分支；Case 1/3/4 覆盖 `key.size <= 64 → 零填充` 分支。

### 12.3 口令派生 `deriveKey`（saltHex=`0a1b2c3d4e5f60718293a4b5c6d7e8f9`，口令=`Passw0rd!`）

| iterations | 期望值 |
| --- | --- |
| 1 | `7e761c1334828544d447f253a916f367104c0c16c054951f90208eca55196ed6` |
| 2 | `49d0540dd3bfd9c02fed2406a03758371aa8b77b99403d8d6ffd5c3178f1cb49` |
| 3 | `3e1a3768115e7c5b5c8719f9c7ad88f61d6e92213d89700ce611235f01917d1b` |

`legacyHash("admin123")` = `01af9bb1ecaaa9cca89e8e32f9d910ce776133525f804dc117a29d7ee6b14e7c`

### 12.4 纯函数边界（金额类按第十一节策略区分「精确」与「delta」）

`calculateTax`（两种取整语义下均一致 → **精确断言**）：

| taxable | tax | | taxable | tax |
| --- | --- | --- | --- | --- |
| `-100.0` | `0.0` | | `3000.0` | `90.0` |
| `0.0` | `0.0` | | `12000.0` | `990.0` |
| `500.0` | `15.0` | | `25000.0` | `3590.0` |
| `1000.0` | `30.0` | | `50000.0` | `9840.0` |
| `2000.0` | `60.0` | | `100000.0` | `22340.0` |

`calculatePayrollValues(base, bonus, ot, attDed, ss)`：

| 入参 | tax | net | 断言方式 |
| --- | --- | --- | --- |
| `10000,0,0,0,0` | `290.0` | `9710.0` | 精确 |
| `4000,0,0,0,0` | `0.0` | `4000.0` | 精确 |
| `0,0,0,0,0` | `0.0` | `0.0` | 精确 |
| `20000,5000,1000,500,2000` | `2290.0` | `21210.0` | **delta: 0.011**（落在 `.5` 边界） |

`mapPerformanceGrade`：`90.0→("S",1.20)`、`89.99→("A",1.10)`、`80.0→("A",1.10)`、`70.0→("B",1.00)`、`60.0→("C",0.80)`、`59.99→("D",0.50)`、`0.0→("D",0.50)`

`truncateUtf8`（手工推演 UTF-8 延续字节回退，**字节级确定**）：`("abc",5)→"abc"`、`("abcdef",3)→"abc"`、`("中文abc",4)→"中"`、`("中文",1)→""`、`("x",0)→""`、`("x",-5)→""`

`formatNum2` 精确可用值：`0.0→"0.00"`、`1.0→"1.00"`、`10.0→"10.00"`、`5000.0→"5000.00"`、`90.0→"90.00"`、`990.0→"990.00"`、`3590.0→"3590.00"`、`9840.0→"9840.00"`、`0.5→"0.50"`、`-0.5→"-0.50"`

### 12.5 断言强度分级（「无法编译」约束下防假绿 / 防假红的唯一杠杆）

`round2(x)` 的实现是 `Float64(Int64(absVal * 100.0 + 0.5)) / 100.0` 再加符号，
其中有两处**本机无法证实**的语义：
(1) `Int64(Float64)` 是向零截断还是就近取整（官方教程只证实 `Int64(1024.1024)→1024`）；
(2) 编译器是否把 `absVal * 100.0 + 0.5` 收缩成一条 fma（结果可能相差 1 ULP）。

因此所有金额断言分三级：

| 级别 | 适用场景 | 断言写法 |
| --- | --- | --- |
| **A 精确** | early-return 字面量 `0.0`；纯 Float64 比较（档位归属、单调性、上下界）；**源码字面量原样返回**（`mapPerformanceGrade` 的 1.20/1.10/1.00/0.80/0.50）；同一函数两侧同口径；纯字符串拼接（golden JSON、结构计数） | `@Assert(a, b)` |
| **B 容差** | 凡经过 `round2` / `formatNum2` 的分值 | `@Assert(a, b, delta: payEps())`，`payEps() = 0.011` |
| **C 量尺** | 想表达「输出落在整数分上」这一**与具体税额无关**的契约，又不想依赖 (1)(2) | `payCentDistance(v) <= 0.01` |

`payCentDistance`（[payroll_controller_test.cj](./backend-cangjie/src/controller/payroll_controller_test.cj)）：

    scaled = |v| * 100.0
    nearest = Float64(Int64(scaled + 0.5))
    d = |scaled - nearest|
    return if (d > 0.5) { 1.0 - d } else { d }

> 关键点：取 `min(d, 1-d)` 之后，**无论 `Int64()` 是截断还是就近，`nearest` 都是某个最近整数**，
> 距离语义不变 ⇒ 该量尺完全不受未知取整方向影响。反向自检 `payCentDistance(1.234) > 0.05`
> 证明量尺本身能分辨非整数分的值（123.4 分 → 距离 0.4）。
> **禁止**再写 `|x - Int64(x + 0.5)| <= 0.51` 这类依赖截断方向的老式判定。

### 12.6 `calculateTax` 分档表（完整 ground truth，含档界边际）

档位：`≤0 → 0`；`≤3000 → 3%`；`≤12000 → 10% - 210`；`≤25000 → 20% - 1410`；`else → 25% - 2660`。
档界**连续**：3000 两侧同 90.00、12000 两侧同 990.00、25000 两侧同 3590.00
⇒「档界 +1 元」的边际税额恰等于新档税率：`3001→0.10`、`12001→0.20`、`25001→0.25`。

| taxable | tax | 档 | | taxable | tax | 档 |
| --- | --- | --- | --- | --- | --- | --- |
| `500.0` | `15.0` | 3% | | `11999.0` | `989.9` | 10% |
| `1234.56` | `37.04` | 3% | | `12000.0` | `990.0` | 10% |
| `2500.0` | `75.0` | 3% | | `12001.0` | `990.2` | **20%** |
| `2999.0` | `89.97` | 3% | | `15000.0` | `1590.0` | 20% |
| `3000.0` | `90.0` | 3% | | `20000.0` | `2590.0` | 20% |
| `3001.0` | `90.1` | **10%** | | `24999.0` | `3589.8` | 20% |
| `4999.0` | `289.9` | 10% | | `25001.0` | `3590.25` | **25%** |
| `5700.0` | `360.0` | 10% | | `30000.0` | `4840.0` | 25% |
| `7777.0` | `567.7` | 10% | | `50001.0` | `9840.25` | 25% |
| `33333.33` | `5673.33` | 25% | | `99999.0` | `22339.75` | 25% |
| `999999.0` | `247339.75` | 25% | | | | |

`calculatePayrollValues` 五元组向量（顺序 `base, bonus, ot, attDed, ss`）：

| 入参 | taxable | tax | net |
| --- | --- | --- | --- |
| `10000,2000,500,300,1500` | `10700` | `360.0` | `10340.0` |
| `99999.99,0.01,0,0,0` | `95000` | `21090.00` | `78910.00`（求和精确舍入到 `100000.00`） |
| `29999,1,0,0,0` | `25000` | `3590.0` | `26410.0` |
| `54999,0,0,0,0` | `50000` | `9839.75` | `45159.25` |
| `17777,0,0,0,0` | `17277` | `1145.4` | `16631.6` |
| `104999,0,0,0,0` | `100000` | `22339.75` | `82659.25` |

> `payGross()`  helper 的求值顺序与被测函数内部**完全一致**（`base+bonus+ot-att-ss` 同序左结合），
> 因此 `g - tax - net` 与被测函数中间量逐位相同，一致性断言可以钉成「恒等于 0」。

### 12.7 JSON 拼接的结构计数常量（低成本钉死契约）

| 函数 | 字段数 | 逗号 | 引号 | 反斜杠（转义用例） |
| --- | --- | --- | --- | --- |
| `payrollRowToJson` | 17 | 16 | 50（34 key + 16 值） | 3 |
| `perfRowToJson` | 15 | 14 | 50（30 key + 20 个 `jsonStr` 值） | 4 |

> **key 计数必须数 `"<dq>:"`**（如 `payDq()+":"` = 17、`perfDq()+":"` = 15），
> 不能数裸 `":"` —— `paidAt` / `updatedAt` 的值自带 `HH:MM:SS` 两个冒号，会把 17 污染成 19。
> `perfRowToJson` 的 `selfScore`/`finalScore` 为 `null` 时是**裸插值**，不引入引号 ⇒ 引号数恒 50。
> MySQL 导出的字面量 `NULL` **不被 `isEmpty()` 判空**，会原样裸插值（`testRowToJsonPassesMysqlNullLiteralThrough`
> / `perfCountOf(out,"NULL")==15`），这是既有行为，测试只负责钉住它、不负责修正它。

### 12.8 `mapPerformanceGrade` 五档 + `rate_limit` 常量契约

| score | grade | ratio | | score | grade | ratio |
| --- | --- | --- | --- | --- | --- | --- |
| `120.0` / `1000.0` | `S` | `1.20` | | `79.99` / `70.0` | `B` | `1.00` |
| `90.0` | `S` | `1.20` | | `69.99` / `60.0` | `C` | `0.80` |
| `89.99` / `80.0` | `A` | `1.10` | | `59.99` / `0.0` / `-5.0` | `D` | `0.50` |

> 系数是源码字面量原样返回 ⇒ 严格相等安全；但**跨档差值不可做算术相等**
> （`0.80 - 0.50 != 0.30`，二进制浮点），只能用大小比较表达。

| 常量 | 值 | 口径 |
| --- | --- | --- |
| `LOGIN_WINDOW_SECONDS` | 900 | 连续失败的统计窗口 |
| `LOGIN_MAX_FAILURES` | 5 | 触封阈值（测试额外约束 `3 ≤ 阈值 ≤ 10`） |
| `LOGIN_BLOCK_SECONDS` | 900 | 封锁时长（测试约束 `≥ LOGIN_WINDOW_SECONDS`，否则「解封即重开」） |
| `LOGIN_MAX_KEYS` | 4096 | 内存表上限，表满时**复用下标 0 槽位** |

### 12.9 后端单测清单

| 文件 | 用例数 | 覆盖对象 |
| --- | --- | --- |
| `common/crypto_util_test.cj` | 22 | sha256 / hmac / deriveKey / verifyPassword / 盐 |
| `common/jwt_util_test.cj` | 26 | 签发-校验往返、篡改、过期、角色与 uid 回读 |
| `common/response_test.cj` | 26 | jsonEscape / jsonStr / parseJsonObject / formatNum2 / truncateUtf8 |
| `common/router_test.cj` | 13 | 路径分段、Query 解码、路由匹配 |
| `controller/payroll_controller_test.cj` | 32 | calculateTax 分档、算薪向量、payrollRowToJson |
| `controller/performance_controller_test.cj` | 30 | mapPerformanceGrade、perfRowToJson（含 golden JSON） |
| `middleware/rate_limit_test.cj` | 39 | 常量契约、纯函数、expiresAt、全表状态机 |
| — **P1.1 小计** | **188** | |
| `controller/employee_import_test.cj` | 35 | parseCsvInto / csvSplitRows / csvStripBom / csvRowIsBlank / csvColIndex / csvCell / strHas / strRuneLen / isAllDigits / isValidYmd / empImportGender / empImportStatus / empImportCols / validateImportRow / importFailJson / importResultJson / empImportHeader |
| **合计** | **223** | |

> P2.1 的 35 个用例同样**从未被 `cjpm test` 执行过**（L-CJ-1），其期望值由 node 独立实现
> 复算固化，见 12.10；风险登记见 L-IMP-1。

> 未覆盖并已诚实记录：`clientIp(ctx)` 仍无**直接单测**（构造 `HttpContext` 的可行性未证实）—— P1.2 已交付的
> `scripts/api-smoke.ps1` 从**行为侧**间接覆盖其后果（登录限流键 `username@ip`：脚本用独立用户名 `no_such_smoke_user`
> 只发 1 次错误口令，避免污染真实账号），但「XFF 解析是否正确」这条仍未断言，见 L-SMOKE-1；
> 各 controller 的 handler 依赖 `queryRows`（需真库）；`expiresAt` 相关的「窗口/封锁到期」分支
> 因**无法注入时钟**而不测，只测同一秒内必然成立的状态迁移。

### 12.10 CSV 解析 ground truth（P2.1，node 独立实现复算）

> 期望值不是手推的：用一份 node 复算脚本按 `parseCsvInto` / `csvSplitRows` / `csvStripBom`
> 的**同一套状态机语义**在 node 里重写一遍，18 组输入一次性输出 `rows / counts / lines`。
> 脚本本身是临时物（位于系统 Temp，不入库），本表是其结论的固化，防止后续改动悄悄漂移语义。
> `\r\n` = CRLF，`\n` = LF，`\r` = CR；BOM = `EF BB BF`。

| # | 输入 | rows | counts | lines | 首行起各行内容 |
| --- | --- | --- | --- | --- | --- |
| 1 | `工号,姓名\r\nA1,张三\r\nA2,李四\r\n` | 3 | 2,2,2 | 1,2,3 | `[工号,姓名]` `[A1,张三]` `[A2,李四]` |
| 2 | `h1,h2\r\na,b\r\nc,d\r\n` | 3 | 2,2,2 | 1,2,3 | `[h1,h2]` `[a,b]` `[c,d]` |
| 3 | `h1,h2\r\na,b`（无尾换行） | 2 | 2,2 | 1,2 | `[h1,h2]` `[a,b]` |
| 4 | `h\na\nb\n`（纯 LF） | 3 | 1,1,1 | 1,2,3 | `[h]` `[a]` `[b]` |
| 5 | `h\ra\rb\r`（纯 CR） | 3 | 1,1,1 | 1,2,3 | `[h]` `[a]` `[b]` |
| 6 | `h1,h2\r\n"技术,研发部",x\r\n` | 2 | 2,2 | 1,2 | `[h1,h2]` `[技术,研发部, x]` |
| 7 | `a,"b,c",d\r\n` | 1 | 3 | 1 | `[a, b,c, d]` |
| 8 | `h\r\n"He said ""hi"""\r\n` | 2 | 1,1 | 1,2 | `[h]` `[He said "hi"]`（12 字符） |
| 9 | `h1,h2\r\n"line1\nline2",tail\r\nend,x\r\n` | 3 | 2,2,2 | **1,2,4** | `[h1,h2]` `[line1\nline2, tail]` `[end,x]` |
| 10 | `h1,h2\r\n"a\nb",c\r\nd,e\r\n` | 3 | 2,2,2 | **1,2,4** | `[h1,h2]` `[a\nb, c]` `[d,e]` |
| 11 | `BOM + 工号,姓名\r\nA1,B\r\n` | 2 | 2,2 | 1,2 | `[工号,姓名]` `[A1,B]`（BOM 已剥，表头可匹配） |
| 12 | ``（空串） | 0 | — | — | 无记录 |
| 13 | `\r\n`（仅一个换行） | **1** | 1 | 1 | `[""]` ← 空行本身就是一条记录 |
| 14 | `only` / `only\r\n` | 1 | 1 | 1 | `[only]`（尾换行不额外产行） |
| 15 | `a,b,\r\n` | 1 | 3 | 1 | `[a, b, ""]`（尾逗号产空字段） |
| 16 | `,,\r\n` | 1 | 3 | 1 | `["", "", ""]` |
| 17 | `a\r\n\r\nb\r\n` | **3** | 1,1,1 | 1,**2**,3 | `[a]` `[""]` `[b]` ← 中间空行占一条 |

单元值（同口径）：

| 表达式 | 结果 | 说明 |
| --- | --- | --- |
| `strRuneLen("He said \"hi\"")` | 12 | 2+1+4+1+1+2+1 |
| `csvStripBom("abc")` | `"abc"`，3 字节 | 无 BOM 原样返回 |
| `csvStripBom(BOM + "abc")` | `"abc"`，3 字节 | BOM 剥离 |
| `csvStripBom("a" + BOM)` | 4 字节 | **BOM 不在开头就不是 BOM**，原样保留 |
| `impBom()` | 3 字节 / 1 字符 | 断言一律用 `toArray().size`，不用 `String.size` |
| 全角 `１` | 3 字节 / 1 字符 | `isAllDigits` 必须为 `false` |
| `"张三"` | 6 字节 / 2 字符 | 长度校验走 rune 口径，否则上限缩水到 1/3 |

> 第 13/17 组是本轮**唯一由复算推翻手写期望**的地方：最初按「空行不产记录」写断言，
> 复算证明解析器为 1 条 / 3 条。结论是语义留在解析器（忠实还原 CSV），
> 策略放到调用方（`doEmployeeImport` 用 `csvRowIsBlank` 剔空行），见 L-IMP-4。

---

## 十三、远端仓库现状与推送方案（2026-11-23 实测，非推测）

> 本节记录**只能从远端获得**的事实。`git remote add` 与 `git fetch` 已实际执行，凭据可用
> （credential.helper=manager，`git ls-remote` 无需交互即成功），但**尚未 push 过任何内容**。

### 13.1 远端拓扑

| 项 | 值 |
| --- | --- |
| remote | `origin = https://github.com/whwwwc1-hue/-.git`（仓库名就是一个连字符 `-`） |
| 远端分支 | `main` / `zc` / `zys`（`zc` 即本用户，`zys` 疑为另一协作者） |
| `origin/main` 历史 | `1bdde7e` Initial commit → `62ac357` "feat: complete Cangjie 1.0.5 + Vue 3 full-stack HRMS project" → `c76f07f` Merge pull request **#1** from `waveingsheep/main` |
| 本地 `main` 历史 | `6e79923` baseline snapshot → `62921a7` P0 hardening → `a6567ca` P1（30 files / 6978 insertions） |
| **共同祖先** | **无**（`git merge-base main origin/main` 返回空、exit 1；两侧 root commit 不同：本地 `6e79923`，远端 `1bdde7e`） |
| 树差异 | `git diff --stat origin/main main` = **41 files changed, +13067 / −104**，其中 A=22（本轮新增）/ M=18 / **D=1** |

**结论**：历史不相连纯粹是因为接手时在工作副本里 `git init` 重新起了仓库；**内容上本地树 = 远端树 + 我的工作**。
唯一「远端有、本地没有」的文件是 `backend-cangjie/.env`。

### 13.2 ⚠️ 远端 `main` 把 `.env` 提交进了版本库

`D backend-cangjie/.env` 表示 `origin/main` **跟踪**着 `backend-cangjie/.env`，而我本地已把它列入 `.gitignore` 且不再跟踪。
含义与对策：

- 这是**既有的凭据泄漏**，不是我造成的，但我的下一次推送若走「整树覆盖」，会**顺带删掉协作者依赖的这个文件**。
- 因此**禁止**用 `git push -f origin main`：那会抹掉 `1bdde7e/62ac357/c76f07f` 三个远端提交与 PR #1 的历史，且属于 force push 主干。
- 正确做法（尚未执行，需用户确认）：`git merge --allow-unrelated-histories -s ours origin/main`
  —— 用 `-s ours` 策略**只接parent 不改树**（结果树与当前本地树逐字节一致），使 `origin/main` 成为祖先；
  之后 push `main` 就是 **fast-forward，不需要 force**。副作用是在合并提交里删除 `backend-cangjie/.env`
  —— 这个副作用**必须事先告诉用户**（可能影响 `zys` 的本地环境），我不擅自做。
- 无论最终怎么推，都应在仓库里另行处理：从历史中清除 `.env`（`git filter-repo`）+ 轮换其中凭据。此事项超出本次开发范围，记录备查。

### 13.3 推送决策清单（留待用户选择，我不擅自改共享主干）

| 方案 | 操作 | 风险 | 备注 |
| --- | --- | --- | --- |
| A 推分支 + PR | 把 `main` 推到新分支（如 `trae/p1`），在 GitHub 开 PR 指向 `main` | 低 | 不动主干；PR 的 diff 即 41 文件那份；`on: push` 不会在非主干触发，需靠 `pull_request` 触发 CI |
| B `-s ours` 合并后推主干 | 见 13.2 | 中（删 `.env`；主干对协作者前移） | 唯一能「非 force 推 main」的路径 |
| C 只推 `zc` 分支 | 覆盖远端 `zc`（其 tip=`1bdde7e`，是本地历史里**没有**的提交，需先确认那是用户自己的旧分支） | 中 | 会丢掉远端 `zc` 独有的对象，需 `--force` ⇒ 未经用户同意不做 |

**已排除项**：任何 `push --force` 到 `main`。

### 13.4 L-CI-1 仍未闭合

`ci.yml` 只在本机以「CI 等价条件」验证过（`E2E_CHANNEL=chromium` + `CI=true` ⇒ 42 passed）。
GitHub Actions 的**真实首跑结果尚无人看过** —— 必须先完成 13.3 中任一推送，再回来看 Actions，
失败就回来修 workflow。该义务在推送完成前不得勾销。

### 13.5 工作量对照（用户要求的「至少匹配现有工作量」）

| 来源 | 规模 |
| --- | --- |
| 基线 `6e79923`（接手快照） | 111 files / **27803** insertions |
| 我：`62921a7` P0 加固 | 8 files（`crypto_util`/`jwt_util`/`response`/`router`/`rate_limit`/`main`/`dbconfig`/`start-backend`） |
| 我：`a6567ca` P1 全量 | **30 files / 6978 insertions**（22 新增） |
| 累计（`git diff --shortstat 6e79923 HEAD`） | 38 files / **8082** insertions |

⚠️ 诚实口径：按行数我目前约为基线的 **29%**，**尚未达标**。P2~P5（4 个功能 + 2 项审批增强 + 2 个新模块 + 5 份交付文档）
是补齐量的主要来源，其中前端 mock/spec 与后端新 controller 单测的行数「含金量」高于文档，但**行数本身不是目标**，
可验证的功能与测试才是。
