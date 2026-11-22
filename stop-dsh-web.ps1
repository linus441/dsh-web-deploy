param()

$root = $PSScriptRoot
$port = 18760
$infoPath = Join-Path $root 'install.json'
if (Test-Path $infoPath) {
    try { $port = [int]((Get-Content $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json).port) } catch { }
}
$listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
if ($listener) {
    foreach ($item in $listener) {
        & taskkill.exe /PID $item.OwningProcess /T /F 2>$null | Out-Null
    }
    Write-Host 'DSH Web 已停止'
} else {
    Write-Host 'DSH Web 未在运行'
}
