<#
.SYNOPSIS
  撤销本仓库的 dsh-purge 补丁，回到“打补丁前”的自动备份状态。

.DESCRIPTION
  reapply-fix.mjs 在写入 index.js / desktop.js 之前，会把原文件自动备份到：
    %USERPROFILE%\.dsh\dsh-purge\patch-backup\
  文件名形如：
    index.js.index.js-<时间戳>
    desktop.js.desktop.js-<时间戳>

  本脚本找出最近一次备份并恢复。恢复后：
    - 当前 DSH 上会重新出现 "unknown prompt variable {{cwd}}" 报错（这是预期）；
    - 也会重新出现 Get-ItemProperty 噪音。

  如果找不到自动备份（例如先重装了插件），脚本不会乱动文件，而是提示重装插件。

.PARAMETER DryRun
  只打印计划，不恢复文件。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\rollback.ps1

.EXAMPLE
  .\scripts\rollback.ps1 -DryRun
#>
param(
  [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE ".dsh" }),
  [string]$Profile = "web",
  [string]$LibDir = "",
  [string]$BackupDir = "",
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if (-not $LibDir) {
  $LibDir = Join-Path $DshHome "profiles\$Profile\node_modules\dsh-purge\lib"
}
$LibDir = [System.IO.Path]::GetFullPath($LibDir)
if (-not $BackupDir) {
  $BackupDir = Join-Path $DshHome "dsh-purge\patch-backup"
}
$BackupDir = [System.IO.Path]::GetFullPath($BackupDir)

Write-Host "============================================================"
Write-Host " dsh-purge cwd fix - ROLLBACK（撤销补丁）"
Write-Host "------------------------------------------------------------"
Write-Host " 插件目录 : $LibDir"
Write-Host " 备份目录 : $BackupDir"
Write-Host " 模式     : $(if ($DryRun) { 'DRY-RUN（只看不改）' } else { '执行' })"
Write-Host "============================================================"

$targets = @(
  @{ Name = "index.js";   Pattern = "index.js.*" },
  @{ Name = "desktop.js"; Pattern = "desktop.js.*" }
)

$plan = @()
foreach ($t in $targets) {
  $target = Join-Path $LibDir $t.Name
  if (-not (Test-Path $target)) {
    throw "找不到插件文件：$target（profile/路径不对？）"
  }
  $candidates = @()
  if (Test-Path $BackupDir) {
    $candidates = @(Get-ChildItem -LiteralPath $BackupDir -File -Filter $t.Pattern -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '-\d{4}-\d{2}-\d{2}T' } |
      Sort-Object LastWriteTime -Descending)
  }
  $pick = $candidates | Select-Object -First 1
  $plan += [pscustomobject]@{ File = $t.Name; Target = $target; Backup = $pick }
}

$missing = @($plan | Where-Object { $null -eq $_.Backup })
if ($missing.Count -gt 0) {
  Write-Host ""
  Write-Host "[FAIL] 没有找到本工具写入前的自动备份："
  $missing | ForEach-Object { Write-Host "       - $($_.File)" }
  Write-Host ""
  Write-Host " 无法自动撤销。想恢复官方原版，可重装插件（会覆盖本地补丁）："
  Write-Host "   dsh plugin --profile $Profile add github:YuJunZhiXue/dsh-purge"
  Write-Host " 然后重启 dsh web。"
  exit 1
}

Write-Host ""
Write-Host "计划："
foreach ($item in $plan) {
  Write-Host "  $($item.File)  <-  $($item.Backup.FullName)  ($($item.Backup.LastWriteTime))"
}

if ($DryRun) {
  Write-Host ""
  Write-Host "[DRY-RUN] 未修改任何文件。"
  exit 0
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$safety = Join-Path $BackupDir ("rollback-safety-" + $stamp)
New-Item -ItemType Directory -Force -Path $safety | Out-Null

foreach ($item in $plan) {
  $current = $item.Target
  $backup = $item.Backup.FullName

  # 先把当前（已打补丁的）文件保存一份，便于反悔
  Copy-Item -LiteralPath $current -Destination (Join-Path $safety $item.File) -Force

  $same = $false
  try {
    $same = ((Get-FileHash -LiteralPath $current -Algorithm SHA256).Hash -eq
             (Get-FileHash -LiteralPath $backup  -Algorithm SHA256).Hash)
  } catch { $same = $false }

  if ($same) {
    Write-Host "[OK] $($item.File)：当前文件已经和备份一致，跳过。"
    continue
  }

  $bytes = [System.IO.File]::ReadAllBytes($backup)
  Remove-Item -LiteralPath $current -Force           # 断开 pnpm 硬链接
  [System.IO.File]::WriteAllBytes($current, $bytes)
  Write-Host "[OK] $($item.File)：已恢复（原补丁前副本保存在 $safety）"
}

# 语法自检
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
  foreach ($item in $plan) {
    & node --check $item.Target 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "[WARN] 语法检查失败：$($item.File)" }
  }
}

Write-Host ""
Write-Host "============================================================"
Write-Host " [DONE] 已撤销补丁（回到打补丁前的自动备份）"
Write-Host "------------------------------------------------------------"
Write-Host " 注意：当前 DSH 上会重新出现 {{cwd}} 报错，这是预期行为。"
Write-Host " 想重新修好：node `"$(Join-Path $PSScriptRoot 'reapply-fix.mjs')`""
Write-Host " 请重启 dsh web 生效。"
Write-Host "============================================================"
