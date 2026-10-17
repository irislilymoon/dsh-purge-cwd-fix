<#
.SYNOPSIS
  dsh web 端到端验证脚本：启动一个临时 dsh web，经 /api 建会话并发一句话，确认不再报
  "unknown prompt variable"。

.DESCRIPTION
  流程：
    1) 用 `dsh web --port 0 --no-open` 在随机端口启动临时实例；
    2) 用打印出来的 token 换取浏览器 cookie；
    3) POST /api/session/create 建会话；
    4) POST /api/session/prompt 发一句测试话（默认“只回复两个字：收到”）；
    5) 轮询 /api/session/list，直到回合结束并检查回复非空；
    6) 关闭临时实例，删除测试会话目录，保留日志。

  注意：
    * 会真实调用一次模型（消耗少量 token），需要已配置模型凭据；
    * 建议先关闭正在运行的 dsh web，避免干扰；
    * 脚本只写临时日志和测试会话，不改插件/配置。

.PARAMETER DshHome
  DSH 主目录，默认 $env:DSH_HOME，否则 %USERPROFILE%\.dsh

.PARAMETER Prompt
  测试用提示词，默认“只回复两个字：收到”

.PARAMETER TimeoutSeconds
  等待回合完成的上限，默认 120 秒

.PARAMETER KeepSession
  保留测试会话（默认结束后删除）

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\verify-dsh-web.ps1

.EXAMPLE
  .\verify-dsh-web.ps1 -Prompt "回复 ok" -TimeoutSeconds 180
#>
param(
  [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE ".dsh" }),
  [string]$Prompt = "只回复两个字：收到",
  [int]$TimeoutSeconds = 120,
  [switch]$KeepSession
)

$ErrorActionPreference = "Stop"
$exitCode = 1
$sid = $null
$proc = $null
$tmp = Join-Path $env:TEMP ("dsh-web-verify-" + [guid]::NewGuid().ToString("N"))
$stdout = Join-Path $tmp "dsh-web.stdout.log"
$stderr = Join-Path $tmp "dsh-web.stderr.log"

Write-Host "============================================================"
Write-Host " dsh web 端到端验证（会真实调用一次模型）"
Write-Host "------------------------------------------------------------"
Write-Host " DSH_HOME : $DshHome"
Write-Host " 测试提示 : $Prompt"
Write-Host " 日志目录 : $tmp"
Write-Host "============================================================"

New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
  # ── 定位 dsh.cmd ───────────────────────────────────────────────────────────
  $dshCmd = (Get-Command dsh.cmd -ErrorAction SilentlyContinue).Source
  if (-not $dshCmd) {
    $candidate = Join-Path $env:APPDATA "npm\dsh.cmd"
    if (Test-Path $candidate) { $dshCmd = $candidate }
  }
  if (-not $dshCmd) {
    throw "找不到 dsh.cmd。请确认 dsh 已安装，且 npm 全局 bin 在 PATH 中。"
  }

  # ── 启动临时实例 ───────────────────────────────────────────────────────────
  Write-Host "[..] 启动临时 dsh web（随机端口，不打开浏览器）"
  $proc = Start-Process -FilePath "cmd.exe" `
    -ArgumentList @("/c", "`"$dshCmd`"", "web", "--port", "0", "--no-open") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
    -PassThru -WindowStyle Hidden

  $url = $null
  $token = $null
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) {
      $errText = if (Test-Path $stderr) { Get-Content $stderr -Raw -ErrorAction SilentlyContinue } else { "" }
      throw "dsh web 提前退出（exit=$($proc.ExitCode)）。stderr: $errText"
    }
    if (Test-Path $stdout) {
      $text = Get-Content $stdout -Raw -ErrorAction SilentlyContinue
      if ($text -match 'http://127\.0\.0\.1:(\d+)/\?token=([A-Za-z0-9_\-]+)') {
        $port = $Matches[1]
        $token = $Matches[2]
        $url = "http://127.0.0.1:$port"
        break
      }
    }
  }
  if (-not $url) { throw "等待 dsh web 启动超时（60s），请查看日志：$stdout / $stderr" }
  Write-Host "[OK] dsh web 已启动：$url"

  # ── token 换 cookie ────────────────────────────────────────────────────────
  $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
  try {
    Invoke-WebRequest -Uri ("$url/?token=" + $token) -WebSession $session `
      -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction Stop | Out-Null
  } catch {
    # 303 重定向本身会抛“超过最大重定向计数”，cookie 已写入 WebSession，忽略即可
  }
  $cookies = $session.Cookies.GetCookies($url)
  if (-not $cookies -or $cookies.Count -eq 0) {
    throw "没有拿到认证 cookie。token 可能已失效或端口不对。"
  }
  Write-Host "[OK] 浏览器 cookie 已获取"

  # ── 通用 RPC 调用 ──────────────────────────────────────────────────────────
  function Invoke-DshApi([string]$method, [hashtable]$argsPayload) {
    $rpcId = [guid]::NewGuid().ToString()
    $envelope = @{
      type    = "client-request"
      rpcId   = $rpcId
      method  = $method
      payload = @{ args = $argsPayload }
    } | ConvertTo-Json -Depth 24 -Compress
    $resp = Invoke-WebRequest -Uri "$url/api/$method" -Method Post -WebSession $session `
      -ContentType "application/json" -Body $envelope -Headers @{ Origin = $url } -SkipHttpErrorCheck
    $parsed = $resp.Content | ConvertFrom-Json
    if (-not $parsed.result.ok) {
      $err = $parsed.result.error | ConvertTo-Json -Compress -Depth 8
      throw "API $method 失败：$err"
    }
    return $parsed.result.value
  }

  # ── 建会话 ─────────────────────────────────────────────────────────────────
  $workdir = (Get-Location).Path
  $created = Invoke-DshApi "session/create" @{ request = @{ cwd = $workdir } }
  $sid = [string]$created.sessionId
  if (-not $sid) { throw "session/create 没有返回 sessionId" }
  Write-Host "[OK] 已创建测试会话：$sid"

  # ── 发消息 ─────────────────────────────────────────────────────────────────
  $requestId = [guid]::NewGuid().ToString()
  $promptPayload = @{
    request = @{
      sessionId = $sid
      requestId = $requestId
      mode      = "queue"
      content   = @(@{ type = "text"; text = $Prompt })
    }
  }
  $accepted = Invoke-DshApi "session/prompt" $promptPayload
  if (-not $accepted.accepted) { throw "session/prompt 未被接受" }
  Write-Host "[OK] 消息已发送，等待模型回复……"

  # ── 轮询会话列表，等回合结束 ───────────────────────────────────────────────
  $row = $null
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $list = Invoke-DshApi "session/list" @{ _request = @{} }
    $row = @($list.items | Where-Object { $_.sessionId -eq $sid }) | Select-Object -First 1
    if ($row -and -not $row.running) { break }
  }
  if (-not $row) { throw "会话列表里找不到测试会话：$sid" }
  if ($row.running) { throw "等待回合结束超时（$TimeoutSeconds s）。日志：$stdout / $stderr" }

  $outline = @($row.projections.values.turnOutline)
  $lastTurn = $outline | Select-Object -Last 1
  $response = if ($lastTurn) { [string]$lastTurn.response } else { "" }
  $turns = [int]$row.projections.values.sessionStats.turns
  $steps = [int]$row.projections.values.sessionStats.steps

  # ── 检查日志里是否仍有原始报错 ─────────────────────────────────────────────
  $logText = ""
  if (Test-Path $stdout) { $logText += (Get-Content $stdout -Raw -ErrorAction SilentlyContinue) }
  if (Test-Path $stderr) { $logText += (Get-Content $stderr -Raw -ErrorAction SilentlyContinue) }
  if ($logText -match "unknown prompt variable") {
    throw "日志中仍出现 unknown prompt variable —— 补丁可能未生效或 dsh web 没有重启。"
  }
  if (-not $response.Trim()) {
    throw "回合结束了但没有回复内容（turns=$turns, steps=$steps）。可能是模型凭据/网络问题，或又出现了组装错误，请查看日志。"
  }

  Write-Host ""
  Write-Host "============================================================"
  Write-Host " [PASS] dsh web 对话链路正常"
  Write-Host "------------------------------------------------------------"
  Write-Host " 测试提示 : $Prompt"
  Write-Host " 模型回复 : $response"
  Write-Host " turns=$turns steps=$steps"
  Write-Host " 未出现 unknown prompt variable"
  Write-Host "============================================================"
  $exitCode = 0
} catch {
  Write-Host ""
  Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "       日志：$stdout"
  Write-Host "             $stderr"
  Write-Host "       排查顺序：1) dsh web 是否已重启  2) 运行 diagnose.ps1  3) 阅读 README.md 的「更新 / 重装后复发」一节"
  $exitCode = 1
} finally {
  # ── 清理：关临时实例、删测试会话、保留日志 ─────────────────────────────────
  if ($proc -and -not $proc.HasExited) {
    try {
      & taskkill.exe /PID $proc.Id /T /F | Out-Null
    } catch {
      try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
  }
  Start-Sleep -Milliseconds 800
  if ($sid -and -not $KeepSession) {
    try {
      $sessionRoot = Join-Path $DshHome "sessions"
      if (Test-Path $sessionRoot) {
        Get-ChildItem -Path $sessionRoot -Recurse -Directory -Filter $sid -ErrorAction SilentlyContinue |
          ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
      }
    } catch { }
  }
  Write-Host ""
  Write-Host "临时实例已关闭。日志保留在：$tmp"
}

exit $exitCode
