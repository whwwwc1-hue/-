# 企业级人力资源管理系统（Cangjie 1.0.5 + Vue 3 HRMS）

> 所属课程仓库：**软件工程职业实践项目作业**（`https://github.com/whwwwc1-hue/-`）  
> **协作者接手必读**：请先查阅 **[COLLABORATOR_GUIDE.md](./COLLABORATOR_GUIDE.md)**，内含 Windows 环境搭建避坑指南（含 Win11 24H2/25H2 仓颉运行时修复）、11 张数据库表字典、全量接口速查、业务扩展 SOP 与后续任务分工清单。

基于 **华为仓颉（Cangjie `1.0.5` + `stdx 1.0.5.1`）** 后端 RESTful API 与 **Vue 3 + TypeScript + Element Plus + Tailwind CSS + ECharts 5** 前端的全栈企业级人力资源管理系统，使用 **MySQL 8.0** 作为持久化存储。

---

## 一、核心技术栈

| 层级 | 技术选型 |
| --- | --- |
| 后端语言与运行时 | Cangjie `1.0.5` (`cjnative`) + `stdx 1.0.5.1`（`stdx.net.http` / `stdx.encoding.json` / `stdx.crypto.digest`） |
| 数据库 | MySQL `8.0.42`（`utf8mb4`，11 张业务核心表） |
| 前端框架 | Vue `3.5` + TypeScript + Vite `5` + Pinia + Vue Router `4` |
| UI 与可视化 | Element Plus + `@element-plus/icons-vue` + Tailwind CSS + ECharts `5` |
| 质量保障 | `vue-tsc` 类型检查（覆盖 `.vue`）+ Vitest 单元测试 + GitHub Actions 前端流水线 |

---

## 二、目录结构

```text
hrms-cangjie/
├── COLLABORATOR_GUIDE.md     # 【必读】协作者完整接手、二次开发与任务分工指南
├── HRMS_AI_MASTER_GUIDE.md   # 总体 AI 开发规范与系统设计文档
├── README.md                 # 项目快速概览与启动入口
├── backend-cangjie/          # 仓颉后端工程
│   ├── cjpm.toml             # cjpm 配置与 stdx 依赖声明
│   ├── .env / .env.example   # 服务端口、MySQL 连接与 JWT 密钥配置
│   └── src/
│       ├── main.cj           # 服务启动入口、默认账号初始化与路由分发
│       ├── config/           # 配置加载
│       ├── db/               # MySQL UTF-8 安全查询执行封装
│       ├── common/           # 统一响应、JSON 工具、SHA256+盐加密、HS256 JWT、路由工具
│       ├── middleware/       # CORS 跨域与 RBAC 鉴权拦截
│       ├── service/          # 审计日志写入等共享服务
│       └── controller/       # 10 大业务模块控制器（认证/组织/员工/考勤/审批/绩效/薪酬/招聘/看板/系统）
├── frontend-web/             # Vue 3 + Vite Web 前端工程
│   ├── vite.config.ts        # 5173 端口与 /api -> 127.0.0.1:8080 代理
│   └── src/
│       ├── api/              # Axios 拦截器与全量接口声明
│       ├── stores/           # Pinia 认证与权限状态
│       ├── router/           # RBAC 动态路由守卫
│       ├── layout/           # 侧边栏+顶栏布局与改密弹窗
│       └── views/            # 登录与 9 大核心业务视图
├── sql/init.sql              # 12 张业务表结构与初始种子数据（含站内通知表）
├── .github/workflows/        # GitHub Actions：前端类型检查 + 单元测试 + 构建
├── start-backend.ps1         # 一键启动 MySQL + 仓颉后端（8080）
└── start-frontend.ps1        # 一键启动前端开发服务器（5173）
```

前端源码内新增两个约定目录，改动时请优先复用：

- `frontend-web/src/constants/`：枚举单一来源（如考勤状态），避免前后端枚举漂移
- `frontend-web/src/utils/`：跨页面复用的小工具（二次确认弹窗、本地时区日期）

---

## 三、快速启动指南

详细配置与环境避坑请阅读 **[COLLABORATOR_GUIDE.md](./COLLABORATOR_GUIDE.md)**。

### 1. 启动数据库与仓颉后端（终端 1）

```powershell
.\start-backend.ps1 -Rebuild
```

后端健康检查地址：`http://127.0.0.1:8080/api/v1/health`

### 2. 启动 Web 前端（终端 2）

```powershell
.\start-frontend.ps1
```

浏览器访问：`http://127.0.0.1:5173`

---

## 四、默认演示账号（登录页支持一键填充）

所有演示账号默认密码均为 **`123456`**：

| 用户名 | 角色 | 说明 |
| --- | --- | --- |
| `admin` | `ADMIN` | 系统管理员：拥有全部功能、账号角色管理及安全审计日志权限 |
| `hr` | `HR` | 人事主管：组织架构、员工档案与异动、考勤修正、薪资核算与发放、招聘入职 |
| `manager` | `MANAGER` | 部门经理：查看本部门员工与考勤、审批本部门请假/加班、主管绩效评分 |
| `emp01` | `EMPLOYEE` | 普通员工：工作台打卡、发起请假/加班申请、填写自评、查看个人已发放工资条 |

---

## 五、核心业务闭环

1. **RBAC 权限控制**：前后端双重校验，普通员工访问全员薪资核算接口返回 `403`。
2. **招聘转入职闭环**：候选人从 `NEW -> INTERVIEW -> OFFER -> HIRED` 一键转入职，自动生成工号与员工账号并记录系统审计日志。
3. **智能考勤与补卡**：实时上下班签到/签退判别迟到/早退，HR 支持异常补卡修正。
4. **假勤审批与年假联动**：员工提交年假申请，部门经理/HR 审批通过后自动扣减员工可用年假余额。
5. **绩效评估联动月度计薪**：周期内完成自评与主管评分（`S=1.2 / A=1.1 / B=1.0 / C=0.8 / D=0.5`），月度薪资核算自动按公式计算奖金、五险一金与累计超额个税，发薪后员工可在「我的工资条」查看电子凭条。
6. **站内消息通知**：假勤审批结果、工资条发放会自动写入 `sys_notification`，顶栏铃铛展示未读角标，抽屉内可分页查看、逐条或一键标记已读。

---

## 六、质量保障与常用命令

前端已接入 `.vue` 级类型检查与单元测试，三条命令都可以在 `frontend-web` 目录直接执行：

```powershell
cd frontend-web
pnpm install        # 首次拉取代码后安装依赖
pnpm typecheck      # vue-tsc --noEmit，覆盖 10 个页面与所有 .ts
pnpm test           # Vitest 单元测试（日期工具、考勤枚举等）
pnpm build          # 先类型检查再 vite build
```

后端改动没有纳入 CI：仓颉 SDK 未预装在 GitHub runner 上，请按 [COLLABORATOR_GUIDE.md](./COLLABORATOR_GUIDE.md) 在本地 `cjpm build` 自测后再提交。

数据库如需在已有环境升级，直接重跑 `sql/init.sql` 即可：全部建表语句均为 `CREATE TABLE IF NOT EXISTS`，种子数据为 `INSERT IGNORE`，不会覆盖现有业务数据。
