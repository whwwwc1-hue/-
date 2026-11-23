#Requires -Version 5.1
<#
.SYNOPSIS
    HRMS 后端接口冒烟回归脚本（P1.2）。

.DESCRIPTION
    针对真实运行中的 Cangjie 后端 + MySQL 做端到端断言，覆盖：
      1) 四个角色（admin / hr / manager / emp01）登录与令牌鉴权
      2) RBAC 越权矩阵（EMPLOYEE / MANAGER / HR 各自的 403 与 401）
      3) 打卡（上班 / 重复上班 / 下班 / 今日查询）
      4) 申请 + 审批 + 年假扣减（含余额不足、重复审批、撤回）
      5) 一键生成工资单 + 工资条金额逐行核对（个税分档 & 实发口径）
      6) 参数校验类 400 / 未知路由 404 / 非法 JSON 400

    设计原则（重要）：
      * 绝不假绿。任何断言失败都会累计，脚本最终退出码非 0。
      * 后端不可达 / 数据库 DOWN 时直接以退出码 2 终止，
        而不是把依赖数据库的用例「跳过并宣称通过」。
      * 所有请求体保持纯 ASCII，规避 PowerShell 5.1 的出站编码歧义。
      * 对会改状态的用例（打卡、审批、生成工资）做了「重复运行友好」处理：
        当天已打卡、年假已耗尽等情形走宽容分支或 SKIP，不会误报回归失败。
      * 只发送 1 次错误口令，且探测不存在的账号用独立用户名，
        避免触发登录限流（5 次失败封 900 秒）把后续登录打死。

.PARAMETER BaseUrl
    后端地址，默认 http://127.0.0.1:8080（与 start-backend.ps1 一致）。

.PARAMETER Password
    演示账号统一口令，默认 123456（与 main.cj 的 seedDefaultUsers 一致）。

.PARAMETER LeaveDays
    年假审批用例申请的天数，默认 1.0；余额不足时自动降级。

.PARAMETER PayMonth
    生成工资单的账期，默认当前月 yyyy-MM。

.PARAMETER SkipMutating
    只跑只读 + 鉴权矩阵，不打卡、不提审批、不生成工资（对共享环境更安全）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\api-smoke.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\api-smoke.ps1 -BaseUrl http://127.0.0.1:8080 -PayMonth 2026-11
#>
param(
    [string] $BaseUrl = "http://127.0.0.1:8080",
    [string] $Password = "123456",
    [double] $LeaveDays = 1.0,
    [string] $PayMonth = "",
    [switch] $SkipMutating
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    # 非交互宿主（如 CI 里没有控制台）忽略即可
}

# 刻意不开 Set-StrictMode：被测接口若返回了缺字段的 JSON，
# StrictMode 会让脚本自己抛异常中断，把「接口契约不符」渲染成「脚本崩溃」。
# 这里改用 trap 兜底：任何未预期的脚本级异常都以退出码 2 结束，
# 并且明确声明本轮回归不作数 —— 宁可作废，绝不假绿。
trap {
    Write-Host ""
    Write-Host "[FATAL] 冒烟脚本自身异常中断：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "        本轮回归判定为「未完成」，不计入通过。" -ForegroundColor Red
    exit 2
}

if ([string]::IsNullOrWhiteSpace($PayMonth)) {
    $PayMonth = (Get-Date).ToString("yyyy-MM")
}

$script:Root = $BaseUrl.TrimEnd('/')
$script:PassCount = 0
$script:FailCount = 0
$script:SkipCount = 0
$script:Failures = New-Object System.Collections.ArrayList
# 金额比对容差：后端 round2 是「半个单位进位」，PowerShell 侧只做量级校验，
# 0.011 足以判定「是否到了正确的分档」，又能容忍浮点末位差异。
$script:MoneyTol = 0.011

function Write-Section {
    param([string] $Title)
    Write-Host ""
    Write-Host "==== $Title ====" -ForegroundColor Cyan
}

function Add-Pass {
    param([string] $Name)
    $script:PassCount++
    Write-Host "  [PASS] $Name" -ForegroundColor Green
}

function Add-Fail {
    param([string] $Name, [string] $Detail)
    $script:FailCount++
    [void] $script:Failures.Add("$Name :: $Detail")
    Write-Host "  [FAIL] $Name" -ForegroundColor Red
    Write-Host "         $Detail" -ForegroundColor DarkRed
}

function Add-Skip {
    param([string] $Name, [string] $Reason)
    $script:SkipCount++
    Write-Host "  [SKIP] $Name （$Reason）" -ForegroundColor Yellow
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Name)
    if ($null -ne $Expected -and $null -ne $Actual -and ($Expected -eq $Actual)) {
        Add-Pass $Name
    } else {
        Add-Fail $Name "期望=$Expected 实际=$Actual"
    }
}

function Assert-True {
    param([bool] $Condition, [string] $Name, [string] $Detail = "条件不成立")
    if ($Condition) { Add-Pass $Name } else { Add-Fail $Name $Detail }
}

function Format-Body {
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return "<empty>" }
    $one = $Text -replace "\s+", " "
    if ($one.Length -gt 180) { return ($one.Substring(0, 180) + "...") }
    return $one
}

function Get-JsonArray {
    <#
        把 ConvertFrom-Json 出来的「数组字段」安全地规整成 Object[]。
        PowerShell 有个著名坑：`$null -eq @()` 为 True，
        所以绝不能用 `$null -ne $Data` 判断「是不是数组」，
        也不能用 `$null -eq $Data` 判断「是不是空数组」。
        这里统一：null / 空数组 都返回 @()，需要区分空与非空时用 Count，
    需要区分「字段缺失」时用原始响应文本另行断言。

    第二个坑（本函数踩过一次，导致看板用例假红）：
    `return @($Value)` 会被 PowerShell 的输出流自动解包 —— 单元素数组
    解包成标量后 `.Count` 是「空」而不是 1，`-ge 1` 直接判假。
    必须用一元逗号 `,` 把数组当成单个对象吐出来。
#>
    param($Value)
    if ($null -eq $Value) { return , @() }
    if ($Value -is [System.Array]) { return , $Value }
    if ($Value -is [System.Collections.IEnumerable]) { return , @($Value) }
    return , @($Value)
}

function Invoke-Api {
    <#
        统一 HTTP 入口。返回 [pscustomobject]：Status / Code / Message / Data / Text / Raw。
        非 2xx 不抛异常（那是被测接口的行为，不是脚本的错误）；
        只有连不上、超时这类传输层故障才抛，交由上层以退出码 2 终止。
    #>
    param(
        [string] $Method,
        [string] $Path,
        $Body = $null,
        $Token = $null,
        $AuthOverride = $null
    )
    $uri = $script:Root + $Path
    $headers = @{}
    # Token 与 AuthOverride 都不声明类型，避免 PowerShell 把显式传入的 $null
    # 绑定成空字符串，从而无法区分「没传令牌」和「传了一个空的 Bearer 头」。
    if ($null -ne $AuthOverride) {
        $headers["Authorization"] = [string] $AuthOverride
    } elseif ($null -ne $Token -and [string] $Token -ne "") {
        $headers["Authorization"] = "Bearer $Token"
    }

    $params = @{
        Uri             = $uri
        Method          = $Method
        UseBasicParsing = $true
        TimeoutSec      = 25
    }
    if ($headers.Count -gt 0) { $params["Headers"] = $headers }
    if ($null -ne $Body) {
        $params["Body"] = $Body
        $params["ContentType"] = "application/json; charset=utf-8"
    }

    $status = 0
    $text = ""
    try {
        $resp = Invoke-WebRequest @params
        $status = [int] $resp.StatusCode
        $text = [string] $resp.Content
    } catch [System.Net.WebException] {
        $r = $_.Exception.Response
        if ($null -eq $r) {
            # 连接被拒 / DNS 失败 / 超时：环境不可用，必须让整轮回归作废
            throw "传输层失败：$Method $uri —— $($_.Exception.Message)"
        }
        $status = [int] $r.StatusCode
        $stream = $r.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $reader.Dispose()
        $stream.Dispose()
    }

    $code = $null
    $message = $null
    $data = $null
    if ($text.Length -gt 0) {
        try {
            $json = $text | ConvertFrom-Json
            $code = $json.code
            $message = $json.message
            $data = $json.data
        } catch {
            Add-Fail "响应体应为统一 JSON 信封 ($Method $Path)" "非 JSON：$(Format-Body $text)"
        }
    }
    return [pscustomobject]@{
        Status = $status
        Code   = $code
        Message = $message
        Data   = $data
        Text   = $text
    }
}

function Assert-Http {
    <# 断言 HTTP 状态码 + 业务 code 同时命中预期。 #>
    param($Resp, [int] $ExpectedStatus, [int] $ExpectedCode, [string] $Name)
    if ($Resp.Status -ne $ExpectedStatus) {
        Add-Fail $Name "HTTP 期望=$ExpectedStatus 实际=$($Resp.Status)；响应=$(Format-Body $Resp.Text)"
        return
    }
    if ($null -ne $ExpectedCode -and $Resp.Code -ne $ExpectedCode) {
        Add-Fail $Name "业务 code 期望=$ExpectedCode 实际=$($Resp.Code)；响应=$(Format-Body $Resp.Text)"
        return
    }
    Add-Pass "$Name (HTTP $ExpectedStatus / code $($Resp.Code))"
}

function Test-MoneyClose {
    param([double] $A, [double] $B, [double] $Tol = $script:MoneyTol)
    return ([Math]::Abs($A - $B) -le $Tol)
}

function Get-ExpectedTax {
    <#
        与 backend-cangjie/src/controller/payroll_controller.cj 的 calculateTax 同口径，
        用来在客户端独立复算个税，防止「前后端同一处逻辑写错却自洽」的假绿。
    #>
    param([double] $Taxable)
    if ($Taxable -lt 0.0) { $Taxable = 0.0 }
    if ($Taxable -le 0.0) { return 0.0 }
    if ($Taxable -le 3000.0) { return $Taxable * 0.03 }
    if ($Taxable -le 12000.0) { return $Taxable * 0.10 - 210.0 }
    if ($Taxable -le 25000.0) { return $Taxable * 0.20 - 1410.0 }
    return $Taxable * 0.25 - 2660.0
}

function Login-As {
    param([string] $Username)
    $body = "{""username"":""$Username"",""password"":""$Password""}"
    $resp = Invoke-Api -Method "POST" -Path "/api/v1/auth/login" -Body $body
    if ($resp.Status -ne 200 -or $null -eq $resp.Data -or -not $resp.Data.token) {
        throw "账号 $Username 登录失败（HTTP $($resp.Status)）：$(Format-Body $resp.Text)"
    }
    return [pscustomobject]@{
        Token = [string] $resp.Data.token
        User  = $resp.Data.user
    }
}

# ============================================================================
# 0. 前置探活：后端 + 数据库必须真实可用，否则整轮作废（退出码 2）
# ============================================================================
Write-Section "0. 前置探活 /api/v1/health"
try {
    $health = Invoke-Api -Method "GET" -Path "/api/v1/health"
} catch {
    Write-Host "[FATAL] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "        请先启动后端：powershell -File .\start-backend.ps1" -ForegroundColor Red
    exit 2
}
Assert-Http $health 200 200 "健康检查返回 200"
if ($null -ne $health.Data) {
    Assert-Equal "UP" ([string] $health.Data.status) "健康状态为 UP（数据库真实可连）"
    Assert-True ($null -ne $health.Data.stats.queryTotal) "健康检查暴露查询统计"
    if ([string] $health.Data.status -ne "UP") {
        Write-Host "[FATAL] 数据库不可用，后续依赖数据的用例没有意义，提前终止。" -ForegroundColor Red
        Write-Host "        lastError=$(Format-Body ([string] $health.Data.db.lastError))" -ForegroundColor Red
        exit 2
    }
} else {
    Write-Host "[FATAL] /health 响应体解析失败，无法判定数据库状态。" -ForegroundColor Red
    exit 2
}

# ============================================================================
# 1. 鉴权：四角色登录 + 未登录 / 坏令牌 / 错口令
# ============================================================================
Write-Section "1. 鉴权与登录"
$tokens = @{}
$profiles = @{}
$roleOf = @{ admin = "ADMIN"; hr = "HR"; manager = "MANAGER"; emp01 = "EMPLOYEE" }
foreach ($name in @("admin", "hr", "manager", "emp01")) {
    try {
        $li = Login-As $name
        $tokens[$name] = $li.Token
        $profiles[$name] = $li.User
        Assert-True ($li.Token.Length -gt 20) "$name 登录取得 JWT"
        Assert-Equal $name ([string] $li.User.username) "$name 登录回显用户名"
        Assert-Equal $roleOf[$name] ([string] $li.User.role) "$name 角色符合预期"
        Assert-True ($li.User.PSObject.Properties.Name -contains "employeeId") "$name 档案含 employeeId"
    } catch {
        Add-Fail "$name 登录" $_.Exception.Message
    }
}

$noToken = Invoke-Api -Method "GET" -Path "/api/v1/employees"
Assert-Http $noToken 401 401 "无令牌访问受保护接口 -> 401"

$badToken = Invoke-Api -Method "GET" -Path "/api/v1/auth/me" -Token "a.b.c"
Assert-Http $badToken 401 401 "伪造令牌 -> 401"

$emptyAuth = Invoke-Api -Method "GET" -Path "/api/v1/auth/me" -AuthOverride "Bearer "
Assert-Http $emptyAuth 401 401 "空 Bearer 令牌 -> 401"

$noScheme = Invoke-Api -Method "GET" -Path "/api/v1/auth/me" -AuthOverride $tokens["emp01"]
Assert-Http $noScheme 401 401 "缺少 Bearer 前缀的裸令牌 -> 401"

# 只发 1 次错误口令：限流阈值是 5 次 / 900 秒，不能把后面的登录打死
$wrongPwd = Invoke-Api -Method "POST" -Path "/api/v1/auth/login" -Body "{""username"":""no_such_smoke_user"",""password"":""wrong-once""}"
Assert-Http $wrongPwd 400 400 "不存在的账号登录 -> 400 且提示剩余尝试次数"
Assert-True ($wrongPwd.Message -match "剩余尝试") "错误口令提示包含剩余尝试次数" "message=$($wrongPwd.Message)"

$noField = Invoke-Api -Method "POST" -Path "/api/v1/auth/login" -Body "{""username"":""admin""}"
Assert-Http $noField 400 400 "登录缺少 password 字段 -> 400"

$badJson = Invoke-Api -Method "POST" -Path "/api/v1/auth/login" -Body "{not-json"
Assert-Http $badJson 400 400 "登录请求体非法 JSON -> 400"

$me = Invoke-Api -Method "GET" -Path "/api/v1/auth/me" -Token $tokens["emp01"]
Assert-Http $me 200 200 "/auth/me 返回当前用户档案"
if ($me.Status -eq 200) {
    Assert-Equal "emp01" ([string] $me.Data.username) "/auth/me 用户名正确"
    Assert-True ($me.Data.PSObject.Properties.Name -contains "annualLeaveBalance") "/auth/me 暴露年假余额"
}

$pwdShort = Invoke-Api -Method "PUT" -Path "/api/v1/auth/password" -Token $tokens["emp01"] -Body "{""oldPassword"":""whatever123"",""newPassword"":""123""}"
Assert-Http $pwdShort 400 400 "新密码过短 -> 400（先于旧密码校验）"

$pwdWrongOld = Invoke-Api -Method "PUT" -Path "/api/v1/auth/password" -Token $tokens["emp01"] -Body "{""oldPassword"":""definitely-wrong"",""newPassword"":""newpass456""}"
Assert-Http $pwdWrongOld 400 400 "旧密码不正确 -> 400（不会真的改密）"

# ============================================================================
# 2. RBAC 越权矩阵
# ============================================================================
Write-Section "2. RBAC 越权矩阵"
$forbidden = @(
    @{ who = "emp01";   method = "GET";  path = "/api/v1/employees";     why = "EMPLOYEE 不可读员工列表" },
    @{ who = "emp01";   method = "POST"; path = "/api/v1/departments";   body = "{""deptName"":""x""}"; why = "EMPLOYEE 不可建部门" },
    @{ who = "emp01";   method = "GET";  path = "/api/v1/payrolls";      why = "EMPLOYEE 不可读工资总表" },
    @{ who = "emp01";   method = "GET";  path = "/api/v1/system/users";  why = "EMPLOYEE 不可读用户管理" },
    @{ who = "emp01";   method = "GET";  path = "/api/v1/candidates";    why = "EMPLOYEE 不可读招聘候选人" },
    @{ who = "emp01";   method = "GET";  path = "/api/v1/requests";      why = "EMPLOYEE 不可读审批列表" },
    @{ who = "manager"; method = "GET";  path = "/api/v1/system/users";  why = "MANAGER 不可读用户管理" },
    @{ who = "manager"; method = "GET";  path = "/api/v1/system/audit-logs"; why = "MANAGER 不可读审计日志" },
    @{ who = "manager"; method = "POST"; path = "/api/v1/payrolls/generate"; body = "{""payMonth"":""$PayMonth""}"; why = "MANAGER 不可生成工资单" },
    @{ who = "manager"; method = "POST"; path = "/api/v1/employees";     body = "{""name"":""x"",""empNo"":""y""}"; why = "MANAGER 不可新建员工" },
    @{ who = "hr";      method = "GET";  path = "/api/v1/system/audit-logs"; why = "HR 不可读审计日志（仅 ADMIN）" },
    @{ who = "hr";      method = "GET";  path = "/api/v1/system/users";  why = "HR 不可读用户管理（仅 ADMIN）" }
)
foreach ($c in $forbidden) {
    $tk = $tokens[$c.who]
    if (-not $tk) { Add-Skip "越权 $($c.who) $($c.method) $($c.path)" "$($c.who) 未取得令牌" ; continue }
    $r = Invoke-Api -Method $c.method -Path $c.path -Token $tk -Body $(if ($c.ContainsKey("body")) { $c["body"] } else { $null })
    Assert-Http $r 403 403 $c.why
}

$allowed = @(
    @{ who = "emp01";   method = "GET"; path = "/api/v1/positions";      why = "EMPLOYEE 可读岗位列表（仅需登录）" },
    @{ who = "emp01";   method = "GET"; path = "/api/v1/departments/tree"; why = "EMPLOYEE 可读部门树（仅需登录）" },
    @{ who = "emp01";   method = "GET"; path = "/api/v1/attendance/today"; why = "EMPLOYEE 可读今日考勤" },
    @{ who = "manager"; method = "GET"; path = "/api/v1/employees";      why = "MANAGER 可读员工列表（本部门过滤）" },
    @{ who = "manager"; method = "GET"; path = "/api/v1/requests";       why = "MANAGER 可读审批列表" },
    @{ who = "hr";      method = "GET"; path = "/api/v1/payrolls";       why = "HR 可读工资总表" },
    @{ who = "hr";      method = "GET"; path = "/api/v1/employees";      why = "HR 可读员工列表" },
    @{ who = "admin";   method = "GET"; path = "/api/v1/system/audit-logs"; why = "ADMIN 可读审计日志" },
    @{ who = "admin";   method = "GET"; path = "/api/v1/dashboard/overview"; why = "ADMIN 可读看板" }
)
foreach ($c in $allowed) {
    $tk = $tokens[$c.who]
    if (-not $tk) { Add-Skip "放行 $($c.who) $($c.path)" "$($c.who) 未取得令牌" ; continue }
    $r = Invoke-Api -Method $c.method -Path $c.path -Token $tk
    Assert-Http $r 200 200 $c.why
}

$notFound = Invoke-Api -Method "GET" -Path "/api/v1/definitely-not-a-route" -Token $tokens["admin"]
Assert-Http $notFound 404 404 "未知路由 -> 404"

$wrongMethod = Invoke-Api -Method "DELETE" -Path "/api/v1/auth/me" -Token $tokens["admin"]
Assert-True ($wrongMethod.Status -eq 404) "方法不匹配落到 404 而非 500" "实际 HTTP $($wrongMethod.Status)"

# ============================================================================
# 3. 看板聚合
# ============================================================================
Write-Section "3. 看板 KPI"
$dash = Invoke-Api -Method "GET" -Path "/api/v1/dashboard/overview" -Token $tokens["hr"]
Assert-Http $dash 200 200 "看板接口返回 200"
if ($dash.Status -eq 200 -and $null -ne $dash.Data) {
    Assert-True ([int] $dash.Data.kpis.totalActiveEmployees -ge 1) "在职员工数 >= 1" "实际 $($dash.Data.kpis.totalActiveEmployees)"
    $rate = [double] $dash.Data.kpis.todayAttendanceRate
    Assert-True ($rate -ge 0.0 -and $rate -le 100.0) "今日出勤率在 0-100 之间" "实际 $rate"
    Assert-True ((Get-JsonArray $dash.Data.deptDistribution).Count -ge 1) "部门分布非空"
    Assert-True ((Get-JsonArray $dash.Data.attendanceTrend).Count -ge 1) "考勤趋势非空"
}

# ============================================================================
# 4. 考勤打卡（会改状态）
# ============================================================================
Write-Section "4. 考勤打卡"
if ($SkipMutating) {
    Add-Skip "上班/下班打卡" "-SkipMutating"
    Add-Skip "今日考勤复核" "-SkipMutating"
} else {
    $ci = Invoke-Api -Method "POST" -Path "/api/v1/attendance/clock-in" -Token $tokens["emp01"]
    $dupIn = ($ci.Status -eq 400 -and $ci.Message -match "已完成上班打卡")
    if ($ci.Status -eq 200) {
        Add-Pass "emp01 上班打卡成功（状态 $($ci.Data.status)，迟到 $($ci.Data.lateMinutes) 分钟）"
    } elseif ($dupIn) {
        Add-Pass "emp01 当日已打卡，重复打卡被正确拒绝（幂等保护生效）"
    } else {
        Add-Fail "emp01 上班打卡" "HTTP $($ci.Status)；响应=$(Format-Body $ci.Text)"
    }

    $ciAgain = Invoke-Api -Method "POST" -Path "/api/v1/attendance/clock-in" -Token $tokens["emp01"]
    Assert-True ($ciAgain.Status -eq 400) "同日二次上班打卡 -> 400" "HTTP $($ciAgain.Status)：$(Format-Body $ciAgain.Text)"

    $co = Invoke-Api -Method "POST" -Path "/api/v1/attendance/clock-out" -Token $tokens["emp01"]
    Assert-Http $co 200 200 "emp01 下班打卡成功"

    $today = Invoke-Api -Method "GET" -Path "/api/v1/attendance/today" -Token $tokens["emp01"]
    Assert-Http $today 200 200 "emp01 今日考勤可查"
    if ($today.Status -eq 200 -and $null -ne $today.Data) {
        Assert-True (-not [string]::IsNullOrEmpty([string] $today.Data.clockInTime)) "上班打卡时间已落库"
        Assert-True (-not [string]::IsNullOrEmpty([string] $today.Data.clockOutTime)) "下班打卡时间已落库"
        Assert-True (@("NORMAL", "LATE", "EARLY_LEAVE", "LATE_AND_EARLY") -contains [string] $today.Data.status) "考勤状态取值合法" "实际 $($today.Data.status)"
    }

    $myAtt = Invoke-Api -Method "GET" -Path "/api/v1/attendance/my" -Token $tokens["emp01"]
    Assert-Http $myAtt 200 200 "emp01 月度考勤汇总可查"
    if ($myAtt.Status -eq 200 -and $null -ne $myAtt.Data) {
        Assert-True ([int] $myAtt.Data.summary.actualAttendDays -ge 1) "本月至少 1 条考勤记录"
        Assert-Equal $PayMonth ([string] $myAtt.Data.summary.month) "汇总月份默认当月"
    }

    $empUpdate = Invoke-Api -Method "PUT" -Path "/api/v1/attendance/1" -Token $tokens["emp01"] -Body "{""status"":""NORMAL""}"
    Assert-Http $empUpdate 403 403 "EMPLOYEE 不可修正考勤（仅 ADMIN/HR）"
}

# ============================================================================
# 5. 申请 + 审批 + 年假扣减（会改状态）
# ============================================================================
Write-Section "5. 请假申请与审批扣年假"
if ($SkipMutating) {
    Add-Skip "提交请假 / 审批扣年假" "-SkipMutating"
} else {
    $subType = "ANNUAL"
    $days = $LeaveDays
    $balBefore = [double]::NaN
    if ($me.Status -ne 200 -or $null -eq $me.Data) {
        # 余额读不到时绝不能降级成事假继续跑，那会把「鉴权挂了」伪装成「用例通过」；
        # 具体 SKIP 在扣减断言处统一记一次，避免重复计数。
        Write-Host "  [WARN] /auth/me 未取得，年假余额未知，扣减断言将被记为 SKIP" -ForegroundColor Yellow
    } else {
        $balBefore = [double] $me.Data.annualLeaveBalance
        if ($balBefore -lt $LeaveDays) {
            if ($balBefore -ge 0.5) {
                $days = 0.5
                Write-Host "  [NOTE] emp01 年假余额 $balBefore 不足 $LeaveDays 天，改用 0.5 天" -ForegroundColor Yellow
            } else {
                $subType = "PERSONAL"
                $days = 0.5
                Write-Host "  [NOTE] emp01 年假余额已耗尽，本用例改用事假，扣减断言记为 SKIP" -ForegroundColor Yellow
            }
        }
    }

    $missing = Invoke-Api -Method "POST" -Path "/api/v1/requests" -Token $tokens["emp01"] -Body "{""category"":""LEAVE"",""subType"":""ANNUAL"",""startTime"":""2026-01-05 09:00:00"",""endTime"":""2026-01-05 18:00:00""}"
    Assert-Http $missing 400 400 "申请缺少 duration/reason -> 400"

    $insufficient = Invoke-Api -Method "POST" -Path "/api/v1/requests" -Token $tokens["emp01"] -Body "{""category"":""LEAVE"",""subType"":""ANNUAL"",""startTime"":""2026-01-05 09:00:00"",""endTime"":""2026-01-15 18:00:00"",""duration"":9999,""reason"":""smoke-insufficient""}"
    Assert-Http $insufficient 400 400 "年假余额不足时提交 -> 400"

    $startTs = (Get-Date).AddDays(30).ToString("yyyy-MM-dd") + " 09:00:00"
    $endTs = (Get-Date).AddDays(30).ToString("yyyy-MM-dd") + " 18:00:00"
    $reqBody = "{""category"":""LEAVE"",""subType"":""$subType"",""startTime"":""$startTs"",""endTime"":""$endTs"",""duration"":$days,""reason"":""smoke-annual-leave""}"
    $created = Invoke-Api -Method "POST" -Path "/api/v1/requests" -Token $tokens["emp01"] -Body $reqBody
    Assert-Http $created 200 200 "emp01 提交 $subType $days 天申请"
    $reqId = 0
    if ($created.Status -eq 200 -and $null -ne $created.Data) {
        $reqId = [int] $created.Data.id
        Assert-True ($reqId -gt 0) "新申请单返回自增 ID" "id=$reqId"
        Assert-Equal "PENDING" ([string] $created.Data.status) "新申请单初始状态 PENDING"
    }

    if ($reqId -gt 0) {
        $selfApprove = Invoke-Api -Method "POST" -Path "/api/v1/requests/$reqId/approve" -Token $tokens["emp01"] -Body "{""action"":""APPROVED""}"
        Assert-Http $selfApprove 403 403 "EMPLOYEE 不可审批"

        $badAction = Invoke-Api -Method "POST" -Path "/api/v1/requests/$reqId/approve" -Token $tokens["hr"] -Body "{""action"":""MAYBE""}"
        Assert-Http $badAction 400 400 "非法审批动作 -> 400"

        $ghost = Invoke-Api -Method "POST" -Path "/api/v1/requests/99999999/approve" -Token $tokens["hr"] -Body "{""action"":""APPROVED""}"
        Assert-Http $ghost 404 404 "审批不存在的申请单 -> 404"

        $approved = Invoke-Api -Method "POST" -Path "/api/v1/requests/$reqId/approve" -Token $tokens["hr"] -Body "{""action"":""APPROVED"",""approveRemark"":""smoke-auto-approved""}"
        Assert-Http $approved 200 200 "HR 审批通过"
        if ($approved.Status -eq 200) {
            Assert-Equal "APPROVED" ([string] $approved.Data.status) "审批结果状态为 APPROVED"
        }

        $dup = Invoke-Api -Method "POST" -Path "/api/v1/requests/$reqId/approve" -Token $tokens["hr"] -Body "{""action"":""APPROVED""}"
        Assert-Http $dup 400 400 "重复审批同一单 -> 400"

        if ([double]::IsNaN($balBefore)) {
            Add-Skip "年假扣减金额核对" "/auth/me 未取得，年假余额未知（见第 1 节失败项）"
        } elseif ($subType -eq "ANNUAL") {
            $after = Invoke-Api -Method "GET" -Path "/api/v1/auth/me" -Token $tokens["emp01"]
            Assert-Http $after 200 200 "审批后重查个人档案"
            if ($after.Status -eq 200) {
                $balAfter = [double] $after.Data.annualLeaveBalance
                Assert-True (Test-MoneyClose ($balBefore - $balAfter) $days 0.05) `
                    "审批通过扣减年假 $days 天（$balBefore -> $balAfter）" `
                    "余额变化=$(($balBefore - $balAfter))，期望=$days"
            }
        } else {
            Add-Skip "年假扣减金额核对" "emp01 年假余额不足，本单为事假"
        }

        # 撤回链路：新建一单再撤回，且撤回后不可重复撤回
        $c2 = Invoke-Api -Method "POST" -Path "/api/v1/requests" -Token $tokens["emp01"] -Body "{""category"":""LEAVE"",""subType"":""PERSONAL"",""startTime"":""$startTs"",""endTime"":""$endTs"",""duration"":0.5,""reason"":""smoke-cancel-me""}"
        Assert-Http $c2 200 200 "emp01 再提交一单用于撤回"
        if ($c2.Status -eq 200 -and $null -ne $c2.Data) {
            $id2 = [int] $c2.Data.id
            $otherCancel = Invoke-Api -Method "POST" -Path "/api/v1/requests/$id2/cancel" -Token $tokens["manager"] -Body "{}"
            Assert-Http $otherCancel 403 403 "他人不可撤回本人申请"
            $okCancel = Invoke-Api -Method "POST" -Path "/api/v1/requests/$id2/cancel" -Token $tokens["emp01"] -Body "{}"
            Assert-Http $okCancel 200 200 "本人撤回成功"
            $againCancel = Invoke-Api -Method "POST" -Path "/api/v1/requests/$id2/cancel" -Token $tokens["emp01"] -Body "{}"
            Assert-Http $againCancel 400 400 "撤回后不可重复撤回"
        }
    } else {
        Add-Skip "审批与扣年假全链路" "未取得申请单 ID"
    }

    $myReq = Invoke-Api -Method "GET" -Path "/api/v1/requests/my" -Token $tokens["emp01"]
    Assert-Http $myReq 200 200 "emp01 可查看本人申请列表"
    if ($myReq.Status -eq 200) {
        $myReqRows = Get-JsonArray $myReq.Data
        Assert-True ($myReqRows.Count -ge 1) "本人申请列表至少 1 条" "实际 $($myReqRows.Count)"
    }
}

# ============================================================================
# 6. 绩效（自评 / 复核 的鉴权与参数校验）
# ============================================================================
Write-Section "6. 绩效"
$perfList = Invoke-Api -Method "GET" -Path "/api/v1/performances" -Token $tokens["emp01"]
Assert-Http $perfList 200 200 "EMPLOYEE 可查看本人绩效"
$initDenied = Invoke-Api -Method "POST" -Path "/api/v1/performances/init-cycle" -Token $tokens["manager"] -Body "{""cycleName"":""smoke-cycle""}"
Assert-Http $initDenied 403 403 "MANAGER 不可开启绩效周期"
$badEval = Invoke-Api -Method "PUT" -Path "/api/v1/performances/99999999/self-eval" -Token $tokens["emp01"] -Body "{""selfScore"":150,""selfComment"":""x""}"
Assert-True ($badEval.Status -in @(400, 404)) "越界自评分 / 不存在记录 -> 400 或 404" "实际 HTTP $($badEval.Status)：$(Format-Body $badEval.Text)"

# ============================================================================
# 7. 薪酬：生成 + 工资条金额逐行核对（会改状态）
# ============================================================================
Write-Section "7. 薪酬生成与金额核对（账期 $PayMonth）"
if ($SkipMutating) {
    Add-Skip "一键生成工资单" "-SkipMutating"
} else {
    $genDenied = Invoke-Api -Method "POST" -Path "/api/v1/payrolls/generate" -Token $tokens["emp01"] -Body "{""payMonth"":""$PayMonth""}"
    Assert-Http $genDenied 403 403 "EMPLOYEE 不可生成工资单"

    $genBad = Invoke-Api -Method "POST" -Path "/api/v1/payrolls/generate" -Token $tokens["hr"] -Body "{not-json"
    Assert-Http $genBad 400 400 "生成工资单请求体非法 JSON -> 400"

    $gen = Invoke-Api -Method "POST" -Path "/api/v1/payrolls/generate" -Token $tokens["hr"] -Body "{""payMonth"":""$PayMonth""}"
    Assert-Http $gen 200 200 "HR 一键生成 $PayMonth 工资单"
    if ($gen.Status -eq 200 -and $null -ne $gen.Data) {
        Assert-Equal $PayMonth ([string] $gen.Data.payMonth) "回显账期一致"
        Assert-True ([int] $gen.Data.generatedCount -ge 1) "处理人数 >= 1" "实际 $($gen.Data.generatedCount)"
    }

    $list = Invoke-Api -Method "GET" -Path "/api/v1/payrolls?payMonth=$PayMonth&pageSize=100" -Token $tokens["hr"]
    Assert-Http $list 200 200 "HR 查询 $PayMonth 工资总表"
    $checked = 0
    $taxMismatch = 0
    $netMismatch = 0
    if ($list.Status -eq 200 -and $null -ne $list.Data) {
        Assert-True ([int] $list.Data.total -ge 1) "工资总表总数 >= 1" "total=$($list.Data.total)"
        Assert-Equal 1 ([int] $list.Data.page) "分页回显 page"
        Assert-Equal 100 ([int] $list.Data.pageSize) "分页回显 pageSize（100 未被夹紧）"
        $rows = Get-JsonArray $list.Data.list
        Assert-True ($rows.Count -le 100) "分页结果不超过 pageSize"
        foreach ($row in $rows) {
            $checked++
            $base = [double] $row.baseSalary
            $bonus = [double] $row.bonus
            $ot = [double] $row.overtimePay
            $att = [double] $row.attendanceDeduction
            $ss = [double] $row.socialSecurity
            $tax = [double] $row.tax
            $net = [double] $row.netSalary

            $taxable = $base + $bonus + $ot - $att - $ss - 5000.0
            $expTax = Get-ExpectedTax $taxable
            $expNet = $base + $bonus + $ot - $att - $ss - $expTax

            if (-not (Test-MoneyClose $tax $expTax 0.02)) {
                $taxMismatch++
                Add-Fail "工资条 #$($row.id) 个税分档核对" "后端 tax=$tax 客户端复算=$([Math]::Round($expTax, 2)) taxable=$([Math]::Round($taxable, 2))"
            }
            if (-not (Test-MoneyClose $net $expNet 0.02)) {
                $netMismatch++
                Add-Fail "工资条 #$($row.id) 实发口径核对" "后端 net=$net 客户端复算=$([Math]::Round($expNet, 2))"
            }
            if ($row.payMonth -ne $PayMonth) {
                Add-Fail "工资条 #$($row.id) 账期一致性" "行内 payMonth=$($row.payMonth) 期望=$PayMonth"
            }
            if ($base -le 0.0) {
                Add-Fail "工资条 #$($row.id) 基本工资应 > 0" "base=$base"
            }
        }
        if ($checked -eq 0) {
            Add-Fail "工资总表可核对" "list 为空，无法核对金额"
        }
    }
    if ($checked -gt 0 -and $taxMismatch -eq 0 -and $netMismatch -eq 0) {
        Add-Pass "逐条核对 $checked 张工资条：个税分档 + 实发口径全部一致"
    }
    if ($taxMismatch -gt 0 -or $netMismatch -gt 0 -or $checked -eq 0) {
        Write-Host "  [HINT] 若上面出现分档不一致，请核对 calculateTax 的四档阈值与速扣数。" -ForegroundColor DarkYellow
    }

    $myPay = Invoke-Api -Method "GET" -Path "/api/v1/payrolls/my" -Token $tokens["emp01"]
    Assert-Http $myPay 200 200 "EMPLOYEE 可查本人工资条（仅已发放）"
    if ($myPay.Status -eq 200) {
        $myPayRows = Get-JsonArray $myPay.Data
        # 类型判定走原始报文：data 为 null 时 $myPay.Data.GetType() 会先把脚本自己搞崩
        Assert-True ($myPay.Text -match '"data"\s*:\s*\[') "本人工资条 data 为 JSON 数组" "响应=$(Format-Body $myPay.Text)"
        if ($myPayRows.Count -eq 0) {
            Write-Host "  [NOTE] emp01 尚无已发放（PAID）工资条，属正常状态。" -ForegroundColor Yellow
        }
    }

    $updBad = Invoke-Api -Method "PUT" -Path "/api/v1/payrolls/99999999" -Token $tokens["hr"] -Body "{""bonus"":100}"
    Assert-True ($updBad.Status -in @(400, 404)) "调整不存在的工资单 -> 400 或 404" "实际 HTTP $($updBad.Status)"

    $payDenied = Invoke-Api -Method "POST" -Path "/api/v1/payrolls/99999999/pay" -Token $tokens["emp01"] -Body "{}"
    Assert-Http $payDenied 403 403 "EMPLOYEE 不可发放工资"

    $batchBad = Invoke-Api -Method "POST" -Path "/api/v1/payrolls/batch-pay" -Token $tokens["hr"] -Body "{}"
    Assert-Http $batchBad 400 400 "批量发薪未指定 payMonth -> 400"
    # 注意：这里刻意不调用成功的 batch-pay，避免把 DRAFT 全部置为 PAID 影响后续回归
}

# ============================================================================
# 8. 审计日志（写操作应留下痕迹）
# ============================================================================
Write-Section "8. 审计日志"
if ($SkipMutating) {
    Add-Skip "审批 / 生成工资审计写入" "-SkipMutating"
} else {
    $audit = Invoke-Api -Method "GET" -Path "/api/v1/system/audit-logs?pageSize=20" -Token $tokens["admin"]
    Assert-Http $audit 200 200 "ADMIN 读取审计日志"
    if ($audit.Status -eq 200 -and $null -ne $audit.Data) {
        $logs = Get-JsonArray $audit.Data.list
        Assert-True ($logs.Count -ge 1) "审计日志非空" "实际 $($logs.Count)"
        $found = $false
        foreach ($l in $logs) {
            $act = [string] $l.action
            if ($act -match "审批|生成|登录|发薪") { $found = $true; break }
        }
        Assert-True $found "最近日志包含本轮回归触发的动作（审批/生成/登录/发薪）" "样例：$(Format-Body (($logs | ForEach-Object { $_.action }) -join ","))"
    }
}

# ============================================================================
# 汇总
# ============================================================================
Write-Section "结果汇总"
Write-Host "  通过 $script:PassCount / 失败 $script:FailCount / 跳过 $script:SkipCount" -ForegroundColor White
if ($script:FailCount -gt 0) {
    Write-Host ""
    Write-Host "失败明细：" -ForegroundColor Red
    foreach ($f in $script:Failures) {
        Write-Host "  - $f" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "冒烟回归未通过。" -ForegroundColor Red
    exit 1
}
Write-Host "冒烟回归全部通过。" -ForegroundColor Green
exit 0
