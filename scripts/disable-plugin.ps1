<#
.SYNOPSIS
  停用 dsh-purge 插件（可回溯）：还原宿主补丁 + 从 profile 移除插件加载，
  但保留插件文件、依赖、规则和提示词，之后可用 enable-plugin.ps1 完整恢复。

.DESCRIPTION
  执行顺序：
    1) 记录状态并做快照（package.json / prompt-inject.md / 补丁状态）
    2) 运行插件自带 `dsh-purge --revert`：把 DSH 程序文件上的插件补丁还原成官方原版
    3) 从 profile 的 dsh.profile.bundles 里移除 "dsh-purge"：
       插件不再加载、bundle 补丁不再应用；node_modules 与 package.json 依赖保留
    4) 打印重启提示

  「可回溯」体现在：插件文件、依赖、prompt-inject.md、规则库都保留；
  重新启用时 enable-plugin.ps1 会重新加回 bundles 并执行 `dsh-purge --apply` 还原补丁。

.PARAMETER DryRun
  只打印计划，不修改任何文件。

.PARAMETER SkipHostPatches
  跳过 `dsh-purge --revert`（仅用于在临时 profile 上测试 bundle 编辑逻辑）。

.PARAMETER ProfileDir
  直接指定 profile 目录（默认 $DSH_HOME\profiles\<Profile>）。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\disable-plugin.ps1

.EXAMPLE
  .\disable-plugin.ps1 -DryRun
#>
param(
  [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE ".dsh" }),
  [string]$Profile = "web",
  [string]$ProfileDir = "",
  [string]$ArchiveRoot = "",
  [switch]$DryRun,
  [switch]$SkipHostPatches
)

$ErrorActionPreference = "Stop"

if (-not $ProfileDir) { $ProfileDir = Join-Path $DshHome "profiles\$Profile" }
$ProfileDir = [System.IO.Path]::GetFullPath($ProfileDir)
if (-not $ArchiveRoot) { $ArchiveRoot = Join-Path $DshHome "dsh-purge\patch-backup\lifecycle" }
$pkgPath = Join-Path $ProfileDir "package.json"
$pluginRoot = Join-Path $ProfileDir "node_modules\dsh-purge"
$pluginBin = Join-Path $pluginRoot "bin\dsh-purge.js"

Write-Host "============================================================"
Write-Host " dsh-purge 停用（可回溯）"
Write-Host "------------------------------------------------------------"
Write-Host " Profile  : $ProfileDir"
Write-Host " 插件目录 : $pluginRoot"
Write-Host " 存档目录 : $ArchiveRoot"
Write-Host " 模式     : $(if ($DryRun) { 'DRY-RUN（只看不改）' } else { '执行' })"
Write-Host "============================================================"

if (-not (Test-Path $pkgPath)) { throw "找不到 profile 的 package.json：$pkgPath" }
if (-not (Test-Path $pluginRoot)) { throw "找不到插件目录：$pluginRoot（可能已经卸载）" }

function Read-JsonFile([string]$path) {
  return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}
function Write-JsonFile([string]$path, $obj) {
  $json = $obj | ConvertTo-Json -Depth 30
  [System.IO.File]::WriteAllText($path, $json + "`n", [System.Text.UTF8Encoding]::new($false))
}
function Get-BundleInfo($pkg) {
  if ($pkg.dsh -and $pkg.dsh.profile -and ($pkg.dsh.profile.PSObject.Properties.Name -contains "bundles")) {
    return @{ Container = $pkg.dsh.profile; Items = @($pkg.dsh.profile.bundles); Kind = "dsh.profile.bundles" }
  }
  if (($pkg.PSObject.Properties.Name -contains "bundles") -and ($pkg.bundles -is [System.Array])) {
    return @{ Container = $pkg; Items = @($pkg.bundles); Kind = "bundles" }
  }
  return $null
}
function Test-PurgeBundle([string]$item) {
  return ($item -eq "dsh-purge") -or ($item -like "dsh-purge@*")
}

$pkg = Read-JsonFile $pkgPath
$info = Get-BundleInfo $pkg
if (-not $info) { throw "package.json 里找不到 bundles 数组（dsh.profile.bundles）" }
$purgeIndex = -1
for ($i = 0; $i -lt $info.Items.Count; $i++) {
  if (Test-PurgeBundle ([string]$info.Items[$i])) { $purgeIndex = $i; break }
}

if ($purgeIndex -lt 0) {
  Write-Host ""
  Write-Host "[OK] dsh-purge 已经处于停用状态（bundles 里没有它），无需重复操作。"
  Write-Host "     如需重新启用，双击 6-重新启用插件.cmd。"
  exit 0
}

# ── 快照 ─────────────────────────────────────────────────────────────────────
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$snapDir = Join-Path $ArchiveRoot "plugin-state-$stamp-disable"
$plan = @(
  "1) 快照 -> $snapDir",
  "2) 运行 dsh-purge --revert（还原宿主补丁；SkipHostPatches=$SkipHostPatches）",
  "3) 从 $($info.Kind) 移除第 $purgeIndex 项 'dsh-purge'（保留依赖与 node_modules）",
  "4) 提示重启 dsh web"
)
Write-Host ""
Write-Host "计划："
$plan | ForEach-Object { Write-Host "  $_" }

if ($DryRun) {
  Write-Host ""
  Write-Host "[DRY-RUN] 未修改任何文件。"
  exit 0
}

New-Item -ItemType Directory -Force -Path (Join-Path $snapDir "profile") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $snapDir "home") | Out-Null
Copy-Item -LiteralPath $pkgPath -Destination (Join-Path $snapDir "profile\package.json") -Force
$patchYml = Join-Path $ProfileDir "cordis.patch.yml"
if (Test-Path $patchYml) { Copy-Item -LiteralPath $patchYml -Destination (Join-Path $snapDir "profile\cordis.patch.yml") -Force }
$injectFile = Join-Path $DshHome "prompt-inject.md"
if (Test-Path $injectFile) { Copy-Item -LiteralPath $injectFile -Destination (Join-Path $snapDir "home\prompt-inject.md") -Force }

$statusText = ""
try {
  $node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
  if (-not $node) { $node = (Get-Command node -ErrorAction SilentlyContinue).Source }
  if ($node -and (Test-Path $pluginBin)) {
    $statusText = (& $node $pluginBin --status 2>&1 | Out-String)
    [System.IO.File]::WriteAllText((Join-Path $snapDir "patch-status-before.txt"), $statusText, [System.Text.UTF8Encoding]::new($false))
  }
} catch { $statusText = "" }

$appliedMatch = [regex]::Match($statusText, "补丁\s+(\d+)/(\d+)\s+已清洗")
$patchesAppliedBefore = if ($appliedMatch.Success) { [int]$appliedMatch.Groups[1].Value } else { -1 }

# ── 还原宿主补丁 ─────────────────────────────────────────────────────────────
$revertOutput = ""
if (-not $SkipHostPatches) {
  if (-not (Test-Path $pluginBin)) { throw "找不到插件 CLI：$pluginBin，无法还原宿主补丁" }
  if (-not $node) { throw "PATH 里找不到 node，无法运行 dsh-purge --revert" }
  Write-Host ""
  Write-Host "[..] 还原宿主补丁（dsh-purge --revert）……"
  $revertOutput = (& $node $pluginBin --revert 2>&1 | Out-String)
  Write-Host $revertOutput.Trim()
  [System.IO.File]::WriteAllText((Join-Path $snapDir "revert-output.txt"), $revertOutput, [System.Text.UTF8Encoding]::new($false))
  if ($revertOutput -match "还原失败|revert failed|\[ERROR\]") {
    throw "宿主补丁还原过程中出现错误（见 $snapDir\revert-output.txt）。已中止，未改动 bundles；请先处理错误或改用卸载流程。"
  }
} else {
  Write-Host ""
  Write-Host "[SKIP] 已按 -SkipHostPatches 跳过宿主补丁还原。"
}

# ── 从 bundles 移除 ──────────────────────────────────────────────────────────
$newItems = @($info.Items | Where-Object { -not (Test-PurgeBundle ([string]$_)) })
$info.Container.bundles = $newItems
Write-JsonFile $pkgPath $pkg

$pluginVersion = "unknown"
try { $pluginVersion = [string](Read-JsonFile (Join-Path $pluginRoot "package.json")).version } catch { }

$state = [ordered]@{
  timestamp            = (Get-Date).ToString("o")
  action               = "disable"
  profile              = $Profile
  profileDir           = $ProfileDir
  bundleKind           = $info.Kind
  removedIndex         = $purgeIndex
  bundlesBefore        = @($info.Items)
  bundlesAfter         = @($newItems)
  patchesAppliedBefore = $patchesAppliedBefore
  hostPatchesReverted  = (-not $SkipHostPatches)
  pluginVersion        = $pluginVersion
}
Write-JsonFile (Join-Path $snapDir "disable-state.json") $state

$readme = @"
dsh-purge 停用快照
时间: $($state.timestamp)
Profile: $ProfileDir
还原的宿主补丁数: $patchesAppliedBefore
移除的 bundle 索引: $purgeIndex

恢复方法（二选一）：
  1) 双击 6-重新启用插件.cmd（推荐，会重新加回 bundle 并执行 --apply 重新打宿主补丁）
  2) 手工把 "dsh-purge" 插回 package.json 的 dsh.profile.bundles（原索引 $purgeIndex），
     重启 dsh web，然后在插件界面点「应用」或运行 dsh-purge --apply。

原始 package.json 备份在本目录 profile\package.json。
"@
[System.IO.File]::WriteAllText((Join-Path $snapDir "如何恢复.txt"), $readme, [System.Text.UTF8Encoding]::new($false))

Write-Host ""
Write-Host "============================================================"
Write-Host " [DONE] dsh-purge 已停用（可回溯）"
Write-Host "------------------------------------------------------------"
Write-Host " - 宿主补丁：$(if ($SkipHostPatches) { '已跳过' } else { '已还原' })"
Write-Host " - bundles：已移除 dsh-purge（原索引 $purgeIndex）"
Write-Host " - 插件文件/依赖/规则/提示词：保留"
Write-Host " - 快照：$snapDir"
Write-Host ""
Write-Host " 请重启 dsh web 生效（双击 4-启动dsh-web.cmd）。"
Write-Host " 需要恢复时双击 6-重新启用插件.cmd。"
Write-Host "============================================================"
