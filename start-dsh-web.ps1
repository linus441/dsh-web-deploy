param([switch]$NoOpen)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$port = 18760
$infoPath = Join-Path $root 'install.json'
if (Test-Path $infoPath) {
    try { $port = [int]((Get-Content $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json).port) } catch { }
}
$urlFile = Join-Path $root 'current-url.txt'
$logFile = Join-Path $root 'logs\web.log'
$errFile = Join-Path $root 'logs\web-err.log'
$lockFile = Join-Path $root 'starting.lock'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'logs') | Out-Null

function Get-DshWebUrl {
    if (-not (Test-Path $logFile)) { return $null }
    $line = Get-Content $logFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^dsh web: (http://\S+)' } | Select-Object -First 1
    if ($line -and $line -match '^dsh web: (http://\S+)') { return $Matches[1] }
    return $null
}

function Open-DshWeb($url) {
    if (-not $NoOpen) { Start-Process $url }
}

$listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
if ($listener) {
    $url = $null
    if (Test-Path $urlFile) { $url = (Get-Content $urlFile -Raw).Trim() }
    if (-not $url) { $url = Get-DshWebUrl }
    if ($url) {
        $url | Set-Content -Path $urlFile -Encoding ASCII
        Write-Host "DSH Web 已在运行：$url"
        Open-DshWeb $url
    } else {
        Write-Host "DSH Web 已在运行：http://127.0.0.1:$port/（请使用已打开的浏览器标签）"
    }
    exit 0
}

$existing = $false
try {
    $existing = [bool](Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match [regex]::Escape($root) -and $_.CommandLine -match '(^|\s)web(\s|$)' })
} catch { }

$isStarter = $false
if (-not $existing -and (Test-Path $lockFile)) {
    try {
        $age = (Get-Date) - (Get-Item $lockFile).LastWriteTime
        if ($age.TotalSeconds -lt 300) {
            $existing = $true
        } else {
            Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}
if (-not $existing) {
    try {
        $lock = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $lock.Close()
        $isStarter = $true
    } catch {
        $existing = $true
    }
}

if ($existing) {
    Write-Host 'DSH Web 正在启动，等待就绪...'
    $url = $null
    for ($i = 0; $i -lt 480; $i++) {
        Start-Sleep -Milliseconds 500
        $url = Get-DshWebUrl
        if ($url) { break }
    }
    if ($url) {
        $url | Set-Content -Path $urlFile -Encoding ASCII
        Write-Host "DSH Web: $url"
        Open-DshWeb $url
        exit 0
    }
    Write-Host 'DSH Web 已在启动中，但暂时没有输出地址；请稍后再双击一次。' -ForegroundColor Yellow
    exit 0
}

$env:DSH_HOME = Join-Path $root 'home'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Remove-Item $logFile, $errFile -ErrorAction SilentlyContinue
Write-Host '正在启动 DSH Web，请稍候...'

$dsh = Join-Path $root 'app\resources\runtime\cli\bin\dsh.cmd'
try {
    $proc = Start-Process -FilePath $dsh -ArgumentList @('web', '--host', '127.0.0.1', '--port', "$port", '--no-open') -RedirectStandardOutput $logFile -RedirectStandardError $errFile -NoNewWindow -PassThru
} catch {
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
    Write-Host "DSH Web 启动失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$url = $null
for ($i = 0; $i -lt 480; $i++) {
    Start-Sleep -Milliseconds 500
    $url = Get-DshWebUrl
    if ($url) { break }
    if ($proc.HasExited) { break }
}
Remove-Item $lockFile -Force -ErrorAction SilentlyContinue

if ($url) {
    $url | Set-Content -Path $urlFile -Encoding ASCII
    Write-Host ("DSH Web: {0}（启动 {1:N1} 秒）" -f $url, $sw.Elapsed.TotalSeconds)
    Open-DshWeb $url
} else {
    Write-Host 'DSH Web 启动失败，错误输出：' -ForegroundColor Red
    if (Test-Path $errFile) { Get-Content $errFile -Tail 30 }
    if (Test-Path $logFile) { Get-Content $logFile -Tail 30 }
    Read-Host '按回车键退出'
    exit 1
}

$proc.WaitForExit()
