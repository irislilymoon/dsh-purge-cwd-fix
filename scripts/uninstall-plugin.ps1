<#
.SYNOPSIS
  彻底卸载 dsh-purge 插件：还原宿主补丁、从所有 profile 移除加载项与依赖、
  删除插件文件和插件数据；其他插件不受影响。

.DESCRIPTION
  执行顺序：
    1) 检查 dsh web 是否在运行（运行中会锁定文件，默认中止）
    2) 交互确认（输入 YES；可用 -Yes 跳过）
    3) 备份现场：profile 配置、prompt-inject.md、AGENTS.md、$DSH_HOME\dsh-purge、
       $DSH_HOME\redteam、插件 package.json、补丁状态 -> 快照目录\plugin-uninstall-<时间戳>\
    4) 运行插件自带 `dsh-purge --uninstall`：还原 DSH 程序文件补丁、shim、清除注入文件和规则
    5) 删除所有 profile 的 node_modules\dsh-purge、$DSH_HOME\dsh-purge、$DSH_HOME\redteam
    6) 从所有 profile 的 package.json 移除 dsh-purge 的 bundle 加载项与依赖
    7) 在 profile 执行 pnpm install，清理 lockfile / node_modules 残留
    8) 打印结果与恢复方式（重新安装命令、快照路径）

  注意：这是不可逆操作（存档快照可人工恢复）。只想「暂时不用」请用 5-停用插件.cmd。

.PARAMETER DryRun
  只打印计划，不修改任何文件。

.PARAMETER Yes
  跳过交互确认（脚本化时使用）。

.PARAMETER Force
  即使检测到 dsh web 在运行也继续（不推荐，可能删不干净）。

.PARAMETER SkipHostPatches
  跳过 `dsh-purge --uninstall` 的补丁还原步骤（仅用于测试；真实卸载不要用）。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\uninstall-plugin.ps1

.EXAMPLE
  .\uninstall-plugin.ps1 -DryRun
#>
param(
  [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE ".dsh" }),
  [string]$Profile = "web",
  [string]$ProfileDir = "",
  [string]$ArchiveRoot = "",
  [switch]$DryRun,
  [switch]$Yes,
  [switch]$Force,
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
Write-Host " dsh-purge 彻底卸载"
Write-Host "------------------------------------------------------------"
Write-Host " DSH_HOME : $DshHome"
Write-Host " Profile  : $ProfileDir"
Write-Host " 插件目录 : $pluginRoot"
Write-Host " 存档目录 : $ArchiveRoot"
Write-Host " 模式     : $(if ($DryRun) { 'DRY-RUN（只看不改）' } else { '执行（不可逆）' })"
Write-Host "============================================================"

if (-not (Test-Path $pkgPath)) { throw "找不到 profile 的 package.json：$pkgPath" }
if (-not (Test-Path $pluginRoot)) {
  Write-Host ""
  Write-Host "[OK] 插件文件已经不存在（$pluginRoot），可能已经卸载。"
  Write-Host "     如仍有残留 bundle 项，可运行 disable-plugin.ps1 检查，或参考 README 的「撤销修复、停用与卸载的区别」一节手工清理。"
  exit 0
}

function Read-JsonFile([string]$path) { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) }
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
function Test-PurgeBundle([string]$item) { return ($item -eq "dsh-purge") -or ($item -like "dsh-purge@*") }
function Remove-Tree([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $true }
  for ($i = 0; $i -lt 5; $i++) {
    try {
      Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
      return $true
    } catch {
      Start-Sleep -Milliseconds 400
    }
  }
  return -not (Test-Path -LiteralPath $path)
}
function Get-DshWebProcesses {
  try {
    $procs = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop
    return @($procs | Where-Object { $_.CommandLine -match 'dsh[\\/]lib[\\/]bin\.js' })
  } catch { return @() }
}

# ── 运行中的 dsh web 检查 ────────────────────────────────────────────────────
$running = @(Get-DshWebProcesses)
if ($running.Count -gt 0 -and -not $Force) {
  Write-Host ""
  Write-Host "[STOP] 检测到 dsh web 正在运行（PID: $($running.ProcessId -join ', ')）。"
  Write-Host "       卸载需要删除 node_modules，运行中的进程会锁定文件。"
  Write-Host "       请先关闭 dsh web（Ctrl+C），再重新运行本脚本。"
  Write-Host "       确认要强行继续可加 -Force（可能删不干净）。"
  exit 1
}

# ── 计划 ─────────────────────────────────────────────────────────────────────
$dirsToDelete = @()
$profilesRoot = Join-Path $DshHome "profiles"
if (Test-Path $profilesRoot) {
  Get-ChildItem -Path $profilesRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $candidate = Join-Path $_.FullName "node_modules\dsh-purge"
    if (Test-Path -LiteralPath $candidate) { $dirsToDelete += $candidate }
  }
}
$dataDir = Join-Path $DshHome "dsh-purge"
$redteamDir = Join-Path $DshHome "redteam"
if (Test-Path $dataDir) { $dirsToDelete += $dataDir }
if (Test-Path $redteamDir) { $dirsToDelete += $redteamDir }

Write-Host ""
Write-Host "计划："
Write-Host "  1) 快照到 $ArchiveRoot\plugin-uninstall-<时间戳>\"
Write-Host "  2) 运行 dsh-purge --uninstall（还原宿主补丁/ shim / 注入文件 / 规则）"
Write-Host "  3) 删除以下目录："
$dirsToDelete | ForEach-Object { Write-Host "       - $_" }
Write-Host "  4) 从所有 profile 的 package.json 移除 dsh-purge（bundles + dependencies）"
Write-Host "  5) 执行 dsh plugin --profile $Profile install --prefer-offline 清理依赖"
Write-Host "  6) 打印恢复方式"

if ($DryRun) {
  Write-Host ""
  Write-Host "[DRY-RUN] 未修改任何文件。"
  exit 0
}

# ── 交互确认 ─────────────────────────────────────────────────────────────────
if (-not $Yes) {
  Write-Host ""
  Write-Host "!! 这是不可逆操作：会删除插件、它的规则库和演练台数据（先做快照）。"
  $answer = Read-Host "确认请输入 YES，其它任意输入取消"
  if ($answer -ne "YES") {
    Write-Host "已取消，未修改任何文件。"
    exit 1
  }
}

# ── 快照 ─────────────────────────────────────────────────────────────────────
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$snapDir = Join-Path $ArchiveRoot "plugin-uninstall-$stamp"
New-Item -ItemType Directory -Force -Path (Join-Path $snapDir "profile") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $snapDir "home") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $snapDir "plugin") | Out-Null

foreach ($name in @("package.json", "pnpm-lock.yaml", "cordis.patch.yml", "cordis.yml", "pnpm-workspace.yaml")) {
  $src = Join-Path $ProfileDir $name
  if (Test-Path $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $snapDir "profile\$name") -Force }
}
foreach ($name in @("prompt-inject.md", "AGENTS.md")) {
  $src = Join-Path $DshHome $name
  if (Test-Path $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $snapDir "home\$name") -Force }
}
Copy-Item -LiteralPath (Join-Path $pluginRoot "package.json") -Destination (Join-Path $snapDir "plugin\package.json") -Force
if (Test-Path $dataDir) { Copy-Item -LiteralPath $dataDir -Destination (Join-Path $snapDir "home\dsh-purge") -Recurse -Force }
if (Test-Path $redteamDir) { Copy-Item -LiteralPath $redteamDir -Destination (Join-Path $snapDir "home\redteam") -Recurse -Force }

$statusBefore = ""
try {
  $nodeForStatus = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
  if ($nodeForStatus -and (Test-Path $pluginBin)) {
    $statusBefore = (& $nodeForStatus $pluginBin --status 2>&1 | Out-String)
    [System.IO.File]::WriteAllText((Join-Path $snapDir "patch-status-before.txt"), $statusBefore, [System.Text.UTF8Encoding]::new($false))
  }
} catch { }

# ── 运行官方卸载逻辑（还原补丁/清注入/清规则/strip 依赖）────────────────────
if (-not $SkipHostPatches) {
  if (-not (Test-Path $pluginBin)) { throw "找不到插件 CLI：$pluginBin" }
  $node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
  if (-not $node) { $node = (Get-Command node -ErrorAction SilentlyContinue).Source }
  if (-not $node) { throw "PATH 里找不到 node，无法运行 dsh-purge --uninstall" }
  Write-Host ""
  Write-Host "[..] 运行插件官方卸载逻辑（dsh-purge --uninstall）……"
  $uninstallOutput = (& $node $pluginBin --uninstall 2>&1 | Out-String)
  Write-Host $uninstallOutput.Trim()
  [System.IO.File]::WriteAllText((Join-Path $snapDir "uninstall-output.txt"), $uninstallOutput, [System.Text.UTF8Encoding]::new($false))
  if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "[ABORT] 官方卸载逻辑失败（退出码 $LASTEXITCODE），插件文件未删除。"
    Write-Host "        快照在：$snapDir"
    Write-Host "        请按上方错误处理，或参考 README 的「撤销修复、停用与卸载的区别」一节手工还原。"
    exit 1
  }
} else {
  Write-Host ""
  Write-Host "[SKIP] 已按 -SkipHostPatches 跳过官方卸载逻辑（测试模式）。"
}

# ── 删除插件目录与数据 ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "[..] 删除插件文件与数据……"
$deleteErrors = @()
foreach ($dir in $dirsToDelete) {
  if (Remove-Tree $dir) {
    Write-Host "  [OK] 已删除 $dir"
  } else {
    $deleteErrors += $dir
    Write-Host "  [WARN] 删除失败（可能被占用）: $dir"
  }
}

# ── 清理所有 profile 的 package.json ────────────────────────────────────────
Write-Host ""
Write-Host "[..] 清理 profile 配置……"
if (Test-Path $profilesRoot) {
  Get-ChildItem -Path $profilesRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $pkgFile = Join-Path $_.FullName "package.json"
    if (-not (Test-Path $pkgFile)) { return }
    try {
      $pkg = Read-JsonFile $pkgFile
      $changed = $false
      $info = Get-BundleInfo $pkg
      if ($info) {
        $filtered = @($info.Items | Where-Object { -not (Test-PurgeBundle ([string]$_)) })
        if ($filtered.Count -ne $info.Items.Count) {
          $info.Container.bundles = $filtered
          $changed = $true
        }
      }
      foreach ($key in @("dependencies", "devDependencies", "optionalDependencies", "peerDependencies")) {
        if (($pkg.PSObject.Properties.Name -contains $key) -and $pkg.$key) {
          $dep = $pkg.$key.PSObject.Properties["dsh-purge"]
          if ($dep) { $pkg.$key.PSObject.Properties.Remove("dsh-purge"); $changed = $true }
        }
      }
      if ($changed) {
        Write-JsonFile $pkgFile $pkg
        Write-Host "  [OK] 已清理 $pkgFile"
      }
    } catch {
      Write-Host "  [WARN] 处理失败 $pkgFile : $($_.Exception.Message)"
    }
  }
}

# ── pnpm install 清理依赖 ───────────────────────────────────────────────────
Write-Host ""
Write-Host "[..] 运行 dsh plugin install 清理依赖……"
$dshCmd = (Get-Command dsh.cmd -ErrorAction SilentlyContinue).Source
if (-not $dshCmd) {
  $candidate = Join-Path $env:APPDATA "npm\dsh.cmd"
  if (Test-Path $candidate) { $dshCmd = $candidate }
}
if ($dshCmd) {
  try {
    $installOutput = (& cmd.exe /c "`"$dshCmd`" plugin --profile $Profile install --prefer-offline" 2>&1 | Out-String)
    Write-Host $installOutput.Trim()
    if ($LASTEXITCODE -ne 0) {
      Write-Host "  [WARN] dsh plugin install 退出码 $LASTEXITCODE（不影响插件已删除；可稍后在 profile 目录手动 pnpm install）"
    } else {
      Write-Host "  [OK] 依赖已清理"
    }
  } catch {
    Write-Host "  [WARN] dsh plugin install 失败：$($_.Exception.Message)"
  }
} else {
  Write-Host "  [WARN] 找不到 dsh.cmd，跳过依赖清理；可稍后手工在 profile 目录运行 pnpm install"
}

# ── 快照说明 ─────────────────────────────────────────────────────────────────
$readme = @"
dsh-purge 卸载快照
时间: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Profile: $ProfileDir
DSH_HOME: $DshHome

本快照包含：
  profile\      package.json / pnpm-lock.yaml / cordis.patch.yml / cordis.yml
  home\         prompt-inject.md / AGENTS.md / dsh-purge 数据 / redteam 数据
  plugin\       插件 package.json
  patch-status-before.txt / uninstall-output.txt

如何恢复插件（任选）：
  1) 重新安装：
       dsh plugin --profile $Profile add github:YuJunZhiXue/dsh-purge
     然后把 "dsh-purge" 加回 profile package.json 的 dsh.profile.bundles，
     重启 dsh web，在插件界面点「应用」。
  2) 恢复本快照里的数据：
       把 home\prompt-inject.md、home\dsh-purge、home\redteam 复制回 $DshHome
       把 profile\package.json 等复制回 $ProfileDir
     再按 1) 重新安装插件。

注意：卸载已还原 DSH 程序文件上的 dsh-purge 补丁，无需额外恢复宿主。
"@
[System.IO.File]::WriteAllText((Join-Path $snapDir "如何恢复.txt"), $readme, [System.Text.UTF8Encoding]::new($false))

Write-Host ""
Write-Host "============================================================"
Write-Host " [DONE] dsh-purge 已卸载"
Write-Host "------------------------------------------------------------"
Write-Host " - 宿主补丁：$(if ($SkipHostPatches) { '已跳过（测试模式）' } else { '已还原为官方原版' })"
$deletedNote = if ($deleteErrors.Count) { "（$($deleteErrors.Count) 个目录删除失败，见上）" } else { "" }
Write-Host " - 插件文件/数据：已删除$deletedNote"
Write-Host " - 其它插件：未改动"
Write-Host " - 快照：$snapDir"
Write-Host ""
Write-Host " 请重启 dsh web 生效。"
if ($deleteErrors.Count) {
  Write-Host " 仍有目录残留，请关闭所有 dsh 进程后手工删除（路径见上），或重新运行本脚本。"
  exit 1
}
Write-Host "============================================================"
