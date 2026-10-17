<#
.SYNOPSIS
  重新启用 dsh-purge 插件（与 disable-plugin.ps1 配对，可回溯）。

.DESCRIPTION
  执行顺序：
    1) 读取最近一次停用快照（生命周期快照目录\plugin-state-*-disable\disable-state.json）
    2) 把 "dsh-purge" 插回 package.json 的 dsh.profile.bundles（按停用前索引）
    3) 运行插件自带 `dsh-purge --apply`：重新把补丁打到 DSH 程序文件上
    4) 打印重启提示

  如果插件文件已被卸载（node_modules\dsh-purge 不存在），本脚本无法恢复，
  会提示先用 `dsh plugin --profile web add github:YuJunZhiXue/dsh-purge` 重新安装。

.PARAMETER DryRun
  只打印计划，不修改任何文件。

.PARAMETER SkipHostPatches
  跳过 `dsh-purge --apply`（仅用于在临时 profile 上测试 bundle 编辑逻辑）。

.PARAMETER Apply
  即使 bundles 里已经有 dsh-purge，也强制执行一次 --apply。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\enable-plugin.ps1

.EXAMPLE
  .\enable-plugin.ps1 -DryRun
#>
param(
  [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE ".dsh" }),
  [string]$Profile = "web",
  [string]$ProfileDir = "",
  [string]$ArchiveRoot = "",
  [switch]$DryRun,
  [switch]$SkipHostPatches,
  [switch]$Apply
)

$ErrorActionPreference = "Stop"

if (-not $ProfileDir) { $ProfileDir = Join-Path $DshHome "profiles\$Profile" }
$ProfileDir = [System.IO.Path]::GetFullPath($ProfileDir)
if (-not $ArchiveRoot) { $ArchiveRoot = Join-Path $DshHome "dsh-purge\patch-backup\lifecycle" }
$pkgPath = Join-Path $ProfileDir "package.json"
$pluginRoot = Join-Path $ProfileDir "node_modules\dsh-purge"
$pluginBin = Join-Path $pluginRoot "bin\dsh-purge.js"

Write-Host "============================================================"
Write-Host " dsh-purge 重新启用"
Write-Host "------------------------------------------------------------"
Write-Host " Profile  : $ProfileDir"
Write-Host " 插件目录 : $pluginRoot"
Write-Host " 模式     : $(if ($DryRun) { 'DRY-RUN（只看不改）' } else { '执行' })"
Write-Host "============================================================"

if (-not (Test-Path $pkgPath)) { throw "找不到 profile 的 package.json：$pkgPath" }
if (-not (Test-Path $pluginRoot)) {
  throw "插件文件不存在：$pluginRoot`n       插件已被彻底卸载，无法「重新启用」。请先在 profile 目录执行：`n       dsh plugin --profile $Profile add github:YuJunZhiXue/dsh-purge`n       或参考 README 的「撤销修复、停用与卸载的区别」一节。"
}

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

# ── 找最近一次停用快照 ───────────────────────────────────────────────────────
$state = $null
$stateFile = $null
$stateDirs = @(Get-ChildItem -Path $ArchiveRoot -Directory -Filter "plugin-state-*-disable" -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
foreach ($dir in $stateDirs) {
  $candidate = Join-Path $dir.FullName "disable-state.json"
  if (Test-Path $candidate) {
    $state = Read-JsonFile $candidate
    $stateFile = $candidate
    break
  }
}

$pkg = Read-JsonFile $pkgPath
$info = Get-BundleInfo $pkg
if (-not $info) { throw "package.json 里找不到 bundles 数组（dsh.profile.bundles）" }

$exists = $false
foreach ($item in $info.Items) { if (Test-PurgeBundle ([string]$item)) { $exists = $true; break } }

if ($exists -and -not $Apply) {
  Write-Host ""
  Write-Host "[OK] dsh-purge 已经在启用状态（bundles 里存在）。"
  Write-Host "     若宿主补丁被还原过、需要重新打补丁，可加 -Apply 参数重新运行本脚本，"
  Write-Host "     或直接运行：node `"$pluginBin`" --apply，然后重启 dsh web。"
  exit 0
}

$targetIndex = $info.Items.Count
if ($state -and $null -ne $state.removedIndex) {
  $targetIndex = [Math]::Max(0, [Math]::Min([int]$state.removedIndex, $info.Items.Count))
}
$newItems = [System.Collections.ArrayList]::new()
foreach ($item in $info.Items) { [void]$newItems.Add($item) }
if (-not $exists) { $newItems.Insert($targetIndex, "dsh-purge") }
$finalItems = @($newItems)

Write-Host ""
Write-Host "计划："
if ($stateFile) { Write-Host "  1) 使用停用快照：$stateFile" } else { Write-Host "  1) 未找到停用快照，按默认逻辑处理" }
if ($exists) { Write-Host "  2) bundles 已有 dsh-purge（-Apply 模式，不重复插入）" } else { Write-Host "  2) 把 'dsh-purge' 插回 bundles 索引 $targetIndex" }
Write-Host "  3) 运行 dsh-purge --apply（SkipHostPatches=$SkipHostPatches）"
Write-Host "  4) 提示重启 dsh web"

if ($DryRun) {
  Write-Host ""
  Write-Host "[DRY-RUN] 未修改任何文件。"
  exit 0
}

if (-not $exists) {
  $info.Container.bundles = $finalItems
  Write-JsonFile $pkgPath $pkg
  Write-Host ""
  Write-Host "[OK] 已把 dsh-purge 插回 $($info.Kind)（索引 $targetIndex）。"
}

# ── 重新打宿主补丁 ───────────────────────────────────────────────────────────
if (-not $SkipHostPatches) {
  if (-not (Test-Path $pluginBin)) { throw "找不到插件 CLI：$pluginBin" }
  $node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
  if (-not $node) { $node = (Get-Command node -ErrorAction SilentlyContinue).Source }
  if (-not $node) { throw "PATH 里找不到 node，无法运行 dsh-purge --apply" }
  Write-Host ""
  Write-Host "[..] 重新应用宿主补丁（dsh-purge --apply）……"
  $applyOutput = (& $node $pluginBin --apply 2>&1 | Out-String)
  Write-Host $applyOutput.Trim()
  if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "[WARN] --apply 没有完全成功（退出码 $LASTEXITCODE）。"
    Write-Host "       插件已重新启用，但宿主补丁可能未全部应用；可打开插件界面手动点「应用」，或检查 prompt-inject.md 是否为空。"
  }
} else {
  Write-Host ""
  Write-Host "[SKIP] 已按 -SkipHostPatches 跳过宿主补丁重打。"
}

Write-Host ""
Write-Host "============================================================"
Write-Host " [DONE] dsh-purge 已重新启用"
Write-Host "------------------------------------------------------------"
Write-Host " 请重启 dsh web 生效（双击 4-启动dsh-web.cmd）。"
Write-Host " 若对话出现 prompt 报错，双击 0-先体检.cmd 检查 cwd 补丁。"
Write-Host "============================================================"
