param(
    [switch]$Rebuild,
    [string]$CangjieHome = $env:CANGJIE_HOME,
    [string]$StdxHome = $env:STDX_HOME,
    [string]$MysqlBin = $env:MYSQL_BIN
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackendDir = Join-Path $RootDir "backend-cangjie"
$MysqlIni = Join-Path $RootDir "mysql-data\my.ini"

function Resolve-Candidate {
    param([string]$Supplied, [string[]]$Candidates, [string]$Label)
    if ($Supplied) {
        if (Test-Path $Supplied) { return $Supplied }
        throw "$Label supplied via parameter/env does not exist: $Supplied"
    }
    foreach ($c in $Candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

# --- MySQL client/server binaries (search common install roots + PATH) ---
function Resolve-MysqlBinDir {
    param([string]$Supplied)
    if ($Supplied) {
        if (Test-Path (Join-Path $Supplied "mysql.exe")) { return $Supplied }
        if (Test-Path $Supplied) { return Split-Path -Parent $Supplied }
        throw "MYSQL_BIN does not contain mysql.exe: $Supplied"
    }
    $pathCmd = Get-Command mysql.exe -ErrorAction SilentlyContinue
    if ($pathCmd) { return Split-Path -Parent $pathCmd.Source }
    $roots = @(
        "C:\Program Files\MySQL", "C:\Program Files (x86)\MySQL",
        "D:\Program Files\MySQL", "D:\MySQL",
        "E:\Program Files\MySQL", $env:ProgramFiles, ${env:ProgramFiles(x86)}
    )
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path $root)) { continue }
        $hit = Get-ChildItem -Path $root -Filter "mysql.exe" -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.DirectoryName }
    }
    return $null
}

$MysqlBinDir = Resolve-MysqlBinDir -Supplied $MysqlBin
$MysqldExe = if ($MysqlBinDir) { Join-Path $MysqlBinDir "mysqld.exe" } else { $null }

# --- Cangjie SDK + stdx ---
$EnvSetup = Resolve-Candidate -Supplied $null -Candidates @(
    if ($CangjieHome) { Join-Path $CangjieHome "envsetup.ps1" }
    "D:\cangjie\envsetup.ps1"
    (Join-Path ${env:ProgramFiles} "Cangjie\envsetup.ps1")
) -Label "Cangjie envsetup.ps1"

$StdxDynamic = Resolve-Candidate -Supplied $null -Candidates @(
    if ($StdxHome) { Join-Path $StdxHome "windows_x86_64_cjnative\dynamic\stdx" }
    "D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx"
    if ($CangjieHome) { Join-Path (Split-Path -Parent $CangjieHome) "cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx" }
) -Label "stdx dynamic dir"

function Test-PortOpen {
    param([string]$HostName, [int]$Port)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $ar = $client.BeginConnect($HostName, $Port, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne(500, $false)
        if ($ok -and $client.Connected) {
            $client.EndConnect($ar)
            $client.Close()
            return $true
        }
        $client.Close()
    } catch {}
    return $false
}

Write-Host "[1/3] Checking MySQL (127.0.0.1:3306)..."
if (-not (Test-PortOpen -HostName "127.0.0.1" -Port 3306)) {
    if (-not $MysqldExe -or -not (Test-Path $MysqldExe)) {
        throw "MySQL server binary not found. Pass -MysqlBin <path\to\bin> or start MySQL manually."
    }
    if (-not (Test-Path $MysqlIni)) {
        throw "MySQL defaults file not found: $MysqlIni"
    }
    Write-Host "Starting user-space MySQL daemon using $MysqlIni ..."
    Start-Process -FilePath $MysqldExe -ArgumentList "--defaults-file=$MysqlIni" -WindowStyle Hidden
    $waited = 0
    while (-not (Test-PortOpen -HostName "127.0.0.1" -Port 3306)) {
        Start-Sleep -Milliseconds 500
        $waited += 500
        if ($waited -gt 15000) {
            throw "Timed out waiting for MySQL on 127.0.0.1:3306"
        }
    }
}
Write-Host "MySQL is ready on 127.0.0.1:3306."

Write-Host "[2/3] Loading Cangjie 1.0.5 + stdx environment..."
if (-not $EnvSetup) {
    throw "Cangjie SDK envsetup.ps1 not found. Install the SDK and pass -CangjieHome <dir> (or set CANGJIE_HOME)."
}
if (-not $StdxDynamic) {
    throw "stdx dynamic library dir not found. Pass -StdxHome <cangjie-stdx dir> (or set STDX_HOME)."
}
Write-Host "  envsetup : $EnvSetup"
Write-Host "  stdx     : $StdxDynamic"
. $EnvSetup
$extraPath = @($StdxDynamic) + $(if ($MysqlBinDir) { @($MysqlBinDir) } else { @() })
$env:PATH = ($extraPath -join ";") + ";" + $env:PATH

Set-Location $BackendDir
$ExePath = Join-Path $BackendDir "target\release\bin\main.exe"
if ($Rebuild -or (-not (Test-Path $ExePath))) {
    Write-Host "[3/3] Building Cangjie backend with cjpm build..."
    cjpm build
    if ($LASTEXITCODE -ne 0) {
        throw "cjpm build failed with exit code $LASTEXITCODE"
    }
} else {
    Write-Host "[3/3] Using compiled backend binary: $ExePath (pass -Rebuild to recompile)"
}

Write-Host "Starting Cangjie HRMS Backend on http://127.0.0.1:8080 ..."
& $ExePath
