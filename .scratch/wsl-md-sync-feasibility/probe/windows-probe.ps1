<#
wsl-md-pulse 真机实测（Windows 侧）

只用系统自带的 PowerShell 5.1、curl.exe 和浏览器，不安装任何东西。
前提：WSL 里正在运行 `bash wsl-probe.sh serve`（它会把本脚本复制到 %USERPROFILE%\wsl-md-probe\ 并打印运行命令）。

运行：
  powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\wsl-md-probe\windows-probe.ps1"
可选参数：
  -OnlyMatrix     只重跑"绑定地址 × 访问地址"矩阵（例如连上 VPN 后再跑一次）
  -OnlyLifecycle  只跑"关闭所有 WSL 终端后服务是否存活"
  -SkipSleep      跳过睡眠/断网等需要人工操作的长连接测试

日志写到 %USERPROFILE%\wsl-md-probe\windows-<时间>.log，跑完把它和 WSL 里的 ~/wsl-md-probe/results/ 一起发回。
#>
param([switch]$OnlyMatrix, [switch]$OnlyLifecycle, [switch]$SkipSleep)

$ErrorActionPreference = 'Continue'
$env:WSL_UTF8 = '1'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$base = Join-Path $env:USERPROFILE 'wsl-md-probe'
New-Item -ItemType Directory -Force -Path $base | Out-Null
$log = Join-Path $base ("windows-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $log | Out-Null

function Section($t) { Write-Host ''; Write-Host "===== $t =====" -ForegroundColor Cyan }
function Now { (Get-Date).ToString('HH:mm:ss.fff') }
function Ask($q) { $a = Read-Host ">>> $q"; Write-Host "[answer] $a"; return $a }

function Probe-Http($url) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $code = & curl.exe -s -m 5 --noproxy '*' -o NUL -w '%{http_code}' $url 2>$null
  $rc = $LASTEXITCODE
  return ('{0,-30} -> http={1} curl_exit={2} {3}ms' -f $url, $code, $rc, $sw.ElapsedMilliseconds)
}

function Test-Ws($url, $count = 3) {
  try {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $cts = New-Object System.Threading.CancellationTokenSource 10000
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ws.ConnectAsync([Uri]$url, $cts.Token).Wait()
    Write-Host ("  {0} ws 已连接，用时 {1}ms" -f (Now), $sw.ElapsedMilliseconds)
    $buf = New-Object byte[] 1024
    for ($i = 0; $i -lt $count; $i++) {
      $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $cts.Token).Result
      Write-Host ("  {0} ws 收到: {1}" -f (Now), [Text.Encoding]::UTF8.GetString($buf, 0, $r.Count))
    }
    $ws.Abort()
    return "WS OK: $url"
  } catch { return "WS FAIL: $url -> $($_.Exception.GetBaseException().Message)" }
}

function Test-Sse($url, $count = 3) {
  try {
    $req = [Net.HttpWebRequest]::Create($url)
    $req.Timeout = 10000; $req.ReadWriteTimeout = 10000; $req.Proxy = $null
    $resp = $req.GetResponse()
    $sr = New-Object IO.StreamReader($resp.GetResponseStream())
    $got = 0
    while ($got -lt $count) {
      $line = $sr.ReadLine()
      if ($null -eq $line) { break }
      if ($line -like 'data:*') { $got++; Write-Host "  $(Now) sse 收到: $line" }
    }
    $resp.Close()
    if ($got -lt $count) { return "SSE FAIL: $url -> 流提前结束" }
    return "SSE OK: $url"
  } catch { return "SSE FAIL: $url -> $($_.Exception.GetBaseException().Message)" }
}

function Show-Env {
  Section '0 环境信息'
  $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $build = [int]$cv.CurrentBuild
  $name = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
  Write-Host ("{0} {1}，{2}，build {3}.{4}" -f $name, $cv.EditionID, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR)
  Write-Host '--- wsl --version'; wsl.exe --version | Out-String | Write-Host
  Write-Host '--- wsl -l -v'; wsl.exe -l -v | Out-String | Write-Host
  Write-Host '--- 网络模式'; wsl.exe -e wslinfo --networking-mode | Out-String | Write-Host
  $wc = Join-Path $env:USERPROFILE '.wslconfig'
  Write-Host "--- $wc"
  if (Test-Path $wc) { Get-Content $wc | Out-String | Write-Host } else { Write-Host '(没有 .wslconfig)' }
  Write-Host '--- 已启用的网卡（用于判断是否连着 VPN）'
  Get-NetAdapter | Where-Object Status -eq 'Up' | Format-Table -AutoSize Name, InterfaceDescription | Out-String | Write-Host
  Write-Host '--- 代理'; netsh winhttp show proxy | Out-String | Write-Host
  Write-Host "HTTP_PROXY=$env:HTTP_PROXY HTTPS_PROXY=$env:HTTPS_PROXY NO_PROXY=$env:NO_PROXY"
  Write-Host "curl.exe: $((Get-Command curl.exe -ErrorAction SilentlyContinue).Source)"
}

function Wait-Serve {
  Section '1 检查 WSL 侧探测服务'
  while ($true) {
    $r = Probe-Http 'http://127.0.0.1:8820/health'
    Write-Host $r
    if ($r -match 'http=200') { return $true }
    $a = Ask '连不上 WSL 侧服务。请在 WSL 终端运行 bash wsl-probe.sh serve，然后按回车重试（输入 s 跳过）'
    if ($a -eq 's') { return $false }
  }
}

function Run-Matrix {
  Section '2 绑定地址 × 访问地址（访问通道研究 E1）'
  Write-Host '8801=127.0.0.1  8802=0.0.0.0  8803=:: 双栈  8804=只绑 ::1'
  foreach ($p in 8801..8804) {
    foreach ($h in '127.0.0.1', '[::1]', 'localhost') { Write-Host (Probe-Http "http://${h}:$p/") }
  }
  Write-Host '--- Windows 侧谁在监听这些端口'
  Get-NetTCPConnection -State Listen -LocalPort 8801, 8802, 8803, 8804, 8820 -ErrorAction SilentlyContinue |
    Select-Object LocalAddress, LocalPort, @{n = 'Proc'; e = { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName } } |
    Format-Table -AutoSize | Out-String | Write-Host
  Write-Host '--- localhost 解析'
  Resolve-DnsName localhost -ErrorAction SilentlyContinue | Format-Table -AutoSize Name, Type, IPAddress | Out-String | Write-Host
  Start-Process 'http://localhost:8801/'
  Start-Process 'http://localhost:8803/'
  Ask '浏览器刚打开了两个标签页：localhost:8801 和 localhost:8803。各自显示 "ok 端口号" 了吗？（例如 "8801 ok, 8803 打不开"）' | Out-Null
  Ask '你现在是否连着 VPN？(y/n) —— 如果平时会用 VPN，连上后用 -OnlyMatrix 参数再跑一次' | Out-Null
}

function Run-LongConn {
  Section '3 WebSocket / SSE 基本连通（访问通道研究 E3）'
  foreach ($h in '127.0.0.1', 'localhost') {
    Write-Host (Test-Ws "ws://${h}:8820/ws")
    Write-Host (Test-Sse "http://${h}:8820/sse")
  }
  Start-Process 'http://127.0.0.1:8820/'
  Write-Host '已在浏览器打开探测页 http://127.0.0.1:8820/ ，页面日志会同步到 WSL 终端。请保持它打开。'
  if ($SkipSleep) { return }

  Section '4 睡眠 / 断网 / 空闲后的恢复（需要你操作）'
  $cases = @(
    '开始菜单 → 电源 → 睡眠，等 2 分钟以上再唤醒',
    '断开 Wi-Fi（或拔网线）30 秒，再连上',
    '什么都不做，让电脑空闲 30 分钟（可以去做别的事）',
    '（可选）休眠：运行 shutdown /h，恢复后再回来'
  )
  foreach ($c in $cases) {
    $a = Ask "场景：$c。准备好后按回车开始（输入 s 跳过这个场景）"
    if ($a -eq 's') { continue }
    $t0 = Get-Date
    Ask '做完后回到这里按回车' | Out-Null
    Write-Host ("场景用时 {0:n0}s" -f ((Get-Date) - $t0).TotalSeconds)
    Write-Host (Probe-Http 'http://127.0.0.1:8820/health')
    Write-Host (Test-Ws 'ws://127.0.0.1:8820/ws' 2)
    Write-Host '--- 正在运行的发行版'; wsl.exe -l --running | Out-String | Write-Host
    Ask '看浏览器探测页：ws/sse 是否自动重新连上？大约多少秒？顶部"距上次消息"是否恢复到 1s 以内？（例如 "y 3s"；如果连不上，写 n）' | Out-Null
  }
}

function Run-Lifecycle {
  Section '5 关闭所有 WSL 终端后，后台服务是否存活（访问通道研究 E9）'
  Ask '请在 WSL 终端运行 bash wsl-probe.sh serve-bg，然后关闭所有 WSL 终端窗口（包括运行 serve 的那个、VS Code 的 WSL 窗口），完成后按回车' | Out-Null
  for ($i = 0; $i -lt 16; $i++) {
    $r = Probe-Http 'http://127.0.0.1:8830/'
    $running = ((wsl.exe -l --running | Out-String) -replace '\s+', ' ').Trim()
    Write-Host "$(Now) $r | 运行中的发行版: $running"
    Start-Sleep -Seconds 15
  }
  Write-Host ''
  Write-Host '如果 8830 在几分钟后变成 curl_exit=7（连不上），说明 WSL 空闲后自动停了。可选的复测：'
  Write-Host '  1) 在 %USERPROFILE%\.wslconfig 里加入两行：[general] 和 instanceIdleTimeout=-1'
  Write-Host '  2) 运行 wsl --shutdown，再打开 WSL 运行 bash wsl-probe.sh serve-bg'
  Write-Host '  3) 用 -OnlyLifecycle 参数重跑本脚本'
}

Show-Env
if ($OnlyLifecycle) {
  Run-Lifecycle
} elseif ($OnlyMatrix) {
  if (Wait-Serve) { Run-Matrix }
} else {
  if (Wait-Serve) {
    Run-Matrix
    Run-LongConn
  }
  $a = Ask '最后一项是后台服务存活测试（需要关闭所有 WSL 终端，约 4 分钟）。现在做吗？(y/n)'
  if ($a -eq 'y') { Run-Lifecycle }
}

Section '结束'
Stop-Transcript | Out-Null
Write-Host "日志: $log"
Write-Host '请把这个日志文件，以及 WSL 里 ~/wsl-md-probe/results/ 目录下的所有日志一起发回。'
