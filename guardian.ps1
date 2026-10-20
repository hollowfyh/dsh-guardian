param(
  [string]$ProfileDir = "",
  [string]$AppPath = "",
  [int]$BootTimeoutSec = 60,
  [int]$MaxAttempts = 3,
  [switch]$Check,
  [switch]$RepairOnly,
  [switch]$NoLaunch,
  [switch]$SimulateFailure,
  [string]$DataDir = '',
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$GuardianHome = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($DataDir -ne '') { $GuardianHome = $DataDir }
$LogDir = Join-Path $GuardianHome 'logs'
$BackupDir = Join-Path $GuardianHome 'backups'
$LastGoodDir = Join-Path $GuardianHome 'last-good'
foreach ($d in @($LogDir, $BackupDir, $LastGoodDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

$DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
if ($ProfileDir -eq '') { $ProfileDir = Join-Path $DshHome 'profiles\desktop' }
$PackageJson = Join-Path $ProfileDir 'package.json'
$PatchFile = Join-Path $ProfileDir 'cordis.patch.yml'
$LogFile = Join-Path $LogDir 'guardian.log'

function Log([string]$msg, [string]$level = 'INFO') {
  $line = ('[{0}] {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $msg)
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
  if (-not $Quiet) { Write-Host $line }
}

function Get-ConfiguredAppPath {
  if ($AppPath -ne '') { return $AppPath }
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'),
    (Join-Path $env:PROGRAMFILES 'DeepSeek Harness\DeepSeek Harness.exe')
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  return $null
}

function Get-DshProcesses {
  Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue
}

function Test-DshBooted {
  $procs = Get-DshProcesses
  if (-not $procs) { return $false }
  $hostProc = Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*dsh-desktop-host*' } | Select-Object -First 1
  if (-not $hostProc) { return $false }
  $listeners = Get-NetTCPConnection -State Listen -OwningProcess $hostProc.ProcessId -ErrorAction SilentlyContinue
  if (-not $listeners) { return $false }
  return $true
}

function Test-DshAppRunning {
  [bool](Get-DshProcesses)
}

function Start-Dsh([string]$exe) {
  if (-not $exe) { throw '找不到 DeepSeek Harness 可执行文件' }
  Log ("启动 DSH: {0}" -f $exe)
  Start-Process -FilePath $exe | Out-Null
}

function Stop-Dsh {
  $procs = Get-DshProcesses
  if (-not $procs) { return }
  Log '停止无响应的 DSH 进程…'
  $procs | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 3
}

function Wait-DshBooted([int]$timeoutSec) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (Test-DshBooted) { return $true }
    Start-Sleep -Milliseconds 800
  }
  return (Test-DshBooted)
}

function Backup-ProfileFile([string]$file, [string]$tag) {
  if (-not (Test-Path $file)) { return }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $dest = Join-Path $BackupDir ("{0}-{1}" -f $stamp, $tag)
  Copy-Item -Path $file -Destination $dest -Force
  Log ("已备份 {0} -> {1}" -f (Split-Path -Leaf $file), (Split-Path -Leaf $dest))
}

function Save-LastGood {
  if (Test-Path $PackageJson) { Copy-Item $PackageJson (Join-Path $LastGoodDir 'package.json') -Force }
  if (Test-Path $PatchFile) { Copy-Item $PatchFile (Join-Path $LastGoodDir 'cordis.patch.yml') -Force }
  Log '已记录 last-good 配置快照'
}

function Get-BundleList {
  $json = Get-Content -Path $PackageJson -Raw -Encoding UTF8 | ConvertFrom-Json
  return @($json.dsh.profile.bundles)
}

function Set-BundleList([string[]]$bundles) {
  $json = Get-Content -Path $PackageJson -Raw -Encoding UTF8 | ConvertFrom-Json
  $json.dsh.profile.bundles = @($bundles)
  $text = $json | ConvertTo-Json -Depth 12
  [IO.File]::WriteAllText($PackageJson, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-NewestBundle {
  if (-not (Test-Path $PackageJson)) { return $null }
  Backup-ProfileFile $PackageJson 'package.json'
  $current = Get-BundleList
  $base = @()
  $lastGoodPkg = Join-Path $LastGoodDir 'package.json'
  if (Test-Path $lastGoodPkg) {
    $base = @((Get-Content $lastGoodPkg -Raw -Encoding UTF8 | ConvertFrom-Json).dsh.profile.bundles)
  }
  $candidate = $null
  for ($i = $current.Count - 1; $i -ge 0; $i--) {
    if ($base -notcontains $current[$i]) { $candidate = $current[$i]; break }
  }
  # 首次运行（还没有 last-good 基线）时，退而移除列表末尾的第三方 bundle，
  # 但绝不碰 @deepseek-ai 基础包和 doctor 自己。
  if (-not $candidate -and -not (Test-Path $lastGoodPkg)) {
    for ($i = $current.Count - 1; $i -ge 0; $i--) {
      $name = [string]$current[$i]
      if ($name -notlike '@deepseek-ai/*' -and $name -ne 'dsh-plugin-doctor') { $candidate = $name; break }
    }
  }
  if (-not $candidate) { return $null }
  $next = @($current | Where-Object { $_ -ne $candidate })
  Set-BundleList $next
  Log ("已从 dsh.profile.bundles 移除嫌疑插件: {0}" -f $candidate) 'REPAIR'
  return $candidate
}

function Restore-LastGood([string]$name) {
  $src = Join-Path $LastGoodDir $name
  if (-not (Test-Path $src)) { return $false }
  switch ($name) {
    'package.json' { Backup-ProfileFile $PackageJson 'package.json'; Copy-Item $src $PackageJson -Force }
    'cordis.patch.yml' { Backup-ProfileFile $PatchFile 'cordis.patch.yml'; Copy-Item $src $PatchFile -Force }
  }
  Log ("已从 last-good 恢复 {0}" -f $name) 'REPAIR'
  return $true
}

function Get-RecentCrashLog {
  $logDir = Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop\logs'
  if (-not (Test-Path $logDir)) { return $null }
  $latest = Get-ChildItem $logDir -Filter 'crash-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($latest) { return $latest.FullName }
  return $null
}

function Write-FailureReport([string[]]$actions) {
  $report = [ordered]@{
    at = (Get-Date).ToString('o')
    profile = $ProfileDir
    attempts = $MaxAttempts
    actions = $actions
    crashLog = (Get-RecentCrashLog)
    hint = '所有修复尝试均失败。请把本文件和 logs/guardian.log 发给助手；可在「设置 → 插件」手动关闭最近安装的插件，或运行 dsh plugin --profile desktop remove <包名>。'
  }
  $path = Join-Path $GuardianHome 'boot-failure.json'
  ($report | ConvertTo-Json -Depth 6) | Set-Content -Path $path -Encoding UTF8
  Log ("修复失败，报告已写入: {0}" -f $path) 'ERROR'
  return $path
}

function Attempt-SingleRepair([int]$level) {
  switch ($level) {
    1 {
      $removed = Remove-NewestBundle
      if ($removed) { return "移除 bundle: $removed" }
      return '没有可移除的新增 bundle'
    }
    2 {
      if (Restore-LastGood 'cordis.patch.yml') { return '恢复 cordis.patch.yml (last-good)' }
      return '没有可恢复的 cordis.patch.yml'
    }
    3 {
      $a = $null; $b = $null
      if (Restore-LastGood 'package.json') { $a = 'package.json' }
      if (Restore-LastGood 'cordis.patch.yml') { $b = 'cordis.patch.yml' }
      if ($a -or $b) { return ("完整回滚: {0}" -f (($a, $b | Where-Object { $_ }) -join ' + ')) }
      return '没有可回滚的 last-good 快照'
    }
  }
  return '未知修复级别'
}

# ---------------- 主流程 ----------------

Log ("守护程序启动，profile={0}" -f $ProfileDir)

$exe = Get-ConfiguredAppPath

if ($Check) {
  Log ("DSH 进程存在: {0}" -f (Test-DshAppRunning))
  Log ("DSH 已就绪 (宿主+端口): {0}" -f (Test-DshBooted))
  if (Test-Path $PackageJson) { Log ("bundles: {0}" -f ((Get-BundleList) -join ', ')) }
  exit 0
}

if ($SimulateFailure) {
  Log '模拟启动失败模式：只执行修复，不启动应用' 'WARN'
  $actions = @()
  for ($level = 1; $level -le 3; $level++) {
    $actions += (Attempt-SingleRepair $level)
  }
  Save-LastGood
  Log '模拟修复完成'
  exit 0
}

# 若已经在跑且健康：不重复启动，并顺手记录基线
if (-not $NoLaunch) {
  if (Test-DshBooted) {
    Log 'DSH 已在正常运行，记录基线后退出'
    Save-LastGood
    exit 0
  }
}

# 首次启动
if (-not $NoLaunch) {
  Start-Dsh $exe
} else {
  Log 'NoLaunch：跳过启动'
}

$booted = $false
if (-not $NoLaunch) { $booted = Wait-DshBooted $BootTimeoutSec }

if ($booted) {
  Log 'DSH 启动成功'
  Save-LastGood
  exit 0
}

Log 'DSH 未在预期时间内就绪，开始自动修复' 'WARN'
$actions = @()
$recovered = $false

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
  Log ("---- 第 {0}/{1} 次修复尝试 ----" -f $attempt, $MaxAttempts) 'WARN'
  if (-not $NoLaunch) { Stop-Dsh }
  $action = Attempt-SingleRepair $attempt
  $actions += ("第 {0} 次: {1}" -f $attempt, $action)
  Log $action 'REPAIR'
  if (-not $NoLaunch) {
    Start-Dsh $exe
    if (Wait-DshBooted $BootTimeoutSec) { $booted = $true; break }
  }
}

if ($booted) {
  Log '自动修复成功，DSH 已恢复' 'REPAIR'
  Save-LastGood
  $report = [ordered]@{ at = (Get-Date).ToString('o'); recovered = $true; actions = $actions }
  ($report | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $GuardianHome 'last-repair.json') -Encoding UTF8
  exit 0
}

if ($RepairOnly -or $NoLaunch) {
  Log '仅修复模式：已执行修复，未验证启动' 'WARN'
  exit 0
}

Write-FailureReport $actions
if (-not $Quiet) { Read-Host '自动修复失败，按回车关闭窗口（诊断报告：boot-failure.json）' | Out-Null }
exit 1
