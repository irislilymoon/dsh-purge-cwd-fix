<#
.SYNOPSIS
  dsh-purge cwd 变量问题只读体检（不修改任何文件）。

.DESCRIPTION
  检查：
    1. dsh / node / dsh-purge 版本
    2. 插件 lib\index.js 是否含 cwd 变量补丁
    3. 宿主 dsh-agent-loop 注册了哪些 prompt 变量（provider/model/cwd）
    4. 插件 lib\desktop.js 是否含注册表扫描补丁
    5. 插件 cordis.patch.yml / identity.js 是否仍依赖 {{cwd}}
    6. 本仓库补丁数据是否完整
  最后给出下一步建议。DSH 或 dsh-purge 更新后先跑它。

.PARAMETER DshHome
  DSH 主目录；默认取 $env:DSH_HOME，否则 %USERPROFILE%\.dsh

.PARAMETER Profile
  profile 名，默认 web

.PARAMETER LibDir
  直接指定 dsh-purge\lib 目录（优先于 DshHome/Profile）

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\diagnose.ps1

.EXAMPLE
  .\scripts\diagnose.ps1 -Profile tui
#>
param(
  [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE ".dsh" }),
  [string]$Profile = "web",
  [string]$LibDir = ""
)

$ErrorActionPreference = "Continue"
$results = New-Object System.Collections.Generic.List[object]

function Add-Result([string]$Level, [string]$Name, [string]$Detail) {
  $script:results.Add([pscustomobject]@{ Level = $Level; Name = $Name; Detail = $Detail })
}

Write-Host "============================================================"
Write-Host " dsh-purge cwd 问题体检（只读）"
Write-Host " 时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "============================================================"

# ── 0. 基础路径 ───────────────────────────────────────────────────────────────
if (-not $LibDir) {
  $LibDir = Join-Path $DshHome "profiles\$Profile\node_modules\dsh-purge\lib"
}
$LibDir = [System.IO.Path]::GetFullPath($LibDir)
$pluginRoot = Split-Path $LibDir -Parent

$shim = (Get-Command dsh.cmd -ErrorAction SilentlyContinue).Source
if (-not $shim) { $shim = Join-Path $env:APPDATA "npm\dsh.cmd" }
$dshPackage = ""
if ($shim -and (Test-Path $shim)) {
  $dshPackage = Join-Path (Split-Path $shim -Parent) "node_modules\@deepseek-ai\dsh"
}

Write-Host " DSH_HOME : $DshHome"
Write-Host " 插件目录 : $LibDir"
Write-Host " 宿主目录 : $(if ($dshPackage) { $dshPackage } else { '(未找到)' })"
Write-Host "------------------------------------------------------------"

# ── 1. 版本 ──────────────────────────────────────────────────────────────────
try {
  $dshVersion = (& dsh --version 2>$null | Select-Object -First 1)
  Add-Result "INFO" "dsh 版本" $dshVersion
} catch {
  Add-Result "WARN" "dsh 版本" "无法执行 dsh --version"
}
try {
  Add-Result "INFO" "node 版本" ((& node -v) -join " ")
} catch {
  Add-Result "WARN" "node 版本" "无法执行 node -v"
}
$pluginVersion = "unknown"; $dshTarget = "unknown"
$pluginPkg = Join-Path $pluginRoot "package.json"
if (Test-Path $pluginPkg) {
  try {
    $pkg = Get-Content $pluginPkg -Raw | ConvertFrom-Json
    $pluginVersion = [string]$pkg.version
    $dshTarget = [string]$pkg.dshTarget
    Add-Result "INFO" "dsh-purge 版本" "$pluginVersion (dshTarget: $dshTarget)"
  } catch {
    Add-Result "WARN" "dsh-purge 版本" "package.json 解析失败"
  }
} else {
  Add-Result "FAIL" "dsh-purge 版本" "找不到 $pluginPkg（profile/路径不对？）"
}

# ── 2. index.js 补丁状态 ─────────────────────────────────────────────────────
$indexPath = Join-Path $LibDir "index.js"
$indexPatched = $false
if (Test-Path $indexPath) {
  $indexText = Get-Content $indexPath -Raw
  $indexPatched = ($indexText.Contains("CWD_PROMPT_VARIABLE") -and $indexText.Contains("installCwdVariable"))
  if ($indexPatched) {
    Add-Result "OK" "index.js cwd 变量补丁" "已在（installCwdVariable / CWD_PROMPT_VARIABLE 均存在）"
  } else {
    Add-Result "FAIL" "index.js cwd 变量补丁" "缺失 —— 这通常就是 dsh web 报 unknown prompt variable 的直接原因"
  }
} else {
  Add-Result "FAIL" "index.js" "文件不存在：$indexPath"
}

# ── 3. 宿主 prompt 变量注册 ──────────────────────────────────────────────────
$agentLoop = ""
if ($dshPackage) {
  $agentLoop = Join-Path $dshPackage "node_modules\@deepseek-ai\dsh-agent-loop\lib\index.js"
}
if ($agentLoop -and (Test-Path $agentLoop)) {
  $registrations = @(Select-String -Path $agentLoop -Pattern 'systemPrompt\.variable\("([a-z0-9_]+)"' -AllMatches |
    ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
  $hostHasCwd = $registrations -contains "cwd"
  Add-Result "INFO" "宿主注册的 prompt 变量" ($(if ($registrations.Count) { $registrations -join ", " } else { "(无)" }))
  if ($hostHasCwd) {
    Add-Result "OK" "宿主原生 cwd 变量" "已注册 —— 插件补丁非必需（重复注册会被安全忽略）"
  } else {
    Add-Result "WARN" "宿主原生 cwd 变量" "未注册 —— 插件补丁（index.js）需要保留"
  }
} else {
  Add-Result "WARN" "宿主 dsh-agent-loop" "找不到文件，无法检查变量注册"
}

# ── 4. desktop.js 补丁状态 ──────────────────────────────────────────────────
$desktopPath = Join-Path $LibDir "desktop.js"
if (Test-Path $desktopPath) {
  $desktopText = Get-Content $desktopPath -Raw
  $desktopFixed = $desktopText.Contains("Get-ItemProperty -LiteralPath `$_.PSPath")
  if ($desktopFixed) {
    Add-Result "OK" "desktop.js 注册表扫描补丁" "已在（使用 try/catch + LiteralPath）"
  } else {
    Add-Result "WARN" "desktop.js 注册表扫描补丁" "缺失 —— 启动时可能出现 Get-ItemProperty 转换无效噪音（不影响对话）"
  }
} else {
  Add-Result "WARN" "desktop.js" "文件不存在：$desktopPath"
}

# ── 5. 插件自身是否仍依赖 {{cwd}} ───────────────────────────────────────────
$identityPath = Join-Path $LibDir "identity.js"
if (Test-Path $identityPath) {
  $identityText = Get-Content $identityPath -Raw
  if ($identityText.Contains('"Your working directory is {{cwd}}."')) {
    Add-Result "INFO" "identity.js 的 CWD_ONLY_SUFFIX" '仍为 "Your working directory is {{cwd}}." —— 补 cwd 变量是长期有效解'
  } else {
    Add-Result "INFO" "identity.js 的 CWD_ONLY_SUFFIX" "已不含 {{cwd}} —— 插件可能已自行修复/改版"
  }
} else {
  Add-Result "WARN" "identity.js" "文件不存在：$identityPath"
}
$patchYml = Join-Path $pluginRoot "cordis.patch.yml"
if (Test-Path $patchYml) {
  $ymlHit = Select-String -Path $patchYml -Pattern 'personaSuffix' -SimpleMatch | Select-Object -First 1
  if ($ymlHit -and $ymlHit.Line -match '\{\{cwd\}\}') {
    Add-Result "INFO" "cordis.patch.yml personaSuffix" ("仍写 {{cwd}}： " + $ymlHit.Line.Trim())
  } else {
    Add-Result "INFO" "cordis.patch.yml personaSuffix" "未使用 {{cwd}}（或无此配置）"
  }
}

# ── 6. 仓库补丁数据 ─────────────────────────────────────────────────────────
$helperFile = Join-Path $PSScriptRoot "patch-data\cwd-variable-helper.txt"
if (Test-Path $helperFile) {
  Add-Result "OK" "仓库补丁数据" "完整：$helperFile"
} else {
  Add-Result "WARN" "仓库补丁数据" "缺少 $helperFile，reapply-fix.mjs 将无法自动补 index.js"
}

# ── 汇总 ─────────────────────────────────────────────────────────────────────
Write-Host ""
foreach ($r in $results) {
  $tag = switch ($r.Level) { "OK" { "[ OK ]" } "FAIL" { "[FAIL]" } "WARN" { "[WARN]" } default { "[INFO]" } }
  Write-Host ("{0} {1}: {2}" -f $tag, $r.Name, $r.Detail)
}
Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host " 结论 / 下一步"
Write-Host "------------------------------------------------------------"

$hasFail = @($results | Where-Object { $_.Level -eq "FAIL" }).Count -gt 0
$hostHasCwd = @($results | Where-Object { $_.Name -eq "宿主原生 cwd 变量" -and $_.Level -eq "OK" }).Count -gt 0
if ($hasFail -and -not $hostHasCwd -and -not $indexPatched) {
  Write-Host " 插件补丁缺失 => 运行：node `"$(Join-Path $PSScriptRoot 'reapply-fix.mjs')`""
  Write-Host " 然后重启 dsh web。"
} elseif ($hasFail) {
  Write-Host " 存在 FAIL 项，请对照 README.md 的「故障排查」一节手工处理。"
} else {
  Write-Host " 补丁状态正常。若 dsh web 仍报 unknown prompt variable："
  Write-Host "   1) 确认 dsh web 已重启（旧进程不会热加载插件文件）；"
  Write-Host "   2) 再运行 reapply-fix.mjs --dry-run 复查；"
  Write-Host "   3) 仍失败则看 README.md 的「更新 / 重装后复发」。"
}
Write-Host ""
Write-Host " 提示：本脚本只读，不修改任何文件。"
