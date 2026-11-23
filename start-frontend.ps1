$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$FrontendDir = Join-Path $RootDir "frontend-web"

Set-Location $FrontendDir
if (-not (Test-Path (Join-Path $FrontendDir "node_modules"))) {
    Write-Host "Installing frontend dependencies with pnpm..."
    pnpm install
}

Write-Host "Starting Vue 3 Frontend Dev Server on http://127.0.0.1:5173 (proxying /api -> http://127.0.0.1:8080)..."
pnpm dev
