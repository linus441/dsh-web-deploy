param(
    [string]$InstallRoot = "",
    [string]$DshVersion = "",
    [string]$ExpectedSha512 = "",
    [string]$PluginCommit = "",
    [string]$InstallerPath = "",
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"
$PackageVersion = "0.0.0"
$versionFile = Join-Path $PSScriptRoot "VERSION"
if (Test-Path $versionFile) { $PackageVersion = (Get-Content $versionFile -Raw -Encoding UTF8).Trim() }
if (-not $InstallRoot) {
    $InstallRoot = Join-Path $env:LOCALAPPDATA "DSH-Web"
}
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$infoPath = Join-Path $InstallRoot "install.json"
if (-not (Test-Path $infoPath)) { throw "找不到 install.json，无法确定当前安装信息：$infoPath" }
$info = Get-Content $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json
$port = [int]$info.port
$currentVersion = [string]$info.dshVersion
$currentCommit = [string]$info.pluginCommit
$pluginRepo = "luowang-ui/dsh-purge-plus"

Write-Host ("DSH Web 部署包 v{0}，检查更新..." -f $PackageVersion) -ForegroundColor Cyan
if (-not $DshVersion) {
    try {
        $feed = Invoke-WebRequest -Uri "https://download.deepseek.com/dsh-desk/feeds/win-x64/nightly.yml" -UseBasicParsing -TimeoutSec 30
        $feedText = if ($feed.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($feed.Content) } else { [string]$feed.Content }
        $versionMatch = [regex]::Match($feedText, '(?m)^version:\s*(\S+)')
        $hashMatch = [regex]::Match($feedText, '(?ms)^sha512:\s*>\-\s*\r?\n\s*([A-Za-z0-9+/=]+)')
        if ($versionMatch.Success) { $DshVersion = $versionMatch.Groups[1].Value }
        if (-not $ExpectedSha512 -and $hashMatch.Success) { $ExpectedSha512 = $hashMatch.Groups[1].Value }
    } catch {
        Write-Host "  无法读取 DSH 更新清单，使用当前版本。" -ForegroundColor Yellow
        $DshVersion = $currentVersion
    }
}
if (-not $DshVersion) { $DshVersion = $currentVersion }

if (-not $PluginCommit) {
    try {
        $api = Invoke-RestMethod -Uri "https://api.github.com/repos/$pluginRepo/commits/main" -Headers @{ "User-Agent" = "dsh-web-deploy-updater" } -TimeoutSec 30
        if ($api.sha) { $PluginCommit = [string]$api.sha }
    } catch {
        Write-Host "  无法查询插件最新 commit，使用当前版本。" -ForegroundColor Yellow
        $PluginCommit = $currentCommit
    }
}
if (-not $PluginCommit) { $PluginCommit = $currentCommit }

Write-Host ("  DSH: {0} -> {1}" -f $currentVersion, $DshVersion)
Write-Host ("  插件 commit: {0} -> {1}" -f $currentCommit, $PluginCommit)

$listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
if ($listener) {
    Write-Host "停止当前网页端..." -ForegroundColor Cyan
    foreach ($item in $listener) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($item.OwningProcess)" -ErrorAction SilentlyContinue
        if ($p -and $p.CommandLine -and $p.CommandLine.Contains($InstallRoot)) {
            & taskkill.exe /PID $item.OwningProcess /T /F 2>$null | Out-Null
        }
    }
    Start-Sleep -Seconds 2
}
Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($InstallRoot) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$appDir = Join-Path $InstallRoot "app"
$pluginDir = Join-Path $InstallRoot "plugins-src"
$appBackup = Join-Path $InstallRoot ("app.bak-" + $stamp)
$pluginBackup = Join-Path $InstallRoot ("plugins-src.bak-" + $stamp)
if (Test-Path $appDir) { Move-Item $appDir $appBackup -Force }
if (Test-Path $pluginDir) { Move-Item $pluginDir $pluginBackup -Force }

$installArgs = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "install.ps1"),
    "-InstallRoot", $InstallRoot, "-Port", "$port", "-DshVersion", $DshVersion,
    "-PluginCommit", $PluginCommit, "-Force", "-NoStart"
)
$installArgs += @("-ExpectedSha512", $ExpectedSha512)
if ($InstallerPath) { $installArgs += @("-InstallerPath", $InstallerPath) }

$code = 0
try {
    & powershell.exe @installArgs
    $code = $LASTEXITCODE
} catch {
    $code = 1
}

if ($code -ne 0) {
    Write-Host "更新失败，恢复旧版本..." -ForegroundColor Red
    if (Test-Path $appDir) { Remove-Item $appDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $pluginDir) { Remove-Item $pluginDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $appBackup) { Move-Item $appBackup $appDir -Force }
    if (Test-Path $pluginBackup) { Move-Item $pluginBackup $pluginDir -Force }
    Write-Host "已恢复旧版本；新的 DSH/插件可能改动了锚点，未覆盖当前安装。" -ForegroundColor Yellow
    exit 1
}

Write-Host "更新完成。旧版本备份：" -ForegroundColor Green
Write-Host ("  " + $appBackup)
Write-Host ("  " + $pluginBackup)
if (-not $NoStart) {
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $InstallRoot "start-dsh-web.ps1")) -WindowStyle Hidden
    $urlFile = Join-Path $InstallRoot "current-url.txt"
    for ($i = 0; $i -lt 240; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Path $urlFile) {
            $url = (Get-Content $urlFile -Raw).Trim()
            if ($url) { Write-Host ("网页端已启动：" + $url); break }
        }
    }
}
