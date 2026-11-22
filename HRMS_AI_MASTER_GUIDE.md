# 人力资源管理系统（HRMS）AI 全栈开发总控文档（Windows 版）

**技术架构**：Cangjie 1.0+（仓颉后端 RESTful API） + Vue 3 / TypeScript（Web 前端） + MySQL 8.0**目标平台**：Windows 10 / 11（x64，PowerShell 5.1 / 7+）**使用对象**：AI 编程助手（Cursor / Claude Code / Windsurf / Cline / Trae / OpenCode 等）**核心目标**：AI 完整阅读本文件后，能够自主完成 Windows 环境检测与配置、为自身挂载仓颉语言规范 Skill/MCP，并分阶段交付一个功能健全、前后端联调通过、可直接用于演示与答辩的人力资源管理系统。

---

## 0. AI Agent 核心执行准则（铁律）

在编写任何一行业务代码之前，AI 必须严格遵守以下工作流：

1. **先装技能，再写仓颉（防语法幻觉）**：
    - 必须先执行 **第 1 节（Windows 仓颉环境校验与安装）** 和 **第 2 节（为自身安装仓颉语言 Skill 与 MCP）**。
    - 编写 `.cj` 文件时，严禁凭直觉混入 Swift、Kotlin、Java、Rust 或旧版仓颉（0.53.x）语法；不确定标准库签名时，必须优先查询已安装的仓颉 Skill 或 MCP 文档。
1. **Windows 终端兼容原则**：
    - 所有命令默认在 **Windows PowerShell** 中执行；目录路径严禁包含中文字符或空格（推荐项目根目录如 `D:\projects\hrms-cangjie`）。
    - 接口自测优先使用 `curl.exe`（而非 PowerShell 别名 `curl`）或 `Invoke-RestMethod`。
1. **小步提交与编译门禁**：
    - 每完成一个后端子模块，必须立即运行 `cjpm build` 校验编译；遇到 `cjc` 报错必须当场分析并修复，不允许跳过编译错误继续往后写。
1. **双端复用架构规范（预留鸿蒙客户端兼容）**：
    - 认证体系统一使用 **HTTP Header 传递 JWT Token**（`Authorization: Bearer <token>`），禁止依赖 Cookie/Session。
    - 后端全局内置 **CORS 跨域中间件**，既满足 Web 浏览器跨域调用，也确保未来零改动兼容 HarmonyOS 仓颉移动端。
1. **分阶段交付与自测**：
    - 严格按照 **第 9 节** 的 `Phase 1` 至 `Phase 7` 顺序推进，每个阶段结束必须输出验收结果摘要并征求用户确认或继续下一阶段。

---

## 1. Windows 平台安装仓颉语言开发环境（SOP）

AI 需先在 PowerShell 中运行检测命令，判断用户电脑是否已安装所需工具链；如缺失，按以下步骤协助或引导用户完成安装。

### 1.1 快捷环境自检（PowerShell）

```powershell
cjc -v
cjpm -v
git --version
node -v
pnpm -v
mysql --version
```

### 1.2 安装仓颉工具链（Cangjie SDK 1.0+）与标准扩展库（stdx）

1. **下载官方安装包**：
    - 前往仓颉编程语言官网下载页：`https://cangjie-lang.cn/download`
    - 下载 **Windows x64 版仓颉 SDK**：`cangjie-sdk-windows-x64-1.x.x.zip`（推荐 1.0 LTS 或最新 1.1.x 稳定版）。
    - 下载对应版本的 **仓颉标准扩展库（stdx，包含 HTTP Server、JSON、加密等核心模块）**：`cangjie-stdx-windows-x64-1.x.x.x.zip`（官方下载页或 `https://gitcode.com/Cangjie/cangjie-stdx-bin`）。
1. **解压到纯英文无空格路径**：
    - 将 SDK 解压至：`D:\cangjie`（确保其下直接包含 `bin`、`tools`、`runtime`、`envsetup.ps1`）。
    - 将 stdx 解压至：`D:\cangjie-stdx`（确保其下包含 `windows_x86_64_cjnative` 或 `windows_x86_64_llvm` 目录）。
1. **在 Windows 上永久配置环境变量（PowerShell 一键脚本）**：

**提示**：AI 可先检查 `D:\cangjie\runtime\lib\` 下实际子目录名是 `windows_x86_64_cjnative`（1.0.x/1.1.x 主流）还是 `windows_x86_64_llvm`（早期 1.0.0），再执行以下脚本写入当前用户环境变量：

```powershell
$CangjieHome = "D:\cangjie"
$StdxPath    = "D:\cangjie-stdx"

# 自动探测 runtime/lib 子目录名称
$RuntimeLibDir = Get-ChildItem "$CangjieHome\runtime\lib" -Directory | Select-Object -First 1 -ExpandProperty FullName

# 写入 CANGJIE_HOME 与 CANGJIE_STDX_PATH（用户级永久生效）
[Environment]::SetEnvironmentVariable("CANGJIE_HOME", $CangjieHome, "User")
[Environment]::SetEnvironmentVariable("CANGJIE_STDX_PATH", $StdxPath, "User")

# 追加 Path 条目（去重）
$OldPath = [Environment]::GetEnvironmentVariable("Path", "User")
$PathsToAdd = @(
    "$CangjieHome\bin",
    "$CangjieHome\tools\bin",
    "$CangjieHome\tools\lib",
    $RuntimeLibDir,
    "$env:USERPROFILE\.cjpm\bin"
)
$NewPathList = ($OldPath -split ";") | Where-Object { $_ -ne "" }
foreach ($p in $PathsToAdd) {
    if ($NewPathList -notcontains $p) { $NewPathList += $p }
}
[Environment]::SetEnvironmentVariable("Path", ($NewPathList -join ";"), "User")

# 立即在当前会话生效（临时加载）
if (Test-Path "$CangjieHome\envsetup.ps1") {
    . "$CangjieHome\envsetup.ps1"
}
Write-Host "仓颉环境变量配置完成，请重新打开终端或运行 cjc -v 验证。" -ForegroundColor Green
```
若执行 `.ps1` 脚本提示权限受限，先在 PowerShell 运行： `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`

1. **验证编译器与最小 Hello World 测试**：

```powershell
cjc -v
cjpm -v
```
预期输出包含 `Cangjie Compiler: 1.x.x (cjnative)` 及 `Target: x86_64-w64-mingw32`。 如安装了 VS Code，可在扩展商店搜索安装官方 **`Cangjie`** 插件以获取 LSP 语法高亮与跳转支持。

### 1.3 安装前端与数据库依赖（Windows）

- **Node.js**：安装 v20+ LTS（`https://nodejs.org/`），随后安装 pnpm：`npm install -g pnpm`。
- **MySQL 8.0**：安装 MySQL 8.0 Community Server（或安装 Docker Desktop 后运行 `docker run -d --name hrms-mysql -e MYSQL_ROOT_PASSWORD=root -p 3306:3306 mysql:8.0`）。
- **Git**：安装 Git for Windows（用于拉取仓颉 Skill 及三方库依赖）。

---

## 2. 为 AI 自身安装仓颉语言 Skill 与 MCP（自举流程）

AI 必须先为自身装备**华为仓颉编程语言专属 Skill** 和文档检索工具，以避免代码生成幻觉。

**⚠️ 重要避坑提醒**：GitHub 上存在同名仓库 `kangarooking/cangjie-skill`，那是用于“把书籍/视频蒸馏成 Agent Skill”的通用元技能，**与华为仓颉编程语言无关，严禁误装**！

### 2.1 在当前项目中安装仓颉语言 Skill（PowerShell）

AI 根据当前宿主 IDE（Cursor / Claude Code / Windsurf / Trae 等），将仓颉 Skill 安装到对应的工作区 skills 目录中（建议同时写入 `.cursor/skills/` 和 `.claude/skills/` 以便跨工具通用）：

```powershell
# 1. 创建本地 Skill 目录
$SkillDirs = @(
    ".cursor\skills\cangjie-lang",
    ".claude\skills\cangjie-lang"
)
foreach ($dir in $SkillDirs) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

# 2. 方案 A（推荐）：拉取社区仓颉代码生成与分析工作手册 Skill
git clone --depth 1 https://github.com/ystyle/cangjie-lang-skill.git .tmp_cj_skill
if (Test-Path ".tmp_cj_skill") {
    Copy-Item -Path ".tmp_cj_skill\*" -Destination ".cursor\skills\cangjie-lang\" -Recurse -Force
    Copy-Item -Path ".tmp_cj_skill\*" -Destination ".claude\skills\cangjie-lang\" -Recurse -Force
    Remove-Item -Recurse -Force .tmp_cj_skill
}

# 3. 方案 B（补充）：拉取 Zxilly/cangjie-mcp 的仓颉 SKILL.md 作为速查参考
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Zxilly/cangjie-mcp/master/SKILL.md" `
    -OutFile ".cursor\skills\cangjie-lang\CANGJIE_MCP_SKILL.md"
Copy-Item ".cursor\skills\cangjie-lang\CANGJIE_MCP_SKILL.md" ".claude\skills\cangjie-lang\CANGJIE_MCP_SKILL.md" -Force
```

**离线/网络受限兜底**：如果当前 Windows 环境无法访问 GitHub，AI 可直接克隆国内 GitCode 上的官方语言规范文档仓作为本地参考知识库：

```powershell
git clone --depth 1 https://gitcode.com/Cangjie/cangjie_spec.git .cursor\skills\cangjie-lang\spec
```
并在读取完本节 **2.3 兜底语法红线** 后立即开展开发。

### 2.2 配置仓颉官方文档检索 MCP Server（强烈推荐）

建议为 AI 客户端配置 **`ystyle/cangjie-docs-mcp`**（自动同步仓颉官方文档并提供精准搜索）或 **`Zxilly/cangjie-mcp`**：

1. **在 AI 工具的 MCP 配置文件（如 `.cursor/mcp.json` 或 Claude Code 配置）中加入**：

```
{
  "mcpServers": {
    "cangjie-docs": {
      "command": "npx",
      "args": ["-y", "cangjie-docs-mcp"]
    }
  }
}
```
*(若本地已安装 Python* *`uv`**，也可使用* *`uvx cangjie-mcp`* *挂载* *`Zxilly/cangjie-mcp`**)*。

1. **AI 自我校验**：配置完毕后，尝试列出 `.cursor/skills/cangjie-lang/` 中的 `SKILL.md` 并完整通读，将其规则载入当前上下文。

### 2.3 仓颉 1.0+ 核心语法与工程红线（内置兜底规则）

无论外部 Skill 是否加载成功，AI 编写 `.cj` 代码必须无条件遵守以下规范：

- **声明与可变性**：不可变用 `let`，可变用 `var`；**函数形参默认不可变**，不可在函数体内重新赋值。
- **基础类型严格匹配**：默认整数为 `Int64`，浮点为 `Float64`，字符串为 `String`，布尔为 `Bool`；不存在隐式宽化类型转换，需显式转换（如 `Int64(x)`、`Float64(n)`）。
- **空安全（Option）**：可空字段（尤其是数据库 `NULL` 列、JSON 可选参数）必须使用 `?T`（等价于 `Option<T>`），取值必须用 `match`、`if let Some(v) <- opt` 或 `opt ?? defaultVal`。
- **面向对象**：类默认不可继承，需继承时声明 `open class`；抽象行为使用 `interface`；值语义结构体使用 `struct`。
- **模式匹配与异常处理**：`match` 必须穷举或以 `_ =>` 兜底；使用 `try { ... } catch (e: Exception) { ... }` 捕获异常，服务层禁止让未捕获异常击穿主进程。
- **Windows `cjpm.toml` 引入 `stdx` 规范**：在 Windows（`x86_64-w64-mingw32`）下引入官方 `stdx` 扩展库，必须在 `cjpm.toml` 中配置 `[target.x86_64-w64-mingw32.bin-dependencies]`（见第 6.2 节示例）。

---

## 3. 人力资源管理系统（HRMS）架构与功能设计

本系统定位为**企业级功能健全的中小型组织人力资源管理系统**，覆盖“**组织建制 → 招聘入职 → 员工档案与异动 → 考勤打卡 → 请假加班审批 → 绩效考核 → 薪酬核算发放 → 数据驾驶舱与审计**”全业务闭环。

### 3.1 技术栈总览

| **层次** | **选型方案** | **说明与兜底策略** |
| --- | --- | --- |
| **后端语言与构建** | Cangjie 1.0+ / `cjpm` | 原生编译为高性能 Windows 可执行文件 |
| **后端 Web 框架** | **首选**：`CJoy` (`https://gitcode.com/Cangjie-SIG/cjoy`)`<br>`**稳妥兜底**：官方 `stdx.net.http` + 自封装 Router | 若三方框架在 Windows 编译存在版本兼容问题，AI 应果断切换至官方 `stdx.net.http.ServerBuilder` + `stdx.encoding.json` 自封装轻量级 REST 路由器，确保 100% 编译通过且零外部坑。 |
| **数据库连接** | MySQL 8.0 + `mysql-driver` (`https://gitcode.com/Cangjie-SIG/mysql-driver` 或 `jianglexing/cangjie-mysql-driver`) | 基于 `std.database.sql` 接口规范，全部采用参数化占位符防止 SQL 注入。 |
| **鉴权与安全** | HMAC-SHA256 JWT + SHA-256 加盐密码哈希 | 使用 `stdx.crypto.digest` 与 `stdx.encoding.base64` 原生实现，轻量无依赖。 |
| **前端框架** | Vue 3.4+ + TypeScript 5 + Vite 5 | 统一使用 `<script setup lang="ts">` |
| **前端 UI 与图表** | Element Plus + Tailwind CSS + ECharts 5 | 企业级中后台视觉规范、响应式布局、交互式报表 |
| **状态与路由** | Pinia + Vue Router 4 + Axios | 动态权限菜单、全局 Token 刷新拦截与错误提示 |

### 3.2 角色权限矩阵（RBAC）

系统内置 4 种角色，前后端双重校验权限：

| **角色代码** | **角色名称** | **核心权限范围** |
| --- | --- | --- |
| `ADMIN` | 系统管理员 | 全部模块读写、账号与角色分配、系统审计日志查询 |
| `HR` | 人事专员 | 部门与岗位管理、招聘与入职、员工档案/异动/离职、全员考勤统计、请假/加班审批、绩效周期管理、全员薪资核算与发放 |
| `MANAGER` | 部门主管 | 查看本部门员工花名册、审批本部门员工请假/加班单、给本部门员工绩效打分、查看本部门考勤 |
| `EMPLOYEE` | 普通员工 | 个人工作台概览、每日上下班打卡与补卡申请、提交/撤销本人请假与加班单、查看个人绩效评分、查看本人已发放工资条、修改个人资料与密码 |

### 3.3 8 大核心功能模块详解

#### 模块 1：系统认证、账号权限与审计日志（Auth & System）

- 账号密码登录、签发 24 小时有效期 JWT Token、获取当前用户信息、修改密码。
- 系统管理员可管理账号启用/禁用、重置密码、分配角色。
- **操作审计日志**：对关键写操作（入职、调岗、离职、审批请假、发放工资、修改权限）自动写入 `sys_audit_log`，支持分页检索。

#### 模块 2：组织架构与岗位职级体系（Organization）

- **部门树管理**：支持无限级父子部门（`parent_id`）、部门负责人指定、部门编制人数与当前在职人数实时聚合统计。删除部门前强制校验是否存在子部门或在职员工。
- **岗位体系管理**：维护岗位名称、岗位编码、所属部门、职级范围（如 P5-P8 / M1-M3）、参考薪资区间。

#### 模块 3：员工全生命周期管理（Employee Lifecycle）

- **花名册管理**：自动生成唯一工号（格式 `EMP` + 年份 + 4位流水号，如 `EMP20260004`）；支持按姓名/工号/手机号模糊搜索、按部门/岗位/在职状态（`PROBATION` 试用、`ACTIVE` 在职、`RESIGNED` 离职）组合分页查询。
- **入职登记**：录入基础档案、合同起止日期、基本薪资、年假额度；勾选“同时创建登录账号”时自动生成 `sys_user` 记录（默认密码 `123456`）。
- **转正与调岗调薪异动**：支持一键办理转正、部门调动、岗位晋升或薪资调整，系统自动向 `hr_emp_transfer` 写入异动历史轨迹并同步更新员工主表。
- **合同到期预警**：自动筛选 30 天内劳动合同即将到期的在职员工，并在首页工作台高亮提示。
- **离职办理**：记录离职日期与原因，将员工状态置为 `RESIGNED` 并自动禁用其登录账号（保留历史考勤与薪资数据完整性）。

#### 模块 4：考勤打卡与异常处理（Attendance）

- **每日打卡**：员工可执行“上班打卡”与“下班打卡”（同一天支持更新下班打卡时间）。
- **自动状态判定规则**（标准工时 `09:00:00` - `18:00:00`）：
    - 上班打卡时间晚于 `09:00:00` 标记为 `LATE`（迟到），记录迟到分钟数；
    - 下班打卡时间早于 `18:00:00` 标记为 `EARLY_LEAVE`（早退）；
    - 两者同时满足记为 `LATE_AND_EARLY`；均正常记为 `NORMAL`；
    - 员工可对异常日期提交备注申诉，HR 可修正考勤状态。
- **月度考勤汇总**：按月份统计每人应出勤天数、实出勤天数、迟到次数、早退次数、请假天数与加班小时数。

#### 模块 5：请假与加班审批工作流（Leave & Overtime）

- **请假申请**：支持 `ANNUAL`（年假，提交时校验剩余年假天数）、`SICK`（病假）、`PERSONAL`（事假）、`MARRIAGE`（婚假）；初始状态 `PENDING`。
- **加班申请**：支持工作日/周末/节假日加班申报，记录小时数与事由。
- **审批流转**：
    - 申请人可在 `PENDING` 状态下主动撤回（`CANCELLED`）；
    - `MANAGER`（本部门）或 `HR` / `ADMIN` 可执行审批通过（`APPROVED`）或驳回（`REJECTED`）并填写审批意见；
    - 年假审批通过后，自动扣减员工表中的 `annual_leave_balance`。

#### 模块 6：绩效考核管理（Performance）

- HR 创建考核周期（如 `2026-Q4`），批量为在职员工生成考核单。
- 员工填写“工作总结与自评分（0-100）”；主管或 HR 给出“考核终评得分（0-100）”与评语。
- 系统根据终评分数自动映射绩效等级与绩效系数：
    - `$score \ge 90 \Rightarrow \text{S 级（系数 } 1.2\text{）}$`
    - `$80 \le score < 90 \Rightarrow \text{A 级（系数 } 1.1\text{）}$`
    - `$70 \le score < 80 \Rightarrow \text{B 级（系数 } 1.0\text{）}$`
    - `$60 \le score < 70 \Rightarrow \text{C 级（系数 } 0.8\text{）}$`
    - `$score < 60 \Rightarrow \text{D 级（系数 } 0.5\text{）}$`

#### 模块 7：薪酬核算与工资条发放（Payroll）

- **一键月度算薪**：HR 选择月份（`YYYY-MM`），后端自动扫描所有在职/试用员工，结合当月考勤、已通过的事假、已通过的加班与绩效奖金自动生成草稿（`DRAFT`）工资单。
- **标准核算公式**：
    - 日薪基数：`$\text{daily\_salary} = \frac{\text{base\_salary}}{21.75}$`，时薪基数：`$\text{hourly\_salary} = \frac{\text{daily\_salary}}{8}$`
    - 加班补贴：`$\text{overtime\_pay} = \text{overtime\_hours} \times \text{hourly\_salary} \times 1.5$`
    - 考勤与事假扣款：`$\text{attendance\_deduction} = (\text{late\_count} + \text{early\_count}) \times 50 + \text{personal\_leave\_days} \times \text{daily\_salary}$`
    - 社保公积金个人扣除（默认示例比例 18.5%）：`$\text{social\_security} = \text{base\_salary} \times 0.185$`
    - 应税所得额：`$\text{taxable} = \max(0,\ \text{base\_salary} + \text{bonus} + \text{overtime\_pay} - \text{attendance\_deduction} - \text{social\_security} - 5000)$`
    - 个人所得税（按月度累进简算）：
        - `$\text{taxable} \le 3000 \Rightarrow \text{tax} = \text{taxable} \times 0.03$`
        - `$3000 < \text{taxable} \le 12000 \Rightarrow \text{tax} = \text{taxable} \times 0.10 - 210$`
        - `$12000 < \text{taxable} \le 25000 \Rightarrow \text{tax} = \text{taxable} \times 0.20 - 1410$`
        - `$\text{taxable} > 25000 \Rightarrow \text{tax} = \text{taxable} \times 0.25 - 2660$`
    - 实发工资：`$$\text{net\_salary} = \text{base\_salary} + \text{bonus} + \text{overtime\_pay} - \text{attendance\_deduction} - \text{social\_security} - \text{tax}$$`
- **调薪与发放**：HR 可在 `DRAFT` 状态下微调奖金或补贴（实时重算实发工资），确认无误后点击“发放（`PAID`）”；支持批量发放与导出 CSV 工资表；普通员工仅可查看本人 `PAID` 状态工资条。

#### 模块 8：招聘管理与数据驾驶舱（Recruitment & Dashboard）

- **简易招聘看板**：管理候选人简历信息与状态流转（`NEW` 简历筛选 → `INTERVIEW` 面试中 → `OFFER` 已发Offer → `HIRED` 已入职 / `REJECTED` 淘汰）。点击“办理入职”可一键带出候选人信息创建正式员工档案。
- **首页数据看板**：
    - 核心 KPI 卡片：在职总人数、本月入职/离职人数、今日出勤率、待审批流程数、30天内到期合同数。
    - ECharts 图表：各部门人数柱状图、人员状态分布饼图、近 7 日考勤出勤趋势折线图、近 6 个月薪资支出趋势图。

---

## 4. 数据库完整设计（MySQL 8.0 DDL）

AI 需在项目根目录生成 `sql/init.sql` 并导入 MySQL 8.0。所有表采用 `InnoDB` 引擎与 `utf8mb4` 字符集：

```
CREATE DATABASE IF NOT EXISTS hrms_db DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE hrms_db;
-- 1. 部门表
CREATE TABLE hr_department (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    parent_id BIGINT NOT NULL DEFAULT 0 COMMENT '父部门ID，0表示顶级部门',
    dept_name VARCHAR(64) NOT NULL COMMENT '部门名称',
    leader_name VARCHAR(64) DEFAULT NULL COMMENT '部门负责人姓名',
    headcount_limit INT NOT NULL DEFAULT 20 COMMENT '编制人数',
    description VARCHAR(255) DEFAULT NULL COMMENT '部门描述',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_parent_id (parent_id)
) ENGINE=InnoDB COMMENT='组织部门表';
-- 2. 岗位表
CREATE TABLE hr_position (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    pos_code VARCHAR(32) NOT NULL UNIQUE COMMENT '岗位编码',
    pos_name VARCHAR(64) NOT NULL COMMENT '岗位名称',
    dept_id BIGINT NOT NULL COMMENT '所属部门ID',
    level_range VARCHAR(32) DEFAULT 'P5-P7' COMMENT '职级范围',
    min_salary DECIMAL(10, 2) NOT NULL DEFAULT 6000.00,
    max_salary DECIMAL(10, 2) NOT NULL DEFAULT 20000.00,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_pos_dept (dept_id)
) ENGINE=InnoDB COMMENT='岗位职级表';
-- 3. 员工档案主表
CREATE TABLE hr_employee (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    emp_no VARCHAR(32) NOT NULL UNIQUE COMMENT '工号',
    name VARCHAR(64) NOT NULL COMMENT '姓名',
    gender TINYINT NOT NULL DEFAULT 1 COMMENT '1男 2女',
    phone VARCHAR(20) NOT NULL COMMENT '手机号',
    email VARCHAR(100) DEFAULT NULL COMMENT '邮箱',
    id_card VARCHAR(32) DEFAULT NULL COMMENT '身份证号（脱敏展示）',
    dept_id BIGINT NOT NULL COMMENT '部门ID',
    position_id BIGINT DEFAULT NULL COMMENT '岗位ID',
    position_name VARCHAR(64) NOT NULL COMMENT '岗位名称冗余',
    base_salary DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '月基本薪资',
    annual_leave_balance DECIMAL(4, 1) NOT NULL DEFAULT 5.0 COMMENT '剩余年假天数',
    hire_date DATE NOT NULL COMMENT '入职日期',
    probation_end_date DATE DEFAULT NULL COMMENT '预计转正日期',
    contract_end_date DATE DEFAULT NULL COMMENT '合同到期日期',
    resign_date DATE DEFAULT NULL COMMENT '离职日期',
    resign_reason VARCHAR(255) DEFAULT NULL COMMENT '离职原因',
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' COMMENT 'PROBATION/ACTIVE/RESIGNED',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_emp_dept (dept_id),
    INDEX idx_emp_status (status),
    INDEX idx_contract_end (contract_end_date)
) ENGINE=InnoDB COMMENT='员工档案表';
-- 4. 员工异动记录表（转正/调岗/调薪）
CREATE TABLE hr_emp_transfer (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    employee_id BIGINT NOT NULL COMMENT '员工ID',
    transfer_type VARCHAR(20) NOT NULL COMMENT 'REGULARIZE/TRANSFER/SALARY_ADJUST/RESIGN',
    before_dept_id BIGINT DEFAULT NULL,
    after_dept_id BIGINT DEFAULT NULL,
    before_position VARCHAR(64) DEFAULT NULL,
    after_position VARCHAR(64) DEFAULT NULL,
    before_salary DECIMAL(10, 2) DEFAULT NULL,
    after_salary DECIMAL(10, 2) DEFAULT NULL,
    effective_date DATE NOT NULL COMMENT '生效日期',
    remark VARCHAR(255) DEFAULT NULL,
    operator_id BIGINT DEFAULT NULL COMMENT '操作人用户ID',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_transfer_emp (employee_id)
) ENGINE=InnoDB COMMENT='员工异动历史表';
-- 5. 系统用户表
CREATE TABLE sys_user (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    username VARCHAR(64) NOT NULL UNIQUE COMMENT '登录账号',
    password_hash VARCHAR(128) NOT NULL COMMENT '加盐SHA256哈希',
    role VARCHAR(20) NOT NULL DEFAULT 'EMPLOYEE' COMMENT 'ADMIN/HR/MANAGER/EMPLOYEE',
    employee_id BIGINT DEFAULT NULL COMMENT '关联员工ID',
    is_active TINYINT(1) NOT NULL DEFAULT 1 COMMENT '1启用 0禁用',
    last_login_at DATETIME DEFAULT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_user_emp (employee_id)
) ENGINE=InnoDB COMMENT='系统用户表';
-- 6. 考勤打卡记录表
CREATE TABLE hr_attendance (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    employee_id BIGINT NOT NULL COMMENT '员工ID',
    work_date DATE NOT NULL COMMENT '考勤日期',
    clock_in_time DATETIME DEFAULT NULL COMMENT '上班打卡时间',
    clock_out_time DATETIME DEFAULT NULL COMMENT '下班打卡时间',
    late_minutes INT NOT NULL DEFAULT 0 COMMENT '迟到分钟数',
    early_minutes INT NOT NULL DEFAULT 0 COMMENT '早退分钟数',
    status VARCHAR(24) NOT NULL DEFAULT 'NORMAL' COMMENT 'NORMAL/LATE/EARLY_LEAVE/LATE_AND_EARLY/ABSENT',
    remark VARCHAR(255) DEFAULT NULL COMMENT '异常说明或补卡备注',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uk_emp_date (employee_id, work_date),
    INDEX idx_att_date (work_date)
) ENGINE=InnoDB COMMENT='考勤打卡表';
-- 7. 请假与加班申请表
CREATE TABLE hr_leave_overtime (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    employee_id BIGINT NOT NULL COMMENT '申请人ID',
    category VARCHAR(20) NOT NULL DEFAULT 'LEAVE' COMMENT 'LEAVE请假 / OVERTIME加班',
    sub_type VARCHAR(20) NOT NULL COMMENT 'ANNUAL/SICK/PERSONAL/MARRIAGE/WORKDAY_OT/WEEKEND_OT',
    start_time DATETIME NOT NULL COMMENT '开始时间',
    end_time DATETIME NOT NULL COMMENT '结束时间',
    duration DECIMAL(5, 1) NOT NULL COMMENT '时长（请假为天，加班为小时）',
    reason VARCHAR(500) NOT NULL COMMENT '事由',
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING' COMMENT 'PENDING/APPROVED/REJECTED/CANCELLED',
    approver_id BIGINT DEFAULT NULL COMMENT '审批人用户ID',
    approve_remark VARCHAR(255) DEFAULT NULL COMMENT '审批意见',
    approved_at DATETIME DEFAULT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_lo_emp_status (employee_id, status),
    INDEX idx_lo_category (category)
) ENGINE=InnoDB COMMENT='请假与加班审批表';
-- 8. 绩效考核表
CREATE TABLE hr_performance (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    cycle_name VARCHAR(32) NOT NULL COMMENT '考核周期，如 2026-Q4',
    employee_id BIGINT NOT NULL COMMENT '员工ID',
    self_summary VARCHAR(1000) DEFAULT NULL COMMENT '员工自评总结',
    self_score DECIMAL(5, 1) DEFAULT NULL COMMENT '员工自评分',
    final_score DECIMAL(5, 1) DEFAULT NULL COMMENT '最终得分',
    grade VARCHAR(8) DEFAULT NULL COMMENT 'S/A/B/C/D',
    bonus_ratio DECIMAL(4, 2) NOT NULL DEFAULT 1.00 COMMENT '绩效系数',
    reviewer_id BIGINT DEFAULT NULL COMMENT '评审人用户ID',
    reviewer_comment VARCHAR(500) DEFAULT NULL COMMENT '评审评语',
    status VARCHAR(20) NOT NULL DEFAULT 'SELF_EVAL' COMMENT 'SELF_EVAL/REVIEWING/COMPLETED',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uk_cycle_emp (cycle_name, employee_id)
) ENGINE=InnoDB COMMENT='绩效考核表';
-- 9. 月度薪资表
CREATE TABLE hr_payroll (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    employee_id BIGINT NOT NULL COMMENT '员工ID',
    pay_month VARCHAR(7) NOT NULL COMMENT '发薪月份 YYYY-MM',
    base_salary DECIMAL(10, 2) NOT NULL DEFAULT 0.00,
    bonus DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '绩效及津贴奖金',
    overtime_pay DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '加班补贴',
    attendance_deduction DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '考勤及事假扣款',
    social_security DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '五险一金个人部分',
    tax DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '个人所得税',
    net_salary DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '实发工资',
    status VARCHAR(20) NOT NULL DEFAULT 'DRAFT' COMMENT 'DRAFT/PAID',
    paid_at DATETIME DEFAULT NULL,
    remark VARCHAR(255) DEFAULT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uk_emp_month (employee_id, pay_month)
) ENGINE=InnoDB COMMENT='月度薪资核算表';
-- 10. 招聘候选人表
CREATE TABLE hr_recruitment_candidate (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    name VARCHAR(64) NOT NULL COMMENT '候选人姓名',
    gender TINYINT NOT NULL DEFAULT 1,
    phone VARCHAR(20) NOT NULL,
    email VARCHAR(100) DEFAULT NULL,
    target_dept_id BIGINT NOT NULL COMMENT '目标部门ID',
    target_position VARCHAR(64) NOT NULL COMMENT '应聘岗位',
    expected_salary DECIMAL(10, 2) DEFAULT 10000.00,
    source VARCHAR(32) DEFAULT 'BOSS直聘' COMMENT '简历来源',
    stage VARCHAR(20) NOT NULL DEFAULT 'NEW' COMMENT 'NEW/INTERVIEW/OFFER/HIRED/REJECTED',
    interview_notes VARCHAR(500) DEFAULT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_cand_stage (stage)
) ENGINE=InnoDB COMMENT='招聘候选人表';
-- 11. 系统审计日志表
CREATE TABLE sys_audit_log (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    user_id BIGINT DEFAULT NULL,
    username VARCHAR(64) DEFAULT NULL,
    module VARCHAR(32) NOT NULL COMMENT '操作模块',
    action VARCHAR(64) NOT NULL COMMENT '操作动作',
    detail VARCHAR(500) DEFAULT NULL COMMENT '操作详情',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_audit_time (created_at)
) ENGINE=InnoDB COMMENT='操作审计日志表';
-- ==========================================
-- 初始演示数据（Seed Data）
-- ==========================================
INSERT INTO hr_department (id, parent_id, dept_name, leader_name, headcount_limit, description) VALUES
(1, 0, '总经办', '张明远', 5, '公司战略决策与经营管理'),
(2, 1, '技术研发中心', '李泽宇', 50, '核心产品架构、仓颉后端与Web研发'),
(3, 1, '人力资源部', '王静', 10, '招聘配置、薪酬绩效与员工关系'),
(4, 1, '市场与产品部', '赵晨', 25, '产品规划、品牌推广与商业化');
INSERT INTO hr_position (id, pos_code, pos_name, dept_id, level_range, min_salary, max_salary) VALUES
(1, 'POS-CIO', '首席信息官', 1, 'M4', 25000.00, 45000.00),
(2, 'POS-DEV-CJ', '仓颉后端工程师', 2, 'P6-P8', 15000.00, 32000.00),
(3, 'POS-DEV-FE', '资深前端工程师', 2, 'P6-P7', 14000.00, 28000.00),
(4, 'POS-HRBP', '资深 HRBP', 3, 'P6-P7', 10000.00, 18000.00),
(5, 'POS-PM', '高级产品经理', 4, 'P6-P8', 16000.00, 30000.00);
INSERT INTO hr_employee (id, emp_no, name, gender, phone, email, dept_id, position_id, position_name, base_salary, annual_leave_balance, hire_date, contract_end_date, status) VALUES
(1, 'EMP20260001', '张明远', 1, '13800000001', 'admin@hrms.local', 1, 1, '首席信息官', 30000.00, 10.0, '2023-01-10', '2028-01-09', 'ACTIVE'),
(2, 'EMP20260002', '王静', 2, '13800000002', 'hr@hrms.local', 3, 4, '资深 HRBP', 14000.00, 8.0, '2023-06-01', '2027-05-31', 'ACTIVE'),
(3, 'EMP20260003', '李泽宇', 1, '13800000003', 'manager@hrms.local', 2, 2, '研发总监', 26000.00, 10.0, '2024-02-01', '2027-01-31', 'ACTIVE'),
(4, 'EMP20260004', '陈思远', 1, '13800000004', 'dev01@hrms.local', 2, 2, '仓颉后端工程师', 19000.00, 5.0, '2025-07-01', '2026-12-15', 'ACTIVE'),
(5, 'EMP20260005', '林小满', 2, '13800000005', 'fe01@hrms.local', 2, 3, '资深前端工程师', 17500.00, 5.0, '2026-09-01', '2029-08-31', 'PROBATION');
INSERT INTO hr_recruitment_candidate (name, gender, phone, email, target_dept_id, target_position, expected_salary, source, stage, interview_notes) VALUES
('周星辰', 1, '13911112222', 'zhou@example.com', 2, '仓颉后端工程师', 20000.00, 'BOSS直聘', 'OFFER', '技术面表现优秀，熟悉仓颉并发模型'),
('吴雨桐', 2, '13933334444', 'wu@example.com', 4, '高级产品经理', 18000.00, '猎聘', 'INTERVIEW', '已完成一面，待复试');
```
**账号自动初始化约定**：仓颉后端启动时检查 `sys_user` 表记录数；若为空，使用后端统一的加盐哈希函数自动写入 4 个演示账号（初始密码均为 `123456`）：

- `admin`（角色 `ADMIN`，关联 `employee_id = 1`）
- `hr`（角色 `HR`，关联 `employee_id = 2`）
- `manager`（角色 `MANAGER`，关联 `employee_id = 3`）
- `emp01`（角色 `EMPLOYEE`，关联 `employee_id = 4`）

---

## 5. RESTful API 接口契约规范

### 5.1 统一响应格式与错误码

所有接口响应头均包含 `Content-Type: application/json; charset=utf-8`：

```
{
  "code": 200,
  "message": "success",
  "data": {}
}
```
- **状态码**：`200` 成功、`400` 业务/参数错误、`401` 未登录或 Token 失效、`403` 权限不足、`404` 资源不存在、`500` 系统内部异常。
- **分页标准 `data`**：`{ "list": [...], "total": 42, "page": 1, "pageSize": 10 }`。

### 5.2 全量接口清单（前缀 `/api/v1`）

| **领域** | **Method** | **路径** | **角色权限** | **核心功能** |
| --- | --- | --- | --- | --- |
| **认证** | `POST` | `/auth/login` | 公开 | 账号密码登录，返回 `{ token, user }` |
| **认证** | `GET` | `/auth/me` | 登录 | 获取当前登录用户信息及关联员工详情 |
| **认证** | `PUT` | `/auth/password` | 登录 | 修改本人密码（校验旧密码） |
| **看板** | `GET` | `/dashboard/overview` | 登录 | 汇总 KPI 指标、合同到期预警列表、部门人数、考勤与薪资趋势图表数据 |
| **部门** | `GET` | `/departments/tree` | 登录 | 获取嵌套树形部门结构及在职人数统计 |
| **部门** | `POST` | `/departments` | ADMIN/HR | 新增部门 |
| **部门** | `PUT` | `/departments/:id` | ADMIN/HR | 修改部门信息 |
| **部门** | `DELETE` | `/departments/:id` | ADMIN/HR | 删除部门（有子部门或在职员工时返回 400） |
| **岗位** | `GET` | `/positions` | 登录 | 查询岗位列表（可按 `deptId` 筛选） |
| **岗位** | `POST/PUT/DELETE` | `/positions[/:id]` | ADMIN/HR | 岗位增删改 |
| **员工** | `GET` | `/employees` | ADMIN/HR/MANAGER | 分页查询花名册（`keyword`, `deptId`, `status`, `page`, `pageSize`；`MANAGER` 自动限定本部门） |
| **员工** | `GET` | `/employees/:id` | ADMIN/HR/MANAGER | 查看员工详细档案与异动记录 |
| **员工** | `POST` | `/employees` | ADMIN/HR | 员工入职登记（支持 `createAccount: true` 自动建账号） |
| **员工** | `PUT` | `/employees/:id` | ADMIN/HR | 编辑基础资料 |
| **员工** | `POST` | `/employees/:id/transfer` | ADMIN/HR | 办理转正/调岗/调薪并记录异动表 |
| **员工** | `POST` | `/employees/:id/resign` | ADMIN/HR | 办理离职并禁用账号 |
| **考勤** | `POST` | `/attendance/clock-in` | 登录 | 当日上班打卡（自动计算是否迟到） |
| **考勤** | `POST` | `/attendance/clock-out` | 登录 | 当日下班打卡（自动计算是否早退） |
| **考勤** | `GET` | `/attendance/today` | 登录 | 查询本人今日打卡状态 |
| **考勤** | `GET` | `/attendance/my` | 登录 | 查询本人某月考勤明细与汇总（`month=YYYY-MM`） |
| **考勤** | `GET` | `/attendance` | ADMIN/HR/MANAGER | 分页查询全员/本部门考勤记录（`month`, `deptId`, `status`） |
| **考勤** | `PUT` | `/attendance/:id` | ADMIN/HR | 管理员补卡或修正考勤状态 |
| **审批** | `POST` | `/requests` | 登录 | 提交请假或加班申请（年假自动校验余额） |
| **审批** | `GET` | `/requests/my` | 登录 | 查询本人申请列表 |
| **审批** | `PUT` | `/requests/:id/cancel` | 登录 | 申请人撤回待审批单据 |
| **审批** | `GET` | `/requests` | ADMIN/HR/MANAGER | 查询审批列表（`category`, `status`） |
| **审批** | `PUT` | `/requests/:id/approve` | ADMIN/HR/MANAGER | 审批通过或驳回（通过年假自动扣减余额） |
| **绩效** | `POST` | `/performances/init-cycle` | ADMIN/HR | 按周期（如 `2026-Q4`）批量初始化在职员工绩效单 |
| **绩效** | `GET` | `/performances` | 登录 | 查询绩效列表（普通员工仅看本人） |
| **绩效** | `PUT` | `/performances/:id/self-eval` | 登录 | 员工提交自评总结与自评分 |
| **绩效** | `PUT` | `/performances/:id/review` | ADMIN/HR/MANAGER | 主管/HR 评定终评分数并自动映射等级与系数 |
| **薪资** | `POST` | `/payrolls/generate` | ADMIN/HR | 按 `payMonth` 一键自动核算生成草稿工资单 |
| **薪资** | `GET` | `/payrolls` | ADMIN/HR | 分页查询全员薪资单（`payMonth`, `status`, `keyword`） |
| **薪资** | `PUT` | `/payrolls/:id` | ADMIN/HR | 调整草稿工资单的奖金/补贴并重算个税与实发 |
| **薪资** | `POST` | `/payrolls/:id/pay` | ADMIN/HR | 单条确认发放 |
| **薪资** | `POST` | `/payrolls/batch-pay` | ADMIN/HR | 批量发放某月全部草稿工资单 |
| **薪资** | `GET` | `/payrolls/my` | 登录 | 普通员工查询本人已发放的历史工资条 |
| **招聘** | `GET/POST/PUT` | `/candidates[/:id]` | ADMIN/HR | 候选人管理与面试阶段流转 |
| **招聘** | `POST` | `/candidates/:id/hire` | ADMIN/HR | 候选人一键转入职（自动写入员工表并更新阶段为 `HIRED`） |
| **系统** | `GET` | `/system/users` | ADMIN | 查询系统账号列表 |
| **系统** | `PUT` | `/system/users/:id` | ADMIN | 修改账号角色/启停状态/重置密码 |
| **系统** | `GET` | `/system/audit-logs` | ADMIN | 分页查询操作审计日志 |

---

## 6. 仓颉后端工程结构与 Windows 构建规范

### 6.1 推荐目录结构（Monorepo）

```
hrms-cangjie/
├── .cursor/skills/cangjie-lang/    # 仓颉语言 Skill
├── HRMS_AI_MASTER_GUIDE.md         # 本总控文档
├── README.md                       # 最终交付启动说明
├── sql/
│   └── init.sql                    # MySQL 8.0 初始化脚本
├── backend-cangjie/                # 仓颉后端项目
│   ├── cjpm.toml                   # 包管理与 Windows stdx 依赖配置
│   ├── .env.example                # 数据库与 JWT 环境变量模板
│   └── src/
│       ├── main.cj                 # 启动入口、初始化默认账号、注册路由、监听 :8080
│       ├── config/
│       │   └── app_config.cj       # 读取环境变量（DB_HOST/PORT/USER/PASS/NAME, JWT_SECRET）
│       ├── common/
│       │   ├── response.cj         # 统一 JSON 响应体 Result 与分页封装
│       │   ├── jwt_util.cj         # HMAC-SHA256 JWT 生成与校验
│       │   ├── crypto_util.cj      # SHA-256 加盐密码哈希
│       │   └── router.cj           # 轻量路由与中间件链（支持路径参数 :id）
│       ├── middleware/
│       │   ├── cors.cj             # 全局 CORS 跨域与 OPTIONS 放行
│       │   └── auth.cj             # Token 解析、登录上下文注入与 RBAC 校验
│       ├── db/
│       │   └── mysql_pool.cj       # 数据库连接封装与查询助手
│       ├── model/                  # 各模块实体 struct/class 与 JSON 序列化实现
│       ├── dao/                    # SQL 数据访问层
│       ├── service/                # 核心业务逻辑层（算薪引擎、考勤判定、审批流、审计日志）
│       └── controller/             # 9 个领域的 HTTP 控制器
└── frontend-web/                   # Vue 3 Web 前端项目
    ├── package.json
    ├── vite.config.ts              # 代理 /api -> http://127.0.0.1:8080
    └── src/
        ├── api/                    # Axios 实例与模块化 API 调用
        ├── stores/                 # Pinia Auth Store
        ├── router/                 # 路由配置与 RBAC 导航守卫
        ├── layout/                 # 侧边栏 + 顶栏 + 面包屑 + 标签页布局
        ├── components/             # 通用表格、状态标签、图表卡片组件
        └── views/
            ├── login/              # 登录页（附带测试账号一键填充按钮）
            ├── dashboard/          # HR 数据驾驶舱与个人工作台
            ├── organization/       # 部门树管理 + 岗位管理
            ├── employee/           # 员工花名册、入职弹窗、异动/离职弹窗、详情抽屉
            ├── attendance/         # 每日打卡面板 + 考勤记录与月度汇总
            ├── approval/           # 请假与加班申请 + 审批中心
            ├── performance/        # 绩效周期、员工自评、主管评分
            ├── payroll/            # 算薪中心、工资条调整与发放、我的工资条
            ├── recruitment/        # 招聘候选人看板与一键入职
            └── system/             # 账号权限管理 + 审计日志
```
### 6.2 Windows 下 `backend-cangjie/cjpm.toml` 配置模板

AI 在初始化后端工程时，需根据本地实际解压的 `stdx` 目录与 `cjc -v` 版本调整以下模板（确保 `bin-dependencies` 指向 Windows 下的 `stdx` 路径）：

```toml
[package]
  cjc-version = "1.0.0"
  name = "hrms_backend"
  description = "HRMS Backend written in Cangjie"
  version = "1.0.0"
  output-type = "executable"
  src-dir = "src"

[dependencies]
  # MySQL 驱动（按实际拉取仓库的标签或本地路径调整）
  # mysql = { git = "https://gitcode.com/Cangjie-SIG/mysql-driver.git", branch = "main" }

# Windows x64 下加载官方 stdx 扩展库示例（动态链接或静态链接按 stdx 解压目录为准）
[target.x86_64-w64-mingw32]
  [target.x86_64-w64-mingw32.bin-dependencies]
    path-option = ["D:\\cangjie-stdx\\windows_x86_64_cjnative\\dynamic\\stdx"]
```

**Windows 运行时 DLL 提示**：如果采用 `dynamic\stdx` 动态链接，启动 `cjpm run` 前需将 `D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx` 加入当前 PowerShell 的 `$env:PATH`，否则 Windows 可能提示找不到动态库。若采用 `static\stdx` 则无此限制。

### 6.3 后端关键实现细节

1. **CORS 中间件**：
    - 响应头必须包含：
        - `Access-Control-Allow-Origin: *`
        - `Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS`
        - `Access-Control-Allow-Headers: Content-Type, Authorization`
    - 收到 `OPTIONS` 预检请求直接返回 HTTP `204`。
1. **数据库防崩溃与事务意识**：
    - 办理入职并创建账号、年假审批通过并扣减余额、候选人一键入职等跨表操作，需保证数据一致性与失败回滚或明确错误返回。
    - 查询结果为空时正确返回 `None` 或空数组 `[]`，避免空指针解包崩溃。

---

## 7. Web 前端工程与 UI/UX 设计规范

### 7.1 视觉与交互要求

- **整体风格**：采用干净利落的现代 SaaS 企业级中后台风格（主色调推荐深蓝 `#1E40AF` / 靛蓝 `#2563EB`，背景浅灰 `#F5F7FA`，白色圆角卡片与细腻边框）。
- **登录页体验**：左侧品牌介绍 + 右侧登录表单；底部提供 **4 个角色的快捷测试账号填充按钮**（管理员 / HR / 部门主管 / 普通员工），点击自动填入账号与密码 `123456`，极大方便演示与验收。
- **动态权限菜单**：左侧导航栏根据 `authStore.user.role` 自动过滤不可访问的菜单；同时在 Vue Router 全局前置守卫中校验 `meta.roles`，未授权跳转至 403 提示页或首页。
- **表单与状态反馈**：所有删除、离职、发放工资、驳回审批等高危操作必须弹出 `ElMessageBox.confirm` 二次确认；按钮在提交期间显示 `loading` 防重复点击。

### 7.2 Vite 联调代理（`frontend-web/vite.config.ts`）

```
server: {
  port: 5173,
  proxy: {
    '/api': {
      target: 'http://127.0.0.1:8080',
      changeOrigin: true
    }
  }
}
```
### 7.3 Axios 拦截器规范

- 请求拦截器：自动读取 `localStorage.getItem('hrms_token')` 写入 `Authorization: Bearer <token>`。
- 响应拦截器：
    - 若 HTTP 状态码为 `401` 或业务 `code === 401`，清除本地登录态并跳转 `/login`；
    - 若业务 `code !== 200`，自动调用 `ElMessage.error(res.message || '请求失败')` 并 reject。

---

## 8. 自动化验收与联调测试标准

AI 在交付前必须完成以下 6 条端到端业务链路验证（后端用 `curl.exe` 验证，前端在浏览器无控制台红字报错）：

1. **权限链路**：使用 `emp01` 登录尝试访问 `GET /api/v1/payrolls`（全员薪资）返回 `403`；使用 `hr` 登录正常返回 `200`。
1. **招聘转入职链路**：在招聘页将候选人“周星辰”点击“办理入职” → 员工花名册新增对应记录 → 自动生成可登录账号 → 审计日志留痕。
1. **考勤打卡链路**：使用 `emp01` 执行上班打卡、下班打卡 → 正确返回打卡状态 → HR 在考勤列表可见并可修正异常。
1. **请假审批与余额联动链路**：`emp01` 提交 1 天年假 → 初始状态 `PENDING` → `manager` 或 `hr` 审批通过 → 员工档案中剩余年假天数减少 `1.0`。
1. **绩效与算薪闭环链路**：HR 创建 `2026-Q4` 考核周期 → 员工自评 → 主管评定 92 分（自动评为 `S` 级） → HR 按 `2026-11` 一键生成工资单 → 确认实发工资计算符合公式 → 确认发放 → 切换 `emp01` 登录在“我的工资条”中看到已发放明细。
1. **前端打包门禁**：在 `frontend-web` 目录执行 `pnpm build`，确保 TypeScript 类型检查与 Vite 生产构建 0 报错。

---

## 9. AI 分阶段执行路线图（Execution Checklist）

请严格按顺序逐阶段推进，每完成一个 Phase 在对话中汇报完成情况与测试输出：

- **Phase 1：Windows 环境与仓颉 Skill 准备**
    - 检测并确认 `cjc -v`、`cjpm -v`、`node -v`、`pnpm -v`、`mysql --version` 正常。
    - 为 AI 自身安装仓颉语言 Skill 到 `.cursor/skills/cangjie-lang/` 与 `.claude/skills/cangjie-lang/`，通读 `SKILL.md`。
- **Phase 2：数据库与项目骨架搭建**
    - 创建 `sql/init.sql` 并在本地 MySQL 执行导入，确认 11 张表与初始数据就绪。
    - 初始化 `backend-cangjie`（配置好 Windows `cjpm.toml` 与 `stdx` 路径），跑通 `cjpm build` 与健康检查接口 `GET /api/v1/health`。
- **Phase 3：后端基础底座 + 组织与员工模块**
    - 完成 `config`、`mysql_pool`、`cors`、`jwt_util`、`auth` 中间件、默认账号初始化及 `audit_log` 服务。
    - 实现 **认证、部门树、岗位、员工档案/异动/离职、系统账号与审计日志** 接口。
    - `cjpm build` 通过并用 `curl.exe` 验证登录、部门树、员工分页与入职接口。
- **Phase 4：后端核心业务流模块**
    - 实现 **考勤打卡与统计、请假与加班审批、绩效考核、薪资核算与发放、招聘入职、数据驾驶舱** 全部接口。
    - `cjpm build` 通过并用 `curl.exe` 跑通第 8 节前 5 条全链路接口测试。
- **Phase 5：Vue 3 Web 前端核心框架与前 4 个业务模块**
    - 初始化 `frontend-web`（Vue 3 + TS + Vite + Element Plus + Tailwind CSS + Pinia + Vue Router + Axios + ECharts）。
    - 完成登录页、动态权限 Layout、首页数据看板、部门与岗位、员工档案与异动页面并与仓颉后端联调。
- **Phase 6：Web 前端其余业务模块与全量联调**
    - 完成考勤打卡、请假加班审批、绩效考核、薪资核算与我的工资条、招聘看板、系统管理页面。
    - 执行全量业务链路联调与 `pnpm build` 生产构建验证。
- **Phase 7：交付文档与一键启动脚本**
    - 在根目录生成 `README.md` 与 Windows 一键启动说明（含 PowerShell 启动后端脚本 `start-backend.ps1` 与启动前端脚本 `start-frontend.ps1`），整理测试账号清单与项目架构图。

