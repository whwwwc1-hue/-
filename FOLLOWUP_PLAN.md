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
      > **数字已过时（截至 P1.1 收口）**：P2.1 / P2.4 / P3.1 又各加 1 个测试文件，现为 **10 文件 / 275 `@TestCase` / 1610 `@Assert`**，
      > 逐文件实测表见 **12.14**。下文「188」保留是为了忠实记录当时的收口状态。
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
      拦截层是**有状态内存 mock**（`route()` 分发表 **32 条**，P1.3 收口时 25 条，P2.2 补 `/employees` + `/employees/import` 两条，P2.4 补 `/attendance/monthly-summary` 一条，P3.2 补 `/notifications` 系列 4 条；逐字段回 `backend-cangjie/src` 源码取契约），fixture teardown 断言 `unmatched == []` —— 前端发起但 mock 未实现的请求会直接让用例失败，这是防「测试通过但契约已漂移」的闸门。
      ⚠️ **订正**：本节原写「29 个接口」是**未经测量的口算数**。实测口径应为 `mock-server.ts` 里 `if (method ===` 的分发条目数（`Measure-Object` = 28，P1.3 时为 25），且 `src/api/hrms.ts` 的 `*Api` 导出是 47 个，两个数都不等于 29。此后凡写入本文档的计数必须附测量命令，见第十一节 11.2。
      金额一致性实证：emp01 生成后「我的工资条」实发 `￥15796.54`，调项后 `￥16620.26`，与核算中心列表逐分对齐（非硬编码，由 mock 按 `calculateTax` 同口径现算）。
      过程中修掉一个**真实前端缺陷**（L-FE-5 冷启动画像过期）并消除一个**既存假绿**（payroll 精确数组断言），详见第九、十节。
- [x] **P1.4 GitHub Actions**：`.github/workflows/ci.yml`，前端 `npm ci && npm run typecheck && npm run build`；后端在 SDK 可用时 `cjpm build && cjpm test`（可先只跑前端 job，避免假绿）。
      ✅ **已完成**：[.github/workflows/ci.yml](./.github/workflows/ci.yml)（已用 js-yaml 解析校验，3 个 job）。
      `frontend`：`npm ci` → `typecheck` → `eslint --max-warnings 0` → `build` → 上传 `dist`。
      `e2e`：`npm ci` → `playwright install --with-deps chromium` → `npx playwright test`，失败时上传 `playwright-report`/`test-results`。
      `backend`：**默认 skipped**，`if: vars.BACKEND_CI_ENABLED == 'true'`。刻意不写未经核实的 SDK 下载地址、也不用 `continue-on-error` —— 两者都会把「后端无 CI」伪装成绿。文件内已逐条写明排除理由与启用前置条件。
      ⚠️ 关键实证：CI 用 `E2E_CHANNEL=chromium` 而非本地默认的 `msedge`。这条**已在本机按 CI 等价条件跑过**（`CI=true` ⇒ `workers=2` + `reuseExistingServer:false` 自建 vite dev + Playwright 自带 chromium）：**42 passed (38.8s)**。

**验收**：前端 CI 绿；单测覆盖全部金额与权限相关纯函数；越权与算薪金额有自动化断言。
      ⚠️ 诚实修正原验收口径：「CI 绿」目前**只覆盖前端**（typecheck/lint/build/**77 个 E2E**；演进：P1.3 42 → P2.2 51 → P2.3 57 → P2.4 65 → P3.1 68 → P3.2 77）。后端 242 个 `@TestCase` 与 `api-smoke.ps1` 的 112 个断言点**仍无执行环境**（L-CJ-1），对应 job 呈 skipped 而非 passed。

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
- [x] **P2.2 CSV 模板下载 + 前端解析**：[EmployeeView.vue](./frontend-web/src/views/employee/EmployeeView.vue) 增加「批量导入」对话框，浏览器端解析（含 GBK/UTF-8 BOM 处理），预览前 20 行与错误行高亮。
      ⚠️ 本条原文「浏览器端解析」已被 P2.1 的决策取代：**权威解析在后端**，前端解析**只服务预览与行号**，判定权不外放（见上方 P2.1 契约第 1 条与 L-IMP-5）。
      ✅ **已完成并经真实浏览器验证**：9 个 E2E 用例（`employee-import.spec.ts`），全量 **51 passed**；`typecheck`/`eslint --max-warnings 0`/`build` 三连 exit 0；并按 CI 等价条件（`CI=true` + `E2E_CHANNEL=chromium` + 自建 dev server）复跑得 **51 passed (47.9s)**。落地要点见下方「P2.2 契约与取证」，新增风险见 L-IMP-5 ~ L-IMP-7。

**P2.2 契约与取证（已落地，后续若改解析器必须同时改这三处）**
- **改动面**：`src/api/hrms.ts`（+`EmployeeImportFailure`/`EmployeeImportResult` 类型与 `importEmployeesApi`，
  单独 `timeout: 60000`，理由见 L-IMP-7）；`EmployeeView.vue`（**+325 行**，新增按钮/对话框/解析器/模板下载）；
  `e2e/support/mock-server.ts`（**+311 行**：`GET /employees`、`POST /employees/import`、`Employee` 接口补 7 个可选字段以对齐
  `employeeRowToJson` 的 20 出参）；新增 `e2e/employee-import.spec.ts`（222 行 / 9 用例）。
  实测 `git diff --stat` = 3 files changed, **661 insertions(+)**，加上新增 spec 共 **883 行**（含空行与注释）。
- **解析器三份同源**：后端 `parseCsvInto`（权威）/ 前端 `EmployeeView.vue` 的 `parseCsv` / mock 的 `parseCsv`，
  三者必须产出同样的 `rows` 与**物理行号** `lines`。12.10 的 17 组输入是这三份的共同断言源。
  行号语义（易错点）：引号内的换行**只推进物理行号、不拆记录**，所以「逻辑第 3 条记录」可以报在物理第 4 行 ——
  这正是 `employee-import.spec.ts` 里 `CSV_QUOTES` 那条用例存在的唯一目的。
- **编码策略**：先 `TextDecoder('utf-8', {fatal:true})`，抛错才回落 `TextDecoder('gbk')`，并把实际采用的编码显示给用户。
  BOM 由前端剥除（`text.replace(/^\uFEFF/, '')`），后端 `csvStripBom` 也剥 —— **两侧都容错**，因为用户可能粘贴文本进对话框而不走文件。
- **刻意没有的三处「贴心」**（都是踩过的坑，不是遗漏）：
  ① 表头不完整时**只告警不禁用提交**，因为后端 `empImportCols` 允许部分列匹配并会逐行报「不能为空」，
     前端若提前拦住就等于替后端改了语义（第一版确实这么写过，已回退）；
  ② 预览只展示前 20 行（`IMPORT_PREVIEW_LIMIT`），不参与任何校验判断；
  ③ mock 不模拟 `sys_user` 开通与审计写入，见 L-IMP-6。
- **模板下载**：`'\uFEFF' + 表头 + CRLF + 示例行 + CRLF`，MIME `text/csv;charset=utf-8`。
  **BOM 是给 Excel 的**（无 BOM 时 Excel 按本地代码页打开会乱码），而解析侧两侧都会剥掉它，用例
  「带 BOM 的文件不误报表头问题」专门钉住这一点。
- [x] **P2.3 电子工资条打印/PDF**：[PayrollView.vue](./frontend-web/src/views/payroll/PayrollView.vue) 弹窗加 `@media print` 专版样式 + 「打印/导出 PDF」，字段含应发各项、五险一金、个税、实发。
      ✅ **已完成并经真实浏览器验证**：新增 `e2e/payroll-print.spec.ts`（251 行 / **6 用例**），全量 **57 passed (1.5m)**；
      `typecheck`/`eslint --max-warnings 0`/`build` 三连 exit 0。验收项「打印预览无侧边栏」不再靠人眼：
      用例在 `emulateMedia({media:'print'})` 下断言 `aside`/`#app`/`#pane-admin`/弹窗全部 hidden、专版 visible，
      并把纸媒渲染导出为 PNG + PDF 附进报告；PDF 实测 `MediaBox [0 0 594.96 841.92]`（= A4）且 `/Count 1`（单页）。
      落地要点见下方「P2.3 契约与取证」，新增风险见 L-PRT-1 ~ L-PRT-3。

**P2.3 契约与取证（已落地；这一版是「同一份 DOM 的第二套媒体查询」，不是新页面也不是 PDF 库产物）**
- **改动面**（实测 `git diff --numstat`，命令见 12.12）：`PayrollView.vue` **+196 / −2**（350 → 544 行）、
  `src/style.css` **+156**（24 → 180 行）、新增 `e2e/payroll-print.spec.ts` 251 行。合计 **603 行**。
  后端**零改动**：不存在 `GET /api/v1/payrolls/:id` 明细接口（`main.cj` 只有 6 条薪资路由），
  专版数据源就是列表行 `payrollRowToJson` 的 17 字段，因此打印件与页面不可能出现两套数字。
- **开关是 `<html>` 上的模式类**，不是 `:has()`：`watch(slipVisible)` 挂/摘 `hrms-payslip-print-mode`，
  `@media print` 规则以「模式类 + print」为双重条件。用 `:has(.hrms-print-root)` 的话，老浏览器整条规则静默失效，
  退化成「打印整页 SPA」——这是最坏的错误形态（用户拿到一张带侧边栏的工资条而无人报错）。
  模式类还带来可断言性：E2E 直接 `toHaveCount(1/0)`，无需猜渲染。
- **`onBeforeUnmount` 兜底是必需的**：路由切走时 `el-dialog` 随组件卸载，`slipVisible` 不会从 true 变 false，
  `watch` 不触发，模式类会残留到下一个页面 —— 下一个页面按 Ctrl+P 就会打出半张工资条。
  用例「路由切换时组件卸载」用 `dispatchEvent('click')` 走**真实 SPA 导航**（弹窗遮罩会拦截普通 click），
  从而证明这条兜底路径而不是靠整页刷新蒙混过去。
- **PDF 走浏览器 print-to-PDF，不引入 jsPDF/html2canvas**：canvas 截图式 PDF 的金额是位图，
  不可选中、不可检索、放大即糊，对工资条这种凭据类文档是倒退。`page.pdf()` 与用户点「另存为 PDF」是同一条流水线。
- **客户端独立复算**（第十一节规则③）：`slipCheck` 用 `round2` 先分别合计应发/代扣再相减，与后端
  `round2(base+bonus+overtime-deduction-social-tax)` 是两条不同取整路径；各项均为两位小数时恒等，
  一旦后端改舍入口径就会显式报「复算校验不一致」并给出差额，而不是安静地打出一张看起来正常的单。
- **刻意保留的两处不贴心**：① 关闭弹窗时**不清空 `activeSlip`**（清空会让正文在淡出动画里先消失），
  专版靠模式类摘除而失效，用例对此有断言；② 草稿态同样可出条，纸质件「发放状态」如实标注
  「草稿（尚未发放）」、发放时间留 `—`，而不是禁用按钮 —— HR 代员工先出条是真实需求，状态由纸质件自证。
- **HR 侧新增入口**：核算中心操作列补「电子凭条」（列宽 150 → 205）。此前只有「我的工资条」页签能看明细，
  HR 只能改数据、无法先出条，属 P2.3 顺带补齐的覆盖空洞。
- [x] **P2.4 考勤月度汇总导出**：`GET /api/v1/attendance/monthly-summary?month=&deptId=` 返回出勤率、迟到/早退/请假工时统计，前端一键导出 CSV。
      ✅ **已完成并经真实浏览器验证**：新增 `e2e/attendance-summary.spec.ts`（220 行 / **7 用例**），另为 P2.4 暴露的「导出只捞当前页」补了 `payroll.spec.ts` 1 例，全量 **65 passed / 0 failed**；
      `typecheck`/`eslint --max-warnings 0`/`build` 三连 exit 0。落地要点见下方「P2.4 契约与取证」，新增风险见 L-ATT-1 ~ L-ATT-2。

**P2.4 契约与取证（已落地；「页面数字 = 导出数字」是靠结构保证的，不是靠比对两次截图）**
- **改动面**（实测 `git show --numstat 8195ff2`，命令见 12.13）：后端 `attendance_controller.cj` **+248/−4**、新增
  `attendance_controller_test.cj` **539 行 / 19 个 `@TestCase`**、`main.cj` +3；前端 `AttendanceView.vue` **+202/−1**、
  `hrms.ts` +36、`mock-server.ts` +132/−8、`attendance-summary.spec.ts` 220、`payroll.spec.ts` +33、`PayrollView.vue` +28/−4。
- **主表是 `hr_employee` 而不是 `hr_attendance`**：以考勤表为主表时，整月一次卡都没打的人**整行消失**，
  分母跟着变小，出勤率反而**虚高**——这正是这类报表最常见的错法。改成员工左连考勤后，`LEFT JOIN` 产生的
  `NULL` 行会落进 `CASE` 的 `ELSE` 分支凭空 +1 天，故每个 `CASE` 都加了 `a.id IS NOT NULL` 守卫。
- **口径**：`ABSENT` 与「有记录但没出勤」都不计出勤天数；迟到 = `late_minutes > 0` **或**状态 `LATE`，早退 = `early_minutes > 0`
  **或**状态 `EARLY_LEAVE`（历史数据里两类标记都有人写，只认一种会漏计）；请假/加班只认 `status='APPROVED'`，
  申请中的单子不进报表；`WHERE e.status <> 'RESIGNED'`（离职者不进当月汇总）。
- **应出勤天数是常量 `attShouldAttendDays = 22`**（无排班表 / 无工作日历），见 L-ATT-1；出勤率 `round2` 后**封顶 100**，
  `shouldDays <= 0` 返回 0 而不是抛除零。
- **JSON 合法性靠 `attMonthSafeNum` 逐字节白名单兜**：刻意**不用** `Float64.tryParse`——它接受 `1e5`/`NaN`/`Infinity`，
  这些值直接插进 JSON 模板会拼出**语法非法**的响应体，前端 `JSON.parse` 整页白屏，且后端仍然 200。
- **合计行由明细累加**（`attMonthlyTotalsJson`），不是第二条 SQL：两条 SQL 就是两个快照，
  「卡片 5 人、表格 6 行」这种自相矛盾只能靠单一数据源消除。`/my` 的 `actualAttendDays` 本轮也同步改成
  排除 `ABSENT` 的计数，与月度汇总同口径。
- **权限 `requireRoles(ctx, ["ADMIN","HR","MANAGER"])`**，MANAGER 的 `deptId` 由服务端 `getUserDeptId(u)` 强制覆盖，
  前端即使伪造查询参数也只能看到本部门；`month` 非法则回落到 `SELECT DATE_FORMAT(CURDATE(),'%Y-%m')` 而不是报 400。
- **CSV 与页面共用同一份 `sumList`/`sumTotals`**，且新增 `refreshSummaryIfNeeded()` 挂在签到 / 签退 / 补卡修正三处写操作之后
  （否则导出用的是改动前的旧快照）；`PayrollView.exportCsv` 顺带从「导出屏幕上这一页」改成按 `pageSize=100` 翻页捞全量
  （后端 `payroll_controller.cj:124` 对 `pageSize > 100` 会**静默回落成 20**，不翻页就会少导出人）。
- **mock 第 28 条分发 `onMonthlySummary` 逐字段镜像后端**（含 MANAGER 限部门、`deptId` 过滤、`ORDER BY deptName, empNo`），
  前端一旦调用未登记的路径就会被 `unmatched == []` 闸门直接判红。

**验收**（逐项标注兑付状态，不整体打勾）：
- 「打印预览无侧边栏」✅ **已兑付并有产物可复核**：`payroll-print.spec.ts` 在 print 媒体下断言 `aside`/`#app` hidden，
  同时导出 `test-results/payslip-print.png` 与 `.pdf`（A4 单页），人眼与断言两条路都能查。
- 「100 行 CSV 导入含错误行时可部分成功并给出定位」⚠️ **口径已被 P2.1 决策改掉**：整批要么全写要么全不写，
  定位靠 `line` 物理行号。故这一条不再按原文验收，改按 P2.1 的「行级错误逐条回显 + 整批不写」兑付（见 `employee-import.spec.ts`）。
- 「导出报表与页面数字一致」✅ **已兑付并有逐格断言可复核**：[attendance-summary.spec.ts](./frontend-web/e2e/attendance-summary.spec.ts)
  「导出 CSV 的每一格都等于页面上的同一格」把 CSV 的 12 列**逐列映射**回 `#pane-summary` 表格的可见单元格比对
  （11 列同值，第 5 列「应出勤天数」单独断言恒为 22），并校验文件名 `考勤月度汇总_2026-11.csv`、UTF-8 BOM、
  `CRLF` 分行、合计行「`N 人`」与 `N × 22` 的应出勤总天数。数据源同源（同一个 `sumList`）+ 逐格比对，
  任何一侧偷偷做二次计算都会在这里变红。

---

## 五、任务包 P3：业务流深化（对应指南工作包 C）

- [x] **P3.1 长假二级审批**：`hr_leave_overtime.status` 扩展为 `PENDING_MGR → PENDING_HR → APPROVED/REJECTED`；`duration > 3` 天走双级；`MANAGER` 仅能推进一级，`HR` 推进二级；年假仅在**终态通过**时扣减余额（避免重复扣减）；增加审批链历史字段与展示。
      ✅ **已完成，前端经真实浏览器验证；后端 `.cj` 仍未经编译（L-CJ-1）**：`sql/init.sql` 新增表 12 `hr_approval_log`
      并在真实 `hrms_db` 实跑生效；后端状态机 15 个纯函数 + 33 个 `@TestCase`（`request_controller_test.cj`）；
      前端 `ApprovalView.vue` 双级改造；`e2e/approval.spec.ts` 由 7 例扩到 **10 例**，全量 **68 passed / 0 failed**，
      `typecheck`/`eslint --max-warnings 0`/`build` 三连 exit 0。落地要点见下方「P3.1 契约与取证」，新增风险见 L-APR-1 ~ L-APR-3。

**P3.1 契约与取证（已落地；「两级签完才扣年假」是靠状态机单一入口保证的，不是靠调用方自觉）**
- **状态机全部收敛成纯函数**（`request_controller.cj:11-193`，一律显式 `public`）：`reqInitialStatus` /
  `reqCurrentLevel` / `reqNextStatus` / `reqCanActStep` / `reqActionDeniedMessage` / `reqShouldDeductAnnual` /
  `reqIsPendingLike` / `reqStatusCondition` / `reqPendingCountCondition` / `reqTrailSql` / `reqTrailJsonFor` /
  `reqIdListFromRows` / `reqIsNumericId` / `loadApprovalTrail` / `requestRowToJson`。
  审批接口不再有任何 `if status == "..."` 的字面量分支散落在 HTTP 处理里。
- **审批链用独立表而不是加列**：新增 `hr_approval_log`（`UNIQUE KEY uk_al_request_step (request_id, step)`）。
  给 `hr_leave_overtime` 加 6 列只能记「最后一级」，历史会在二级覆盖一级；独立表天然支持 N 级，
  且 `UNIQUE(request_id, step)` 是并发重复审批的最后一道防线——所以 `executeSql` 返回 `false` 时**必须报 500**，
  不能像 P0 之前那样把「唯一键冲突」当成功吞掉。
- **双级判定只看 `category == "LEAVE" && duration > 3.0`**：加班单的 `duration` 单位是**小时**，
  与请假共用阈值会把「加班 4 小时」误判成长假。阈值 `reqLongLeaveDays = 3.0` 是**严格大于**，
  正好 3 天仍是老的 `PENDING` 单级，既有数据与既有 E2E 断言不受影响。
- **年假只在 `reqNextStatus` 算出的 `nextStatus == "APPROVED"` 时扣一次**，扣减与推进在**同一个 `executeSql` 事务**内
  （`UPDATE hr_employee` + `UPDATE hr_leave_overtime` + `INSERT INTO hr_approval_log` + `START TRANSACTION/COMMIT`）。
  「一级通过不扣、二级通过才扣」不是靠判断第几级，而是靠 `PENDING_MGR` 的下一级是 `PENDING_HR` 而非终态——
  重复调用只会撞 `!reqIsPendingLike` 的 400，结构上不可能扣第二次。
- **每次调用只推一级**（`ADMIN` 也不允许跳级）：`reqNextStatus("PENDING_MGR","APPROVED") = "PENDING_HR"`，
  所以主管签完只是把单子交给 HR，链不可跳过。
- **兼容读法**：`reqStatusCondition("PENDING")` 展开成 `lo.status IN ('PENDING','PENDING_MGR','PENDING_HR')`，
  老的「待办」查询与 `dashboard_controller.cj:23` 的待办计数（同一口径，见 `reqPendingCountCondition`）
  不会因为多出两个状态值而漏单。其余模块（`attendance_controller.cj:154/155`、`payroll_controller.cj:81/87`、
  `performance_controller.cj:83`）只认 `APPROVED` 终态，语义本来就对，**刻意不改**。
- **出参新增三键**（`currentLevel` / `myAction` / `approvalTrail`）都是「按当前查看者现算」，不是库里的列：
  `myAction` 让前端**不需要重复实现一遍 RBAC**，后端说能审才渲染按钮；`/requests/my` 恒为空串（本人不能审自己）。
  审批链用 `IN (...)` **一次批量取回**（`reqTrailSql`），避免每行起一个 `mysql.exe` 子进程——本仓每条 SQL 一个进程，
  N+1 的代价在这里是线性的、看得见的。
- **mock 第 28 条分发不变、但 `onApproveRequest` 整体重写为后端镜像**（`mock-server.ts`）：同一套
  `reqInitialStatus/reqCurrentLevel/reqNextStatus/reqCanActStep/reqShouldDeductAnnual` 用 TS 再写一遍，
  并新增 `approvalLogs` 数组 + `approvalSteps()` / `approvalChain()` 断言口；`onCancelRequest` 放宽到 pending-like，
  工作台 `status=PENDING` 过滤同步展开三档。

**P3.1 取证（E2E 三层同时断言，命令与结果见 12.14）**
- 「4 天年假必须两级签完才扣年假」✅：`长假二级审批（P3.1）` 第 1 例——建单即 `PENDING_MGR` 且 `approvalSteps == 0`、
  余额 **5 不动**；主管一级通过后 `PENDING_HR`、余额仍 **5**；HR 二级通过才 `APPROVED`、余额 **5 → 1**（一次扣 4 天）；
  `approvalChain` 整链 pin 为 `[[1,'manager','PENDING_HR'],[2,'hr','APPROVED']]`，表格回显
  `1. manager（部门主管）通过` / `2. hr（人力资源）通过`。
- 「HR 不能代签一级 / 链不可跳过」✅：同例断言 HR 侧 `通过` 按钮 `toHaveCount(0)` 且显示「待部门主管处理」；
  第 2 例用 `apiPost()` **绕过界面直连接口**（UI 已藏掉按钮，服务端 403 只能这样测），钉死四条契约——
  一级期间 HR `403 长假一级审批请由部门主管或系统管理员处理`、二级期间主管 `403 长假已进入二级审批…`、
  终态重复审批 `400 该申请单已处理，无法重复审批`，且三种越权之后 `approvalSteps` 与余额**一律不变**。
- 「阈值是严格大于」✅：第 3 例同一账号连建 4 天与 3 天两张单，分别是 `PENDING_MGR` 与 `PENDING`，
  3 天单主管一步签完（`approvalSteps == 1`、余额 5 → 2），证明老单级路径没有被双级改造破坏。
- 「撤回覆盖长假」✅：第 3 例 `PENDING_MGR` 状态下撤回按钮仍在（`isPendingLike` 与后端同口径），
  确认后落 `CANCELLED` 且余额不动。
- 「向后兼容」✅：既有 7 例（1 天单级闭环 / 撤回 / 驳回 / 余额边界 / 权限门）**全部原样通过**，
  其中「恰好扣满」那例因 5 天 > 3 天**必须**改走两级，已按新语义补上 HR 二级步骤而不是放宽断言。

- [x] **P3.2 站内通知中心**：新增 `sys_notification` 表（`user_id, type, title, content, ref_id, read_flag, created_at`），在「合同 30 天内到期 / 审批结果 / 工资条发放」三处触发写入；`GET /api/v1/notifications`、`PUT /api/v1/notifications/:id/read`、`POST /api/v1/notifications/read-all`；[AppLayout.vue](./frontend-web/src/layout/AppLayout.vue) 顶栏铃铛红点 + 抽屉列表 + 30s 轮询。
  > **已完整交付**（后端 `b4427b1` + 本轮前端/测试）：建表 + 表 13 已在真实库执行、`notification_controller.cj`（**470 行 / 39 个顶层函数，全部 `public`**）、
  > `main.cj` 4 条路由、三处触发接线 ✅；`notification_controller_test.cj` **727 行 / 64 `@TestCase` / 164 `@Assert`** ✅；
  > `hrms.ts` 4 个接口 + `NotificationItem/NotificationListResult`、`AppLayout.vue` 铃铛 `el-badge` + 抽屉 + 30s 轮询 + 按 `type` 跳转 ✅；
  > `mock-server.ts` 4 条分发（28 → **32**）+ 3 个触发点镜像 ✅；`e2e/notification.spec.ts` **351 行 / 9 用例** ✅。
  > 为了让「点通知跳工资条 / 跳审批工作台」成立，顺带给了 `PayrollView.vue` 与 `ApprovalView.vue` 认 `route.query.tab` 的能力（后者还要求 `canApprove` 才认 `approve`，否则员工会落到不存在的页签）。
  >
  > 触发点接线比原始描述多做了一处：长假转 `PENDING_HR` 时给在职 HR 发「待你复核」，
  > 否则二级审批只能靠 HR 自己刷工作台才发现有单。测量值与踩坑见 12.15。

**验收**（逐项标注兑付状态）：
- 「4 天长假必须两级签完才扣年假」✅ **已兑付**（P3.1，见上方取证）。
- 「发薪后员工铃铛出现未读消息且点击跳转工资条」✅ **前端链路已兑付**（`e2e/notification.spec.ts` 前 3 条：批量发薪 →
  红点 `1` → 点通知跳 `/payroll?tab=my` 并看到 `￥15796.54`；重复点发放不翻倍——这条直接钉住 `uk_user_type_ref` 语义）。
  ⚠️ 真实库侧仍受 **L-NOTIF-3** 限制（`sys_user` 为空表 ⇒ 命中路径没在真库跑过），故整块 P3.2 标 🟡 而非 ✅。

---

## 六、任务包 P4：新业务模块（对应指南工作包 D，按第六节 SOP 落地）

- [x] **P4.1 培训与学分**：`hr_training` + `hr_training_record`；HR 发布计划、员工报名、签到、学分汇总；`/api/v1/trainings` 全套路由注册 + `TrainingView.vue` + 菜单项。
      **七步闭环已全部落地**：建表 2 张 → `training_controller.cj`(1478，46 纯函数 + 11 handler) → `main.cj` 11 条路由 →
      仓颉单测 36 类 / 93 TC / 255 AS → 真库 13 组 SQL 实测 →（后端切片见 12.16，提交 `e251a9d`）→
      `api/hrms.ts` 6 interface + 11 Api → `TrainingView.vue` 4 tab 844 行 → `router` 四角色 `meta.roles` →
      `AppLayout` 菜单 + `TRAINING_PUBLISHED` 跳转 → `mock-server` 分发 32→43 + 状态机 → `e2e/training.spec.ts` 13 用例 →
      `rbac-menu` 四角色 `MENUS`（前端/E2E 切片见 12.17，三连全绿、**90 passed**）。
      ⚠️ 一处**后端待办**已记 12.17 ④：`PUT /trainings/:id` 不支持局部更新，只改 `status` 会被整表单校验打成 400。
- [ ] **P4.2 差旅与报销**：`hr_expense`（`DRAFT → SUBMITTED → APPROVED → PAID`），复用审批视图风格；审批通过与月度发薪联动（报销金额进入薪资明细，注意与 P0.1 的事务边界）。
      **进度（2026-11-28）**：后端已交付 —— 表 16 `hr_expense`(23 列) + `expense_controller.cj`(1897) + 13 条路由 + 4 个通知类型，真库 29 组实测通过，见 **12.18**。
      ⚠️ **一处刻意偏离**：报销额**不并入薪资明细**，改走独立发放通道；理由与源码证据见 12.18 ③（`bonus` 会被 `calculateTax` 计税，实报实销不该计税）。
      **未做**：`expense_controller_test.cj` 单测、报销 API、`ExpenseView.vue`、`meta.roles`、菜单项与 `notifRoutes`、`mock-server` 分发、`e2e/expense.spec.ts`、`rbac-menu` 四角色 `MENUS`。

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
| 2026-11-23 | **P2.2** | 前端导入链路落地：`hrms.ts` 补 `EmployeeImportResult`/`EmployeeImportFailure`/`importEmployeesApi`（**单独 `timeout: 60000`**，后端整批一条 SQL 交 `mysql.exe`，500 行远超全局 15s）；`EmployeeView.vue` 加「批量导入」对话框 + 与后端同语义的 `parseCsv`（引号 / `""` 转义 / 引号内换行只推进物理行号 / CRLF·CR·LF 三种换行 / 无尾换行末行也产记录）+ `decodeCsvFile`（`TextDecoder utf-8 fatal` 失败即回落 `gbk`）+ `downloadCsvTemplate`（`\uFEFF` 起头，Excel 打开不乱码） | ✅ 9 用例 / 全量 **51 passed**；`typecheck`·`lint --max-warnings 0`·`build` 全 exit 0 |
| 2026-11-23 | ★ P2.2 抓到覆盖空洞 | 写「导入后回列表检索」用例时发现 **mock 从来没有 `GET /employees` 路由** —— 员工花名册自 P1.3 起就没被任何 E2E 覆盖，只因它一直没人测 | ✅ 补 `GET /employees`（20 出参逐字段对齐 `employeeRowToJson`、`keyword/deptId/status/page/pageSize` 五参与后端同口径、MANAGER 强制本部门且**忽略前端传来的 deptId**、`ORDER BY id DESC`、非法分页值回落 1/10）+ `POST /employees/import`。`unmatched == []` 这条闸门正是为此而设 |
| 2026-11-23 | ★ P2.2 前端两处「过度贴心」回退 | 第一版把「提交」按钮写成 `:disabled="!importCsvText \|\| !importHeaderOk"`，并在 `submitImport` 里对表头不全直接早退 | ✅ 全部回退。后端 `empImportCols` 允许**部分列匹配**并对缺失列逐行报「不能为空」，前端提前拦住 = 擅自替后端收紧语义。现改为**只黄字告警不拦提交**，把判定权交回唯一权威 |
| 2026-11-23 | ★ P2.2 计数口算错（本文档自己的） | 第四节长期写着「mock 覆盖 **29 个接口**」，本轮沿用该数写 L-MOCK-1 时顺手实测：`Select-String 'if \(method ===' \| Measure-Object` = **25**（P2.2 后 27），`hrms.ts` 的 `export const *Api` = **47**，**两个口径都得不出 29** | ✅ 全文订正为 27 并写明口径；新增 **11.2 文档计数纪律**：凡写入本文档的计数必须附可复跑测量命令 + 明确统计口径，「接口数」这类模糊词不再单独出现 |
| 2026-11-23 | P2.2 有意的取舍 | mock 未模拟 `sys_user` 开通与审计日志写入（真实后端导入成功会做这两件事） | ⚠️ 登记 **L-IMP-6**：`Account.username` 是 4 个演示账号的字面量联合类型，塞工号进去会破坏 `/system/users`、`/system/audit-logs` 既有用例的计数断言。改由 `api-smoke.ps1` 在真实库核对；对话框提示语也刻意写成「真实后端会以工号开通」而非谎报已完成 |
| 2026-11-23 | P2.2 复跑记录 | 按 CI 等价条件复跑（`CI=true` + `E2E_CHANNEL=chromium`，Playwright 自建 dev server、`workers=2`） | ✅ **51 passed (47.9s)**。仍不勾销 L-CI-1：本机等价复跑 ≠ GitHub runner 实跑 |
| 2026-11-23 | **P2.3** | 电子工资条打印 / 存为 PDF 落地：`style.css` +156 行（`@page A4` + `html.hrms-payslip-print-mode` 下的 `@media print` 隐藏 `#app`/遮罩/加载层/全局提示 + `.hrms-print-sheet` 三张表）、`PayrollView.vue` +196/−2 行（`Teleport` 打印专版、弹窗 footer「打印 / 存为 PDF」、核算中心操作列补「电子凭条」、`round2/money/slipCheck/slipVerifyText/printSlip/watch/onBeforeUnmount`）、新增 `e2e/payroll-print.spec.ts` 251 行 / 6 用例 | ✅ 全量 **57 passed (1.5m)**；`typecheck`·`lint --max-warnings 0`·`build` 三连 exit 0。后端零改动 |
| 2026-11-23 | ★ P2.3 验收项从「人眼」改成「断言 + 产物」 | 第四节验收一直写着「打印预览无侧边栏」，但无头环境看不见打印预览 | ✅ 三层兑付：① `emulateMedia({media:'print'})` 下断言 `aside`/`#app`/`#pane-admin`/弹窗 hidden 且专版 visible；② 同一状态导出 PNG 供人眼复核；③ `page.pdf()` 导出真 PDF，实测 `MediaBox [0 0 594.96 841.92]`（A4）+ `/Count 1`（单页）。剩余不可验证部分登记 **L-PRT-3**，不假装消解 |
| 2026-11-23 | ★ P2.3 不用 `:has()` 的理由 | 直觉写法是 `@media print { body:not(:has(.hrms-print-root)) … }`，一行搞定且无需 JS 参与 | ✅ 改走 `<html>` 模式类：`:has()` 在老浏览器是**整条规则静默失效**，退化形态是「打印出整页 SPA」——用户拿到带侧边栏的工资条而全程无报错，属最坏错误。模式类可被 E2E `toHaveCount` 直接断言，且不依赖 `afterprint`（无头下不可靠） |
| 2026-11-23 | ★ P2.3 抓到状态残留路径 | 路由切走时 `el-dialog` 随组件卸载，`slipVisible` 不会由 true 变 false，`watch` 不触发，模式类会残留到下一个页面 | ✅ 补 `onBeforeUnmount` 兜底；用例用 `locator.dispatchEvent('click')` 命中 `router-link` 走**真实 SPA 导航**（弹窗遮罩会拦截普通 click，`page.goto` 则是整页刷新、清不清都测不出东西） |
| 2026-11-23 | P2.3 两处刻意不贴心 | ① 关闭弹窗不清空 `activeSlip`；② 草稿态也能出条，不禁用按钮 | ✅ ①清空会让正文在淡出动画里先消失，专版靠模式类摘除即失效，用例断言「关闭后 print 媒体也打不出它」；②纸质件如实打印「草稿（尚未发放）」+ 发放时间 `—`，由单据自证状态比前端禁用更诚实。另：复算不一致分支 E2E 不可达，登记 **L-PRT-2** |
| 2026-11-23 | **P2.4** | 考勤月度汇总导出落地：`attendance_controller.cj` +248/−4（新增 `handleAttendanceMonthlySummary` + 7 个纯函数 + 常量 `attShouldAttendDays = 22`，并顺手把 `/my` 的 `actualAttendDays` 改成排除 `ABSENT` 的计数，与汇总同口径）、`main.cj` +3 注册路由、新增 `attendance_controller_test.cj` 539 行 / **19 个 `@TestCase`**；前端 `AttendanceView.vue` +202/−1（第 3 个页签「月度汇总导出」：月份/部门筛选 + 6 张合计卡片 + 11 列明细 + 一键 CSV）、`hrms.ts` +36、`mock-server.ts` +132/−8（第 28 条分发 `onMonthlySummary`）、新增 `attendance-summary.spec.ts` 220 行 / 7 用例、`payroll.spec.ts` +33、`PayrollView.vue` +28/−4 | ✅ 全量 **65 passed / 0 failed**（`--workers=1`）；`typecheck`·`lint --max-warnings 0`·`build` 三连 exit 0。仓颉侧仍**未经编译**（L-CJ-1） |
| 2026-11-23 | ★ P2.4 主表选错会让出勤率虚高 | 直觉写法是 `FROM hr_attendance`，但整月一次卡都没打的人**整行消失**，分母跟着缩小 —— 越是缺勤越多的人越不出现在报表里，出勤率反而上升 | ✅ 主表改为 `hr_employee`（`WHERE e.status <> 'RESIGNED'`）。换表后新的坑：`LEFT JOIN` 的 `NULL` 行会落进 `CASE ... ELSE` 分支被**凭空算成 1 天出勤**，故每个 `CASE` 都补 `a.id IS NOT NULL` 守卫。用例「整月无打卡者以 0 天出现在报表里」直接断言 5 行齐全 |
| 2026-11-23 | ★ P2.4 数值注入 JSON 的合法性 | 把 `late_minutes` 这类 `VARCHAR` 存来的数字直接 `${}` 插进 JSON 模板，遇到 `1e5` / 空串 / `NaN` 就拼出**语法非法**的响应体，前端 `JSON.parse` 白屏而后端依旧 200 | ✅ 新增 `attMonthSafeNum(raw, defaultText)` 逐字节白名单校验（只放数字、单个 `.`、可选前导 `-`）。**刻意不用 `Float64.tryParse`**：它接受 `1e5`/`NaN`/`Infinity`，能解析 ≠ 能安全插入。`attendance_controller_test.cj` 里专门有一组「拒绝集」用例覆盖这些输入 |
| 2026-11-23 | ★ P2.4 导出与页面的快照漂移 | 「页面数字 = 导出数字」不只需要同源数据结构，还需要**同一份快照**：签退或补卡修正之后，屏幕上的汇总还停留在改动前 | ✅ 新增 `refreshSummaryIfNeeded()` 挂到 `handleClockIn` / `handleClockOut` / `submitFix` 三处写操作末尾（条件：有权限且 `sumLoaded`）。没加载过就不发请求，避免给不看汇总的人多加一次轮询 |
| 2026-11-23 | ★ P2.4 顺带抓到薪资导出漏行 | `PayrollView.exportCsv` 直接把**屏幕上那一页**写成 CSV，`pageSize` 默认 10 时「导出全部」实际只导出 10 人 | ✅ 改为按 `pageSize=100` 循环翻页直到 `batch.length < pageSize` 或 `rows.length >= total`；依据是 `payroll_controller.cj:124` 对 `pageSize > 100` **静默回落成 20**，所以只能拿 100 而不能拿 10000。`payroll.spec.ts` 新增 1 例断言出站参数与导出行数 |
| 2026-11-23 | ★ P2.4 E2E 首跑 6 红 → 全绿（两处假红的根因） | ① `pickMonth` 写成「先 `fill`+`Enter` 再 `waitForRequest`」，Vue 的 `@change` 是微任务，请求早于监听器发出 ⇒ 10s 超时；② `PAYROLL_MONTH` 恰等于真实当前月（2026-11），`el-date-picker` 值未变化，**`@change` 根本不触发** | ✅ ① 一律**先注册 waiter 再触发动作**；② 先比对 `inputValue()`，相同则 early return。证据取自 `test-results/**/error-context.md` 的 aria 快照（combobox 值已是 `2026-11`、卡片已是 5 人 / 1.82%）——**先拿到运行时证据再改断言**，否则极易顺手把断言放松成假绿 |
| 2026-11-23 | ★ P2.4 两处「测我自己编的数据」的诱惑 | ① 出勤率断言写成 `0.00`，实际表格输出 number `0`；② 想在 payroll 导出用例里断言 toast，但 `exportCsv` 从来没有成功提示 | ✅ ① 改成逐格 `toBe('0')`，以**渲染结果**为准而非叙述语感（同 11.2 教训）；② 去掉 toast 断言，改断言 `download.suggestedFilename()` 与行数 —— 断言不存在的行为比不测更糟 |
| 2026-11-23 | P2.3 用例首跑纠偏 2 处 | ① `getByRole('button',{name:'关闭'})` strict violation —— EP 叉号的可访问名是「关闭此对话框」，包含匹配命中 2 个；② 断言 `toContainText('发放时间：')` 落空 —— 专版里「发放时间」是表格 `<th>`，**没有冒号**，冒号只存在于抬头那行 `<span>` | ✅ ① 加 `exact: true`；② 改为定位该行的 `<td>` 末格 `toHaveText('—')` / `toHaveText(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/)`，断言从「文案存在」升级为「格子内容」。教训同 11.2：**模板里写没写标点，要以模板为准，不能凭叙述语感** |
| 2026-11-24 | **P3.1 数据库** | `sql/init.sql` 的 `hr_leave_overtime.status` 注释扩为六值并说明「`PENDING_MGR`/`PENDING_HR` 同属未终态」，`approver_id/approve_remark/approved_at` 改注为「最近一次」；新增**表 12 `hr_approval_log`**（`UNIQUE KEY uk_al_request_step (request_id, step)` + `INDEX idx_al_request`） | ✅ 已用 `mysql.exe` 对真实 `hrms_db` 实跑 DDL + `ALTER TABLE ... MODIFY`，`SHOW TABLES LIKE 'hr_approval_log'` 命中、`COUNT(*)=0`。⚠️ 存量库需手工跑 `ALTER`，见 **L-APR-1** |
| 2026-11-24 | **P3.1 后端** | `request_controller.cj` +239/−28：**把散在 HTTP 处理里的状态判断全部收敛成 15 个纯函数**（`reqInitialStatus`/`reqCurrentLevel`/`reqNextStatus`/`reqCanActStep`/`reqActionDeniedMessage`/`reqShouldDeductAnnual`/`reqIsPendingLike`/`reqStatusCondition`/`reqPendingCountCondition`/`reqTrailSql`/`reqTrailJsonFor`/`reqIdListFromRows`/`reqIsNumericId`/`loadApprovalTrail`/`requestRowToJson`）；建单落 `reqInitialStatus`、审批改为「一次只推一级 + 同事务写审批链 + 终态才扣年假」、列表/我的申请出参补 `currentLevel`/`myAction`/`approvalTrail`、撤回放宽到 pending-like；`dashboard_controller.cj` 待办计数改 `reqPendingCountCondition()` | ⚠️ **未编译**（L-CJ-1）；新增 `request_controller_test.cj` **405 行 / 33 个 `@TestCase` / 100 个 `@Assert`**做静态论证，并用 node 逐函数复算对齐期望值 |
| 2026-11-24 | ★ P3.1 仓颉跨文件可见性未能证实 | 想查「顶层 `func` 不加修饰符能否被同包其它文件（测试文件）调用」：`WebFetch` 打 `docs.cangjie-lang.cn` 与 `developer.huawei.com` 的可见性章节**两次都返回空**（SPA 无正文），`WebSearch` 只拿到 DeepWiki 的不完整修饰符表（`public/internal/protected`，无默认值说明） | ⚠️ **不赌**：本次新增的可测函数**一律显式 `public`**。同时登记 **L-APR-2** —— 既有 4 个测试文件（payroll/performance/rate_limit/response）依赖的正是「包内私有跨文件可见」，这条假设至今没被编译器验证过 |
| 2026-11-24 | **P3.1 前端** | `ApprovalView.vue` +88/−8：状态下拉**追加**（不是插入）`PENDING_MGR`/`PENDING_HR` 两项以免破坏 `pickOption(...,1,'已通过')` 的下标契约；工作台新增「审批级次」「审批链」两列；操作列条件从 `canApprove` 改为后端下发的 `row.myAction === 'APPROVE'`；建单 >3 天出两级提示；提示语按响应 `status` 分级（单级仍保持 `申请已提交`/`审批已通过` 原文，既有断言零放宽） | ✅ `vue-tsc --noEmit`、`eslint .`、`vite build` 三连 exit 0 |
| 2026-11-24 | **P3.1 mock + E2E** | `mock-server.ts` +191/−16：`ReqRow` 补三键 + 新增 `approvalLogs`/`approvalSteps()`/`approvalChain()`，用 TS **再写一遍**后端状态机并整体重写 `onApproveRequest`；`approval.spec.ts` +245/−1，7 例 → **10 例** | ✅ 全量 **68 passed / 0 failed**（此前基线 65），`mock.unmatched == []` 闸门全绿 |
| 2026-11-24 | ★ P3.1 既有用例必须跟着语义走，不能放宽 | 「余额边界：恰好扣满」原本用 **5 天**年假一步签完，改双级后 `mgr` 一级通过**不再扣减**，该用例必红 | ✅ 按新语义补 HR 二级步骤（`PENDING_MGR → PENDING_HR → APPROVED`、余额 5→5→0），断言从 1 条变 6 条而不是把 `toBe(0)` 改成 `toBeLessThanOrEqual(5)`。**用例红是因为语义变了，不是因为用例错了** |
| 2026-11-24 | ★ P3.1 服务端 403 只能绕开 UI 测 | 越级分支下前端已按 `myAction` 藏掉按钮，纯 UI 用例永远打不到 `approve` 的 403 分支，会造成「前端挡住了 = 后端也挡住了」的错觉 | ✅ 新增 `apiPost()`：在已登录页面内 `fetch` 直连接口（带 `Bearer` 头），断言 HTTP 码 + 信封 `message` + **副作用为零**（`approvalSteps`、`leaveBalance`、`status` 三项都不许动）。同时登记 **L-MOCK-2 类风险**：此路径 mock 与后端各写一遍，真实 403 仍待 `E2E_REAL=1` 复验（L-MOCK-1） |
| 2026-11-24 | ★ P3.1 E2E 首跑 1 红（自写用例的坑） | 「长假可撤回 + 3 天单级」连建两张单，两条 toast 都含「申请已提交」（长假那条是 `申请已提交，超过 3 天的长假需…`），`toast()` 是 `filter({hasText})` ⇒ **strict mode 命中 2 个** | ✅ 建单助手改用 `.last()`。上一轮已犯过同类错（P2.3 的「关闭」按钮），规律是：**Element Plus 的 toast 会叠加存活 3 秒，任何连续两次相同前缀的提示都必须显式取最后一条**；同时刻意不做「等 toast 消失」的 sleep，避免把时序耦合进用例 |
| 2026-11-24 | ★ **L-APR-2 的证据补强**（写文档时反向查出的自身错误归因） | 为写第十节风险条目，把基线 `6e79923` 的全部顶层函数逐个扫了跨文件引用 | 基线 **20 个非 `public` 顶层 `func`**（`calculateTax` / `buildUserProfileJson` / `maskIdCard` / `unescapeField` / `dispatchRequest` 等）**跨文件引用 0 处**；另 90 个 `public func` 承担全部跨文件调用 | 「包内私有可跨文件」这条假设**既无官方条文、也无基线实例**，只是「未被证伪」⇒ L-APR-2 措辞已升级。同时**推翻我自己的一处取证**：`mysql_pool.cj` 那 10 余个 `let B_*: UInt8 = 0xNN` 是 **P0.1 我自己加的**（`git show 6e79923:...` 匹配 **0 处**），不能当「基线已证实」用，第十一节已改为如实标注。真正有基线先例的是**数组字面量**（全仓仅 `mysql_pool.cj` 的 `args` **1 处**）与**行尾 `+` 续接拼接（193 处）** |
| 2026-11-24 | **P3.2 后端（部分交付）** | 新建 `notification_controller.cj`：SQL 文本生成、`ref_id` 去重键、`IN (...)` 拼串、行→JSON **全部抽成不碰库的纯函数**并显式 `public`（吸取 L-APR-2 教训，不给跨文件私有可见性留依赖）；`main.cj` 注册 4 条路由；三处业务触发接线；`sql/init.sql` 加**表 13 `sys_notification`** | ✅ 表 13 已在真实 `hrms_db` 执行，`SHOW CREATE TABLE` 核对字符集/唯一键/索引齐全；生成的 SQL 文本按后端同款命令行（`--batch -N -e "SOURCE f"`）实测可执行。⬜ **前端铃铛 / mock 分发 / E2E / 单测文件未做**（用户要求先提交一部分），剩余清单见 12.15 末尾 |
| 2026-11-24 | ★ **P3.2 推翻自己写的注释** | 我为「批量发薪拼多条 INSERT」写的注释称*逐条写能让撞 UNIQUE 只影响自己那条、不把整批带崩*。写完后反查 `runMysqlFile` 命令行发现**没有 `--force`**，于是构造三语句脚本（成功 / 撞 `uk_notif_user_type_ref` / 成功）在真实库实测 | `ERROR 1062 ... at line 19 in file: ...notif_live.sql`，**第 19 行之后所有语句一条都没执行**（该脚本后面的 5 个探测段全部无输出），退出码 **1** ⇒ 我的断言是**错的**。改用 `INSERT IGNORE` 重测：B1/B2 两条都在、退出码 **0**。**修复**：`notifInsertSql` 改 `INSERT IGNORE INTO`，并在文件头与 `notifJoinInserts` 注释里如实记录「IGNORE 负责不中止、逐条负责少伤，两者作用不同」 |
| 2026-11-24 | ★ 无 SDK 下的检查手段已接近用尽 | 补了两个临时脚本（不入仓，见 12.15）：`.cj` 括号/三引号配平 + 全项目跨文件调用符号解析 | `notification_controller.cj` **零未解析调用**；dashboard/payroll/request 对通知符号的跨文件调用**全部命中且全部 `public`**。剩余告警全是既存类别（`ReentrantMutex`/`SHA256` 等 stdlib 类型、`AuthUser`/`DeptRow` 等 `class/struct` 名、测试框架 `Assert`、`init`/`main` 入口），系脚本只采集顶层 `let/var/func` 所致，**非新增缺陷** |
| 2026-11-24 | **P3.2 通知中心：前端 + mock + E2E（本轮接上「继续」后的第二批）** | 12.15 第⑤项欠债清单已按序兑付 4 项（第 5 项「建 sys_user 测试账号」仍欠，见 L-NOTIF-3） | ① `notification_controller_test.cj` **727 行 / 64 `@TestCase` / 164 `@Assert`**，期望值由 TEMP 下两份 node 镜像脚本独立复算并**整行逐字回核**（第一批 39 pins / 第二批 56 pins，各 0 MISS）；② `hrms.ts` 4 接口 + `AppLayout.vue` 铃铛 `el-badge` + 抽屉 + 30s 轮询 + 按 `type` 跳转；③ `mock-server.ts` **分发 28 → 32** + 3 个触发点镜像（`onApproveRequest`/`onPaySingle`/`onBatchPay`/`onOverview`）；④ `e2e/notification.spec.ts` **351 行 / 9 用例**。为让跳转成立，`PayrollView.vue` / `ApprovalView.vue` 补了认 `route.query.tab` 的能力（后者还要求 `canApprove`）。三连全绿、`playwright test --list` = **77 tests / 9 files**（原 68 / 8）、全量 **77 passed**。踩了 5 个坑全部记进 12.15 ⑥，其中两个改了**既存**用例：`el-drawer` 自带 `<header>` 撞 strict mode（改 `:with-header="false"`）、全局 `unread-count` 打进两条「本模块不该发别的接口」的闸门（只放行这一条具体路径） |
| 2026-11-24 | **用户指令再次变更（优先级 + 交付节奏）** | 原话：「这次主要方向是增加必要的功能，要体现工作量，可以适当减轻那些如安全性的开发内容，因为体现不出工作量大小。你每完成一批功能后注意要更新到仓库中的zc分支」 | ① 覆盖「先做记号、过几天再提交」——改为**每完成一批就 commit + push `zc`**；② 安全加固类（注入面、越权矩阵、`sqlSafety` 断言）**降级为顺带产出，不再单独开工**，因为它的行数体现不出功能量；③ 下一批 = **P4.1 培训与学分**（建表 + 控制器 + 路由 + 前端页 + 仓颉单测 + mock 分发 + E2E 全链路一次做完） |
| 2026-11-24 | **计量纠偏（第三次）**：`powershell -File` 子进程看到的是**过期文件系统快照** | 同一份 `notification_controller_test.cj`，脚本内 `Get-Content` 报 690 行、内联命令报 727 行（`Read` 工具末行号 727 为权威）；`notification_controller.cj` 同样报 432 vs 470 | 台账里所有行数/条数**只用内联命令、`Read` 末行号或 `git --numstat` 取**，不得用 `-File` 跑的脚本回填。本节新写的 9 files / 1571(+) / 10(−) 与 55 files / 15170 / 152 均取自 `git diff --numstat` 与 `git diff --shortstat 6e79923 HEAD`（提交后须复跑对账，命令见 13.5 口径 1） |
| 2026-11-25 | **P3.2 第二批已提交并推送 `zc`** | commit **`62a42e8`**：`10 files / 1644(+), 47(−)`；代码口径 `git diff --cached --shortstat 6e79923 -- . ":(exclude)FOLLOWUP_PLAN.md"` = **56 files / 15165(+), 147(−)**，与 13.5 表内数字一致（暂存前后各复跑一次，无漂移） | ① 按新指令兑现「每批功能推一次 zc」；② 推送前把同源残留的 **432 → 470、690 → 727、318 → 351** 三处错数改正为内联实测值，并把 ④ 的「68 tests in 8 files」标注为第一批状态（第二批为 77 / 9）；③ **推送方式变更**：local config 里的 `http.proxy=127.0.0.1:7890` 已失效（端口无监听、`ProxyEnable` 回 0），改用 `git -c http.proxy= -c https.proxy= push` **直连成功** `b4427b1..62a42e8`，详见 13.6 的状态变更块；④ 下一批立即开工 **P4.1 培训与学分** |
| 2026-11-26 | **P4.1 培训与学分：后端 + 仓颉单测已交付（前端/E2E 未做）** | 建表 2 张（`hr_training` / `hr_training_record`）+ `training_controller.cj` **1478 行**（46 纯函数 + 11 handler）+ `main.cj` **11 条路由** + `notification_controller.cj` 接 `TRAINING_PUBLISHED` + `training_controller_test.cj` **36 类 / 93 TC / 255 AS**；逐文件与真库实测见 **12.16** | ① 按用户指令只做功能、不开安全类工作；② 单测期望值全部由 node 镜像程序化生成（12.16 ④），并借此抓到 `formatNum2` 镜像与真实实现不一致（`1.5` vs 正确 `1.50`）；③ 两处**反向结论**已记录：L1026 的嵌套双引号插值经全库扫描确认基线有 5 处先例（不改），`check_test.js` 的 `oddQuoteLines=[482]` 是脚本误报；④ 本批按 P3.2 的两段式先例**只提交后端切片**，前端与 E2E 留待下次，未跑三连与 Playwright（本批无前端改动，不影响基线 77 passed） |
| 2026-11-28 | **P4.1 培训与学分：前端 + E2E 收口，模块闭环** | `TrainingView.vue` 844 行（4 tab + 2 弹窗）+ `hrms.ts` 144 行（6 interface / 11 Api，与 11 条路由 1:1）+ `router` `meta.roles` 四角色 + `AppLayout` 菜单与 `TRAINING_PUBLISHED` 跳转 + `mock-server` 分发 **32→43** + `e2e/training.spec.ts` **13 用例** + `rbac-menu` 四角色菜单；逐文件与契约对齐点见 **12.17** | ① 三连 exit 0、`--list` = 90 tests / 10 files、全量 **90 passed (1.7m)**，无 flake、未放宽断言；② **纠偏**：`stats`/`records` 后端实际放行 ADMIN/HR/**MANAGER**（`requireRoles` 逐个回源码核对），上一批 12.16 ⑦ 记成 ADMIN/HR 是错的，mock 已按真实角色对齐；前端 `stats` tab 刻意仍只给 ADMIN/HR（后端宽、前端窄，见 12.17 ③）；③ 抓到并绕过一个**真实后端语义坑**：`PUT` 无条件跑整表单校验，只传 `{status}` 会 400，改为回填完整 payload，并用 E2E 钉住 body 字段；④ 「未考核」用 `-1` 哨兵在 UI 上渲染成 `—` 而非 `0`；`capacityLeft` 前端现算；`blockReason` 逐字用后端原文 |
| 2026-11-28 | **新功能批次：P4.2 差旅与报销（后端切片）** | `hr_expense` 23 列 + `expense_controller.cj` 1897 行（84 纯函数 / 13 handler）+ `main.cj` 13 条路由 + `notification_controller` 4 个 `EXPENSE_*` 类型；逐项见 **12.18** | ① **刻意偏离原计划并已记理由**：报销额**不进 `hr_payroll`**——`calculateTax` 会把 `bonus` 计入应税所得，而实报实销不该计税，并入等于算错个税并动摇 P1.3 的金额一致性闸门；改为独立发放通道（settlement 台账 + `pay`），全文件零引用 `hr_payroll`；② 真库 MySQL 8.0.43 实测 **29 组**（只读 12 + 写态 13 + 约束 4），含「局部更新不清空其余列」「乐观条件首次 1 行/二次 0 行」「驳回重报清审批痕迹」「通知 3 次写入仍 1 条」「重复票号 ERROR 1062」，测试数据已清回种子；③ 自查纠出 3 处真错：`notifInsertSql` 是单收件人不是批量、`ORDER BY CAST(SUM() AS CHAR)` 会按字符串序排错、插值里写 `\"` 无先例；④ `ERROR 1267` 已定性为**验证脚本自身的排序规则冲突**（会话变量 vs 字面量），非线上 SQL 问题；⑤ 本批同样按两段式**只提交后端**，单测与前端/E2E 留下一批 |


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
| L-MOCK-1 | E2E 的 32 条 `route()` 分发条目（口径见 11.2，原写「29 个接口」系口算错）由**有状态内存 mock** 提供，`E2E_REAL=1` 直连真实后端的路径**从未跑过**（无 SDK，后端起不来） | 「77 passed」证明的是**前端逻辑 + 前端对契约的理解**自洽，不等于**后端实现无缺陷** | 与 `L-SMOKE-1` 同性质。所有 mock 契约均逐字段 `Read` 自 `backend-cangjie/src`（第九节有取证行），SDK 就位后首件事是 `E2E_REAL=1` 复跑；届时失败**默认判为 mock 与后端的漂移**，以源码为准修 mock。**P2.2 新入这条风险的最大实例**：mock 此前**完全没有 `/employees` 路由**，员工花名册在 P1.3~P2.1 期间其实是「前端写好、E2E 从未覆盖列表」的空白区，直到 P2.2 需要「导入后回列表检索」才暴露 ⇒ 已补 `GET /employees`（20 出参 + 4 筛选 + MANAGER 限本部门 + 分页回落）与 `POST /employees/import` |
| L-MOCK-2 | mock 是「按我读到的源码写的」，存在**读错字段**的残余风险 | 字段名/口径同时写错时 mock 与 spec 会自洽假绿 | 缓解手段是 teardown 的 `unmatched == []` 闸门（前端发起而 mock 未实现的接口必红）+ 分页/鉴权分支照抄后端语义；**根治手段只有 `E2E_REAL=1`**，见 L-MOCK-1 |
| L-E2E-1 | 整页加载后的 `page.on('request')` 监听器**只能在导航之后挂载**，早于监听器完成的请求采不到 | 对采到的请求做 `toEqual([精确数组])` 会退化成**计时器**，随机假绿/假红（`payroll.spec.ts` 的旧断言就假绿了若干轮才被揭穿） | 纪律固化：**导航后一律断言「不该出现的为空集」+ `toContain(关键项)`，禁止精确数组**；确需精确计数时改用 `page.route` 侧计数（拦截点必然全采） |
| L-E2E-2 | `--workers` 在本终端默认取到 `2`（`CI` 环境变量为真） | 与本地 `vite` 单实例预览服务并发时偶发抖动，报错形态像用例问题 | 本地复跑显式 `--workers=1`；CI 里由 Playwright 自己起 preview，不受此影响 |
| L-CI-1 | `ci.yml` 的**前端两个 job 尚未在 GitHub runner 上真跑过**（本机只能做到「等价条件复现」：`CI=true` + `E2E_CHANNEL=chromium` + 自建 dev server，P2.2 后复跑 **51 passed (47.9s)**） | runner 镜像差异（apt 依赖、Node 22 预装版本、`npm ci` 跨平台可选依赖）仍可能造成首跑失败 | 首次推送后**必须去看一眼 Actions 的实际结果**，失败即回来修 workflow，不许默认它绿。已尽量降低风险：浏览器不依赖 runner 预装（显式 `playwright install --with-deps chromium`）、依赖用 `npm ci` 锁死、`node-version: '22'` 与本机同大版本 |
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
| **L-IMP-5** | 前端 `parseCsv` 与后端 `parseCsvInto` 是**两份独立实现**（TS / 仓颉），逐字符同语义靠人工维护，**无自动比对** | 任一侧改了引号/换行/空行处理而另一侧没跟上，就会出现「预览 8 行、后端算 9 行」或**错误行号错位**（真实事故形态：用户按行号改文件却改错行） | ① 12.10 的 17 组 ground truth 同时是**两侧的共同断言源**：后端 35 个 `@TestCase` 取其中若干，前端 `employee-import.spec.ts` 的「引号内逗号与换行」用例取引号+物理行号这一组；② 前端预览的 `数据 N 行` 直接来自前端解析，若与后端返回的 `total` 不一致，用例「预检 2 行 / 校验 3 行」会红。**SDK 就位后的第一件事**应是 `E2E_REAL=1` 跑这 9 个用例，让真后端来验收前端解析器 |
| **L-IMP-6** | E2E mock **刻意不模拟** 导入时的 `sys_user` 开通与审计日志写入 | 「导入后能用工号登录」「审计里能查到这次导入」这两条**E2E 全绿也证明不了** | 有意的取舍，理由写在 `mock-server.ts` 注释里：`Account.username` 是 4 个演示账号的**字面量联合类型**，把工号塞进去会污染 `/system/users` 与 `/system/audit-logs` 既有用例的计数断言。改由 `api-smoke.ps1` 在真实库上核对（该脚本已有 `/system/users` 与 `/system/audit-logs` 的断言点）。**对话框里也照实说**「真实后端会以工号开通账号」，不写成已完成 |
| **L-IMP-7** | 导入超时在前端**单独放宽到 60s**，是全局 15s 的一个例外 | 若后端改为逐行 INSERT 或 MySQL 变慢，60s 也可能不够；反过来，恶意大文件会长时间占住连接 | 上限已由 `EMP_IMPORT_MAX_ROWS = 500` 与 mock 的同一常量双向钉住；`hrms.ts` 里写明放宽原因（整批一条 SQL 交 `mysql.exe`，500 行远超全局默认）。真实后端就位后应实测 500 行耗时再决定是否收回这个例外 |
| **L-PRT-1** | 打印专版**只有工资条这一张单**，且字段上限就是列表行 `payrollRowToJson` 的 17 个 | 「核算中心整表打印」「按部门批量出条」都没有；若后端将来把补贴/奖金拆成明细行，纸质件不会自动跟着变 | 有意收窄：P2.3 只兑付第四节那一条需求。机制已通用化（`html` 模式类 + `.hrms-print-root` + `.hrms-print-sheet`），P2.4 若需打印可直接复用，不必再造第二套 |
| **L-PRT-2** | 「复算校验**不一致**」这条告警分支在 E2E 里**不可达** | mock 与后端同源计算，正常数据永远一致；CI 全绿也从未真正打印过一张「不一致」的单，该分支只有静态复核 | 诚实登记而非补测试：要触发它得人为篡改一次 `netSalary`，而这会让用例变成「测我自己编的数据」。SDK 就位后用 `E2E_REAL=1` 跑真实后端，若两侧口径漂移就会当场显形 —— 这正是这条分支存在的目的 |
| **L-PRT-3** | 无头环境**验不了真实打印面板**：驱动、纸张来源、中文字体缺失、用户未勾「背景图形」都看不见 | 「A4 单页」这个结论只在 Chromium print-to-PDF 下成立（实测 `MediaBox 594.96×841.92`、`/Count 1`），换物理打印机不保证同结果 | 已用 `print-color-adjust: exact` 强制表头底色（这是不勾背景图形时最常见的塌法），并给三张小表加 `break-inside: avoid` 防「实发金额」掉到第二页。剩余不确定性属用户环境，标注为不消解 |
| **L-ATT-1** | 应出勤天数是**硬编码常量 22**（`attShouldAttendDays`，5 天 × 4.4 周），库里既无排班表也无工作日历，节假日/调休/大小周一概不算 | 出勤率对**任何人**都只是近似值：法定假多的月份会系统性偏低，2 月会偏高；「合计出勤天数 / 应出勤天数」这类卡片同理 | 有意为之：加一张 `hr_work_calendar` 意味着新的建表脚本、导入逻辑和一整套 E2E 种子，超出 P2.4 那一条需求的范围。已在常量处注释标明口径，且**前端把 22 显示为独立一列**而不是藏起来，让人一眼看出分母是假设值。真实排班就位后只需改 `attShouldAttendDays` 的取值来源，SQL 与出参结构不变 |
| **L-ATT-2** | 考勤汇总的迟到/早退口径是「**分钟数 > 0 或状态标记**」，而算薪扣款走的是 [payroll_controller.cj:83](./backend-cangjie/src/controller/payroll_controller.cj) 的**仅 `late_minutes > 0`** | 同一员工同一月，「月度汇总」报 1 次迟到、工资条考勤扣款却是 0 元（状态被标成 `LATE` 但分钟数没写）。两处都"对"，用户看到的是自相矛盾 | 本轮**不统一口径**：改算薪规则会动到金额，属薪酬业务决策，且无 SDK 无法回归。已做的止损是①两侧口径都写进代码注释与本表；②`attendance_controller_test.cj` 用 19 个用例把「汇总侧」的口径钉死，将来若有人统一，这里必然红。真正的一致性需要产品侧先定「状态标记算不算迟到」 |
| **L-APR-1** | `sql/init.sql` 的改动**不会自动作用到已存在的库**：新建表 12 `hr_approval_log` 只在 `init.sql` 里，而存量 `hrms_db` 早已建过库；`hr_leave_overtime.status` 的注释扩写同理需要 `ALTER TABLE ... MODIFY` | 后来者在旧库上直接起服务，审批链写入会 `Table 'hrms_db.hr_approval_log' doesn't exist`，二级流转全部 500 | 本机已用 `mysql.exe` 对该库**实跑过** DDL + `ALTER` 并验证命中（见第九节）。但这是「我这台机器好了」，不是「部署脚本好了」——根治需要一份幂等迁移脚本，属独立工作项，未排期。`init.sql` 的建库路径本身是完整的 |
| **L-APR-2** | 仓颉「顶层 `func` 不加修饰符 = 包内私有，且同包其它文件可见」**至今没有官方条文证实**（WebFetch 可见性章节两次返回空正文、WebSearch 只给到不含默认值的修饰符表）；更糟的是基线也**给不出反证支持**：本轮扫完基线 **20 个非 `public` 顶层 `func`**，跨文件引用 **0 处** | 若默认语义是「仅本文件可见」，则 `request_controller_test.cj` 与既有 **4 个测试文件**（`payroll`/`performance`/`rate_limit`/`response`）会在 `cjpm test` 首跑时**集体报未定义**——275 个 `@TestCase` 里有 242 个建立在这条假设上 | 本轮已止损：P3.1 新增的 15 个可测函数**一律显式 `public`**，不依赖该假设。旧文件不做无证据的批量改动（改动本身也可能引入新问题），SDK 就位后首跑即以此判别真伪 |
| **L-APR-3** | 审批状态机、审批链写入、以及 `UNIQUE(request_id, step)` 冲突 → `executeSql` 返回 false → 500 这条并发保护分支，**全部未经编译与真实运行** | E2E 的 10 例绿只证明「前端 + TS 镜像的状态机」自洽，不能证明仓颉那份实现对 `Float64` 比较、`IN (...)` 拼串、事务顺序的处理正确 | 与 L-CJ-1/L-MOCK-1 同性质。已做的兜底：①15 个纯函数写了 33 个 `@TestCase`，期望值用 node 按同算法独立复算过；②状态机在 TS 里**逐函数重写一遍**作为交叉实现（两份同源不同人写的实现能对齐，说明至少不是笔误）；③`step` 取值刻意放在改写 `row.status` **之前**，这类顺序坑已在代码注释里标明。根治仍是 `cjpm build && cjpm test` + `E2E_REAL=1` |
| L-NOTIF-1 | **P3.2**：存量库不会自动获得 `sys_notification` | `sql/init.sql` 用的是 `CREATE TABLE IF NOT EXISTS`，**只在全新初始化时生效**；已建好的库里没有这张表，`notification_controller` 的每条 SQL 都会以 `ERROR 1146 (42S02) Table 'hrms_db.sys_notification' doesn't exist` 失败，而 `executeSql` 返回 `Bool` 且**调用侧不检查** ⇒ 通知静默丢失，接口返回空列表，前端看不出异常 | 本轮已在开发库 `hrms_db` 手工执行 DDL（`SHOW CREATE TABLE` 已核对），但**仓库内没有迁移脚本**。部署到任何其它库都必须二选一：重跑 `init.sql`，或单独执行第十一节记录的建表语句。根治 = 补一份带版本号的迁移 SQL（与 L-APR-1 同一项欠债，建议合并处理） |
| L-NOTIF-2 | 合同到期提醒的**触发时机是设计缺陷级取舍** | 触发点挂在 `handleDashboardOverview`（因为只有它已经查出 30 天内到期的行集），意味着**只有 ADMIN/HR 打开工作台时才会生成提醒**；若 HR 整个月不登录，到期提醒一条都不会产生——这恰好是最需要提醒的场景 | 已在注释里写明该取舍。根治需定时任务（仓颉侧无现成调度），或改为「登录时扫描一次」并放宽为只读扫描 + 首次命中写库。验收时不得把「工作台能看到到期列表」当成「通知已按时生成」 |
| L-NOTIF-3 | P3.2 的**员工→账号映射命中路径仍只在 mock 里验证过**，真实库 `sys_user` 依旧是空表 | `SELECT COUNT(*) FROM sys_user` → **0**（同库 `hr_employee` → 5）⇒ `notifResolveUser` 在真实库上恒返回 0，`pushNotification` 直接丢弃通知——**接口不会报错，但一条通知也不会落库**。本轮交付的前端铃铛 + 9 条 E2E 全部跑在有状态 mock 上（mock 用 `accounts.find(a => a.employeeId === e && a.isActive)` 复刻了同一条映射，见 `notifUserIdByEmp`），所以**验证的是我对契约的理解，不是真实库的行为** | 建 `sys_user` 测试账号后复跑第十一节记录的 `notifUserMapSql` 探测段，并在 SDK 就位后用 `E2E_REAL=1` 复跑 `e2e/notification.spec.ts`。在此之前第五节验收清单该项标 🟡（前端已交付、真实库未验证），不得改 ✅ |

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
（⚠️ P2.4 补注：「能解析」≠「能安全拼进 JSON」。`Float64.tryParse` 接受 `1e5`/`NaN`/`Infinity`，
 这三者插进 JSON 模板会拼出**语法非法**的响应体，故 `attMonthSafeNum` 刻意改用逐字节白名单，见第四节 P2.4 与 12.13）
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

**P3.1 新增的取证结论（本轮 `git grep` 基线 `6e79923` 实测，计数均可复核）**：
- **数组字面量 `[..]` 在基线确有先例**：`git grep -n -E "=\s*\[" 6e79923 -- backend-cangjie/src` → **1 处**，
  即 `mysql_pool.cj` 的 `let args = [ "-h", ..., "-p${globalConfig.dbPass}", ..., "-e", "SOURCE ${unixPath}" ]`
  —— 多行、元素含插值、类型由元素推断为 `Array<String>`。故 `request_controller.cj` 的
  `let reqPendingStatuses = ["PENDING", "PENDING_MGR", "PENDING_HR"]` 属**已证实写法**（此前 P2.1 测试文件
  刻意回避数组字面量只是保守，并非该写法被证伪）。`for (s in reqPendingStatuses)` 亦走已证实的 `for (x in arr)`。
- **行尾 `+` 续接的多行字符串拼接**：基线 **193 处**（最早 `attendance_controller.cj:12`），
  `reqTrailJsonFor` 的逐字段拼 JSON 沿用同款排版。
- **`ArrayList<ArrayList<String>>` 嵌套泛型**：基线 **2 处** ⇒ `loadApprovalTrail` / `reqTrailJsonFor` 的签名可用。
- **`let X: UInt8 = 0xNN` 顶层带类型注解的十六进制字面量**：**基线没有先例**（`git show 6e79923:.../mysql_pool.cj`
  匹配 `: UInt8 =` → **0 处**），那批 `B_TAB / B_NUL / B_SUB` 常量是本仓库 P0.1 自己加的，属于「同样未编译」的代码，
  **不能自证**。故 `reqLongLeaveDays: Float64 = 3.0` 的依据退回更基本的一条：显式类型注解 + 浮点字面量，
  与基线 `let globalConfig = AppConfig()`、函数签名里的 `Float64` 同族，风险等级低但不等于已证实。
- ⚠️ **仍未证实（且本轮刻意不依赖）**：顶层 `func` 不加修饰符时「同包其它文件」是否可见。
  本轮把基线的全部 **20 个非 `public` 顶层 `func`**（`toBase64Url`/`signPayload`/`attendanceRowToJson`/
  `buildUserProfileJson`/`maskIdCard`/`calculateTax`/`mapPerformanceGrade`/`runMysqlFile`/`dispatchRequest` 等）
  逐个做了跨文件引用扫描 —— **跨文件引用为 0 处**（基线另有 90 个 `public func`，所有真实的跨文件调用都走这些）。
  也就是说：这条假设**既无官方条文、也无基线实例**，只是「未被证伪」。
  **本轮处置**：P3.1 新增的 15 个可测函数**一律显式 `public`**，把这条不确定性从新增代码里彻底摘除；
  既有 4 个测试文件对该假设的依赖登记为 **L-APR-2**，留给 `cjpm test` 首跑判别。

**P3.2 新增的取证结论（本轮在真实 `hrms_db` 上实测；这类结论 `git grep` 复跑不出来，故命令一并记录）**：

- ⚠️ **`mysql.exe` 跑脚本是「首错即中止」**（推翻我自己写的注释，已修）。`runMysqlFile` 的完整参数是
  `--defaults-extra-file / -D / --connect-timeout / --batch / -N / -e "SOURCE <file>"`
  （[mysql_pool.cj](./backend-cangjie/src/db/mysql_pool.cj#L184-L191)），**没有 `--force`**。
  复跑命令（三语句：成功 / 撞 `uk_notif_user_type_ref` / 成功）：

  ```powershell
  & "D:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe" --default-character-set=utf8mb4 `
    -uroot -p123456 -D hrms_db --batch -N -e "SOURCE C:/Users/<user>/AppData/Local/Temp/x.sql"
  ```

  实测输出 `ERROR 1062 (23000) at line 19 in file: '...x.sql': Duplicate entry ...`，
  **该行之后的 5 个探测段全部无输出**、退出码 **1**；把 `INSERT INTO` 换成 `INSERT IGNORE INTO` 重跑，
  三条里应存的两条都在、退出码 **0**。⇒ 全仓推论：**任何「一个脚本拼多条语句」的写法都不得假设后续语句会继续跑**
  （`init.sql` 的种子段同理：中间一条失败，后面的种子全部不会执行）。
- **`sqlEscape` 往返保真**（实测 `HEX()`，非推断）：输入 `李'明\华"测试"` + 真实 CRLF + `换行`，
  落库 `HEX(title) = E69D8E 27 E6988E 5C E58D8E 22 E6B58B E8AF95 22 0D0A E68DA2 E8A18C`、`CHAR_LENGTH = 13`
  —— 单引号/反斜杠/双引号都以**单字节原样**存储，换行保留为真实 `0D0A`。
  读回时 `--batch` 会把 `\` 显示成 `\\`、换行显示成 `\n`，**这是客户端显示转义、不是数据被改**
  （正是 `mysql_pool.cj` 里字段反转义那一步存在的理由）。
  输出侧 `jsonEscape` 已覆盖 `\ " \r \n \t`（[response.cj](./backend-cangjie/src/common/response.cj#L8-L15)）
  ⇒ 即便通知标题里真带换行（员工名来自 CSV 导入时可能），拼出的 JSON 也不会炸。
- **表 13 的 DDL 与已在库上核对的形态**（L-NOTIF-1 要求的「第十一节记录的建表语句」即此，可直接粘贴执行）：

  ```sql
  CREATE TABLE IF NOT EXISTS sys_notification (
      id BIGINT PRIMARY KEY AUTO_INCREMENT,
      user_id BIGINT NOT NULL COMMENT '接收人(sys_user.id)',
      type VARCHAR(30) NOT NULL,
      title VARCHAR(120) NOT NULL,
      content VARCHAR(500) DEFAULT NULL,
      ref_id VARCHAR(64) NOT NULL DEFAULT '',
      read_flag TINYINT(1) NOT NULL DEFAULT 0,
      created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE KEY uk_notif_user_type_ref (user_id, type, ref_id),
      INDEX idx_notif_user_read (user_id, read_flag)
  ) ENGINE=InnoDB COMMENT='站内通知表';
  ```

  `SHOW CREATE TABLE` 实测回显：库默认 `utf8mb4_0900_ai_ci` 被显式覆盖为 **`utf8mb4_unicode_ci`**（与全库一致，
  也让 `ref_id` 的唯一键大小写不敏感）；两个索引均存在。`user_id` 用 `BIGINT` 对齐 `sys_user.id`（**不是** `INT`）。
- **`sys_user` 是空表**（`COUNT(*)` → 0，同库 `hr_employee` → 5）⇒ `notifUserMapSql` / `notifResolveUser` 的
  **命中路径本轮无法实测**，只证明了语法正确、空结果不报错。这是 L-NOTIF-3 的由来。
- **无 SDK 时新增的两项检查（脚本为临时件，不入仓，逻辑如上所述）**：
  ① `.cj` 括号 / 三引号配平（剥离 `//`、`/* */`、`"..."`、`"""..."""`、`'...'` 后再配对，并保留换行以定位行号）；
  ② 全项目跨文件调用符号解析（收集全部顶层 `public func / func / let / var` 定义 + 一份已知外部符号白名单，
  再逐文件检查被调用的标识符是否命中）。扫描面：**42 个 `.cj` 文件、476 个顶层定义**。
  结果：`notification_controller.cj`（470 行）**零未解析调用**，
  dashboard / payroll / request 对通知符号的跨文件调用全部命中且**全部 `public`**。
  该文件顶层共 **39 个 `func`，全部显式 `public`、0 个非 public**，且**没有任何顶层 `let` 常量**
  （类型白名单与文案映射都写成 `if/else` 链，见 `notifIsValidType` / `notifTypeLabel`）
  ⇒ **P3.2 新增代码对 L-APR-2 那条未证实假设的依赖为 0**，比 P3.1 更进一步。
  ⚠️ 这两项只能证明「名字与结构自洽」，**证明不了类型检查**（如 `Int64` 与 `Float64` 混用、`Option` 解包），L-CJ-1 不变。

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

### 11.2 文档计数纪律（P2.2 建立，起因是本文档自己犯过一次口算错）

P1.3 收口时把 mock 覆盖量写成「**29 个接口**」，沿用数轮到 P2.2 才被发现：实测 `mock-server.ts` 里
`if (method ===` 的分发条目只有 25 条（P2.2 后 27 条，P2.4 后 28 条，P3.2 后 32 条），`src/api/hrms.ts` 的 `*Api` 导出是 47 个，
**两个口径都得不出 29**。这类数字一旦进入文档就会被后续章节当事实引用，危害等同于代码里的错断言。

**规则**：写入本文档的**任何计数**（接口数、用例数、断言点数、文件数、行数）必须满足：
1. 附**可复跑的测量命令**（`Select-String ... | Measure-Object` / `git diff --shortstat` / Playwright 汇总行）；
2. 明确**统计口径**（"分发条目数" 与 "接口数" 不是一回事，必须写清是哪一个）；
3. 该数字**变了必须同步改**，改不动就在原处标注"截至 X 轮"。

本轮据此重算并订正的三处：第四节「29 个接口」→ 27 条分发条目；`L-MOCK-1` 与第四节的用例数 → **51 passed**；
第十二节新增 12.11 记录导入功能的前后端契约测量值。

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

### 12.11 P2.2 前端链路的测量值（全部为命令实跑输出，非口算）

**E2E 清单**（测量命令：`npx playwright test --workers=1 --reporter=line`，工作目录 `frontend-web`）

| spec | 用例数 | 来源 |
| --- | --- | --- |
| auth / rbac-menu / attendance / payroll / approval | 42 | P1.3 既有 |
| **employee-import** | **9** | **P2.2 新增** |
| 合计 | **51 passed** | `--workers=1`；按 CI 等价条件（`CI=true` + `E2E_CHANNEL=chromium`，Playwright 自建 dev server）复跑得 **51 passed (47.9s)** |

`employee-import.spec.ts` 的 9 条逐个存在理由（不是凑覆盖率）：

| # | 用例 | 钉住的行为 | 若删掉会失去什么 |
| --- | --- | --- | --- |
| 1 | 下载模板 | 模板 13 列名与后端 `empImportHeader()` **逐字**相同、`\uFEFF` 起头、示例部门取自种子 | 后端改列名而前端模板不改 ⇒ 用户下载即报错 |
| 2 | 预检不写库 | `dryRun` 语义：返回 `total/imported:[]` 但列表**真的没变** | 「只校验」实现成「偷偷写入」 |
| 3 | 取消预检后正式导入 | 两次提交间状态复位 + 导入后按工号可检索 | 前端只改了 mock 内存而列表没回读 ⇒ 假绿 |
| 4 | 行级错误定位 | 第 2 行部门不存在、第 3 行手机号非数字，**合法行仍不写库** | 12.10 的「策略在调用方」这条设计失效无人发现 |
| 5 | 文件内工号重复 | `工号 X 在本次文件内重复` 走的是**批内去重**，与「已存在于系统」是两条分支 | 重复行被静默合并成一条 |
| 6 | 带 BOM 不误报 | 前端 `replace(/^\uFEFF/,'')` 生效，表头判定不被 BOM 破坏 | Excel 存的 CSV 一律被判「表头不匹配」 |
| 7 | 引号内逗号/换行 | 单字段含 `,` 与 `\n`，且**错误行号报物理行 4 而非逻辑第 2 条** | 12.10 第 9/10 组的行号语义在前端侧无人验证 |
| 8 | MANAGER 无入口 | 能看到花名册、看不到「批量导入」（后端 `requireRoles(["ADMIN","HR"])`） | 权限只靠后端拦，前端漏出入口按钮 |
| 9 | EMPLOYEE 直达被拦 | 路由守卫在挂载前退回 `/dashboard` | 无权角色进得来页面，只剩接口 403 |

**代码量测量**（`git diff --stat` + `Get-Content .Count`）

| 文件 | 变化 |
| --- | --- |
| `frontend-web/src/api/hrms.ts` | +25 |
| `frontend-web/src/views/employee/EmployeeView.vue` | +325（现 843 行） |
| `frontend-web/e2e/support/mock-server.ts` | +311（现 1482 行） |
| `frontend-web/e2e/employee-import.spec.ts` | 新增 222 行 |
| 合计 | **883 行**（含空行与注释） |

**静态闸门实测**：`npm run typecheck` exit 0 / `npm run lint`（`--max-warnings 0`）exit 0 / `npm run build` exit 0（仅 `echarts` chunk >500 kB 的既存体积提示）。

### 12.12 P2.3 打印链路的测量值（每条附复跑命令，口径见 11.2）

改动量（cwd `frontend-web`，命令 `git diff --numstat -- src/views/payroll/PayrollView.vue src/style.css`；spec 为新文件，行数取 `(Get-Content …).Count`）：

| 文件 | 实测 |
| --- | --- |
| `src/views/payroll/PayrollView.vue` | **+196 / −2**（350 → 544 行） |
| `src/style.css` | **+156 / −0**（24 → 180 行） |
| `e2e/payroll-print.spec.ts` | 新增 **251 行** / **6 个 `test(`** / **61 处 `expect(`** |
| 合计 | **603 行**（含空行与注释） |

计数命令（`expect(` 与 `test(` 用 `Select-String -Pattern … | Measure-Object`，与上表同一口径）：

```powershell
(Get-Content src\views\payroll\PayrollView.vue).Count   # 544
(Get-Content src\style.css).Count                       # 180
(Get-Content e2e\payroll-print.spec.ts).Count           # 251
(Select-String -Path e2e\payroll-print.spec.ts -Pattern '^\s*test\(' | Measure-Object).Count   # 6
(Select-String -Path e2e\payroll-print.spec.ts -Pattern 'expect\(' | Measure-Object).Count      # 61
```

验证结果（`npx playwright test --workers=1 --reporter=line`，末行汇总）：**57 passed (1.5m)**，
其中 `payroll-print.spec.ts` 6 例（首跑 1 failed → 修 `exact: true` 后全绿，见第九节「P2.3 用例首跑纠偏」）。
`npm run build` 亦为 exit 0，专版 CSS 随 `dist/assets/index-*.css` 一并产出（不是运行时注入）。

纸面产物的实测（不是「看起来对」，是从文件字节里读出来的）：

| 断言 | 命令 | 实测值 |
| --- | --- | --- |
| PDF 确为 A4 | 用例 `page.pdf({preferCSSPageSize:true})` 落盘后，`[regex]::Matches($t,'MediaBox\s*\[[^\]]*\]')` | 命中 3 处且**全为** `[ 0 0 594.96 841.92 ]`（Chromium 把页面尺寸写进多个对象），即 210×297mm |
| 单页不成册 | 同上取 `/Count \d+` | `/Count 1` —— 3 处 MediaBox 是对象冗余，不是 3 页 |
| 是合法 PDF | 用例内 `fs.readFileSync(pdf).subarray(0,5).toString('latin1')` | `%PDF-`（`expect` 断言，红了就 fail） |
| 人眼复核 | `test-results/payslip-print.png`（gitignore） | 无侧边栏、无表格、无遮罩；三张小表 + 绿框复算文案 + 页脚说明 |

纸质件金额（`payroll-print.spec.ts` 的 `CHEN` 常量，与 `payroll.spec.ts` 同源逐位推导）：
应发 `￥19000.00 + ￥1710.00 + ￥491.38 = ￥21201.38`，
代扣 `-￥923.56 −￥3515.00 −￥966.28 = −￥5404.84`，实发 `￥15796.54` —— 三个数由**前端 `slipCheck` 独立复算**得出，
用例同时断言页脚文案与记账 `netSalary` 一致，所以「打印件数字与后端一致」不是靠肉眼比对两张页面得出的结论。

### 12.13 P2.4 考勤月度汇总的测量值（每条附复跑命令，口径见 11.2）

改动量（cwd 仓库根，命令 `git show --numstat --format="" 8195ff2`）：

| 文件 | 实测 |
| --- | --- |
| `backend-cangjie/src/controller/attendance_controller.cj` | **+248 / −4** |
| `backend-cangjie/src/controller/attendance_controller_test.cj` | 新增 **+539 / −0** / **19 个 `@TestCase`** |
| `backend-cangjie/src/main.cj` | +3 / −0 |
| `frontend-web/src/views/attendance/AttendanceView.vue` | **+202 / −1**（358 → 559 行） |
| `frontend-web/src/api/hrms.ts` | +36 / −0 |
| `frontend-web/e2e/support/mock-server.ts` | +132 / −8 |
| `frontend-web/e2e/attendance-summary.spec.ts` | 新增 **220 行** / **7 个 `test(`** / **50 处 `expect(`** |
| `frontend-web/e2e/payroll.spec.ts` | +33 / −0（260 → 293 行，新增 1 例） |
| `frontend-web/src/views/payroll/PayrollView.vue` | +28 / −4（导出改翻页） |
| 提交合计 | **9 files / 1441 insertions(+), 17 deletions(-)** |

计数命令（cwd `frontend-web`；`(Get-Content …).Count` 与 `Select-String … | Measure-Object`）：

```powershell
(Get-Content src\views\attendance\AttendanceView.vue).Count   # 559
(Get-Content e2e\attendance-summary.spec.ts).Count             # 220
(Get-Content e2e\payroll.spec.ts).Count                        # 293
(Select-String -Path e2e\attendance-summary.spec.ts -Pattern '^\s*test\(' | Measure-Object).Count   # 7
(Select-String -Path e2e\attendance-summary.spec.ts -Pattern 'expect\(' | Measure-Object).Count      # 50
# mock 分发条目（全文档统一口径 = 行首 4 空格的 `if (method ===`，见 11.2）
(Select-String -Path e2e\support\mock-server.ts -Pattern '^    if \(method === ' | Measure-Object).Count   # 28
# 后端单测总数（`-Path` 不支持 `**`，必须走 Get-ChildItem -Recurse）
(Get-ChildItem -Path ..\backend-cangjie\src -Recurse -Filter *_test.cj | Select-String -Pattern '@TestCase' | Measure-Object).Count   # 242
```

验证结果（`npx playwright test --workers=1 --reporter=line`，末行汇总）：**65 passed / 0 failed**（8 个 spec 文件），
`npx playwright test --list` 亦为 `Total: 65 tests in 8 files`，两个口径互相印证。
`npm run typecheck` / `npm run lint`（`--max-warnings 0`）/ `npm run build` 三连 exit 0。
仓颉侧 **19 个新用例从未执行**（L-CJ-1），期望值全部用 node 独立复算，见下表。

汇总数字的独立复算（分母恒为 `22 × 人数`，因为 L-ATT-1）：

| 口径 | 手算 | 断言值 |
| --- | --- | --- |
| 全员 5 人 / 合计出勤 2 天 | `2 / (22×5) = 1.8181…` | `1.82%` |
| `EMP20260004`（唯一迟到者，2 天） | `2 / 22 = 9.0909…` | `9.09` |
| `EMP20260004` 迟到明细 | 1 次 / 20 分钟；请假 1 天；加班 3 h（仅 `APPROVED`） | 卡片 `1 / 0`、`20 / 0`、`1 天 / 3 h` |
| 整月无打卡者 | `0 / 22 = 0` | 渲染为 `0`（**不是** `0.00`，表格直接输出 number） |
| 切 `2026-08` | `EMP20260003` 1 天 → `4.5454…` | `4.55`；`EMP20260002` → `0` |
| MANAGER 限本部门 3 人 | `2 / (22×3) = 3.0303…` | `3.03%` |
| CSV 合计行 | `N` 人 → 应出勤总天数 `N × 22` | `5 人` / `110` |

`attendance_controller_test.cj` 的 19 个用例分组：谓词（`attMonthIsLate` / `attMonthIsEarly` 的状态标记与分钟数四象限）、
出勤率边界（`≤0` 分母、`>100` 封顶、`round2`）、`attMonthSafeNum` **拒绝集**（`1e5` / `NaN` / `Infinity` / `12,345` / `+5` / 空串 / 双点）、
`isValidYearMonth`（长度 7、`bytes[4]==0x2D`、月 `01..12`、非 `2` 字头年份）、单人 JSON **整串 pin**（12 键逐字对齐）、
合计行 10 键、页面与导出的结构计数。

### 12.14 P3.1 长假二级审批的测量值（每条附复跑命令，口径见 11.2）

变更规模（`git diff --numstat`，工作区未提交时实测；⚠️ 该命令统计的是**已跟踪文件**，新增的测试文件不在其中）：

```
66  2   FOLLOWUP_PLAN.md
1   1   backend-cangjie/src/controller/dashboard_controller.cj
239 28  backend-cangjie/src/controller/request_controller.cj
245 1   frontend-web/e2e/approval.spec.ts
191 16  frontend-web/e2e/support/mock-server.ts
88  8   frontend-web/src/views/approval/ApprovalView.vue
22  4   sql/init.sql
+ 405 行（未跟踪）backend-cangjie/src/controller/request_controller_test.cj
```

仓颉单测总量（`@TestCase` / `@Assert` 均以 `Select-String` 实测，非累加口算）：

```powershell
Get-ChildItem -Path backend-cangjie/src -Recurse -Filter *_test.cj | ForEach-Object {
  "{0,-42} TC={1,-4} AS={2}" -f $_.Name,
    (Select-String -Path $_.FullName -Pattern '@TestCase' | Measure-Object).Count,
    (Select-String -Path $_.FullName -Pattern '@Assert\(' | Measure-Object).Count }
```

| 测试文件 | `@TestCase` | `@Assert` |
| --- | --- | --- |
| `crypto_util_test.cj` | 22 | 103 |
| `jwt_util_test.cj` | 26 | 85 |
| `response_test.cj` | 26 | 188 |
| `router_test.cj` | 13 | 57 |
| `attendance_controller_test.cj` | 19 | 142 |
| `employee_import_test.cj` | 35 | 300 |
| `payroll_controller_test.cj` | 32 | 267 |
| `performance_controller_test.cj` | 30 | 205 |
| **`request_controller_test.cj`（P3.1 新增）** | **33** | **100** |
| `rate_limit_test.cj` | 39 | 163 |
| **合计 / 10 个文件** | **275** | **1610** |

> 订正：第三节 P1.1 的「7 个测试文件 / 188 个 `@TestCase`」是 P1.1 收口时的快照，P2.1/P2.4/P3.1 各加了 1 个文件，
> 现为 **10 文件 / 275 用例 / 1610 断言**。所有仓颉用例依旧**从未执行**（L-CJ-1）。

mock 分发条数与 E2E：

| 项 | 实测值 | 复跑命令 |
| --- | --- | --- |
| `mock-server.ts` 分发条目 | **28**（P3.1 未新增路由，只重写 `onApproveRequest` 语义；P3.2 后为 **32**，见 12.15） | `(Select-String -Path frontend-web/e2e/support/mock-server.ts -Pattern 'if \(method ===' \| Measure-Object).Count` |
| `approval.spec.ts` 用例数 | 7 → **10** | `npx playwright test e2e/approval.spec.ts --list` |
| 全量 E2E | **68 passed / 0 failed**（此前基线 65） | `npx playwright test --workers=1` → `1.3m` |
| 静态口径互证 | `Total: 68 tests in 8 files` | `npx playwright test --list` |
| 前端三连 | `typecheck` / `lint --max-warnings 0` / `build` 均 exit 0；`✓ built in 7.79s` | `npm run typecheck; npm run lint; npm run build` |

P3.1 状态机的 ground truth（仓颉与 TS 两份实现**必须逐格相同**，node 复算命令见下）：

| 输入 | `reqInitialStatus` | `reqCurrentLevel` | `reqNextStatus(..,"APPROVED")` | 扣年假 |
| --- | --- | --- | --- | --- |
| `LEAVE / ANNUAL / 4 天` | `PENDING_MGR` | 1 | `PENDING_HR` | **否** |
| 上者二级通过 | — | 2 | `APPROVED` | **是，且仅此一次** |
| `LEAVE / ANNUAL / 3 天`（严格大于才分级） | `PENDING` | 1 | `APPROVED` | 是 |
| `LEAVE / ANNUAL / 5 天`（余额恰为 5） | `PENDING_MGR` | 1 → 2 | 两步到 `APPROVED` | 5 → 5 → **0** |
| `OVERTIME / 12 h` | `PENDING`（加班不参与分级） | 1 | `APPROVED` | 否 |
| 任意态 + `action="REJECTED"` | — | — | `REJECTED`（驳回不分级） | 否 |
| 任意态 + `action` 不在白名单（如 `"XX"`） | — | — | `""` ⇒ handler 直接 400 | 否 |
| `APPROVED` / `REJECTED` / `CANCELLED` | — | **0**（终态） | ⚠️ 仍返回 `APPROVED` —— **`reqNextStatus` 不看当前态是否终态**，拦下重复审批的是 handler 前置的 `reqIsPendingLike` 与「已处理」400 | 否 |

> 这一格是刻意写进文档的**契约陷阱**：`reqNextStatus` 是纯「本级动作 → 下一状态」映射，
> 终态防护由调用点的 `reqIsPendingLike(status)` 负责。若有人只测 `reqNextStatus` 就以为重复审批被挡住了，
> 会得出完全相反的结论。E2E 用例②「终态后直连接口 → 400 `该申请单已处理，无法重复审批`」正是钉在这条调用顺序上。

```powershell
# 两份实现交叉核对：直接跑 E2E 的 3 个新用例，它们同时断言 UI、HTTP 与 mock 内部状态
npx playwright test e2e/approval.spec.ts --grep "长假" --workers=1
```

### 12.15 P3.2 站内通知中心的测量值（后端 `b4427b1` + 前端/测试本次提交）

> 本节分两次写：①~④ 是后端那一批的实测值与欠债清单；⑤ 记录欠债的兑付情况；⑥ 是第二批（单测/前端/mock/E2E）的测量值。
> 所有数字取自命令实跑输出（11.2 纪律），不写「大约」。

**① 本次提交的逐文件 `numstat`（对比 `HEAD`，即 `7174898`）**：

| 文件 | +/- | 说明 |
| --- | --- | --- |
| `backend-cangjie/src/controller/notification_controller.cj` | **470 / 0**（新增） | 39 个顶层 `func`，全部 `public`；无顶层 `let` |
| `backend-cangjie/src/main.cj` | 11 / 0 | 4 条路由（固定路径在 `:id` 之前） |
| `backend-cangjie/src/controller/request_controller.cj` | 10 / 0 | 终态通知 + `PENDING_HR` 逐个提醒在职 HR |
| `backend-cangjie/src/controller/dashboard_controller.cj` | 9 / 1 | `case Some(_) =>` → `case Some(u) =>` + 到期批量提醒（角色门控） |
| `backend-cangjie/src/controller/payroll_controller.cj` | 8 / 1 | 单条发薪 SELECT 追加 `p.employee_id`；批量发薪改**先取行后更新** |
| `sql/init.sql` | 19 / 0 | 表 13 `sys_notification` |
| `FOLLOWUP_PLAN.md` | 本文档增量 | 不计入代码分子（13.5 口径 1） |

代码口径累计（排除本文档、对比基线 `6e79923`，含暂存区）：**53 files / 13599 insertions(+), 142 deletions(-)**，
即 13599 / 27803 ≈ **48.9%**（P3.1 提交后为 13073 ≈ 47%）。

**② 表 13 在真实库落地后的 `SHOW CREATE TABLE` 关键回显**（不是 `init.sql` 的文本，是库里的实际形态）：

| 项 | 实测值 |
| --- | --- |
| collation | `utf8mb4_unicode_ci`（库默认是 `utf8mb4_0900_ai_ci`，被表选项覆盖） |
| 唯一键 | `UNIQUE KEY uk_notif_user_type_ref (user_id, type, ref_id)` |
| 索引 | `INDEX idx_notif_user_read (user_id, read_flag)` |
| `user_id` | `bigint`（对齐 `sys_user.id`） |
| `created_at` | `datetime NOT NULL DEFAULT CURRENT_TIMESTAMP` |
| `AUTO_INCREMENT` | 建表后为 **1**，本轮全部探测做完（已清理）为 **7**。逐条对得上：A 段 1 次 + 批量段 2 次（第 3 条因脚本中止**根本没执行**，不占号）+ IGNORE 段 3 次 = **6 次分配** ⇒ 下一个 id 是 7 |
| 清理确认 | `SELECT COUNT(*) FROM sys_notification` → **0**（探测行用 `user_id IN (990001,990002)` + `ref_id LIKE 'ZZP32:%'` 隔离，未碰任何业务数据；`hr_employee` 仍为 5 行） |

> ⚠️ 顺带记一条容易被误读的现象：**撞唯一键的 INSERT 也会吃掉一个自增 id**（MySQL 先分配再判重），
> 所以这张表的 `id` 天然有洞、`COUNT(*)` 与 `AUTO_INCREMENT` 对不上是**正常**的，
> 别拿它当「数据丢了」的证据；真要核对用 `ref_id`，不要用 `id` 连续。

**③ 本轮拿到的 4 组实测结论**（详细论证在第十一节「P3.2 新增的取证结论」，此处只留可核对的数字）：

| 探测 | 结果 |
| --- | --- |
| 三语句脚本（成功/撞 UNIQUE/成功），`mysql.exe` 无 `--force` | `ERROR 1062 at line 19` ⇒ **其后全部语句未执行**，exit **1** |
| 同上改 `INSERT IGNORE` | B1、B2 **都在**，exit **0** ⇒ `notifInsertSql` 已据此改写 |
| 转义往返（`'`、`\`、`"`、真实 CRLF） | `CHAR_LENGTH = 13` 与输入等长；`HEX` 显示 `27 / 5C / 22 / 0D0A` 均为单字节原样 |
| 纯函数镜像自检（9 项：注入串、限额、空 `IN` 列表、非法 type…） | **9 / 9 通过**，含 `notifStrList([]) == "''"`（回落值错误会让整条 SQL 语法失败） |

**④ 第一批的前端三连（那一轮零前端改动，跑它是为了证明「没被我带崩」而非「我做了前端」）**：
`vue-tsc --noEmit` exit **0** / `eslint --max-warnings 0` exit **0** / `npm run build` exit **0**（`✓ built in 7.92s`，
唯一告警是既存的 chunk > 500 kB 提示）。`npx playwright test --list` 当时仍为 **68 tests in 8 files**，未增删用例
——第二批加入 `notification.spec.ts` 后为 **77 tests in 9 files**，三连与全量的最新值见下方 ⑦。

**⑤ 上一轮的欠债清单——本轮（P3.2 第二批）兑付情况**：
1. ✅ `notification_controller_test.cj`：727 行 / **64 `@TestCase` / 164 `@Assert`**，39 个纯函数里可脱离数据库的
   全部覆盖，期望值由 `TEMP` 下两份 node 镜像脚本**独立复算 + 整行逐字回核**（第一批 39 pins、第二批 56 pins，
   各 0 MISS）。⚠️ 两条踩坑记录见下方 ⑥。
2. ✅ `src/api/hrms.ts` 4 个接口 + `NotificationItem/NotificationListResult`；`AppLayout.vue` 顶栏
   `el-badge`（`:max="99"`、`unread===0` 隐藏）+ 抽屉列表 + `onMounted` 30s `setInterval` / `onBeforeUnmount` 清理
   + 按 `type` 跳转（`PAYROLL_PAID`→`/payroll?tab=my`、`LEAVE_NEXT_LEVEL`→`/approval?tab=approve`、
   `LEAVE_APPROVED/REJECTED`→`/approval`、`CONTRACT_EXPIRING`→`/employee`，与文档里预写的 `/payroll/my`、
   `/employees` 不同——**以路由表为准**，`main.ts` 里根本没有这两条路径）。
3. ✅ `mock-server.ts` 4 条分发：**分发数 28 → 32**（第三节与 11.2 口径已同步）；`unread-count` / `read-all`
   两条固定路径同样排在 `/notifications/:id/read` 之前，镜像后端的路由顺序坑。
4. ✅ `e2e/notification.spec.ts`：351 行 / 9 用例，覆盖验收项「发薪后铃铛出现未读且点击跳工资条」、
   重复发薪不产生第二条、单条已读只减 1 不清零、通过/驳回两条 ref 互不吞掉、长假 `LEAVE_NEXT_LEVEL` 只发一次、
   合同到期仅 HR/ADMIN、全部已读与重复点击、越权 PUT 他人通知 **404 且对方仍是未读**、脏 `readFlag`/`limit=9999` 回落。
5. ⬜ 建 `sys_user` 测试账号补命中路径——**仍欠**（见更新后的 L-NOTIF-3）。

**⑥ 本轮新增的取证与踩坑（三条都是现场撞出来的，不是推演）**：
| # | 现象 | 结论 / 处置 |
| --- | --- | --- |
| 1 | 我给「内容里同时含 `'` 与 `\`」写的单测期望永远为假 | 起因是把仓颉**输入字面量**写成了已转义的形状（`"含\\'引号\"和\\\\斜杠"` 解码后带多余反斜杠），与镜像里的 `js` 串不一致。`sqlEscape` 只处理 `\` `'` CR LF、**不转义 `"`**，`jsonEscape` 反之**不转义 `'`**——两个方向混在一条断言里必然对不上。拆成「只含单引号」与「只含反斜杠」两条，逐条按规则重算后 39/39 命中 |
| 2 | `el-drawer` 让 3 个既存用例红（`locator('header')` strict mode 命中 2） | 抽屉自带的标题行渲染成语义 `<header>`，与布局顶栏同名，**即使抽屉从未打开也在 DOM 里**。改为 `:with-header="false"` + 正文首行自绘标题（`aria-label` 仍取 `title`），不动任何既存断言 |
| 3 | 全局铃铛把两条「本模块不该发别的接口」的断言打成红 | `payroll.spec.ts:89` 与 `rbac-menu.spec.ts` 的 `trackProtectedApi` 都是**路由级越权闸门**，而 `unread-count` 属于布局级轮询，任何页面都会发。只在两处白名单里加 `/api/v1/notifications/unread-count` 这一条**具体路径**（刻意不放整段 `/notifications`，抽屉列表仍必须用户点开才会发） |
| 4 | 第二次 `signIn(page, ...)` 一律 30s 超时 | 同一 context 已持有 token，`/login` 被 `router.beforeEach` 弹回首页，`请输入用户名` 永不出现。**换角色必须走 `openRole()`**（新 context = 新 localStorage）；另外顶栏未读数只在 `onMounted`/开抽屉时刷新，页内原地触发的新通知不会自己变红点 |
| 5 | 用例里显式 `page.close()` 会漏出 vite 代理噪音 | 审批提示 `ElMessage.success` 之后组件还在 `refreshProfile` + 两个列表刷新，提前关上下文把在途请求甩给了 8080（表现为 `ECONNREFUSED`）。fixtures 的 teardown 本就统一回收，**删掉显式 close** 即可 |

**⑦ P3.2 第二批测量值（全部内联命令实跑，逐条可复跑；⚠️ 勿用 `powershell -File` 取数，见第九节日志「计量纠偏（第三次）」）**：

| 对象 | 实测 | 复跑命令 |
| --- | --- | --- |
| `notification_controller_test.cj` | **727 行 / 64 `@TestCase` / 164 `@Assert`**（原目标 ≥150 AS，超额 9%） | `(Get-Content ...notification_controller_test.cj).Count`；条数用 Grep 计数 |
| `e2e/notification.spec.ts` | **351 行 / 9 `test(`** | 同上 |
| `mock-server.ts` | **2066 行**，`if (method ===` **32 条**（P3.1 为 28） | `(Select-String -Pattern 'if \(method ===' \| Measure-Object).Count` |
| `AppLayout.vue` / `hrms.ts` | **337 行**（+113）/ **188 行**（+15） | 同上 |
| `vue-tsc` / `eslint src` / `npm run build` | **exit 0**（`build 17.27s`，唯一告警是既存 chunk > 500 kB） | 三连 |
| `playwright test --list` | `Total: 77 tests in 9 files`（原 68 / 8 files） | `npx playwright test --list` |
| 全量 E2E | **77 passed / 0 failed**（`--workers=2`，2.0m），`mock.unmatched == []` 闸门全绿 | `npx playwright test --reporter=line` |

⚠️ 一处**故意没有做**：抽屉列表接口对「本人之外」的数据可见性完全依赖后端 `WHERE user_id = ?`，
我没有为它单独加安全断言——按用户本轮指令（「适当减轻那些如安全性的开发内容，因为体现不出工作量大小」），
这部分只在 ⑤4 里留了一条越权 404 的 E2E 兜底，不再展开注入面/矩阵类工作。

### 12.16 P4.1 培训与学分（后端切片，本次提交）的测量值

> 本批只交付**后端 + 仓颉单测**，前端视图 / mock 分发 / E2E 留作下一批（原因见本节 ⑤ 与第九节 11-26 行）。
> 这与 P3.2 的两段式交付同构（`b4427b1` 后端 → `62a42e8` 前端/测试），刻意不把半成品混进一个提交里。

**① 逐文件 `numstat`（对比 `HEAD`，即 `62a42e8`）**：

| 文件 | +/- | 说明 |
| --- | --- | --- |
| `backend-cangjie/src/controller/training_controller.cj` | **1478 / 0**（新文件） | 培训域全部业务逻辑；行号索引见 ② |
| `backend-cangjie/src/controller/training_controller_test.cj` | **1070 / 0**（新文件） | 36 个 `@test` 类 / 93 个 `@TestCase` / 255 个 `@Assert`，见 ③ |
| `backend-cangjie/src/main.cj` | 23 / 2 | 11 条路由注册（固定段 `available`/`my`/`stats` 必须排在 `/:id` 之前） |
| `sql/init.sql` | 64 / 4 | 表 14 `hr_training`（L358）+ 表 15 `hr_training_record`（L380）+ 种子（L996+） |
| `backend-cangjie/src/controller/notification_controller.cj` | 2 / 0 | `TRAINING_PUBLISHED` 接入 `notifIsValidType` / `notifTypeLabel`（「培训新课上线」） |
| **合计** | **5 files / 2637(+), 6(−)** | 命令：`git diff --cached --numstat HEAD -- . ":(exclude)FOLLOWUP_PLAN.md"` |

**② `training_controller.cj` 的结构（`Select-String '^public func'` 实测行号，可复跑）**：
纯函数区 46 个（`trainingIsValidStatus:28` 起，含状态机 `trainingStatusTransition:83`、钳位 `trainingClamp*:133/141/154`、
学分折算 `trainingCreditOf:167`、名额 `trainingCapacityLeft:182`、五道闸门 `trainingAudienceDenied:194` /
`trainingSignupDenied:207` / `trainingCheckinDenied:224` / `trainingUnsignupDenied:245` / `trainingResultDenied:262`、
SQL 生成 20 个、行→JSON 6 个），处理器 11 个（`handleTrainingList:738` … `handleTrainingResult:1193`）。
**路由与处理器 1:1**：main.cj 11 条 ↔ 11 个 handler，无孤儿注册、无未挂路由的 handler。

**③ 仓颉单测的结构测量（`node check_test.js` 实跑输出，非估算）**：

```
lines=1071 classes=36 testcases=93 asserts=255
dup=[]            # 无重复 @test 类名
over3=[]          # 无单类 >3 个 @TestCase（11.2 纪律）
braceDepth=0 negative=0
oddQuoteLines=[482] count=1
```

`oddQuoteLines=[482]` 已单独复核，**是自检脚本的误报、不是代码缺陷**：该行含字面量 `"\\"`
（转义反斜杠紧跟闭引号），脚本「前一字符是 `\` 即视为转义」的规则无法处理 `\\` 自身的转义。
手工按仓颉词法逐字符配对：串 1 `"\\"` = 单个反斜杠，串 2 为 expected，均闭合。

**④ 期望值的生产方式（本机无仓颉 SDK，L-CJ-1 的替代取证链）**：
`training_controller_test.cj` **不是手写的**，由三个 node 脚本程序化生成，避免手抄长 SQL 串造成字节漂移：

| 脚本 | 作用 | 实测输出 |
| --- | --- | --- |
| `train_mirror.js` | 逐字复刻仓颉纯函数 + 从 `.cj` 里抽取 `"""` SQL 模板 | — |
| `train_gen.js` | 生成规则/SQL 用例的期望值 | `cases=144 lines=288`，无 BAD CASE |
| `train_testgen.js` | 渲染整个 `.cj` 测试文件 | `classes=36 testcases=93 asserts=255 lines=914`（+157 行辅助/注释 = ③ 的 1071） |

生成链纠错两处（都属**镜像与真实实现不一致**，若不修会污染整批 SQL 断言）：
1. `formatNum2` 镜像原用 `Math.round(f*100)/100`，产出 `1.5`；真实 `response.cj` 用 cents 算法，
   产出 **`1.50`**（永远两位小数）。已按源码逐字重写，影响 `trainingInsertSql` / `trainingUpdateSet` /
   `trainingCreditChangedSql` / `trainingSettleCreditSql` / `trainingResultSql` 五处期望串。
2. `templates()` 原按「含 `${` 的行」抽模板，漏掉纯常量串 `trainingScoreAvgSql` / `trainingCoveredEmpSql`；
   放宽为「函数体内全部字符串字面量」后补齐。

**⑤ 一条编译风险的反向结论（差点改错）**：
`training_controller.cj:1026` 在 `"..."` 单行串的 `${}` 里嵌了 `"0"`（`trainingNumCol(o, 0, "0")`）。
我先按「基线无先例」判定为风险，写了 `chk_nest.js` 全库扫描 35 个 `.cj`：命中 6 行，其中 **5 行属基线已编译代码**
（`auth_controller.cj:34`、`system_controller.cj:35`、`attendance_controller.cj:164`、
`performance_controller.cj:35`、`dashboard_controller.cj:119`）⇒ 该写法在仓颉中合法，**不改**。
先前的「0 先例」结论是我第一版 grep 正则（只匹配 `${函数(`）+ `head_limit` 截断共同造成的假阴性。

**⑥ 真库（MySQL 8.0 / `hrms_db`）实测**：
`verify_training.sql` 13 组 SQL 全部跑通；要点三条——
时间语义交给 `TIMESTAMPDIFF`（非法日期 → `NULL` → `querySingleInt(..., -1)` 回退 −1 → 谓词 false；跨度符号 +480/−480 正确）、
`AVG(score)` 输出 `71.50000`、`IFNULL(CAST(r.score AS CHAR),'null')` 输出字面量 `null`
（这是「未考核 ≠ 0 分」在 SQL 侧的落地方式，仓颉侧对应 `-1.0` 哨兵）。
受众命中路径复测：`dept_id=2` 的课命中 user id 3、4；`dept_id=0` 的全员课命中 4 行。
演示账号由 `seed_users.sql` 补齐（admin/hr/manager/emp01，口令 `123456`，
哈希用 `SHA2(CONCAT('HRMS_CANGJIE_2026_SALT:','123456'),256)` 直接 SQL 复现）。

**⑦ 本批明确未做（下一批的确定范围，不含任何安全类工作）**：
`api/hrms.ts` 培训 API 与 interface、`views/training/TrainingView.vue`、`router/index.ts` 的 `meta.roles`、
`AppLayout.vue` 的 `menuItems` 与 `notifRoutes`（`TRAINING_PUBLISHED` → `/training`）、
`mock-server.ts` 约 10 条分发、`e2e/training.spec.ts`、`rbac-menu.spec.ts` 四个角色的 `MENUS` 数组，
以及三连（`vue-tsc` / `eslint --max-warnings 0` / `build`）与全量 Playwright（基线 **77 passed / 9 files**）。
**接口契约已按源码钉死**（后端出参键名，前端 interface 的唯一依据）：
计划行 15 列含 `credit`/`signedCount`/`attendedCount`；员工课程行 17 列含 `capacityLeft`/`canSignup`/`canCheckin`/
`canUnsignup`/`blockReason`/`myStatusLabel`；记录行 13 列用 `courseCredit`（与计划行的 `credit` **不同名**，
这是最容易被前端抄错的一处）；名册 11 列；排行 4 列；课程统计 6 列。

### 12.17 P4.1 培训与学分（前端 + E2E，本次提交）的测量值

> 本节兑付 12.16 ⑦ 的欠债清单，P4.1 至此走完「建表 → 控制器 → 路由 → api → 视图 → meta.roles → 菜单 → mock → E2E」闭环。

**① 逐文件 `numstat`（对比 `HEAD` = `77080dd`，命令 `git diff --cached --numstat HEAD -- . ":(exclude)FOLLOWUP_PLAN.md"`）**：

| 文件 | +/- | 说明 |
| --- | --- | --- |
| `src/views/training/TrainingView.vue` | **844 / 0**（新文件） | 4 个 tab + 新建/编辑弹窗 + 花名册录入弹窗，行号索引见 ② |
| `src/api/hrms.ts` | 144 / 0 | 6 个 interface + 11 个 `*Api`，与后端 11 条路由 **1:1** |
| `src/router/index.ts` | 6 / 0 | `/training` 路由，`meta.roles` 为**四角色全放行**（培训面向全员） |
| `src/layout/AppLayout.vue` | 5 / 1 | 菜单项插在「招聘管理」之后、「系统与审计」之前；`notifRoutes` 加 `TRAINING_PUBLISHED` |
| `e2e/support/mock-server.ts` | **767 / 0** | 分发 **32 → 43 条**（`Select-String 'if \(method ==='` 实测），含培训状态机与请求日志 |
| `e2e/training.spec.ts` | **457 / 0**（新文件） | 3 个 describe / **17 个 `test()`**，展开后 **13 条用例**（另 4 条是 `for` 生成的角色参数化） |
| `e2e/rbac-menu.spec.ts` | 4 / 4 | 四个角色的 `MENUS` 数组各插「培训与学分」 |
| **合计** | **7 files / 2227(+), 5(−)** | |

**② `TrainingView.vue` 的 tab 与权限门（`canManage = ADMIN ∥ HR`）**：

| tab `name` | 文案 | 可见性 | 后端接口 |
| --- | --- | --- | --- |
| `plans` | 培训计划 | `v-if="canManage"` | `GET /trainings` |
| `available` | 可报名培训 | 全员 | `GET /trainings/available` |
| `my` | 我的培训 | 全员 | `GET /trainings/my` |
| `stats` | 学分统计 | `v-if="canManage"` | `GET /trainings/stats` |

默认落地 tab 按角色分流：`canManage → plans`，否则 `available`；通知跳转用 `route.query.tab` 覆盖默认值。

**③ ★ 角色口径纠偏（后端源码为准，推翻 12.16 ⑦ 的记述）**：
`Select-String 'requireRoles'` 实测 `training_controller.cj` 的 11 个 handler 闸门为——
ADMIN/HR/MANAGER 三处（`handleTrainingList:738`、`handleTrainingStats:987`、`handleTrainingRoster:1031`），
ADMIN/HR 三处（`Create:769` / `Update:816` / `Result:1193`），其余五处仅 `requireAuth`。
12.16 ⑦ 把 stats 记成 ADMIN/HR 是**我上一批的误记**。mock 分发已逐条对齐真实角色（L1292-1302）。
**有意保留的差异**：MANAGER 能取 `stats`/`records` 的数据，但前端不给入口（`stats` tab 仍只认 `canManage`）。
理由不是遗漏——培训统计页放在经理菜单里会与 P1.3「菜单即权限」的 RBAC 断言口径冲突，且经理本职是审批不是报表；
这是「后端宽、前端窄」，收紧方向安全，反向（前端给入口但后端 403）才是要防的。

**④ ★ 一个真实后端语义坑（不是前端臆造，E2E 已钉住）**：
`handleTrainingUpdate` **无条件**跑完整表单校验，所以「发布草稿」这种只改状态的操作
如果只 `PUT {status:"PUBLISHED"}` 会被打成 **400「培训主题必填」**。
前端 `publish()` / `finish()` 因此改为**回填整行完整 payload + `status`** 再提交；
`e2e/training.spec.ts:181` 那条用例直接断言 PUT body 里 `title`/`trainer`/`startTime` 等字段齐全。
> 待办（下一批顺带）：后端 `handleTrainingUpdate` 应支持 PATCH 式局部更新（只传 `status` 时跳过表单校验），
> 目前的做法是把校验负担推给调用方，多一个前端就多一份抄漏字段的风险。

**⑤ 契约落地细节（三处最容易被前端猜错的点）**：
1. `score` 用 **`-1` 当「未录入」哨兵**（后端 `getJsonFloat(obj,"score",-1.0)`），前端显示 `—` 而不是 `0`——「未考核 ≠ 0 分」在 UI 侧的兑现。
2. `capacityLeft` 在 `available` 接口里**不返回**，由前端 `capacity - signedCount` 现算（计划接口两个字段都有，同源不冲突）。
3. `blockReason` 是后端五道闸门的原文，前端**逐字渲染、不本地改写文案**，保证「为什么不能报名」的解释只有一处真源。

**⑥ mock 侧新增能力（后续模块可复用）**：
`readonly calls: MockRequest[]` + `waitForCall(method, path, timeoutMs)`（游标式，避免重复领同一条日志），
用于断言「点了按钮真的发出了这条写请求」而不是只断言 UI 变了；`reset()` 清空日志。
⚠️ 真实后端模式下无日志，依赖 `waitForCall` 的用例必须显式 `skip`（文件头已写明）。

**⑦ 验证结果（全部我本人复跑，非子代理自报）**：
`npx vue-tsc --noEmit` exit 0 / `npx eslint src --max-warnings 0` exit 0 / `npm run build` exit 0（`built in 20.56s`）。
`npx playwright test --list` = **90 tests in 10 files**（基线 77 tests / 9 files）。
全量 `npx playwright test --reporter=line` = **90 passed (1.7m)**，无 flake、未放宽任何断言。
`rbac-menu` 的菜单数随之变为 admin 10 / hr 9 / manager 7 / emp01 6 —— 这四条同时钉住 `router/index.ts` 与 `AppLayout.vue` 两份配置。

---

### 12.18 P4.2 差旅与报销（后端切片，本次提交）的测量值

> 本批只交付**后端**（建表 + 控制器 + 路由 + 通知接线），仓颉单测 / 前端 / mock / E2E 是下一批。

**① 逐文件 `numstat`（对比 `HEAD` = `a5f78a7`）**：

| 文件 | +/- | 说明 |
| --- | --- | --- |
| `backend-cangjie/src/controller/expense_controller.cj` | **1897 / 0**（新文件） | 100 个 `public func` = 84 纯函数 + 3 辅助 + 13 handler |
| `backend-cangjie/src/main.cj` | 30 / 0 | 13 条路由，固定段 `my/pending/stats/settlement` 排在 `/:id` 之前 |
| `sql/init.sql` | 54 / 1 | 表 16 `hr_expense`（L323，23 列）+ 12 条种子 + `sys_notification.type` 注释补 4 个新类型 |
| `notification_controller.cj` | 11 / 1 | `EXPENSE_SUBMITTED/APPROVED/REJECTED/PAID` 接入 `notifIsValidType` / `notifTypeLabel` |
| **合计** | **4 files / 1992(+), 2(−)** | |

**② 状态机与闸门（本模块的业务密度都在这里，全部是可单测的纯函数）**
`DRAFT →(submit) SUBMITTED →(approve) APPROVED →(pay) PAID`；`SUBMITTED →(reject) REJECTED →(submit) SUBMITTED`；
`SUBMITTED →(withdraw) DRAFT`；`PAID` 终态。闸门：类别限额（TRAVEL 20000 / TRANSPORT 5000 / MEAL 2000 /
OFFICE 10000 / OTHER 1000，未知类别直接拒）、差旅必填 city 且 days∈[1,60]（非差旅强制清零）、
金额 >0 / 按分钳位两位小数 / ≤100000、`pay_month` 必须等于 `occur_date` 所在月、日期真实存在
（`TIMESTAMPDIFF` 复核，非法日期 → NULL → 闸门拒）、**同员工同月票号唯一**（先 `expenseReceiptDupSql` 预检
给友好原因，UNIQUE 兜底）、仅 DRAFT/REJECTED 可改、仅 DRAFT 可删、PUT 禁改 status、
**MANAGER 只能审本部门且 ≤5000、>5000 必须 ADMIN/HR**、审批人 == `submit_user_id` 一律拒（自审闸门）、
发放仅限 APPROVED 且批次月份 == 单据 `pay_month`。

**③ ★ 一处刻意的范围偏离（比原计划更正确，理由已在源码注释里）**
第六节 P4.2 原写「审批通过与月度发薪联动（报销金额进入薪资明细）」。实际**不写入 `hr_payroll`**，
改为独立发放通道（`GET /expenses/settlement` 待发放台账 + `POST /expenses/:id/pay` 记 `paid_at/paid_by`）。
原因是硬冲突：本项目 `calculateTax` 把 `hr_payroll.bonus` **计入应税所得**，而实报实销的报销款不是工资性收入、
不该计税；并入会算错个税，并动摇 P1.3 已有的金额一致性 E2E 闸门（`15796.54` / `16620.26`）。
`expense_controller.cj` 全文对 `hr_payroll` **零引用**，`handleExpenseSettlement` 上方写了完整理由注释块。

**④ 真库（MySQL 8.0.43 / `hrms_db`）实测 29 组**
只读 12 组（全筛选列表与 `COUNT` 条件一致、MANAGER 待审只回本部门、stats 四组数值序、结算台账、
票号预检命中与排除自身、非法日期 NULL）+ 写态 13 组（草稿→局部更新**其余列不被清空**→提交乐观条件
首次 1 行/二次 0 行→越权撤回 0 行/本人撤回 1 行→驳回后重报**审批痕迹清空**→审批→发放→
删 PAID 返回 0 行→通知跨 3 次写入仍只 1 条→LIKE 转义→注入面→清理）+ 约束 4 组
（NULL 票号可共存、重复票号 `ERROR 1062` 且脚本中止、`ROW_COUNT()` 佐证）。测试数据已清回 12 行种子。

**⑤ 过程中的三条纠错（都改了代码，不是只记录）**
1. `notifInsertSql` 我先按「批量 List 版」调，读源码确认真实签名是**单收件人**
   （`notification_controller.cj:107`），改成 P4.1 同款 `notifUserIds` + 循环 + `notifJoinInserts` + 一次 `executeSql`。
2. 三处 `ORDER BY CAST(SUM(...) AS CHAR) DESC` 会按**字符串序**排错（18600.00 vs 7260.00），改回按原始 `SUM(...)` 数值序。
3. 删除 handler 曾在插值里写 `\"`（全库无先例），改成先取局部变量再插值。
另：验证脚本里用会话变量与 `ref_id` 列比较会报 `ERROR 1267 Illegal mix of collations`——
**是测试脚本自身的产物**（用户变量与列同为 IMPLICIT），控制器发的是字面量（COERCIBLE），改用字面量即通过；
但记为已知环境差异，别误判成线上 SQL 有问题。

**⑥ 语法先例抽查（我本人复跑，非采信子代理自报）**
`var` 声明有 `main.cj:41`、`crypto_util.cj:110/141/145` 等先例；
`expense_controller.cj:566` 的 `kw.replace("\\", "\\\\")` 与 **`response.cj:9` 逐字同款**；
无三元 `?:`、无 `else if`、无 lambda/LINQ。三引号 SQL、`??`、`match/case Some/None` 均沿用 training 写法。
⚠️ 本机无 SDK，以上是「先例论证」不是「编译证明」（L-CJ-1 不变）。

**⑦ 本批明确未做（下一批范围）**
`expense_controller_test.cj` 仓颉单测、`api/hrms.ts` 报销 API、`ExpenseView.vue`、`router` `meta.roles`、
`AppLayout` 菜单项与 `notifRoutes`（`EXPENSE_*` → `/expense`）、前端 `NOTIF_TYPES` 映射、
`mock-server` 分发（现 **43 条**）、`e2e/expense.spec.ts`、`rbac-menu.spec.ts` 四角色 `MENUS`（现 admin 10 / hr 9 / manager 7 / emp01 6）、
三连与全量 Playwright（基线 **90 passed / 10 files**）。

**⑧ 路由与角色闸门（`requireRoles` 逐行实测，前端 mock 的唯一依据）**

| 路由 | 闸门 | 行号 |
| --- | --- | --- |
| `GET /expenses`、`/expenses/pending`、`/expenses/stats` | ADMIN/HR/MANAGER | 1220 / 1473 / 1504 |
| `GET /expenses/settlement`、`POST /expenses/:id/pay` | ADMIN/HR | 1554 / 1844 |
| `POST /expenses/:id/approve` | ADMIN/HR/MANAGER（内部再按部门+金额档位收口） | 1761 |
| `POST /expenses`、`PUT/DELETE /expenses/:id`、`GET /expenses/my`、`GET /expenses/:id`、`submit`、`withdraw` | `requireAuth` | 1243 / 1319 / 1395 / 1441 / 1591 / 1640 / 1707 |

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
| **A 推分支 + PR ✅ 已执行（2026-11-23，见 13.6）** | 把 `main` 推到新分支（实际分支名 `trae/hrms-work`），在 GitHub 开 PR 指向 `main` | 低 | 不动主干；PR 的 diff 即 41 文件那份；`on: push` 不会在非主干触发，需靠 `pull_request` 触发 CI |
| B `-s ours` 合并后推主干 | 见 13.2 | 中（删 `.env`；主干对协作者前移） | 唯一能「非 force 推 main」的路径 |
| C 只推 `zc` 分支 | 覆盖远端 `zc`（其 tip=`1bdde7e`，是本地历史里**没有**的提交，需先确认那是用户自己的旧分支） | 中 | 会丢掉远端 `zc` 独有的对象，需 `--force` ⇒ 未经用户同意不做 |

**已排除项**：任何 `push --force` 到 `main`。

### 13.4 L-CI-1 仍未闭合

`ci.yml` 只在本机以「CI 等价条件」验证过（`E2E_CHANNEL=chromium` + `CI=true` ⇒ 42 passed）。
GitHub Actions 的**真实首跑结果尚无人看过** —— 必须先完成 13.3 中任一推送，再回来看 Actions，
失败就回来修 workflow。该义务在推送完成前不得勾销。

### 13.5 工作量对照（用户要求的「至少匹配现有工作量」）

每个数字都来自 `git log --format="COMMIT %h %s" --shortstat` 或 `git diff --shortstat` 的实跑输出，
口径与例外见表下三条说明（本节是 11.2 计数纪律的执行样本）。

| 来源 | 规模（实测） |
| --- | --- |
| 基线 `6e79923`（接手快照） | 111 files / **27803** insertions |
| 我：`62921a7` P0 加固 | **11 files / 1123 insertions(+), 114 deletions(-)** |
| 我：`a6567ca` P1 全量 | **30 files / 6978 insertions(+), 46 deletions(-)**（22 个新文件） |
| 我：`7b39a1c` 文档（第十三节） | 1 file / 63 insertions |
| 我：`be92fca` P2.1 后端导入 + 单测 | **4 files / 1403 insertions(+), 3 deletions(-)** |
| 我：`936e0e4` P2.2 前端导入 + E2E | **5 files / 972 insertions(+), 5 deletions(-)** |
| 我：`86f7b8f` P2.3 工资条打印 | **4 files / 715 insertions(+), 13 deletions(-)**（代码 **603** 行，其余为本文档增量，逐项见 12.12） |
| 我：`8195ff2` P2.4 考勤月度汇总 | **9 files / 1441 insertions(+), 17 deletions(-)**（逐项见 12.13，仓颉侧含 539 行新单测） |
| 我：`7174898` P3.1 长假二级审批（**已提交**） | **8 files / 1364 insertions(+), 64 deletions(-)**；排除本文档（173/6）= **7 files / 1191(+), 58(−)**，逐项见 12.14 |
| 我：`b4427b1` P3.2 通知中心（**后端已提交**） | **7 files / 666 insertions(+), 9 deletions(-)**；排除本文档（139/7）= **6 files / 527(+), 2(−)**（`notification_controller.cj` 470/0、`main.cj` 11/0、`request_controller.cj` 10/0、`dashboard_controller.cj` 9/1、`payroll_controller.cj` 8/1、`init.sql` 19/0），逐项见 12.15 |
| 我：P3.2 通知中心（**前端/测试/单测，本次提交**） | **9 files / 1571 insertions(+), 10 deletions(-)**：新增 `notification_controller_test.cj` 727/0、`e2e/notification.spec.ts` 351/0；改动 `AppLayout.vue` 147/2、`mock-server.ts` 287/2（分发 28→32）、`hrms.ts` 27/0、`ApprovalView.vue` 12/2、`PayrollView.vue` 11/1、`rbac-menu.spec.ts` 5/1、`payroll.spec.ts` 4/2。⚠️ 逐文件数字取自**暂存后**的 `git diff --cached --numstat`（`git add -A` 会把这些 LF 文件按 `core.autocrlf` 归一化，暂存前的 `git diff --numstat` 给出的是另一套数——首轮我就把 mock 记成了 331/0） |
| 我：P4.1 培训与学分（**后端 + 仓颉单测，本次提交**） | **5 files / 2637 insertions(+), 6 deletions(-)**：新增 `training_controller.cj` 1478/0、`training_controller_test.cj` 1070/0；改动 `main.cj` 23/2、`init.sql` 64/4、`notification_controller.cj` 2/0，逐项见 12.16 |
| 我：P4.1 培训与学分（**前端 + E2E，本次提交**） | **7 files / 2227 insertions(+), 5 deletions(-)**：新增 `TrainingView.vue` 844/0、`e2e/training.spec.ts` 457/0；改动 `mock-server.ts` 767/0、`hrms.ts` 144/0、`router/index.ts` 6/0、`AppLayout.vue` 5/1、`rbac-menu.spec.ts` 4/4，逐项与契约坑见 **12.17**。**P4.1 七步闭环至此走完** |
| 我：P4.2 差旅与报销（**后端切片，本次提交**） | `expense_controller.cj` **1897 行 / 100 个 `public`（84 纯函数 + 13 handler + 3 辅助）** + 表 16 `hr_expense` 23 列（含同员工同月票号 UNIQUE）+ 13 条路由 + 4 个通知类型。逐文件、闸门清单、真库 29 组实测与三处纠错见 **12.18**。⚠️ **半批**：仓颉单测 / 前端 / mock / E2E 未做 |
| **代码累计（P4.2 后端切片暂存后实测，排除本文档）** | **61 files / 22010 insertions(+), 149 deletions(-)**（命令：`git diff --cached --shortstat 6e79923 -- . ":(exclude)FOLLOWUP_PLAN.md"`）。较 P4.1 收口时的 60 files / 20020(+) / 149(−) 净增 **+1990 行 / 1 个新文件**，与本批 numstat 的 1992(+) 差 **2 行 = 本批改动到基线既有行的 2 个删除行**（`init.sql` 1 + `notification_controller.cj` 1），差值已对上 |
| 含文档累计（`86f7b8f` 提交后实测） | 45 files / 11220 insertions(+), 147 deletions(-) |

三条口径说明：
1. **代码累计**的复跑命令：`git diff --shortstat 6e79923 HEAD -- . ":(exclude)FOLLOWUP_PLAN.md"`。
   选它做分子是因为它**不受我写多少文档影响** —— 否则「工作量」会随着我补注释、补风险条目无限自增，这个数就没意义了。
   ⚠️ 本行 P3.2 用的是**带暂存区的工作区版本**（`git diff --cached --shortstat 6e79923 -- . ":(exclude)FOLLOWUP_PLAN.md"`），
   因为 P3.2 提交尚未落地；P3.1 已于 `7174898` 落地，故改用权威 `git show --numstat`，
   不再需要「手工相加未跟踪文件」（上一版为此写了 405 行相加的说明，现已无用）。
2. 「含文档累计」这一行注定过期：把命令里的 exclude 去掉即可复测（`git diff --shortstat 6e79923 HEAD`），
   但每写一次本行它就自增，所以它**只作趋势参考、不进对账口径**。此处实测值来自 P2.3 提交前的 `git add -A` 暂存区。
3. 旧版本本节写过「8 files」「38 files / 8082 insertions」「约 29%」，三个数**都是当时口算的**，
   现已全部替换为 `git show --shortstat` 输出（P0 实为 11 files，不是 8）。这正是 11.2 立纪律的直接动因。

⚠️ 诚实结论：按代码插入量 **20020 / 27803 ≈ 72.0%** → **22010 / 27803 ≈ 79.2%**（上一版 72.0%，增量来自 P4.2 后端切片的 +1990，见 13.5 表），
**已越过用户要求的「至少匹配现有需求量」这条线**，且 P4.1 至此**不再是半批**：七步闭环走完，90 条 E2E 全绿。
**需求 23 条里已完整交付 17 条，P4.2 半条已交付**（后端 + 真库 29 组完成，单测与前端/E2E 未落；P3.2 只剩真实库账号命中路径一项受 L-NOTIF-3 限制，已在 12.15 ⑤ 兑付）。
比值已近 80%，但**过线不等于闭环**：P4.2 剩下的「单测 + 前端视图 + mock + E2E」是下一批的确定范围，
连同 12.17 ④ 的 `PUT /trainings/:id` 局部更新待办（P4.2 的 `PUT /expenses/:id` 已按局部更新实现，可回补培训模块）。
P5 的 5 份交付文档**不计入**上面的分子（口径 1）。行数仍不是目标，可验证的功能与测试才是 ——
但用户这句话本身是可量化的，所以我不拿「质量优先」当借口回避它。

### 13.6 首次推送执行记录（2026-11-23，方案 A）

用户指示「把目前做的工作先上传到 github 仓库中」。按 13.3 选择**风险最低的 A 方案**：
推新分支、不动主干、不 force。

```
git -c http.proxy=http://127.0.0.1:7890 push -u origin "HEAD:refs/heads/trae/hrms-work"
 => * [new branch]  HEAD -> trae/hrms-work
```

**远端 ref 实测**（`git ls-remote --heads origin`，推送后）：

| ref | tip | 说明 |
| --- | --- | --- |
| `refs/heads/main` | `c76f07f` | **未变**（仍是 PR #1 的合并提交） |
| `refs/heads/zc` | `1bdde7e` | 未变 |
| `refs/heads/zys` | `c76f07f` | 未变 |
| `refs/heads/trae/hrms-work` | `25794ff` | 新增，等于本地 `git rev-parse HEAD` |

⇒ 13.2 担心的副作用**没有发生**：`origin/main` 的 `backend-cangjie/.env` 仍在，协作者环境不受影响。
⇒ 本地 `main` 的 upstream 因带 `-u` 变成 `origin/trae/hrms-work`（副作用记录在案，后续推送默认落这个分支）。

**必须先解决的网络事实（非猜测，本轮实测）**：`git.exe` 直连 github.com 失败，两条不同报错都出现过
（`Recv failure: Connection was reset` / `Failed to connect to github.com port 443`），
且对**公开仓库** `https://github.com/git/git.git` 同样失败 ⇒ 与凭据无关。
`Test-NetConnection github.com -Port 443` 的 `TcpTestSucceeded=False`，
但 `Invoke-WebRequest https://github.com/...` 返回 200 —— 差异的原因是 **PowerShell 会读系统 IE 代理，git 不会**：
`HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings` 里 `ProxyEnable=1`、`ProxyServer=127.0.0.1:7890`。
对策已持久化到**本仓库 local config**（不动全局配置）：

```
git config --local http.proxy  http://127.0.0.1:7890
git config --local https.proxy http://127.0.0.1:7890
```

复测命令：`git ls-remote --heads origin`；若代理端口变化导致失败，改这两行即可。

> **2026-11-25 状态变更（P3.2 第二批推送时实测）**：`127.0.0.1:7890` 上已无进程监听（`Get-NetTCPConnection -State Listen -LocalPort 7890`
> 返回空，`HKCU` 的 `ProxyEnable` 也变回 0），带 `http.proxy` 的推送因此 `Failed to connect to 127.0.0.1 port 7890`。
> 但**清空代理后直连可用**：`git -c http.proxy= -c https.proxy= push origin HEAD:refs/heads/zc` ⇒ `b4427b1..62a42e8  HEAD -> zc`，exit 0。
> 结论：代理只是当时的兜底，**不是永久前提**。今后推送先试
> `git -c http.proxy= -c https.proxy= push origin HEAD:refs/heads/zc`；仅当它失败且 `github.com:443` 也连不通时，才恢复带代理的写法。
> ⚠️ 不要用不带任何 `-c` 的裸 `git push`：它会读上面写入 local config 的两行，代理一停就必然失败。

**L-CI-1 仍为开放**：`GET https://api.github.com/repos/whwwwc1-hue/-/actions/runs?per_page=5` 实测 `total_count=0`。
成因不是失败而是**没触发** —— [ci.yml](./.github/workflows/ci.yml) 的 `push.branches` 只列 `main`/`master`，
分支推送不满足；`pull_request` 无分支过滤，因此**开 PR 就会首跑**。
入口：`https://github.com/whwwwc1-hue/-/pull/new/trae/hrms-work`（本会话无 `gh` CLI、也不擅自取用凭据管理器里的 token 代发 PR）。
闭合条件：Actions 出现该 PR（或 main）的首个 run，且 `frontend`/`e2e` 两个 job 为 success；`backend` job 允许 skipped（T0.1 仍阻塞）。

### 13.7 推送分支订正：`trae/hrms-work` → `zc`（2026-11-23，用户指示）

用户纠正：「分支提交错了，你把你加的分支删掉，提交到 zc 这个分支」。执行过程与实测结果：

```
git stash push -m "P2.4 WIP (backend monthly-summary)"        # 当时有 2 个未提交的 WIP 文件
git checkout -b zc main                                       # 本地新建 zc，起点 = main(f57dfb9)
git rebase --onto origin/zc --root zc                         # 两段历史无共同祖先，用 --root 全量重放
git checkout --theirs README.md ; git add README.md ; git rebase --continue
git push -u origin zc                     => 1bdde7e..3db4681  zc -> zc   （快进，非 force）
git push origin --delete trae/hrms-work   => - [deleted]  trae/hrms-work
```

关键事实（均为命令实测，非推断）：

| 项 | 实测 |
| --- | --- |
| `origin/zc` 原 tip | `1bdde7e` "Initial commit"，树里**只有** `README.md`（2 行占位） |
| 与本地历史的关系 | `git merge-base HEAD origin/zc` 为空 ⇒ **无共同祖先**（两条独立 root） |
| 重放的提交数 | 9（`6e79923..f57dfb9` → `fb57e1b..3db4681`，hash 全部变化） |
| 冲突 | 仅 1 处：`README.md` add/add，保留本地完整版（内容远多于占位版） |
| 重放后内容是否等价 | `git diff --stat f57dfb9 zc` 输出**为空** ⇒ 树完全一致，无内容丢失 |
| 是否快进 | `git merge-base --is-ancestor origin/zc zc` 退出码 0 ⇒ 推送为 fast-forward，**无需 `--force`** |
| 是否动过主干 | 否。`origin/main` 仍是 `c76f07f`，`backend-cangjie/.env` 未被删除 |

**本地分支现状**：工作分支改为 `zc`（upstream = `origin/zc`）；本地 `main` 保留在旧 hash `f57dfb9` 作为回退点，
其 upstream 曾由 13.6 的 `-u` 指向已删除的 `origin/trae/hrms-work`，需知悉这一点（不影响 `zc` 的推送）。

L-CI-1 的 PR 入口随之改为 `https://github.com/whwwwc1-hue/-/pull/new/zc`，其余闭合条件不变。

### 13.8 P4.1 后端切片的推送与「代理状态反转」（2026-11-26）

| 项 | 值 |
| --- | --- |
| 本批 commit | `e251a9d`（6 files / **2727(+), 12(−)**，含台账 96 行；纯代码 **5 files / 2637(+), 6(−)**，与 12.16 ① 一致） |
| 推送结果 | `e3a38ba..e251a9d HEAD -> zc`，fast-forward；`git ls-remote --heads origin zc` 复测 = `e251a9d`，**无 force、未新建分支、未动 main/zys** |
| ⚠️ 代理结论**反转** | 13.5 记的是「代理失效，必须 `git -c http.proxy= -c https.proxy= push`」。**本次该命令直接失败**：`curl 28 / RPC failed; Recv failure: Connection was reset`，连 `ls-remote` 都取不到 ref。实测注册表 `ProxyEnable = 1`、`ProxyServer = 127.0.0.1:7890` 已恢复可用，**改用默认配置（带代理）才推送成功** |
| 下次怎么做 | 先 `Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'` 看 `ProxyEnable`：为 `1` 就**不要**清空代理，直接 `git push origin HEAD:refs/heads/zc`；为 `0` 才用 13.5 的清空代理写法。两者都失败再考虑 `dangerouslyDisableSandbox`（本次沙箱内带代理可通，无需绕行） |

