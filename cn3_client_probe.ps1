<#
LazyVPS CN3 Client Probe v3.0.0-open
中国本地端 / Windows 客户端去程与代理体感测试脚本

示例：
powershell -ExecutionPolicy Bypass -File .\cn3_client_probe.ps1 -VpsHost 1.2.3.4 -Ports 22,443,8443 -Proxy http://127.0.0.1:7890
#>
param(
    [string]$VpsHost = "",
    [int[]]$Ports = @(22),
    [string]$Proxy = "",
    [int]$PingCount = 10,
    [string]$OutDir = ""
)
$ErrorActionPreference = "SilentlyContinue"
$Version = "3.0.0-open"

function NowStamp { return (Get-Date).ToString("yyyyMMdd_HHmmss") }
function FitText([string]$Text, [int]$Width) {
    if ($null -eq $Text) { $Text = "" }
    $s = [string]$Text
    if ($s.Length -gt $Width) { return $s.Substring(0, [Math]::Max(0, $Width-1)) + "…" }
    return $s.PadRight($Width)
}
function Bar([double]$Value, [int]$Width = 26) {
    if ($Value -lt 0) { $Value = 0 }
    if ($Value -gt 100) { $Value = 100 }
    $n = [Math]::Round($Value / 100 * $Width)
    return ("█" * $n) + ("░" * ($Width - $n))
}
function GradeText([double]$Score) {
    if ($Score -ge 90) { return "A+ 优秀" }
    if ($Score -ge 82) { return "A 主力" }
    if ($Score -ge 74) { return "B+ 良好" }
    if ($Score -ge 66) { return "B 可用" }
    if ($Score -ge 56) { return "C 备用" }
    return "D 谨慎"
}
function TestTcpPort([string]$HostName, [int]$Port, [int]$TimeoutMs = 2500) {
    $client = New-Object System.Net.Sockets.TcpClient
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $success = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($success -and $client.Connected) {
            $client.EndConnect($iar) | Out-Null
            $sw.Stop(); $client.Close()
            return [PSCustomObject]@{Port=$Port; Status="OK"; LatencyMs=[Math]::Round($sw.Elapsed.TotalMilliseconds,2)}
        }
        $client.Close()
        return [PSCustomObject]@{Port=$Port; Status="FAIL"; LatencyMs="NA"}
    } catch {
        try { $client.Close() } catch {}
        return [PSCustomObject]@{Port=$Port; Status="FAIL"; LatencyMs="NA"}
    }
}
function GetPingStats([string]$HostName, [int]$Count) {
    $results = @()
    try { $results = Test-Connection -ComputerName $HostName -Count $Count -ErrorAction SilentlyContinue } catch {}
    $ok = @($results | Where-Object { $_ })
    $sent = $Count; $recv = $ok.Count
    $loss = if ($sent -gt 0) { [Math]::Round((($sent-$recv)/$sent)*100,2) } else { 100 }
    if ($recv -gt 0) {
        $times = @($ok | ForEach-Object { $_.ResponseTime })
        return [PSCustomObject]@{
            Sent=$sent; Received=$recv; LossPercent=$loss;
            MinMs=($times | Measure-Object -Minimum).Minimum;
            AvgMs=[Math]::Round(($times | Measure-Object -Average).Average,2);
            MaxMs=($times | Measure-Object -Maximum).Maximum
        }
    }
    return [PSCustomObject]@{Sent=$sent; Received=0; LossPercent=100; MinMs="NA"; AvgMs="NA"; MaxMs="NA"}
}
function TestProxyUrl([string]$Name, [string]$Url, [string]$ProxyUrl) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ([string]::IsNullOrWhiteSpace($ProxyUrl)) {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 12
        } else {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 12 -Proxy $ProxyUrl
        }
        $sw.Stop()
        return [PSCustomObject]@{Name=$Name; Url=$Url; Status="OK"; HttpCode=$resp.StatusCode; LatencyMs=[Math]::Round($sw.Elapsed.TotalMilliseconds,2)}
    } catch {
        $sw.Stop()
        return [PSCustomObject]@{Name=$Name; Url=$Url; Status="FAIL"; HttpCode="NA"; LatencyMs="NA"}
    }
}
function ScoreClient($Ping, $TcpRows, $ProxyRows) {
    $score = 100.0
    if ($Ping.AvgMs -ne "NA") {
        $avg = [double]$Ping.AvgMs
        if ($avg -gt 80) { $score -= [Math]::Min(25, ($avg-80)*0.10) }
        if ($avg -gt 160) { $score -= [Math]::Min(20, ($avg-160)*0.08) }
    } else { $score -= 35 }
    $score -= [Math]::Min(35, [double]$Ping.LossPercent * 1.2)
    if ($TcpRows.Count -gt 0) {
        $ok = @($TcpRows | Where-Object {$_.Status -eq "OK"}).Count
        $rate = $ok / $TcpRows.Count * 100
        $score -= [Math]::Max(0, (100-$rate)*0.45)
    }
    if ($ProxyRows.Count -gt 0) {
        $ok = @($ProxyRows | Where-Object {$_.Status -eq "OK"}).Count
        $rate = $ok / $ProxyRows.Count * 100
        $score -= [Math]::Max(0, (100-$rate)*0.25)
    }
    if ($score -lt 0) { $score = 0 }
    if ($score -gt 100) { $score = 100 }
    return [Math]::Round($score,1)
}

if ([string]::IsNullOrWhiteSpace($VpsHost)) { $VpsHost = Read-Host "请输入 VPS IP 或域名" }
if ([string]::IsNullOrWhiteSpace($VpsHost)) { Write-Host "未输入 VPS 地址，退出。" -ForegroundColor Red; exit 1 }
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = "cn3_client_test_$(NowStamp)" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "LazyVPS CN3 Client Probe v$Version" -ForegroundColor Cyan
Write-Host "中国本地端去程 / 端口 / 代理体感测试" -ForegroundColor White
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "目标 VPS：$VpsHost"
Write-Host "测试端口：$($Ports -join ',')"
Write-Host "代理地址：$(if($Proxy){$Proxy}else{'未设置，仅测试本地到 VPS'})"
Write-Host "输出目录：$OutDir"
Write-Host ""

$ping = GetPingStats -HostName $VpsHost -Count $PingCount
$tcpRows = @()
foreach ($p in $Ports) { $tcpRows += TestTcpPort -HostName $VpsHost -Port $p }

$traceFile = Join-Path $OutDir "tracert_to_vps.txt"
try { tracert -d $VpsHost | Out-File -Encoding UTF8 $traceFile } catch {}

$proxyRows = @()
if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
    $proxyTargets = @(
        @{Name="Cloudflare"; Url="https://www.cloudflare.com/cdn-cgi/trace"},
        @{Name="Google204"; Url="https://www.gstatic.com/generate_204"},
        @{Name="GitHub"; Url="https://github.com"},
        @{Name="OpenAI"; Url="https://chat.openai.com/cdn-cgi/trace"}
    )
    foreach ($t in $proxyTargets) { $proxyRows += TestProxyUrl -Name $t.Name -Url $t.Url -ProxyUrl $Proxy }
}

$score = ScoreClient -Ping $ping -TcpRows $tcpRows -ProxyRows $proxyRows
$grade = GradeText -Score $score

$summaryCsv = Join-Path $OutDir "client_summary.csv"
@(
    [PSCustomObject]@{Item="VpsHost"; Value=$VpsHost}
    [PSCustomObject]@{Item="PingAvgMs"; Value=$ping.AvgMs}
    [PSCustomObject]@{Item="PingLossPercent"; Value=$ping.LossPercent}
    [PSCustomObject]@{Item="Score"; Value=$score}
    [PSCustomObject]@{Item="Grade"; Value=$grade}
    [PSCustomObject]@{Item="Proxy"; Value=$(if($Proxy){$Proxy}else{"NA"})}
) | Export-Csv -Encoding UTF8 -NoTypeInformation $summaryCsv

$tcpCsv = Join-Path $OutDir "tcp_ports.csv"
$tcpRows | Export-Csv -Encoding UTF8 -NoTypeInformation $tcpCsv

$proxyCsv = Join-Path $OutDir "proxy_experience.csv"
$proxyRows | Export-Csv -Encoding UTF8 -NoTypeInformation $proxyCsv

$report = Join-Path $OutDir "client_report.md"
$md = @()
$md += "# LazyVPS Client Probe 本地端测试报告"
$md += ""
$md += "- VPS：$VpsHost"
$md += "- Ping 平均：$($ping.AvgMs) ms"
$md += "- Ping 丢包：$($ping.LossPercent)%"
$md += "- 综合评分：$score"
$md += "- 评级：$grade"
$md += "- 代理：$(if($Proxy){$Proxy}else{'未设置'})"
$md += ""
$md += "## TCP 端口"
$md += "| Port | Status | LatencyMs |"
$md += "|---|---|---|"
foreach ($r in $tcpRows) { $md += "| $($r.Port) | $($r.Status) | $($r.LatencyMs) |" }
$md += ""
$md += "## 代理体感"
$md += "| Name | Status | HttpCode | LatencyMs |"
$md += "|---|---|---|---|"
foreach ($r in $proxyRows) { $md += "| $($r.Name) | $($r.Status) | $($r.HttpCode) | $($r.LatencyMs) |" }
$md | Out-File -Encoding UTF8 $report

Write-Host ""
Write-Host "+--------------------------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host "|                 LazyVPS 中国本地端去程 / 代理体感 CMD 仪表盘                 |" -ForegroundColor Cyan
Write-Host "+--------------------------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host ("| 目标 VPS     | {0} |" -f (FitText $VpsHost 62)) -ForegroundColor Cyan
Write-Host ("| 综合评分     | {0}  {1} |" -f (FitText "$score / $grade" 20), (Bar $score 30)) -ForegroundColor Cyan
Write-Host ("| Ping/丢包    | Avg {0} ms / Loss {1}% |" -f $ping.AvgMs, $ping.LossPercent) -ForegroundColor Cyan
Write-Host "+--------------------------------------------------------------------------------+" -ForegroundColor Cyan

Write-Host ""
Write-Host "+----------+----------+------------+" -ForegroundColor Cyan
Write-Host "| Port     | Status   | LatencyMs  |" -ForegroundColor Cyan
Write-Host "+----------+----------+------------+" -ForegroundColor Cyan
foreach ($r in $tcpRows) {
    $color = if ($r.Status -eq "OK") { "Green" } else { "Red" }
    Write-Host ("| {0} | {1} | {2} |" -f (FitText $r.Port 8), (FitText $r.Status 8), (FitText $r.LatencyMs 10)) -ForegroundColor $color
}
Write-Host "+----------+----------+------------+" -ForegroundColor Cyan

if ($proxyRows.Count -gt 0) {
    Write-Host ""
    Write-Host "+-------------+----------+----------+------------+" -ForegroundColor Cyan
    Write-Host "| 代理目标    | Status   | HTTP     | LatencyMs  |" -ForegroundColor Cyan
    Write-Host "+-------------+----------+----------+------------+" -ForegroundColor Cyan
    foreach ($r in $proxyRows) {
        $color = if ($r.Status -eq "OK") { "Green" } else { "Red" }
        Write-Host ("| {0} | {1} | {2} | {3} |" -f (FitText $r.Name 11), (FitText $r.Status 8), (FitText $r.HttpCode 8), (FitText $r.LatencyMs 10)) -ForegroundColor $color
    }
    Write-Host "+-------------+----------+----------+------------+" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "输出文件：" -ForegroundColor Cyan
Write-Host "  - $report"
Write-Host "  - $summaryCsv"
Write-Host "  - $tcpCsv"
Write-Host "  - $proxyCsv"
Write-Host "  - $traceFile"
Write-Host ""
Write-Host "一句话：本地到 VPS 的去程评分 $score / $grade；搭配 VPS 端回程测试才是完整闭环。" -ForegroundColor Yellow
