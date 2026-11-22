param(
    [string]$InstallRoot = "",
    [int]$Port = 18760,
    [string]$DshVersion = "0.2.2-rc.1",
    [string]$PluginRepo = "luowang-ui/dsh-purge-plus",
    [string]$PluginCommit = "29860ae10f28ea0cf56484bc4df88078699a76f8",
    [string]$InstallerPath = "",
    [string]$ExpectedSha512 = "",
    [switch]$NoStart,
    [switch]$NoShortcut,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$AppName = "DSH Web"
$PackageVersion = "0.0.0"
$versionFile = Join-Path $PSScriptRoot "VERSION"
if (Test-Path $versionFile) { $PackageVersion = (Get-Content $versionFile -Raw -Encoding UTF8).Trim() }
Write-Host ("DSH Web 部署包 v{0}" -f $PackageVersion) -ForegroundColor Green
if (-not $ExpectedSha512 -and $DshVersion -eq "0.2.2-rc.1") {
    $ExpectedSha512 = "swcK0J6ofGkaAWLRpOes2ca7CWO8vuM5Vp0FRnQ/DG3q+Z+OhvsgLz3hIiSYpRUETY+fEz+Ww86fNa0jiVIifw=="
}
if (-not $InstallRoot) {
    $InstallRoot = Join-Path $env:LOCALAPPDATA "DSH-Web"
}
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$AppDir = Join-Path $InstallRoot "app"
$HomeDir = Join-Path $InstallRoot "home"
$LogDir = Join-Path $InstallRoot "logs"
$PluginDir = Join-Path $InstallRoot "plugins-src\dsh-purge-plus"
$ProfileDir = Join-Path $HomeDir "profiles\web"
$DshCmd = Join-Path $AppDir "resources\runtime\cli\bin\dsh.cmd"
$SevenZip = Join-Path $PSScriptRoot "tools\7z.exe"
$HostPatch = Join-Path $PSScriptRoot "patches\apply-host-022.mjs"
$TotalSteps = 9
$ScriptWatch = [Diagnostics.Stopwatch]::StartNew()

function Step([int]$n, [string]$text) {
    $pct = if ($n -ge $TotalSteps) { 100 } else { [math]::Round((($n - 1) / $TotalSteps) * 100) }
    Write-Host ""
    Write-Host ("[{0}/{1}] 进度 {2}% | {3}" -f $n, $TotalSteps, $pct, $text) -ForegroundColor Cyan
    Write-Host ("  已用时 {0:N1} 秒" -f $ScriptWatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
}
function Estimate-Download([double]$bytesPerSecond) {
    if ($bytesPerSecond -le 0) { return "" }
    $seconds = 299593552 / $bytesPerSecond
    if ($seconds -lt 60) { return ("约 {0:N0} 秒" -f $seconds) }
    return ("约 {0:N1} 分钟" -f ($seconds / 60))
}
function Fail([string]$text) {
    Write-Host ""
    Write-Host ("安装失败：" + $text) -ForegroundColor Red
    exit 1
}
function Write-Utf8NoBom([string]$path, [string]$text) {
    $dir = Split-Path -Parent $path
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}
function Read-Text([string]$path) {
    return ((Get-Content -LiteralPath $path -Raw -Encoding UTF8) -replace "`r`n", "`n")
}
function Get-Sha512Base64([string]$path) {
    $sha = [Security.Cryptography.SHA512]::Create()
    $stream = [IO.File]::OpenRead($path)
    try { $hash = $sha.ComputeHash($stream) } finally { $stream.Dispose(); $sha.Dispose() }
    return [Convert]::ToBase64String($hash)
}
function Measure-DownloadSpeed([string]$url) {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) { return 0 }
    $out = & $curl.Source -L --fail --range 0-1048575 --max-time 8 -s -o NUL -w "%{speed_download}" $url 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return 0 }
    $value = 0.0
    if ([double]::TryParse([string]$out, [ref]$value)) { return $value }
    return 0
}
function Download-File([string]$url, [string]$out) {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source -L --fail --retry 3 --retry-delay 2 -# -o $out $url
        if ($LASTEXITCODE -ne 0) { throw "下载失败（curl exit $LASTEXITCODE）：$url" }
    } else {
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 300
    }
}
function Stop-ProcessTree([int]$processId) {
    & taskkill.exe /PID $processId /T /F 2>$null | Out-Null
    Start-Sleep -Seconds 2
}
function Wait-WebUrl([string]$logPath, [int]$seconds) {
    for ($i = 0; $i -lt ($seconds * 2); $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Path $logPath) {
            $line = Get-Content $logPath -ErrorAction SilentlyContinue | Where-Object { $_ -match '^dsh web: (http://\S+)' } | Select-Object -First 1
            if ($line -and $line -match '^dsh web: (http://\S+)') { return $Matches[1] }
        }
    }
    return $null
}

if (-not [Environment]::Is64BitOperatingSystem) { Fail "需要 Windows 64 位系统。" }
if (-not (Test-Path $SevenZip)) { Fail "缺少 tools\7z.exe，请从完整发布包运行。" }
if (Test-Path $InstallRoot) {
    $hasFiles = Get-ChildItem $InstallRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hasFiles -and -not $Force) { Fail "安装目录已存在：$InstallRoot。先运行卸载，或加 -Force 覆盖。" }
}
New-Item -ItemType Directory -Force -Path $InstallRoot, $AppDir, $HomeDir, $LogDir, $ProfileDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallRoot "plugins-src") | Out-Null

Step 1 "检查网络下载通道"
$officialUrl = "https://download.deepseek.com/dsh-desk/bin/win-x64/deepseek-harness-$DshVersion-win-x64.exe"
$mirrorUrl = "https://github.com/LinJianKun/deepseek-harness-desktop-mirror/releases/download/v$DshVersion/deepseek-harness-$DshVersion-win-x64.exe"
$channels = @(
    [pscustomobject]@{ Name = "official"; Url = $officialUrl },
    [pscustomobject]@{ Name = "github-mirror"; Url = $mirrorUrl }
)
$chosen = $null
$chosenSpeed = 0.0
foreach ($channel in $channels) {
    $speed = Measure-DownloadSpeed $channel.Url
    $mb = [math]::Round($speed / 1MB, 2)
    Write-Host ("  {0}: {1} MB/s" -f $channel.Name, $mb)
    if ($speed -gt $chosenSpeed) {
        $chosenSpeed = $speed
        $chosen = $channel
    }
}
if (-not $chosen) {
    if ($InstallerPath) {
        $chosen = [pscustomobject]@{ Name = "local"; Url = $InstallerPath }
    } else {
        Fail "所有下载通道都不可用，请检查网络后重试。"
    }
}
Write-Host ("  使用通道：{0}" -f $chosen.Name) -ForegroundColor Green
$eta = Estimate-Download $chosenSpeed
if ($InstallerPath) {
    Write-Host "  使用本地安装包，跳过 DSH 下载；预计总安装 2-5 分钟" -ForegroundColor DarkGray
} elseif ($eta) {
    Write-Host ("  预计 DSH 下载 {0}，总安装约 3-8 分钟" -f $eta) -ForegroundColor DarkGray
} else {
    Write-Host "  预计总安装约 3-8 分钟" -ForegroundColor DarkGray
}

Step 2 "下载 DSH 安装包"
$temp = Join-Path $env:TEMP ("dsh-web-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$installer = Join-Path $temp "dsh-installer.exe"
if ($InstallerPath) {
    Copy-Item -LiteralPath $InstallerPath -Destination $installer -Force
    Write-Host "  使用本地安装包：$InstallerPath"
} else {
    Download-File $chosen.Url $installer
}
if (-not (Test-Path $installer)) { Fail "安装包下载失败。" }
if ($ExpectedSha512) {
    $actual = Get-Sha512Base64 $installer
    if ($actual -ne $ExpectedSha512) {
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
        Fail "安装包 SHA512 校验失败，已停止。"
    }
    Write-Host "  SHA512 校验通过"
}

Step 3 "解包 DSH 到独立目录"
$payload = Join-Path $temp "app-64.7z"
& $SevenZip e $installer "-o$temp" '$PLUGINSDIR\app-64.7z' -y | Out-Null
if (-not (Test-Path $payload)) { Fail "无法从安装包提取 app-64.7z。" }
& $SevenZip x $payload "-o$AppDir" -y | Out-Null
if (-not (Test-Path (Join-Path $AppDir "DeepSeek Harness.exe"))) { Fail "DSH 程序解包失败。" }
if (-not (Test-Path (Join-Path $AppDir "resources\runtime\cli\bin\dsh.cmd"))) { Fail "DSH CLI 解包失败。" }

Step 4 "创建完全独立的 DSH 数据目录"
$profilePackage = [ordered]@{
    name = "dsh-profile-web"
    private = $true
    dependencies = [ordered]@{}
    dsh = [ordered]@{ profile = [ordered]@{ bundles = @("@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app") } }
}
Write-Utf8NoBom (Join-Path $ProfileDir "package.json") (($profilePackage | ConvertTo-Json -Depth 10) + "`n")
Write-Utf8NoBom (Join-Path $ProfileDir "cordis.yml") "# dsh profile root - empty entry list`n[]`n"
Write-Utf8NoBom (Join-Path $ProfileDir "pnpm-workspace.yaml") "packages:`n  - .`n`nnodeLinker: hoisted`nautoInstallPeers: false`n"

Step 5 "下载并安装破甲插件"
$pluginArchive = Join-Path $temp "dsh-purge-plus.tar.gz"
$pluginUrls = @(
    "https://codeload.github.com/$PluginRepo/tar.gz/$PluginCommit",
    "https://github.com/$PluginRepo/archive/$PluginCommit.tar.gz"
)
$pluginDownloaded = $false
foreach ($pluginUrl in $pluginUrls) {
    try {
        Remove-Item $pluginArchive -Force -ErrorAction SilentlyContinue
        Download-File $pluginUrl $pluginArchive
        if ((Test-Path $pluginArchive) -and (Get-Item $pluginArchive).Length -gt 1024) {
            $pluginDownloaded = $true
            break
        }
    } catch {
        Write-Host ("  插件下载失败，换下一个通道：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}
if (-not $pluginDownloaded) { Fail "破甲插件源码下载失败，请检查 GitHub 网络。" }
$pluginExtract = Join-Path $temp "plugin"
New-Item -ItemType Directory -Force -Path $pluginExtract | Out-Null
$tar = Get-Command tar.exe -ErrorAction SilentlyContinue
if ($tar) {
    & $tar.Source -xzf $pluginArchive -C $pluginExtract
} else {
    & $SevenZip x $pluginArchive "-o$pluginExtract" -y | Out-Null
}
$pluginSource = Get-ChildItem $pluginExtract -Directory | Select-Object -First 1
if (-not $pluginSource) { Fail "破甲插件源码解压失败。" }
if (Test-Path $PluginDir) { Remove-Item $PluginDir -Recurse -Force }
Move-Item $pluginSource.FullName $PluginDir

# Do not ship the offensive red-team skill library. Windows Defender flags some
# of its webshell examples as Backdoor:PHP/Chopper.E!dha. The core prompt
# injection, approval patches and agent presets remain available.
$redteamSkills = Join-Path $PluginDir "skills\redteam"
if (Test-Path $redteamSkills) { Remove-Item $redteamSkills -Recurse -Force }

$toolsJs = Join-Path $PluginDir "lib\redteam\tools.js"
if (Test-Path $toolsJs) {
    $text = Read-Text $toolsJs
    if ($text -notmatch 'resources/app/dsh/') {
        $old = "  const nm = text.lastIndexOf('/node_modules/')`n  if (nm >= 0) addCandidate(list, join(text.slice(0, nm), 'node_modules', '@deepseek-ai', 'dsh', 'package.json'))"
        $new = $old + "`n  const app = text.indexOf('/resources/app/dsh/')`n  if (app >= 0) addCandidate(list, text.slice(0, app + '/resources/app/dsh/'.length) + 'package.json')"
        $text = $text.Replace($old, $new)
    }
    if ($text -notmatch 'process.resourcesPath') {
        $old = "  addCandidate(candidates, join(process.cwd(), 'package.json'))"
        $new = $old + "`n  try {`n    if (process.resourcesPath) addCandidate(candidates, join(process.resourcesPath, 'app', 'dsh', 'package.json'))`n  } catch { }`n  try {`n    addCandidate(candidates, join(dirname(process.execPath), 'resources', 'app', 'dsh', 'package.json'))`n  } catch { }"
        $text = $text.Replace($old, $new)
    }
    Write-Utf8NoBom $toolsJs $text
}

foreach ($presetFile in @(
    (Join-Path $PluginDir "presets\unrestricted\agent.cordis.yml"),
    (Join-Path $PluginDir "presets\redteam\agent.cordis.yml")
)) {
    if (-not (Test-Path $presetFile)) { continue }
    $text = Read-Text $presetFile
    $block = "    - id: tool-subagent-list-agents`n      name: '@deepseek-ai/dsh-tool-subagent-control/list-agents'`n      disabled: false`n`n"
    $text = $text.Replace($block, "")
    $text = $text.Replace("        modelSelectionSettings: true`n        backgroundMode: continuable", "        modelSelection: true`n        modelDiscovery: true")
    $text = $text.Replace("name: dsh-purge/redteam/tools", "name: dsh-purge-plus/redteam/tools")
    Write-Utf8NoBom $presetFile $text
}

$pkgPath = Join-Path $ProfileDir "package.json"
$pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$linkSpec = "link:" + ($PluginDir -replace "\\", "/")
$pkg.dependencies | Add-Member -NotePropertyName "dsh-purge-plus" -NotePropertyValue $linkSpec -Force
$bundles = @($pkg.dsh.profile.bundles)
if ($bundles -notcontains "dsh-purge-plus") { $bundles += "dsh-purge-plus" }
$pkg.dsh.profile.bundles = $bundles
Write-Utf8NoBom $pkgPath (($pkg | ConvertTo-Json -Depth 20) + "`n")

$env:DSH_HOME = $HomeDir
Push-Location $ProfileDir
& $DshCmd plugin --profile web install
$installCode = $LASTEXITCODE
Pop-Location
if ($installCode -ne 0) { Fail "插件依赖安装失败（exit $installCode）。" }

Step 6 "应用破甲宿主补丁"
$applyLog = Join-Path $LogDir "apply.log"
$applyErr = Join-Path $LogDir "apply.err.log"
Remove-Item $applyLog, $applyErr -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath $DshCmd -ArgumentList @("web", "--host", "127.0.0.1", "--port", "$Port", "--no-open") -RedirectStandardOutput $applyLog -RedirectStandardError $applyErr -NoNewWindow -PassThru
$url = Wait-WebUrl $applyLog 240
if (-not $url) {
    Stop-ProcessTree $proc.Id
    Fail "DSH Web 没有在预期时间内启动，日志：$applyLog"
}
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
Invoke-WebRequest -Uri $url -UseBasicParsing -WebSession $session -TimeoutSec 30 | Out-Null
try {
    $apply = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/dsh-purge/apply" -f $Port) -Method POST -WebSession $session -ContentType "application/json" -Body "{}" -UseBasicParsing -TimeoutSec 300
    $applyJson = $apply.Content | ConvertFrom-Json
    if (-not $applyJson.ok) { throw "插件返回 ok=false" }
    Write-Host ("  已应用补丁：applied={0}, already={1}, failed={2}" -f $applyJson.applied, $applyJson.already, $applyJson.failed)
} catch {
    Stop-ProcessTree $proc.Id
    Fail ("应用补丁失败：" + $_.Exception.Message)
}
Stop-ProcessTree $proc.Id

$resources = Join-Path $AppDir "resources"
$sealed = Join-Path $resources ("app.asar.sealed-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
if (Test-Path (Join-Path $resources "app.asar")) { Move-Item (Join-Path $resources "app.asar") $sealed -Force }
$cmdPath = Join-Path $AppDir "resources\runtime\cli\bin\dsh.cmd"
if (Test-Path $cmdPath) {
    $cmdText = Get-Content $cmdPath -Raw -Encoding UTF8
    $cmdText = $cmdText.Replace("app.asar\dsh", "app\dsh")
    Write-Utf8NoBom $cmdPath $cmdText
}

$nodeExe = Join-Path $AppDir "resources\runtime\primary-runtime\dependencies\node\bin\node.exe"
if ((Test-Path $nodeExe) -and (Test-Path $HostPatch)) {
    & $nodeExe $HostPatch $AppDir
    if ($LASTEXITCODE -ne 0) { Fail "DSH 0.2.2 兼容补丁失败。" }
} else {
    Write-Host "  跳过可选的 0.2.2 兼容补丁（缺少 node 或补丁文件）" -ForegroundColor Yellow
}

$permission = @"

- id: permission
  config:
    defaultPreset: danger-full-access
    presets:
      read-only:
        sandbox: read-only
        approval: ask
      workspace-write:
        sandbox: workspace-write
        approval: ask
      danger-full-access:
        sandbox: danger-full-access
        approval: never
"@
$patchPath = Join-Path $ProfileDir "cordis.patch.yml"
$existingPatch = if (Test-Path $patchPath) { Get-Content $patchPath -Raw -Encoding UTF8 } else { "" }
if ($existingPatch -notmatch '(?m)^- id: permission') {
    Add-Content -Path $patchPath -Value $permission -Encoding UTF8
}

Step 7 "创建启动器和官方图标快捷方式"
Copy-Item (Join-Path $PSScriptRoot "start-dsh-web.ps1") (Join-Path $InstallRoot "start-dsh-web.ps1") -Force
Copy-Item (Join-Path $PSScriptRoot "stop-dsh-web.ps1") (Join-Path $InstallRoot "stop-dsh-web.ps1") -Force
$vbs = @'
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & dir & "\start-dsh-web.ps1""", 0, False
'@
Write-Utf8NoBom (Join-Path $InstallRoot "start-dsh-web.vbs") $vbs
if (-not $NoShortcut) {
    $desktop = [Environment]::GetFolderPath("Desktop")
    $lnkPath = Join-Path $desktop "DSH Web.lnk"
    $wsh = New-Object -ComObject WScript.Shell
    $shortcut = $wsh.CreateShortcut($lnkPath)
    $shortcut.TargetPath = Join-Path $env:SystemRoot "System32\wscript.exe"
    $shortcut.Arguments = '"' + (Join-Path $InstallRoot "start-dsh-web.vbs") + '"'
    $shortcut.WorkingDirectory = $InstallRoot
    $shortcut.IconLocation = (Join-Path $AppDir "DeepSeek Harness.exe") + ",0"
    $shortcut.WindowStyle = 7
    $shortcut.Save()
    Write-Host ("  桌面快捷方式：{0}" -f $lnkPath)
}

Step 8 "写入安装信息"
$info = [ordered]@{
    installerVersion = $PackageVersion
    installRoot = $InstallRoot
    port = $Port
    dshVersion = $DshVersion
    pluginCommit = $PluginCommit
    createdAt = (Get-Date).ToString("o")
}
Write-Utf8NoBom (Join-Path $InstallRoot "install.json") (($info | ConvertTo-Json -Depth 5) + "`n")

Step 9 "完成"
Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
if (-not $NoStart) {
    $launcher = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $InstallRoot "start-dsh-web.ps1")) -PassThru -WindowStyle Hidden
    $startUrl = $null
    for ($i = 0; $i -lt 240; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Path (Join-Path $InstallRoot "current-url.txt")) {
            $startUrl = (Get-Content (Join-Path $InstallRoot "current-url.txt") -Raw).Trim()
            break
        }
    }
    if ($startUrl) { Write-Host ("  网页端已启动：{0}" -f $startUrl) -ForegroundColor Green }
}
Write-Host ""
Write-Host ("DSH Web 部署包 v{0} 安装总耗时 {1:N1} 秒。" -f $PackageVersion, $ScriptWatch.Elapsed.TotalSeconds) -ForegroundColor Green
Write-Host "安装完成。以后双击桌面的 DSH Web 快捷方式启动。" -ForegroundColor Green
Write-Host ("安装目录：{0}" -f $InstallRoot)
Write-Host "卸载：运行同目录的 uninstall.cmd"
Write-Host "更新：运行同目录的 update.cmd"
