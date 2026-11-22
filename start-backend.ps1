param(
    [switch]$Rebuild
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackendDir = Join-Path $RootDir "backend-cangjie"
$MysqlIni = Join-Path $RootDir "mysql-data\my.ini"
$MysqlBin = "C:\Program Files\MySQL\MySQL Server 8.0\bin"
$MysqldExe = Join-Path $MysqlBin "mysqld.exe"
$StdxDynamic = "D:\cangjie-stdx\windows_x86_64_cjnative\dynamic\stdx"

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
    if (-not (Test-Path $MysqldExe)) {
        throw "MySQL server binary not found: $MysqldExe"
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
if (-not (Test-Path "D:\cangjie\envsetup.ps1")) {
    throw "Cangjie SDK envsetup.ps1 not found at D:\cangjie\envsetup.ps1"
}
. "D:\cangjie\envsetup.ps1"
$env:PATH = "$StdxDynamic;$MysqlBin;" + $env:PATH

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
