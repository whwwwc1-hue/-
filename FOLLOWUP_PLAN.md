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

- [ ] **T0.1 安装仓颉工具链**（决策点 D-A，见文末）：`cangjie-sdk 1.0.5` + `cangjie-stdx 1.0.5.1`，解压至无空格路径；按指南 2.3 判断是否需要 Win11 24H2/25H2 运行时补丁。
- [ ] **T0.2 前端可构建**：修复 pnpm（或统一改用 npm），安装依赖，跑通一次 `vite build`，把结果写进进度日志。
- [ ] **T0.3 数据库可连接**：向用户索取真实 MySQL 账号密码，或按指南用 `--defaults-file` 拉起独立实例并导入 [sql/init.sql](./sql/init.sql)；确认 `hrms_db` 11 张表就位。
- [ ] **T0.4 环境自适应配置**（不依赖 SDK 的部分先做）：
  - `tempDir` 由环境变量 `TMP_SQL_DIR` 驱动，缺省回落到系统临时目录，禁止硬编码绝对路径。
  - `mysqlExe` 缺省值改为在 `PATH` 中查找 `mysql.exe`，失败再报错。
  - `.env.example` 与 `start-backend.ps1` 同步上述键；`start-backend.ps1` 的 `$MysqlBin` / `$StdxDynamic` / `D:\cangjie` 改为可参数化并做存在性校验提示。
- [ ] **T0.5 初始化 Git**：`git init` + 首次基线提交，后续每个任务包独立分支，遵守指南第八节的 Conventional Commits。

**验收**：`cjpm build`、`vite build` 各有真实输出记录；`GET /api/v1/health` 返回 `UP` 且能在停 MySQL 时反映真实状态（依赖 P0.2）。

---

## 二、任务包 P0：工程地基加固（数据访问层 + 安全 + 类型闭环）

### P0.1 数据访问层重构（决策点 D-B）
- **现状**：`queryRows / querySingleValue / querySingleInt / executeSql / insertAndGetId` 五个公开函数被 10 个控制器 + audit_service 广泛调用，共 ~190K 字符的后端代码全部依赖这一层。
- **设计原则**：**只改内部实现，不改公开签名**，使控制器零改动，从而把风险限制在单文件内。
- [ ] 抽出 `DbClient` 抽象（`query / execute / lastInsertId`），`mysql_pool.cj` 保留原五个函数作为门面转发。
- [ ] 引入**串行化闸门 + 有界并发**（`Mutex`/`Semaphore`）与单查询超时，杜绝子进程风暴。
- [ ] 临时 SQL 文件名加入进程 ID 与随机后缀，消除跨进程覆盖。
- [ ] **错误显式化**：新增 `DbResult`（`Ok/Err`），`queryRows` 失败时向上传播，控制器统一返回 `500 { code:500, message:"数据库不可用" }` 而非空列表。
- [ ] 去掉 `--raw`，改用 `--batch` 默认转义并在解析侧还原 `\t \n \\ \0`，修复 D2 错列问题；同时改为按**列数校验**后再索引。
- [ ] （若 D-B 选择引入官方驱动）新增 `MysqlDriverClient` 实现 `DbClient`：`std.database.sql` + `mysqlcj`，参数化占位符 `?` + 连接池；`sqlStr/sqlEscape` 标注为遗留接口并逐模块替换。

### P0.2 健康检查真实化
- [ ] `/api/v1/health` 执行 `SELECT 1`，返回 `{ status, db: "UP|DOWN", version }`；MySQL 不可用时返回 `503`，使 T0.4/T0.5 之后 D1 可被自动化探测。

### P0.3 认证与密钥安全
- [ ] `.gitignore` 增加 `backend-cangjie/.env`、`backend-cangjie/tmp_sql/`；`.env` 保留在本地，仓库只留 `.env.example`。
- [ ] 启动时校验 `JWT_SECRET`：若等于示例值或长度 < 32，打印显式告警（生产可选 fail-fast 开关 `STRICT_ENV=1`）。
- [ ] 密码改为经 `MYSQL_PWD` 环境变量传入子进程，消除命令行明文（修 D5）。
- [ ] 登录失败限流：按 `username + IP` 在内存计数，15 分钟内失败 ≥ 5 次返回 `429`，并写审计日志。
- [ ] Token 失效前静默续签（`/auth/me` 剩余有效期 < 1/4 时下发新 `token`），避免长时间填表掉登录。

### P0.4 前端工程闭环
- [ ] 加入 `vue-tsc`，`package.json` 脚本改为 `dev/build/typecheck/lint`，`build` 前执行 `vue-tsc --noEmit`，真正兑现 D4。
- [ ] 加入 ESLint 9 + `eslint-plugin-vue` + Prettier 与最小可用规则集（只做类型/未定义变量/模板 key 等硬错误，不做风格洁癖）。
- [ ] 统一 `api/hrms.ts` 返回类型与 `request.ts` 拦截器解包契约的单一定义源，消除视图内 `as any`。

**验收**：`cjpm build` 通过；`vue-tsc --noEmit && vite build` 0 错误；停掉 MySQL 后 health 与业务接口返回结构化 5xx 而非空数据。

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

## 八、决策点（需用户确认后执行）

- **D-A｜仓颉 SDK 是否现在安装？**
  - 选项 1：由我下载并安装 SDK + stdx（需要访问外网与数百 MB 磁盘）。
  - 选项 2：用户手动安装后告知路径，我负责改 `cjpm.toml` / `start-backend.ps1` 并验证。
  - 选项 3：**暂不安装**，我先只做 T0.2/T0.4/T0.5 + P0.4 + 全部前端/文档任务；后端 `.cj` 改动照常写但标注「未编译验证」，等 SDK 就位再统一编译回归。
  - 影响：不安装则 P0.1/P0.2/P0.3/P1.1/P1.2/P2.1/P3/P4 的**后端部分全部无法验证**，交付可信度显著下降。
- **D-B｜数据访问层路线**
  - 路线 A（彻底）：引入 `std.database.sql` + `mysqlcj` 官方 SIG 驱动 → 真参数化 + 连接池，性能问题根治，但依赖能否拉到该包。
  - 路线 B（渐进，推荐先做）：先落地 P0.1 的加固版（错误显式化、去 `--raw`、串行化、超时、列数校验），零控制器改动、风险最低；接口抽象保留，之后再切路线 A。
- **D-C｜MySQL 凭据**：请提供可用的账号密码与是否允许我导入 `sql/init.sql`（会 `DROP/CREATE` 覆盖同名表）。
- **D-D｜包管理器**：统一 pnpm（修 corepack）还是改用 npm（当前可用，但 `pnpm-lock.yaml` 需替换为 `package-lock.json`）。

---

## 九、进度日志（每完成一项追加）

| 时间 | 任务 | 动作 | 验证结果 |
| --- | --- | --- | --- |
| 2026-11-23 | 体检 | 通读 README/COLLABORATOR_GUIDE，抽查 10 控制器、db 层、前端配置与脚本 | 确认 D1~D5 五个真实缺陷；确认 SDK/Git/pnpm/MySQL 凭据四项环境缺口 |
| 2026-11-23 | — | 建立本计划文档 | 待用户确认 D-A ~ D-D |
