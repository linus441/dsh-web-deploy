param(
    [string]$InstallRoot = "",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if (-not $InstallRoot) {
    $InstallRoot = Join-Path $env:LOCALAPPDATA "DSH-Web"
}
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
if (-not (Test-Path $InstallRoot)) {
    Write-Host "没有找到安装目录：$InstallRoot" -ForegroundColor Yellow
    exit 0
}

$port = 18760
$infoPath = Join-Path $InstallRoot 'install.json'
if (Test-Path $infoPath) {
    try { $port = [int]((Get-Content $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json).port) } catch { }
}

if (-not $Force) {
    Write-Host "即将删除：$InstallRoot"
    Write-Host "只会删除这个独立目录和桌面快捷方式，不会碰你的桌面版 DSH 或 ~/.dsh。"
    $answer = Read-Host "确认卸载？(y/N)"
    if ($answer -notmatch '^[Yy]') { Write-Host "已取消"; exit 0 }
}

$listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
if ($listener) {
    foreach ($item in $listener) {
        & taskkill.exe /PID $item.OwningProcess /T /F 2>$null | Out-Null
    }
}
Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($InstallRoot) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$desktop = [Environment]::GetFolderPath("Desktop")
$lnkPath = Join-Path $desktop "DSH Web.lnk"
if (Test-Path $lnkPath) {
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $shortcut = $wsh.CreateShortcut($lnkPath)
        if ($shortcut.Arguments -and $shortcut.Arguments.Contains($InstallRoot)) {
            Remove-Item $lnkPath -Force
            Write-Host "已删除桌面快捷方式"
        }
    } catch { }
}

Remove-Item $InstallRoot -Recurse -Force
Write-Host "卸载完成。" -ForegroundColor Green
Write-Host "桌面版 DSH 和 %USERPROFILE%\.dsh 未被修改。"
