[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [string]$Controller = "http://127.0.0.1:9090",
    [string]$Proxy = "http://127.0.0.1:7890",
    [string]$Secret = "",
    [string]$Group = "",
    [ValidateSet("", "quick", "standard", "deep", "capacity", "unlock", "diagnostic")]
    [string]$Mode = "",
    [string]$ExpectedExitIp = "",
    [string]$NodePattern = "",
    [int]$MaxNodes = 0,
    [string]$OutDir = "",
    [string]$MihomoPath = "",
    [string]$CapacityEndpoint = "https://speed.cloudflare.com",
    [switch]$NoLaunch,
    [switch]$NoColor,
    [switch]$RedactReportIp,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Version = "2.0.0"
$ScriptName = "LazyVPS Airport Full Tester"
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try {
    [Console]::InputEncoding = $script:Utf8NoBom
    [Console]::OutputEncoding = $script:Utf8NoBom
    $global:OutputEncoding = $script:Utf8NoBom
} catch {}
$excelExporter = Join-Path $PSScriptRoot "export_excel.ps1"
if (Test-Path $excelExporter) { . $excelExporter }
$script:RuntimeProcess = $null
$script:RuntimeDir = $null
$script:SwitchLog = New-Object System.Collections.Generic.List[object]
$script:ApiDelayRows = New-Object System.Collections.Generic.List[object]
$script:ServiceRows = New-Object System.Collections.Generic.List[object]
$script:StabilityRows = New-Object System.Collections.Generic.List[object]
$script:SpeedRows = New-Object System.Collections.Generic.List[object]
$script:TopologyRows = New-Object System.Collections.Generic.List[object]
$script:TlsRows = New-Object System.Collections.Generic.List[object]

# ---------- ANSI / CMD UI ----------
$ESC = [char]27
$Ansi = @{
    Reset = "$ESC[0m"; Bold = "$ESC[1m"; Dim = "$ESC[2m"
    Red = "$ESC[31m"; Green = "$ESC[32m"; Yellow = "$ESC[33m"
    Blue = "$ESC[34m"; Magenta = "$ESC[35m"; Cyan = "$ESC[36m"; White = "$ESC[37m"
}
if ($NoColor -or [Console]::IsOutputRedirected) {
    foreach ($key in @($Ansi.Keys)) { $Ansi[$key] = "" }
}

function Write-Ui {
    param([string]$Text, [string]$Color = "White", [switch]$NoNewline)
    $prefix = if ($Ansi.ContainsKey($Color)) { $Ansi[$Color] } else { "" }
    if ($NoNewline) { Write-Host ($prefix + $Text + $Ansi.Reset) -NoNewline }
    else { Write-Host ($prefix + $Text + $Ansi.Reset) }
}

function Show-Cover {
    if (-not [Console]::IsOutputRedirected) { Clear-Host }
    Write-Ui "================================================================================================" Cyan
    Write-Ui @'
 █████╗ ██╗██████╗ ██████╗  ██████╗ ██████╗ ████████╗    ████████╗███████╗███████╗████████╗
██╔══██╗██║██╔══██╗██╔══██╗██╔═══██╗██╔══██╗╚══██╔══╝    ╚══██╔══╝██╔════╝██╔════╝╚══██╔══╝
███████║██║██████╔╝██████╔╝██║   ██║██████╔╝   ██║          ██║   █████╗  ███████╗   ██║
██╔══██║██║██╔══██╗██╔═══╝ ██║   ██║██╔══██╗   ██║          ██║   ██╔══╝  ╚════██║   ██║
██║  ██║██║██║  ██║██║     ╚██████╔╝██║  ██║   ██║          ██║   ███████╗███████║   ██║
╚═╝  ╚═╝╚═╝╚═╝  ╚═╝╚═╝      ╚═════╝ ╚═╝  ╚═╝   ╚═╝          ╚═╝   ╚══════╝╚══════╝   ╚═╝
'@ Cyan
    Write-Ui "      /\_/|      /\_/|      /\_/|      /\_/|     台北101 · 全节点万马奔腾评测版" Magenta
    Write-Ui " ____/ o o\ ____/ o o\ ____/ o o\ ____/ o o\    API切换 · 容量 · 稳定性 · 解锁 · SVG" Blue
    Write-Ui "================================================================================================" Cyan
    Write-Ui ("{0} v{1}  |  FLClash / Mihomo  |  CMD + XLSX + CSV + HTML + SVG" -f $ScriptName, $Version) White
    Write-Ui "配置与密码只在本机使用，不写入测试报告。" Dim
    Write-Host
}

function Select-Menu {
    param([object[]]$Items, [int]$DefaultIndex = 0)
    $selected = [Math]::Max(0, [Math]::Min($Items.Count - 1, $DefaultIndex))
    while ($true) {
        Show-Cover
        Write-Ui "选择测试模式（数字直选 / ↑↓ / W/S / Enter / Q）：" White
        Write-Host
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $mark = if ($i -eq $selected) { "▶" } else { "·" }
            $color = if ($i -eq $selected) { "Yellow" } else { "White" }
            Write-Ui (" {0} [{1}] {2,-14} {3}" -f $mark, $Items[$i].Key, $Items[$i].Title, $Items[$i].Description) $color
        }
        Write-Host
        Write-Ui ("READY  当前 [{0}]" -f $Items[$selected].Key) Green -NoNewline
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::UpArrow -or $key.KeyChar -match '[wWkK]') {
            $selected--; if ($selected -lt 0) { $selected = $Items.Count - 1 }
        } elseif ($key.Key -eq [ConsoleKey]::DownArrow -or $key.KeyChar -match '[sSjJ]') {
            $selected++; if ($selected -ge $Items.Count) { $selected = 0 }
        } elseif ($key.Key -eq [ConsoleKey]::Enter) {
            return $Items[$selected].Value
        } elseif ($key.KeyChar -match '[qQ]') {
            return "exit"
        } else {
            $hit = $Items | Where-Object { $_.Key -eq [string]$key.KeyChar } | Select-Object -First 1
            if ($hit) { return $hit.Value }
        }
    }
}

function Show-ProgressLine {
    param([int]$Current, [int]$Total, [string]$Node, [string]$Stage)
    if ($Total -le 0) { $Total = 1 }
    $pct = [Math]::Min(100, [Math]::Round($Current / $Total * 100))
    $filled = [Math]::Round($pct / 100 * 28)
    $bar = ("█" * $filled) + ("░" * (28 - $filled))
    $line = "`r[{0}] {1,3}%  {2}  |  {3}" -f $bar, $pct, $Node, $Stage
    Write-Ui $line Cyan -NoNewline
}

function Write-Section([string]$Title) {
    Write-Host
    Write-Ui ("=" * 96) Cyan
    Write-Ui ("◆ " + $Title) White
    Write-Ui ("-" * 96) Cyan
}

# ---------- General helpers ----------
function Get-Percentile {
    param([double[]]$Values, [double]$P)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 1) { return [double]$sorted[0] }
    $position = ($sorted.Count - 1) * $P
    $lower = [Math]::Floor($position)
    $upper = [Math]::Ceiling($position)
    if ($lower -eq $upper) { return [double]$sorted[$lower] }
    return [double]$sorted[$lower] * ($upper - $position) + [double]$sorted[$upper] * ($position - $lower)
}

function Get-Grade([double]$Score) {
    if ($Score -ge 90) { return "A+" }
    if ($Score -ge 82) { return "A" }
    if ($Score -ge 74) { return "B+" }
    if ($Score -ge 66) { return "B" }
    if ($Score -ge 56) { return "C" }
    return "D"
}

function Escape-Xml([object]$Value) {
    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function Escape-Html([object]$Value) {
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Repair-Mojibake([object]$Value) {
    $text = [string]$Value
    if (-not $text -or $text -notmatch 'Ã|Â|â€|â„|ðŸ|å.|æ.|ç.|é.|ï¼|�') { return $text }
    try {
        $bytes = [System.Text.Encoding]::GetEncoding(1252).GetBytes($text)
        $fixed = $script:Utf8NoBom.GetString($bytes)
        if ($fixed -and $fixed -notmatch '�') { return $fixed }
    } catch {}
    return $text
}

function Limit-Text([object]$Value, [int]$Length) {
    $text = [string]$Value
    if ($text.Length -le $Length) { return $text }
    return $text.Substring(0, [Math]::Max(1, $Length - 1)) + "…"
}

function Get-ReportIp([string]$Value) {
    if ($script:RedactReportIp -and $Value) { return "REDACTED" }
    return $Value
}

function Save-Csv {
    param([object[]]$Rows, [string]$Path)
    if ($Rows -and $Rows.Count -gt 0) { $Rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8 }
    else { Set-Content -Path $Path -Value "" -Encoding UTF8 }
}

function Get-Profile([string]$Name) {
    switch ($Name) {
        "quick"      { return @{ Threads=2; Seconds=3; HttpSamples=5; Services="core"; Capacity=$true; Stability=$true } }
        "standard"   { return @{ Threads=4; Seconds=5; HttpSamples=12; Services="all"; Capacity=$true; Stability=$true } }
        "deep"       { return @{ Threads=8; Seconds=8; HttpSamples=30; Services="all"; Capacity=$true; Stability=$true } }
        "capacity"   { return @{ Threads=8; Seconds=8; HttpSamples=12; Services="none"; Capacity=$true; Stability=$true } }
        "unlock"     { return @{ Threads=0; Seconds=0; HttpSamples=5; Services="all"; Capacity=$false; Stability=$true } }
        "diagnostic" { return @{ Threads=0; Seconds=0; HttpSamples=3; Services="core"; Capacity=$false; Stability=$true } }
        default       { return @{ Threads=4; Seconds=5; HttpSamples=12; Services="all"; Capacity=$true; Stability=$true } }
    }
}

function Import-LocalSettings {
    $settingsPath = Join-Path $PSScriptRoot "settings.json"
    if (-not (Test-Path $settingsPath)) { return }
    try {
        $settings = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $PSBoundParameters.ContainsKey('Controller') -and $settings.controller) { $script:Controller = [string]$settings.controller }
        if (-not $PSBoundParameters.ContainsKey('Proxy') -and $settings.proxy) { $script:Proxy = [string]$settings.proxy }
        if (-not $PSBoundParameters.ContainsKey('Secret') -and $settings.secret) { $script:Secret = [string]$settings.secret }
        if (-not $PSBoundParameters.ContainsKey('Group') -and $settings.group) { $script:Group = [string]$settings.group }
        if (-not $PSBoundParameters.ContainsKey('ExpectedExitIp') -and $settings.expected_exit_ip) { $script:ExpectedExitIp = [string]$settings.expected_exit_ip }
        if (-not $PSBoundParameters.ContainsKey('Mode') -and $settings.mode) { $script:Mode = [string]$settings.mode }
        if (-not $PSBoundParameters.ContainsKey('NodePattern') -and $settings.node_pattern) { $script:NodePattern = [string]$settings.node_pattern }
        if (-not $PSBoundParameters.ContainsKey('MaxNodes') -and $settings.max_nodes) { $script:MaxNodes = [int]$settings.max_nodes }
        if (-not $PSBoundParameters.ContainsKey('CapacityEndpoint') -and $settings.capacity_endpoint) { $script:CapacityEndpoint = [string]$settings.capacity_endpoint }
        if (-not $PSBoundParameters.ContainsKey('RedactReportIp') -and $settings.redact_report_ip -eq $true) { $script:RedactReportIp = $true }
    } catch {
        Write-Ui "settings.json 读取失败，将使用命令行或默认值：$($_.Exception.Message)" Yellow
    }
}

function Find-LocalConfig {
    if ($script:ConfigPath) { return }
    $configs = @(
        Get-ChildItem -LiteralPath $PSScriptRoot -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @(".yaml", ".yml") }
    )
    if ($configs.Count -eq 1) {
        $script:ConfigPath = $configs[0].FullName
        return
    }
    if ($configs.Count -gt 1) {
        throw "資料夾內找到多個 YAML/YML 配置。請把要測試的配置直接拖到 run_airport_tester.cmd 上。"
    }
}

# ---------- Mihomo runtime / API ----------
function Resolve-MihomoPath {
    if ($MihomoPath -and (Test-Path $MihomoPath)) { return (Resolve-Path $MihomoPath).Path }
    $bundled = Join-Path $PSScriptRoot "bin\mihomo.exe"
    if (Test-Path $bundled) { return $bundled }
    $command = Get-Command mihomo.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return ""
}

function Start-ConfigRuntime {
    param([string]$Path)
    if (-not $Path) { return }
    if (-not (Test-Path $Path)) { throw "配置文件不存在：$Path" }
    if ($NoLaunch) { return }
    $mihomo = Resolve-MihomoPath
    if (-not $mihomo) { throw "找不到 mihomo.exe。请先运行 setup_mihomo.cmd，或直接启动 FLClash 后不传配置文件。" }

    $script:RuntimeDir = Join-Path $env:TEMP ("lazyvps-airport-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $script:RuntimeDir | Out-Null
    $runtimeConfig = Join-Path $script:RuntimeDir "config.yaml"
    $runtimeSecret = "lazyvps-" + [guid]::NewGuid().ToString("N")
    $source = Get-Content -Path $Path -Encoding UTF8
    $filtered = $source | Where-Object { $_ -notmatch '^(mixed-port|external-controller|secret|allow-lan)\s*:' }
    $filtered | Set-Content -Path $runtimeConfig -Encoding UTF8
    Add-Content -Path $runtimeConfig -Encoding UTF8 -Value @(
        "",
        "mixed-port: 19080",
        "external-controller: 127.0.0.1:19090",
        "secret: `"$runtimeSecret`"",
        "allow-lan: false"
    )

    $script:Controller = "http://127.0.0.1:19090"
    $script:Proxy = "http://127.0.0.1:19080"
    $script:Secret = $runtimeSecret
    $stdout = Join-Path $script:RuntimeDir "mihomo.stdout.log"
    $stderr = Join-Path $script:RuntimeDir "mihomo.stderr.log"
    $script:RuntimeProcess = Start-Process -FilePath $mihomo -ArgumentList @("-d", $script:RuntimeDir, "-f", $runtimeConfig) -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
}

function Stop-ConfigRuntime {
    if ($script:RuntimeProcess -and -not $script:RuntimeProcess.HasExited) {
        Stop-Process -Id $script:RuntimeProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($script:RuntimeDir -and (Test-Path $script:RuntimeDir)) {
        Remove-Item $script:RuntimeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-MihomoApi {
    param([string]$Path, [string]$Method = "GET", [object]$Body = $null, [int]$TimeoutSec = 8)
    $uri = $script:Controller.TrimEnd('/') + $Path
    $request = [System.Net.HttpWebRequest]::Create($uri)
    $request.Method = $Method
    $request.Timeout = $TimeoutSec * 1000
    $request.ReadWriteTimeout = $TimeoutSec * 1000
    $request.Accept = "application/json"
    $request.UserAgent = "LazyVPS-Airport-Tester/$Version"
    if ($script:Secret) { $request.Headers["Authorization"] = "Bearer $($script:Secret)" }
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Compress
        $payload = $script:Utf8NoBom.GetBytes($json)
        $request.ContentType = "application/json; charset=utf-8"
        $request.ContentLength = $payload.Length
        $requestStream = $request.GetRequestStream()
        try { $requestStream.Write($payload, 0, $payload.Length) } finally { $requestStream.Dispose() }
    }
    $response = $request.GetResponse()
    try {
        if ($response.ContentLength -eq 0) { return $null }
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), $script:Utf8NoBom, $true)
        try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if (-not $content) { return $null }
        return $content | ConvertFrom-Json
    } finally {
        $response.Dispose()
    }
}

function Wait-Controller {
    for ($i = 0; $i -lt 30; $i++) {
        try { Invoke-MihomoApi -Path "/version" -TimeoutSec 2 | Out-Null; return $true } catch { Start-Sleep -Milliseconds 500 }
    }
    return $false
}

function Get-TestGroupAndNodes {
    $proxyData = Invoke-MihomoApi -Path "/proxies"
    $properties = @($proxyData.proxies.PSObject.Properties)
    $groups = @()
    foreach ($property in $properties) {
        $value = $property.Value
        if ($value.type -match 'Selector|URLTest|Fallback|LoadBalance' -and $value.all) {
            $groups += [pscustomobject]@{
                Name=(Repair-Mojibake $property.Name)
                Type=$value.type
                All=@($value.all | ForEach-Object { Repair-Mojibake $_ })
                Now=(Repair-Mojibake $value.now)
            }
        }
    }
    if (-not $groups) { throw "控制器没有返回可切换的代理组。" }

    $groupNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $groups) { [void]$groupNames.Add([string]$item.Name) }
    foreach ($item in $groups) {
        $directNodes = @($item.All | Where-Object { $_ -and -not $groupNames.Contains([string]$_) })
        $item | Add-Member -NotePropertyName DirectNodes -NotePropertyValue $directNodes
    }

    $selectedGroup = $null
    if ($script:Group) { $selectedGroup = $groups | Where-Object { $_.Name -eq $script:Group } | Select-Object -First 1 }
    if (-not $selectedGroup) {
        foreach ($preferred in @("PROXY", "GLOBAL", "世界", "节点选择", "代理", "Proxy")) {
            $selectedGroup = $groups | Where-Object { $_.Name -eq $preferred -and $_.DirectNodes.Count -gt 0 } | Select-Object -First 1
            if ($selectedGroup) { break }
        }
    }
    if (-not $selectedGroup) { $selectedGroup = $groups | Sort-Object @{Expression={$_.DirectNodes.Count};Descending=$true} | Select-Object -First 1 }
    if ($selectedGroup.DirectNodes.Count -eq 0) { throw "代理组 $($selectedGroup.Name) 只包含其他策略组，没有可直接切换的节点。请用 -Group 指定包含实体节点的组。" }

    $reserved = @("DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE")
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $nodes = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($selectedGroup.DirectNodes)) {
        if (-not $name -or $reserved -contains $name) { continue }
        if ($script:NodePattern -and $name -notmatch $script:NodePattern) { continue }
        if ($seen.Add([string]$name)) { $nodes.Add([string]$name) }
    }
    if ($script:MaxNodes -gt 0 -and $nodes.Count -gt $script:MaxNodes) {
        $limited = New-Object System.Collections.Generic.List[string]
        foreach ($node in @($nodes | Select-Object -First $script:MaxNodes)) { $limited.Add([string]$node) }
        $nodes = $limited
    }
    if ($nodes.Count -eq 0) { throw "代理组 $($selectedGroup.Name) 中没有可测试节点。" }
    $script:Group = $selectedGroup.Name
    return @{ Group=$selectedGroup; Nodes=$nodes.ToArray(); Groups=$groups }
}

function Set-ActiveNode {
    param([string]$Node)
    $start = Get-Date
    $status = "OK"; $message = ""
    try {
        $encoded = [uri]::EscapeDataString($script:Group)
        Invoke-MihomoApi -Path ("/proxies/" + $encoded) -Method "PUT" -Body @{name=$Node} | Out-Null
        Start-Sleep -Milliseconds 850
        $current = Invoke-MihomoApi -Path ("/proxies/" + $encoded)
        if ($current.now -ne $Node) { throw "控制器当前节点为 $($current.now)" }
    } catch {
        $status = "FAIL"; $message = $_.Exception.Message
    }
    $script:SwitchLog.Add([pscustomobject]@{Time=$start.ToString("s");Group=$script:Group;Node=$Node;Status=$status;Message=$message})
    return ($status -eq "OK")
}

function Get-ApiDelay {
    param([string]$Node)
    try {
        $encoded = [uri]::EscapeDataString($Node)
        $result = Invoke-MihomoApi -Path ("/proxies/$encoded/delay?timeout=7000&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204") -TimeoutSec 10
        return [double]$result.delay
    } catch { return $null }
}

# ---------- Curl / proxy tests ----------
function Get-CurlPath {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) { throw "找不到 Windows curl.exe。请使用 Windows 10/11，或把 curl.exe 加入 PATH。" }
    return $curl.Source
}

function Invoke-CurlMetric {
    param([string]$Url, [int]$TimeoutSec = 12, [switch]$NoProxy)
    $args = @("-sS", "-L", "--connect-timeout", "4", "--max-time", [string]$TimeoutSec, "-o", "NUL", "-w", "%{time_total}|%{http_code}|%{size_download}|%{speed_download}")
    if (-not $NoProxy) { $args = @("-x", $script:Proxy) + $args }
    $args += @("-A", "LazyVPS-Airport-Tester/1.0", $Url)
    try {
        $output = & (Get-CurlPath) @args 2>$null
        $parts = ([string]$output).Trim().Split('|')
        if ($parts.Count -lt 4) { throw "invalid curl output" }
        return [pscustomobject]@{ Seconds=[double]$parts[0]; Code=[int]$parts[1]; Bytes=[double]$parts[2]; BytesPerSecond=[double]$parts[3]; Ok=([int]$parts[1] -ge 200 -and [int]$parts[1] -lt 400) }
    } catch {
        return [pscustomobject]@{ Seconds=0.0; Code=0; Bytes=0.0; BytesPerSecond=0.0; Ok=$false }
    }
}

function Get-ExitTopology {
    param([string]$Node)
    $ip = ""; $country = ""; $region = ""; $city = ""; $asn = ""; $isp = ""
    try {
        $ip = (& (Get-CurlPath) -x $script:Proxy -sS -L --max-time 12 "https://api.ipify.org").Trim()
        $geoRaw = & (Get-CurlPath) -x $script:Proxy -sS -L --max-time 12 "https://ipinfo.io/json"
        $geo = ([string]$geoRaw) | ConvertFrom-Json
        $country = [string]$geo.country; $region = [string]$geo.region; $city = [string]$geo.city
        $org = [string]$geo.org
        if ($org -match '^(AS\d+)\s+(.*)$') { $asn = $Matches[1]; $isp = $Matches[2] } else { $isp = $org }
    } catch {}
    if ($ip -match '^198\.(1[89])\.') { $ip = "" }
    $match = if (-not $script:ExpectedExitIp) { "未设定" } elseif ($ip -eq $script:ExpectedExitIp) { "符合" } else { "不符合" }
    $row = [pscustomobject]@{
        Node=$Node;ExitIP=(Get-ReportIp $ip);Country=$country;Region=$region;City=$city;ASN=$asn;ISP=$isp
        ExpectedExitIP=(Get-ReportIp $script:ExpectedExitIp);ExpectedMatch=$match
        EntryIP="未采集";EntryIPNote="避免把 Clash Fake-IP 误判为入口IP"
    }
    $script:TopologyRows.Add($row)
    return $row
}

function Test-TlsHttps {
    param([string]$Node)
    $args = @(
        "-x", $script:Proxy, "-sS", "-L", "--connect-timeout", "4", "--max-time", "12",
        "-o", "NUL", "-w", "%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_total}|%{http_code}|%{ssl_verify_result}",
        "-A", "LazyVPS-TLS-Probe/1.0", "https://github.com/"
    )
    $dns = 0.0; $connect = 0.0; $tls = 0.0; $total = 0.0; $code = 0; $verify = -1; $status = "FAIL"
    try {
        $output = & (Get-CurlPath) @args 2>$null
        $parts = ([string]$output).Trim().Split('|')
        if ($parts.Count -lt 6) { throw "invalid TLS probe output" }
        $dns = [double]$parts[0] * 1000
        $connect = [double]$parts[1] * 1000
        $tls = [double]$parts[2] * 1000
        $total = [double]$parts[3] * 1000
        $code = [int]$parts[4]
        $verify = [int]$parts[5]
        if ($code -ge 200 -and $code -lt 400 -and $verify -eq 0) { $status = "OK" }
    } catch {}
    $row = [pscustomobject]@{
        Node=$Node;Target="https://github.com/";Status=$status;HttpCode=$code;SslVerifyResult=$verify
        DnsMs=[Math]::Round($dns,2);ConnectMs=[Math]::Round($connect,2);TlsReadyMs=[Math]::Round($tls,2);TotalMs=[Math]::Round($total,2)
    }
    $script:TlsRows.Add($row)
    return $row
}

function Test-HttpStability {
    param([string]$Node, [int]$Count)
    $values = New-Object System.Collections.Generic.List[double]
    $failures = 0
    for ($i = 1; $i -le $Count; $i++) {
        $metric = Invoke-CurlMetric -Url ("https://www.gstatic.com/generate_204?r=" + [guid]::NewGuid().ToString("N")) -TimeoutSec 8
        $ms = if ($metric.Seconds -gt 0) { [Math]::Round($metric.Seconds * 1000, 3) } else { 0 }
        if ($metric.Ok) { $values.Add($ms) } else { $failures++ }
        $script:StabilityRows.Add([pscustomobject]@{Node=$Node;Sample=$i;LatencyMs=$ms;HttpCode=$metric.Code;Status=($(if($metric.Ok){"OK"}else{"FAIL"}))})
    }
    $avg = if ($values.Count) { ($values | Measure-Object -Average).Average } else { $null }
    $p50 = Get-Percentile -Values $values.ToArray() -P 0.50
    $p95 = Get-Percentile -Values $values.ToArray() -P 0.95
    $jitter = $null
    if ($values.Count -gt 0) {
        $mean = [double]$avg; $sum = 0.0
        foreach ($value in $values) { $sum += [Math]::Pow($value - $mean, 2) }
        $jitter = [Math]::Sqrt($sum / $values.Count)
    }
    return [pscustomobject]@{
        AvgMs=$(if($null -eq $avg){$null}else{[Math]::Round($avg,2)})
        P50Ms=$(if($null -eq $p50){$null}else{[Math]::Round($p50,2)})
        P95Ms=$(if($null -eq $p95){$null}else{[Math]::Round($p95,2)})
        JitterMs=$(if($null -eq $jitter){$null}else{[Math]::Round($jitter,2)})
        LossPercent=[Math]::Round($failures / [Math]::Max(1,$Count) * 100,2)
    }
}

function Get-ActiveAdapterName {
    try {
        $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction Stop | Sort-Object RouteMetric,InterfaceMetric | Select-Object -First 1
        return (Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop).Name
    } catch { return "" }
}

function Get-AdapterBytes {
    param([string]$Adapter, [string]$Direction)
    if (-not $Adapter) { return $null }
    try {
        $stats = Get-NetAdapterStatistics -Name $Adapter -ErrorAction Stop
        if ($Direction -eq "down") { return [double]$stats.ReceivedBytes }
        return [double]$stats.SentBytes
    } catch { return $null }
}

function Start-CurlTransfer {
    param([string]$Direction, [int]$Seconds, [string]$OutputFile, [string]$ErrorFile, [string]$PayloadFile)
    $format = "%{size_download}|%{size_upload}|%{time_total}|%{http_code}|%{speed_download}|%{speed_upload}"
    $args = @("-x", $script:Proxy, "-sS", "-L", "--http1.1", "--connect-timeout", "4", "--max-time", [string]$Seconds, "-o", "NUL", "-w", $format, "-A", "LazyVPS-Capacity/1.0")
    if ($Direction -eq "down") {
        $args += ($script:CapacityEndpoint.TrimEnd('/') + "/__down?bytes=1000000000&r=" + [guid]::NewGuid().ToString("N"))
    } else {
        $args += @("-X", "POST", "-H", "Content-Type: application/octet-stream", "--data-binary", ("@" + $PayloadFile), ($script:CapacityEndpoint.TrimEnd('/') + "/__up?r=" + [guid]::NewGuid().ToString("N")))
    }
    return Start-Process -FilePath (Get-CurlPath) -ArgumentList $args -NoNewWindow -PassThru -RedirectStandardOutput $OutputFile -RedirectStandardError $ErrorFile
}

function Invoke-TransferPhase {
    param([string]$Node, [string]$Direction, [string]$Stage, [int]$Threads, [int]$Seconds, [string]$PayloadFile)
    $temp = Join-Path $env:TEMP ("lazyvps-phase-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $processes = @(); $outputs = @(); $adapter = Get-ActiveAdapterName
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Threads; $i++) {
        $out = Join-Path $temp ("$i.out"); $err = Join-Path $temp ("$i.err")
        $outputs += $out
        $processes += Start-CurlTransfer -Direction $Direction -Seconds $Seconds -OutputFile $out -ErrorFile $err -PayloadFile $PayloadFile
    }
    $samples = New-Object System.Collections.Generic.List[double]
    $lastTime = $stopwatch.Elapsed.TotalSeconds; $lastBytes = Get-AdapterBytes -Adapter $adapter -Direction $Direction
    while (@($processes | Where-Object { -not $_.HasExited }).Count -gt 0) {
        Start-Sleep -Milliseconds 250
        $nowTime = $stopwatch.Elapsed.TotalSeconds; $nowBytes = Get-AdapterBytes -Adapter $adapter -Direction $Direction
        if ($null -ne $lastBytes -and $null -ne $nowBytes -and $nowTime -gt $lastTime) {
            $mbps = [Math]::Max(0, ($nowBytes - $lastBytes) * 8 / ($nowTime - $lastTime) / 1000000)
            $samples.Add($mbps)
            $script:SpeedRows.Add([pscustomobject]@{Node=$Node;Direction=$Direction;Stage=$Stage;Sample=$samples.Count;ElapsedSeconds=[Math]::Round($nowTime,3);InstantMbps=[Math]::Round($mbps,3)})
        }
        $lastTime = $nowTime; $lastBytes = $nowBytes
    }
    foreach ($process in $processes) { $process.WaitForExit() }
    $stopwatch.Stop()

    $totalBytes = 0.0; $individualPeak = 0.0
    foreach ($out in $outputs) {
        if (-not (Test-Path $out)) { continue }
        $text = (Get-Content $out -Raw -ErrorAction SilentlyContinue).Trim()
        $parts = $text.Split('|')
        if ($parts.Count -lt 6) { continue }
        $bytes = if ($Direction -eq "down") { [double]$parts[0] } else { [double]$parts[1] }
        $elapsed = [double]$parts[2]
        $rate = if ($elapsed -gt 0) { $bytes * 8 / $elapsed / 1000000 } else { 0 }
        $totalBytes += $bytes
        if ($rate -gt $individualPeak) { $individualPeak = $rate }
    }
    $duration = [Math]::Max(0.001, $stopwatch.Elapsed.TotalSeconds)
    $average = $totalBytes * 8 / $duration / 1000000
    $peak = $individualPeak
    if ($samples.Count -gt 0) {
        $window = 4; $rolling = New-Object System.Collections.Generic.List[double]
        if ($samples.Count -lt $window) { $peak = ($samples | Measure-Object -Maximum).Maximum }
        else {
            for ($i = 0; $i -le $samples.Count - $window; $i++) {
                $sum = 0.0; for ($j = 0; $j -lt $window; $j++) { $sum += $samples[$i+$j] }
                $rolling.Add($sum / $window)
            }
            $peak = ($rolling | Measure-Object -Maximum).Maximum
        }
    }
    $peak = [Math]::Max($average, [double]$peak)
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{AverageMbps=[Math]::Round($average,2);PeakMbps=[Math]::Round($peak,2);Bytes=[Math]::Round($totalBytes);Seconds=[Math]::Round($duration,2);Threads=$Threads}
}

function Test-Capacity {
    param([string]$Node, [hashtable]$Profile)
    $payload = Join-Path $env:TEMP ("lazyvps-upload-" + [guid]::NewGuid().ToString("N") + ".bin")
    $stream = [System.IO.File]::Open($payload, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $stream.SetLength(32MB); $stream.Dispose()
    try {
        $singleDown = Invoke-TransferPhase -Node $Node -Direction "down" -Stage "single" -Threads 1 -Seconds $Profile.Seconds -PayloadFile $payload
        $multiDown = Invoke-TransferPhase -Node $Node -Direction "down" -Stage "multi" -Threads $Profile.Threads -Seconds $Profile.Seconds -PayloadFile $payload
        $singleUp = Invoke-TransferPhase -Node $Node -Direction "up" -Stage "single" -Threads 1 -Seconds $Profile.Seconds -PayloadFile $payload
        $multiUp = Invoke-TransferPhase -Node $Node -Direction "up" -Stage "multi" -Threads $Profile.Threads -Seconds $Profile.Seconds -PayloadFile $payload
    } finally { Remove-Item $payload -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{
        SingleDown=$singleDown.AverageMbps;MultiDown=$multiDown.AverageMbps;MaxDown=$multiDown.PeakMbps
        SingleUp=$singleUp.AverageMbps;MultiUp=$multiUp.AverageMbps;MaxUp=$multiUp.PeakMbps
        Threads=$Profile.Threads;DownMB=[Math]::Round(($singleDown.Bytes+$multiDown.Bytes)/1MB,2);UpMB=[Math]::Round(($singleUp.Bytes+$multiUp.Bytes)/1MB,2)
    }
}

function Get-ServiceCatalog {
    $all = @(
        @{Name="ChatGPT";Url="https://chatgpt.com/";Codes=@(200,301,302,307,308)},
        @{Name="OpenAI API";Url="https://api.openai.com/v1/models";Codes=@(200,401)},
        @{Name="Claude";Url="https://claude.ai/";Codes=@(200,301,302,307,308)},
        @{Name="Gemini";Url="https://gemini.google.com/";Codes=@(200,301,302,307,308)},
        @{Name="Perplexity";Url="https://www.perplexity.ai/";Codes=@(200,301,302)},
        @{Name="Copilot";Url="https://copilot.microsoft.com/";Codes=@(200,301,302)},
        @{Name="YouTube";Url="https://www.youtube.com/";Codes=@(200,301,302)},
        @{Name="Netflix";Url="https://www.netflix.com/title/80018499";Codes=@(200,301,302)},
        @{Name="Disney+";Url="https://www.disneyplus.com/";Codes=@(200,301,302)},
        @{Name="PrimeVideo";Url="https://www.primevideo.com/";Codes=@(200,301,302)},
        @{Name="HBO Max";Url="https://www.max.com/";Codes=@(200,301,302)},
        @{Name="DAZN";Url="https://www.dazn.com/";Codes=@(200,301,302)},
        @{Name="动画疯";Url="https://ani.gamer.com.tw/";Codes=@(200,301,302)},
        @{Name="Abema";Url="https://abema.tv/";Codes=@(200,301,302)},
        @{Name="TikTok";Url="https://www.tiktok.com/";Codes=@(200,301,302)},
        @{Name="Spotify";Url="https://open.spotify.com/";Codes=@(200,301,302)},
        @{Name="Steam";Url="https://store.steampowered.com/";Codes=@(200,301,302)},
        @{Name="IG音频";Url="https://www.instagram.com/";Codes=@(200,301,302)},
        @{Name="GitHub";Url="https://github.com/";Codes=@(200,301,302)},
        @{Name="Apple TV+";Url="https://tv.apple.com/";Codes=@(200,301,302)},
        @{Name="Twitch";Url="https://www.twitch.tv/";Codes=@(200,301,302)},
        @{Name="Crunchyroll";Url="https://www.crunchyroll.com/";Codes=@(200,301,302)},
        @{Name="BBC iPlayer";Url="https://www.bbc.co.uk/iplayer";Codes=@(200,301,302)},
        @{Name="Hulu";Url="https://www.hulu.com/";Codes=@(200,301,302)},
        @{Name="Peacock";Url="https://www.peacocktv.com/";Codes=@(200,301,302)},
        @{Name="BiliBiliIntl";Url="https://www.bilibili.tv/";Codes=@(200,301,302)}
    )
    return $all
}

function Test-Services {
    param([string]$Node, [string]$Level)
    $catalog = Get-ServiceCatalog
    if ($Level -eq "none") { return [pscustomobject]@{Success=0;Total=0} }
    if ($Level -eq "core") { $catalog = $catalog | Where-Object { $_.Name -in @("ChatGPT","OpenAI API","Claude","Gemini","YouTube","Netflix","GitHub") } }
    $success = 0
    foreach ($service in $catalog) {
        $metric = Invoke-CurlMetric -Url $service.Url -TimeoutSec 14
        $ok = $service.Codes -contains $metric.Code
        if ($ok) { $success++ }
        $script:ServiceRows.Add([pscustomobject]@{Node=$Node;Service=$service.Name;Status=($(if($ok){"解锁成功"}else{"解锁失败"}));HttpCode=$metric.Code;LatencyMs=[Math]::Round($metric.Seconds*1000,2);Url=$service.Url})
    }
    return [pscustomobject]@{Success=$success;Total=@($catalog).Count}
}

function Get-NodeScore {
    param($ApiDelay, $Stability, $Capacity, $Services, $Topology)
    $score = 0.0
    if ($null -ne $ApiDelay) { $score += [Math]::Max(0, 15 - [Math]::Max(0,$ApiDelay-40)*0.08) }
    if ($null -ne $Stability.AvgMs) { $score += [Math]::Max(0, 20 - [Math]::Max(0,$Stability.AvgMs-50)*0.06) }
    $score += [Math]::Max(0, 15 - $Stability.LossPercent*1.5 - [Math]::Max(0,$Stability.JitterMs-10)*0.15)
    if ($Capacity) {
        $score += [Math]::Min(20, $Capacity.MaxDown/500*20)
        $score += [Math]::Min(10, $Capacity.MaxUp/200*10)
    } else { $score += 15 }
    if ($Services.Total -gt 0) { $score += $Services.Success/$Services.Total*15 } else { $score += 8 }
    if (-not $script:ExpectedExitIp -or $Topology.ExpectedMatch -eq "符合") { $score += 5 }
    return [Math]::Round([Math]::Max(0,[Math]::Min(100,$score)),1)
}

# ---------- Reports ----------
function Write-SvgReport {
    param([object[]]$Results, [string]$Path)
    $rows = @($Results | Sort-Object Score -Descending)
    $displayRows = @($rows | Select-Object -First 100)
    $height = 470 + $displayRows.Count * 86
    $avgScore = if ($rows.Count) { [Math]::Round(($rows.Score | Measure-Object -Average).Average,1) } else { 0 }
    $top = if ($rows.Count) { $rows[0].Node } else { "--" }
    $matchCount = @($rows | Where-Object { $_.ExpectedMatch -eq "符合" }).Count
    $matchPct = if ($rows.Count -and $script:ExpectedExitIp) { [Math]::Round($matchCount/$rows.Count*100,1) } else { 0 }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"1400`" height=`"$height`" viewBox=`"0 0 1400 $height`">")
    [void]$sb.AppendLine("<defs><linearGradient id=`"bg`" x1=`"0`" y1=`"0`" x2=`"1`" y2=`"1`"><stop stop-color=`"#07111f`"/><stop offset=`"1`" stop-color=`"#151333`"/></linearGradient><linearGradient id=`"hero`"><stop stop-color=`"#22d3ee`"/><stop offset=`"1`" stop-color=`"#c084fc`"/></linearGradient><style>text{font-family:Inter,'Microsoft YaHei','PingFang SC',system-ui,sans-serif}.mono{font-family:Consolas,monospace}.small{fill:#94a3b8;font-size:14px}.label{fill:#8fa6c5;font-size:15px}.value{fill:#f8fafc;font-size:25px;font-weight:700}</style></defs>")
    [void]$sb.AppendLine("<rect width=`"1400`" height=`"$height`" rx=`"28`" fill=`"url(#bg)`"/>")
    [void]$sb.AppendLine("<rect x=`"42`" y=`"38`" width=`"8`" height=`"92`" rx=`"4`" fill=`"url(#hero)`"/>")
    [void]$sb.AppendLine("<text x=`"70`" y=`"78`" fill=`"#e6fbff`" font-size=`"36`" font-weight=`"800`">LAZYVPS AIRPORT FULL TESTER</text>")
    [void]$sb.AppendLine("<text x=`"70`" y=`"111`" fill=`"#8fa6c5`" font-size=`"18`">台北101 · 全节点容量 / 稳定性 / 解锁 / 出口身份报告</text>")
    [void]$sb.AppendLine("<text x=`"1350`" y=`"76`" text-anchor=`"end`" fill=`"#67e8f9`" font-size=`"18`">v$Version</text>")
    $cards = @(
        @{X=42;Label="NODES";Value=$rows.Count;Color="#22d3ee"},
        @{X=372;Label="AVG SCORE";Value=$avgScore;Color="#34d399"},
        @{X=702;Label="TOP NODE";Value=$top;Color="#fbbf24"},
        @{X=1032;Label="EXIT MATCH";Value=("{0}%" -f $matchPct);Color="#c084fc"}
    )
    foreach ($card in $cards) {
        [void]$sb.AppendLine("<rect x=`"$($card.X)`" y=`"154`" width=`"306`" height=`"108`" rx=`"18`" fill=`"#101d33`" stroke=`"#31425c`"/>")
        [void]$sb.AppendLine("<text x=`"$($card.X+20)`" y=`"188`" class=`"label`">$($card.Label)</text>")
        [void]$sb.AppendLine("<text x=`"$($card.X+20)`" y=`"235`" fill=`"$($card.Color)`" font-size=`"25`" font-weight=`"800`">$(Escape-Xml $card.Value)</text>")
    }
    [void]$sb.AppendLine("<rect x=`"42`" y=`"292`" width=`"1316`" height=`"64`" rx=`"14`" fill=`"#0b1628`" stroke=`"#263752`"/>")
    [void]$sb.AppendLine("<text x=`"66`" y=`"332`" class=`"small`">RANK</text><text x=`"130`" y=`"332`" class=`"small`">NODE</text><text x=`"505`" y=`"332`" class=`"small`">EXIT IP / ASN</text><text x=`"760`" y=`"332`" class=`"small`">DOWN S/N/MAX</text><text x=`"990`" y=`"332`" class=`"small`">UP S/N/MAX</text><text x=`"1195`" y=`"332`" class=`"small`">P95 / LOSS</text><text x=`"1320`" y=`"332`" text-anchor=`"end`" class=`"small`">SCORE</text>")
    $y = 374; $rank = 0
    foreach ($row in $displayRows) {
        $rank++
        $fill = if ($rank % 2) { "#101d33" } else { "#0d192c" }
        $scoreColor = if ($row.Score -ge 82) { "#34d399" } elseif ($row.Score -ge 66) { "#38bdf8" } elseif ($row.Score -ge 56) { "#fbbf24" } else { "#fb7185" }
        [void]$sb.AppendLine("<rect x=`"42`" y=`"$y`" width=`"1316`" height=`"72`" rx=`"14`" fill=`"$fill`" stroke=`"#263752`"/>")
        [void]$sb.AppendLine("<text x=`"76`" y=`"$($y+43)`" text-anchor=`"middle`" fill=`"#67e8f9`" font-size=`"20`" font-weight=`"700`">$rank</text>")
        [void]$sb.AppendLine("<text x=`"130`" y=`"$($y+31)`" fill=`"#f8fafc`" font-size=`"18`" font-weight=`"700`">$(Escape-Xml $row.Node)</text>")
        [void]$sb.AppendLine("<text x=`"130`" y=`"$($y+54)`" class=`"small`">API $($row.ApiDelayMs) ms · Unlock $($row.UnlockSuccess)/$($row.UnlockTotal)</text>")
        [void]$sb.AppendLine("<text x=`"505`" y=`"$($y+31)`" fill=`"#e2e8f0`" font-size=`"16`" class=`"mono`">$(Escape-Xml $row.ExitIP)</text><text x=`"505`" y=`"$($y+54)`" class=`"small`">$(Escape-Xml ($row.ASN + ' · ' + $row.Country))</text>")
        [void]$sb.AppendLine("<text x=`"760`" y=`"$($y+43)`" fill=`"#67e8f9`" font-size=`"16`" class=`"mono`">$($row.SingleDown) / $($row.MultiDown) / $($row.MaxDown)</text>")
        [void]$sb.AppendLine("<text x=`"990`" y=`"$($y+43)`" fill=`"#d8b4fe`" font-size=`"16`" class=`"mono`">$($row.SingleUp) / $($row.MultiUp) / $($row.MaxUp)</text>")
        [void]$sb.AppendLine("<text x=`"1195`" y=`"$($y+43)`" fill=`"#e2e8f0`" font-size=`"15`" class=`"mono`">$($row.HttpP95Ms) ms / $($row.HttpLossPercent)%</text>")
        [void]$sb.AppendLine("<text x=`"1320`" y=`"$($y+43)`" text-anchor=`"end`" fill=`"$scoreColor`" font-size=`"23`" font-weight=`"800`">$($row.Score) $($row.Grade)</text>")
        $y += 86
    }
    [void]$sb.AppendLine("<text x=`"42`" y=`"$($height-38)`" class=`"small`">容量单位 Mb/s；主表平台仅显示解锁成功/失败，HTTP Code 保存在 service_matrix.csv。配置密码不会写入报告。</text>")
    [void]$sb.AppendLine("</svg>")
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

function Write-HtmlReport {
    param([object[]]$Results, [string]$Path)
    $rows = @($Results | Sort-Object Score -Descending)
    $table = New-Object System.Text.StringBuilder
    foreach ($row in $rows) {
        [void]$table.AppendLine("<tr><td>$(Escape-Html $row.Rank)</td><td>$(Escape-Html $row.Node)</td><td>$(Escape-Html $row.ExitIP)</td><td>$($row.MaxDown)</td><td>$($row.MaxUp)</td><td>$($row.HttpP95Ms)</td><td>$($row.HttpLossPercent)%</td><td>$($row.UnlockSuccess)/$($row.UnlockTotal)</td><td>$($row.Score) $($row.Grade)</td></tr>")
    }
    $html = @"
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>LazyVPS Airport Report</title><style>body{margin:0;background:#07111f;color:#e2e8f0;font-family:Segoe UI,Microsoft YaHei,sans-serif}main{max-width:1400px;margin:auto;padding:24px}img{width:100%;height:auto;border-radius:20px}table{width:100%;border-collapse:collapse;margin-top:24px;background:#101d33}th,td{padding:11px;border-bottom:1px solid #263752;text-align:left}th{color:#67e8f9;position:sticky;top:0;background:#0b1628}.note{color:#94a3b8}</style></head><body><main><img src="report.svg" alt="机场测评 SVG"><p class="note">主表为汇总，平台明细、容量样本和切换日志请查看同目录 CSV。</p><table><thead><tr><th>#</th><th>节点</th><th>出口IP</th><th>Max Down</th><th>Max Up</th><th>HTTP P95</th><th>Loss</th><th>解锁</th><th>评分</th></tr></thead><tbody>$table</tbody></table></main></body></html>
"@
    [System.IO.File]::WriteAllText($Path, $html, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-SvgReportV2 {
    param([object[]]$Results, [string]$Path)
    $rows = @($Results | Sort-Object Score -Descending)
    $displayRows = @($rows | Select-Object -First 100)
    $height = 500 + $displayRows.Count * 104
    $avgScore = if ($rows.Count) { [Math]::Round(($rows.Score | Measure-Object -Average).Average,1) } else { 0 }
    $top = if ($rows.Count) { Limit-Text $rows[0].Node 30 } else { "--" }
    $matchCount = @($rows | Where-Object { $_.ExpectedMatch -eq "符合" }).Count
    $matchValue = if ($rows.Count -and $script:ExpectedExitIp) { "{0}%" -f [Math]::Round($matchCount/$rows.Count*100,1) } else { "N/A" }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"1920`" height=`"$height`" viewBox=`"0 0 1920 $height`" role=`"img`" aria-label=`"LazyVPS Airport Full Tester Report`">")
    [void]$sb.AppendLine('<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#050b18"/><stop offset="0.55" stop-color="#07172b"/><stop offset="1" stop-color="#160d2d"/></linearGradient><linearGradient id="neon"><stop stop-color="#22d3ee"/><stop offset="0.52" stop-color="#38bdf8"/><stop offset="1" stop-color="#c084fc"/></linearGradient><linearGradient id="card"><stop stop-color="#10223c"/><stop offset="1" stop-color="#0d1930"/></linearGradient><pattern id="grid" width="42" height="42" patternUnits="userSpaceOnUse"><path d="M42 0H0V42" fill="none" stroke="#1d4164" stroke-width="1" opacity=".22"/></pattern><filter id="glow"><feGaussianBlur stdDeviation="6" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter><style>text{font-family:"Microsoft JhengHei","Noto Sans CJK TC","Segoe UI Emoji",Arial,sans-serif}.mono{font-family:Consolas,"Cascadia Mono",monospace}.small{fill:#8ea8c7;font-size:15px}.label{fill:#8eaccd;font-size:16px;letter-spacing:1.4px}.value{fill:#f8fafc;font-size:29px;font-weight:800}.node{fill:#f8fafc;font-size:19px;font-weight:700}</style></defs>')
    [void]$sb.AppendLine("<rect width=`"1920`" height=`"$height`" rx=`"30`" fill=`"url(#bg)`"/><rect width=`"1920`" height=`"$height`" rx=`"30`" fill=`"url(#grid)`"/>")
    [void]$sb.AppendLine('<path d="M0 132 C420 34 690 196 1030 92 S1580 30 1920 122" fill="none" stroke="url(#neon)" stroke-width="2" opacity=".32"/><circle cx="1688" cy="86" r="120" fill="#7c3aed" opacity=".08"/>')
    [void]$sb.AppendLine('<rect x="44" y="40" width="9" height="96" rx="5" fill="url(#neon)" filter="url(#glow)"/><text x="78" y="82" fill="#ecfeff" font-size="38" font-weight="900" letter-spacing="1.2">LAZYVPS // AIRPORT FULL TESTER</text><text x="78" y="119" fill="#86b9d8" font-size="19">全節點容量 · 穩定性 · AI / 串流解鎖 · 出口身份 · TLS / HTTPS</text>')
    [void]$sb.AppendLine("<text x=`"1874`" y=`"78`" text-anchor=`"end`" fill=`"#67e8f9`" font-size=`"18`" font-weight=`"700`">REPORT ENGINE v$Version</text><text x=`"1874`" y=`"108`" text-anchor=`"end`" fill=`"#64748b`" font-size=`"14`">UTF-8 · SVG · XLSX · HTML</text>")
    $cards = @(
        @{X=44;Label="NODES";Value=$rows.Count;Color="#22d3ee"},
        @{X=508;Label="AVG SCORE";Value=$avgScore;Color="#34d399"},
        @{X=972;Label="TOP NODE";Value=$top;Color="#fbbf24"},
        @{X=1436;Label="EXIT MATCH";Value=$matchValue;Color="#c084fc"}
    )
    foreach ($card in $cards) {
        [void]$sb.AppendLine("<rect x=`"$($card.X)`" y=`"158`" width=`"440`" height=`"112`" rx=`"20`" fill=`"url(#card)`" stroke=`"#2d4d70`"/><path d=`"M$($card.X+18) 252 H$($card.X+422)`" stroke=`"$($card.Color)`" stroke-width=`"3`" opacity=`".6`"/>")
        [void]$sb.AppendLine("<text x=`"$($card.X+24)`" y=`"193`" class=`"label`">$($card.Label)</text><text x=`"$($card.X+24)`" y=`"239`" fill=`"$($card.Color)`" font-size=`"28`" font-weight=`"850`">$(Escape-Xml $card.Value)</text>")
    }
    [void]$sb.AppendLine('<rect x="44" y="300" width="1832" height="62" rx="16" fill="#081529" stroke="#2a4768"/><text x="78" y="338" class="label">RANK</text><text x="150" y="338" class="label">NODE / API / UNLOCK</text><text x="720" y="338" class="label">EXIT IP / ASN</text><text x="990" y="338" class="label">DOWN S / N / MAX</text><text x="1235" y="338" class="label">UP S / N / MAX</text><text x="1500" y="338" class="label">P95 / LOSS</text><text x="1830" y="338" text-anchor="end" class="label">SCORE</text>')
    $y = 384; $rank = 0
    foreach ($row in $displayRows) {
        $rank++
        $fill = if ($rank % 2) { "#0e1d34" } else { "#0b192d" }
        $scoreColor = if ($row.Score -ge 82) { "#34d399" } elseif ($row.Score -ge 66) { "#38bdf8" } elseif ($row.Score -ge 56) { "#fbbf24" } else { "#fb7185" }
        $nodeName = Limit-Text $row.Node 48
        $barWidth = [Math]::Round([Math]::Max(0,[Math]::Min(100,[double]$row.Score)) * 1.3)
        [void]$sb.AppendLine("<rect x=`"44`" y=`"$y`" width=`"1832`" height=`"86`" rx=`"18`" fill=`"$fill`" stroke=`"#243f60`"/><rect x=`"44`" y=`"$y`" width=`"5`" height=`"86`" rx=`"3`" fill=`"$scoreColor`"/>")
        [void]$sb.AppendLine("<text x=`"96`" y=`"$($y+52)`" text-anchor=`"middle`" fill=`"#67e8f9`" font-size=`"24`" font-weight=`"800`">$rank</text><text x=`"150`" y=`"$($y+34)`" class=`"node`">$(Escape-Xml $nodeName)</text><text x=`"150`" y=`"$($y+62)`" class=`"small`">API $($row.ApiDelayMs) ms  ·  Unlock $($row.UnlockSuccess)/$($row.UnlockTotal)  ·  TLS $($row.TlsHttpsMs) ms</text>")
        [void]$sb.AppendLine("<text x=`"720`" y=`"$($y+35)`" fill=`"#e2e8f0`" font-size=`"17`" class=`"mono`">$(Escape-Xml $row.ExitIP)</text><text x=`"720`" y=`"$($y+62)`" class=`"small`">$(Escape-Xml ($row.ASN + ' · ' + $row.Country))</text>")
        [void]$sb.AppendLine("<text x=`"990`" y=`"$($y+50)`" fill=`"#67e8f9`" font-size=`"17`" class=`"mono`">$($row.SingleDown) / $($row.MultiDown) / $($row.MaxDown)</text><text x=`"1235`" y=`"$($y+50)`" fill=`"#d8b4fe`" font-size=`"17`" class=`"mono`">$($row.SingleUp) / $($row.MultiUp) / $($row.MaxUp)</text>")
        [void]$sb.AppendLine("<text x=`"1500`" y=`"$($y+50)`" fill=`"#dbeafe`" font-size=`"16`" class=`"mono`">$($row.HttpP95Ms) ms / $($row.HttpLossPercent)%</text><rect x=`"1660`" y=`"$($y+58)`" width=`"130`" height=`"5`" rx=`"3`" fill=`"#24364f`"/><rect x=`"1660`" y=`"$($y+58)`" width=`"$barWidth`" height=`"5`" rx=`"3`" fill=`"$scoreColor`"/><text x=`"1830`" y=`"$($y+49)`" text-anchor=`"end`" fill=`"$scoreColor`" font-size=`"27`" font-weight=`"900`">$($row.Score)  $($row.Grade)</text>")
        $y += 104
    }
    [void]$sb.AppendLine("<text x=`"44`" y=`"$($height-42)`" class=`"small`">容量單位 Mb/s · 平台 HTTP 明細位於 service_matrix.csv / report.xlsx · 配置與 Controller Secret 不寫入報告</text><text x=`"1876`" y=`"$($height-42)`" text-anchor=`"end`" class=`"small`">Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</text></svg>")
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), $script:Utf8NoBom)
}

function Write-HtmlReportV2 {
    param([object[]]$Results, [string]$Path)
    $rows = @($Results | Sort-Object Score -Descending)
    $table = New-Object System.Text.StringBuilder
    foreach ($row in $rows) {
        [void]$table.AppendLine("<tr data-node=`"$(Escape-Html $row.Node)`"><td>$($row.Rank)</td><td class=`"node`">$(Escape-Html $row.Node)</td><td class=`"mono`">$(Escape-Html $row.ExitIP)</td><td>$($row.MaxDown)</td><td>$($row.MaxUp)</td><td>$($row.HttpP95Ms)</td><td>$($row.HttpLossPercent)%</td><td>$($row.UnlockSuccess)/$($row.UnlockTotal)</td><td><span class=`"grade`">$($row.Score) $($row.Grade)</span></td></tr>")
    }
    $html = @"
<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>LazyVPS Airport Full Tester</title><style>:root{color-scheme:dark;--bg:#050b18;--card:#0e1d34;--line:#29486b;--cyan:#22d3ee;--violet:#c084fc;--text:#e6f3ff;--muted:#8ea8c7}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 85% 0,#241043 0,transparent 30%),linear-gradient(145deg,#030812,#07172b 58%,#090818);color:var(--text);font-family:"Microsoft JhengHei","Segoe UI Emoji",system-ui,sans-serif}main{max-width:1920px;margin:auto;padding:28px}.hero{position:relative;height:min(42vw,520px);min-height:280px;border:1px solid var(--line);border-radius:28px;overflow:hidden;box-shadow:0 24px 80px #0009}.hero img{width:100%;height:100%;object-fit:cover}.hero:after{content:"";position:absolute;inset:0;background:linear-gradient(90deg,#030812e8 0,#07111f8c 43%,transparent 72%)}.hero-copy{position:absolute;z-index:2;left:5%;top:22%;max-width:680px}.eyebrow{color:var(--cyan);letter-spacing:.2em;font-weight:700}.hero h1{font-size:clamp(32px,4.5vw,72px);line-height:1;margin:.18em 0;background:linear-gradient(90deg,#fff,#67e8f9,#d8b4fe);-webkit-background-clip:text;color:transparent}.hero p{color:#b9cee4;font-size:clamp(15px,1.4vw,22px)}.report{margin-top:24px;width:100%;border-radius:24px;border:1px solid var(--line);background:#07111f}.toolbar{display:flex;gap:16px;align-items:center;justify-content:space-between;margin:28px 0 12px}.toolbar h2{margin:0}.toolbar input{min-width:320px;padding:13px 16px;border-radius:12px;border:1px solid var(--line);background:#081529;color:#fff;outline:none}.toolbar input:focus{border-color:var(--cyan);box-shadow:0 0 0 3px #22d3ee22}.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:20px;background:#081529}table{width:100%;border-collapse:collapse;min-width:1120px}th,td{padding:15px 14px;border-bottom:1px solid #1f3856;text-align:left;white-space:nowrap}th{position:sticky;top:0;background:#0b1a30;color:#8ec5e7;font-size:13px;letter-spacing:.08em}tbody tr:hover{background:#122944}.node{font-weight:700;color:#f8fafc;max-width:520px;overflow:hidden;text-overflow:ellipsis}.mono{font-family:Consolas,monospace}.grade{display:inline-block;padding:5px 10px;border-radius:999px;color:#07111f;background:linear-gradient(90deg,var(--cyan),var(--violet));font-weight:900}.note{color:var(--muted);line-height:1.7}.links{display:flex;gap:10px;flex-wrap:wrap}.pill{padding:7px 12px;border:1px solid var(--line);border-radius:999px;color:#a9c7e4;background:#0d1c31}@media(max-width:720px){main{padding:12px}.toolbar{display:block}.toolbar input{margin-top:12px;min-width:100%}.hero-copy{top:14%}}</style></head><body><main><section class="hero"><img src="cover.png" alt="科技網路測評封面"><div class="hero-copy"><div class="eyebrow">NETWORK INTELLIGENCE // v$Version</div><h1>AIRPORT<br>FULL TESTER</h1><p>全節點容量、延遲、丟失率、TLS、出口身份與 AI / 串流解鎖矩陣。</p><div class="links"><span class="pill">SVG</span><span class="pill">EXCEL</span><span class="pill">HTML</span><span class="pill">CSV</span></div></div></section><img class="report" src="report.svg" alt="全節點 SVG 排名"><div class="toolbar"><h2>全節點資料表</h2><input id="search" placeholder="搜尋節點名稱…" autocomplete="off"></div><div class="table-wrap"><table><thead><tr><th>#</th><th>節點</th><th>出口 IP</th><th>MAX DOWN</th><th>MAX UP</th><th>HTTP P95</th><th>LOSS</th><th>解鎖</th><th>評分</th></tr></thead><tbody id="rows">$table</tbody></table></div><p class="note">完整平台矩陣、速度採樣、穩定性時間序列、TLS 與路由切換記錄請查看同目錄的 report.xlsx 與 CSV。對外分享前可啟用 RedactReportIp。</p></main><script>const q=document.getElementById('search'),rows=[...document.querySelectorAll('#rows tr')];q.addEventListener('input',()=>{const s=q.value.toLowerCase();rows.forEach(r=>r.hidden=!r.dataset.node.toLowerCase().includes(s))});</script></body></html>
"@
    [System.IO.File]::WriteAllText($Path, $html, $script:Utf8NoBom)
}

function Save-AllReports {
    param([object[]]$Results, [hashtable]$RunInfo)
    $ranked = @($Results | Sort-Object Score -Descending)
    for ($i = 0; $i -lt $ranked.Count; $i++) { $ranked[$i].Rank = $i + 1 }
    Save-Csv -Rows $ranked -Path (Join-Path $script:OutDir "summary_ranking.csv")
    Save-Csv -Rows $script:ServiceRows.ToArray() -Path (Join-Path $script:OutDir "service_matrix.csv")
    Save-Csv -Rows $script:SpeedRows.ToArray() -Path (Join-Path $script:OutDir "speed_samples.csv")
    Save-Csv -Rows $script:StabilityRows.ToArray() -Path (Join-Path $script:OutDir "stability_timeseries.csv")
    Save-Csv -Rows $script:ApiDelayRows.ToArray() -Path (Join-Path $script:OutDir "api_delay.csv")
    Save-Csv -Rows $script:TopologyRows.ToArray() -Path (Join-Path $script:OutDir "topology_ip.csv")
    Save-Csv -Rows $script:TlsRows.ToArray() -Path (Join-Path $script:OutDir "tls_https_probe.csv")
    Save-Csv -Rows $script:SwitchLog.ToArray() -Path (Join-Path $script:OutDir "route_switch_log.csv")
    $RunInfo | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $script:OutDir "run_args.json") -Encoding UTF8
    $coverSource = Join-Path $PSScriptRoot "assets\airport-cyber-cover-v2.png"
    if (Test-Path $coverSource) { Copy-Item $coverSource (Join-Path $script:OutDir "cover.png") -Force }
    Write-SvgReportV2 -Results $ranked -Path (Join-Path $script:OutDir "report.svg")
    Write-HtmlReportV2 -Results $ranked -Path (Join-Path $script:OutDir "report.html")
    if (Get-Command Write-LazyVpsXlsx -ErrorAction SilentlyContinue) {
        $averageScore = if ($ranked.Count) { [Math]::Round(($ranked.Score | Measure-Object -Average).Average, 1) } else { 0 }
        $topNode = if ($ranked.Count) { $ranked[0].Node } else { "--" }
        $dashboard = @(
            [pscustomobject]@{Metric="Version";Value=$Version;Description="LazyVPS Airport Full Tester"},
            [pscustomobject]@{Metric="Mode";Value=$RunInfo.mode;Description="測試模式"},
            [pscustomobject]@{Metric="Nodes";Value=$ranked.Count;Description="實際完成節點數"},
            [pscustomobject]@{Metric="Average Score";Value=$averageScore;Description="全節點平均分"},
            [pscustomobject]@{Metric="Top Node";Value=$topNode;Description="本次最高分節點"},
            [pscustomobject]@{Metric="Generated";Value=(Get-Date -Format "yyyy-MM-dd HH:mm:ss");Description="報告產生時間"}
        )
        $sheets = [ordered]@{
            Dashboard=$dashboard
            Ranking=$ranked
            Services=$script:ServiceRows.ToArray()
            Speed=$script:SpeedRows.ToArray()
            Stability=$script:StabilityRows.ToArray()
            ApiDelay=$script:ApiDelayRows.ToArray()
            Topology=$script:TopologyRows.ToArray()
            TLS=$script:TlsRows.ToArray()
            SwitchLog=$script:SwitchLog.ToArray()
        }
        Write-LazyVpsXlsx -Sheets $sheets -Path (Join-Path $script:OutDir "report.xlsx")
    }
}

function Show-FinalDashboard {
    param([object[]]$Results)
    Show-Cover
    Write-Section "全节点最终排名"
    $ranked = @($Results | Sort-Object Score -Descending)
    Write-Ui ("{0,-4} {1,-34} {2,9} {3,9} {4,9} {5,9} {6,9}" -f "#","NODE","MAX-D","MAX-U","P95","LOSS","SCORE") Cyan
    $rank = 0
    foreach ($row in $ranked) {
        $rank++
        $color = if ($row.Score -ge 82) { "Green" } elseif ($row.Score -ge 66) { "Cyan" } elseif ($row.Score -ge 56) { "Yellow" } else { "Red" }
        $name = if ($row.Node.Length -gt 32) { $row.Node.Substring(0,31) + "…" } else { $row.Node }
        Write-Ui ("{0,-4} {1,-34} {2,9} {3,9} {4,9} {5,8}% {6,6} {7}" -f $rank,$name,$row.MaxDown,$row.MaxUp,$row.HttpP95Ms,$row.HttpLossPercent,$row.Score,$row.Grade) $color
    }
    Write-Section "输出文件"
    Write-Ui ("SVG 看板      : " + (Join-Path $script:OutDir "report.svg")) Green
    Write-Ui ("HTML 报告     : " + (Join-Path $script:OutDir "report.html")) Green
    Write-Ui ("Excel 工作簿  : " + (Join-Path $script:OutDir "report.xlsx")) Green
    Write-Ui ("排名总表      : " + (Join-Path $script:OutDir "summary_ranking.csv")) White
    Write-Ui ("平台矩阵      : " + (Join-Path $script:OutDir "service_matrix.csv")) White
    Write-Ui ("容量样本      : " + (Join-Path $script:OutDir "speed_samples.csv")) White
    Write-Ui ("稳定性时间序列: " + (Join-Path $script:OutDir "stability_timeseries.csv")) White
    Write-Ui ("TLS/HTTPS 探测 : " + (Join-Path $script:OutDir "tls_https_probe.csv")) White
}

function Invoke-RendererSelfTest {
    if (-not $OutDir) { $OutDir = Join-Path $env:TEMP ("airport-selftest-" + [guid]::NewGuid().ToString("N")) }
    $script:OutDir = [System.IO.Path]::GetFullPath($OutDir)
    New-Item -ItemType Directory -Force -Path $script:OutDir | Out-Null
    $expectedUtf8 = "🇹🇼 台灣-測試節點"
    $simulatedMojibake = [System.Text.Encoding]::GetEncoding(1252).GetString($script:Utf8NoBom.GetBytes($expectedUtf8))
    if ((Repair-Mojibake $simulatedMojibake) -ne $expectedUtf8) { throw "UTF-8 node name repair self-test failed." }
    $demo = @(
        [pscustomobject]@{Rank=0;Node="🇹🇼 台灣-示範節點-01";ExitIP="203.0.113.10";Country="TW";ASN="AS64500";ISP="Example Network";ExpectedMatch="未设定";ApiDelayMs=28;TlsHttpsMs=91;HttpAvgMs=86;HttpP50Ms=81;HttpP95Ms=121;HttpJitterMs=8.4;HttpLossPercent=0;SingleDown=286;MultiDown=632;MaxDown=718;SingleUp=118;MultiUp=221;MaxUp=249;CapacityThreads=4;DownTrafficMB=320;UpTrafficMB=96;UnlockSuccess=24;UnlockTotal=26;Score=92.4;Grade="A+";Status="完成"},
        [pscustomobject]@{Rank=0;Node="🇯🇵 日本-示範節點-02";ExitIP="203.0.113.22";Country="JP";ASN="AS64501";ISP="Example Network";ExpectedMatch="未设定";ApiDelayMs=43;TlsHttpsMs=112;HttpAvgMs=103;HttpP50Ms=96;HttpP95Ms=168;HttpJitterMs=13.1;HttpLossPercent=1.2;SingleDown=214;MultiDown=501;MaxDown=566;SingleUp=94;MultiUp=181;MaxUp=205;CapacityThreads=4;DownTrafficMB=260;UpTrafficMB=80;UnlockSuccess=21;UnlockTotal=26;Score=79.8;Grade="B+";Status="完成"}
    )
    $info = @{version=$Version;mode="self-test";node_count=2;generated_at=(Get-Date).ToString("s");secret_configured=$false}
    Save-AllReports -Results $demo -RunInfo $info
    [xml](Get-Content (Join-Path $script:OutDir "report.svg") -Raw -Encoding UTF8) | Out-Null
    Write-Ui ("Renderer self-test OK: " + $script:OutDir) Green
}

# ---------- Main ----------
try {
    Import-LocalSettings
    Find-LocalConfig
    Show-Cover
    if ($SelfTest) {
        Invoke-RendererSelfTest
        exit 0
    }
    if (-not $Mode) {
        $Mode = Select-Menu -DefaultIndex 1 -Items @(
            [pscustomobject]@{Key="1";Title="快速全节点";Description="核心平台 + 轻量容量 + 出口IP";Value="quick"},
            [pscustomobject]@{Key="2";Title="标准全功能";Description="容量、稳定性、26平台、出口身份（推荐）";Value="standard"},
            [pscustomobject]@{Key="3";Title="深度稳定性";Description="8线程容量 + 30次延迟采样 + 全平台";Value="deep"},
            [pscustomobject]@{Key="4";Title="容量优先";Description="单线/多线/最大上下行 + 延迟丢包";Value="capacity"},
            [pscustomobject]@{Key="5";Title="解锁矩阵";Description="AI、流媒体、开发者平台全量检查";Value="unlock"},
            [pscustomobject]@{Key="6";Title="连接诊断";Description="控制器、切换、出口、HTTPS快速检查";Value="diagnostic"},
            [pscustomobject]@{Key="0";Title="安全退出";Description="不执行测试";Value="exit"}
        )
    }
    if ($Mode -eq "exit") { exit 0 }
    $profile = Get-Profile $Mode

    if ($ConfigPath) { Start-ConfigRuntime -Path $ConfigPath }
    if (-not (Wait-Controller)) { throw "无法连接 Mihomo Controller：$Controller。请确认 external-controller、secret 与防火墙。" }
    Get-CurlPath | Out-Null
    $selection = Get-TestGroupAndNodes
    $nodes = @($selection.Nodes)

    if (-not $OutDir) { $OutDir = Join-Path (Get-Location) ("airport_test_" + (Get-Date -Format "yyyyMMdd_HHmmss")) }
    $script:OutDir = [System.IO.Path]::GetFullPath($OutDir)
    New-Item -ItemType Directory -Force -Path $script:OutDir | Out-Null
    $nodes | ForEach-Object { [pscustomobject]@{Group=$script:Group;Node=$_} } | Export-Csv -Path (Join-Path $script:OutDir "selected_nodes.csv") -NoTypeInformation -Encoding UTF8
    $groupMembership = foreach ($groupItem in @($selection.Groups)) {
        foreach ($member in @($groupItem.All)) {
            [pscustomobject]@{Group=$groupItem.Name;Type=$groupItem.Type;Current=$groupItem.Now;Member=$member;SelectedGroup=($groupItem.Name -eq $script:Group)}
        }
    }
    Save-Csv -Rows @($groupMembership) -Path (Join-Path $script:OutDir "group_membership.csv")

    Show-Cover
    Write-Section "运行参数"
    Write-Ui ("模式       : {0}" -f $Mode) White
    Write-Ui ("代理组     : {0}" -f $script:Group) White
    Write-Ui ("节点数     : {0}" -f $nodes.Count) White
    Write-Ui ("控制器     : {0}" -f $script:Controller) White
    Write-Ui ("本地代理   : {0}" -f $script:Proxy) White
    Write-Ui ("预期出口IP : {0}" -f $(if($script:ExpectedExitIp){$script:ExpectedExitIp}else{"未设定"})) White
    Write-Ui "同名节点默认不重复测试；配置密码不会写入输出。" Yellow
    Write-Host

    $results = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $nodes.Count; $index++) {
        $node = $nodes[$index]
        Show-ProgressLine -Current ($index + 1) -Total $nodes.Count -Node $node -Stage "切换节点"
        if (-not (Set-ActiveNode -Node $node)) {
            $results.Add([pscustomobject]@{Rank=0;Node=$node;ExitIP="";Country="";ASN="";ExpectedMatch="";ApiDelayMs="NA";TlsHttpsMs="NA";HttpAvgMs="NA";HttpP50Ms="NA";HttpP95Ms="NA";HttpJitterMs="NA";HttpLossPercent=100;SingleDown=0;MultiDown=0;MaxDown=0;SingleUp=0;MultiUp=0;MaxUp=0;UnlockSuccess=0;UnlockTotal=0;Score=0;Grade="D";Status="切换失败"})
            continue
        }

        Show-ProgressLine -Current ($index + 1) -Total $nodes.Count -Node $node -Stage "API延迟 / 出口IP"
        $apiDelay = Get-ApiDelay -Node $node
        $script:ApiDelayRows.Add([pscustomobject]@{Node=$node;DelayMs=$apiDelay;Status=($(if($null -ne $apiDelay){"OK"}else{"FAIL"}))})
        $topology = Get-ExitTopology -Node $node
        $tlsProbe = Test-TlsHttps -Node $node

        Show-ProgressLine -Current ($index + 1) -Total $nodes.Count -Node $node -Stage "HTTP稳定性"
        $stability = Test-HttpStability -Node $node -Count $profile.HttpSamples

        $capacity = $null
        if ($profile.Capacity) {
            Show-ProgressLine -Current ($index + 1) -Total $nodes.Count -Node $node -Stage "单线/多线/最大上下行"
            $capacity = Test-Capacity -Node $node -Profile $profile
        }

        Show-ProgressLine -Current ($index + 1) -Total $nodes.Count -Node $node -Stage "AI / 流媒体 / 开发者平台"
        $services = Test-Services -Node $node -Level $profile.Services
        $score = Get-NodeScore -ApiDelay $apiDelay -Stability $stability -Capacity $capacity -Services $services -Topology $topology
        if (-not $capacity) { $capacity = [pscustomobject]@{SingleDown=0;MultiDown=0;MaxDown=0;SingleUp=0;MultiUp=0;MaxUp=0;Threads=0;DownMB=0;UpMB=0} }
        $result = [pscustomobject]@{
            Rank=0;Node=$node;ExitIP=$topology.ExitIP;Country=$topology.Country;ASN=$topology.ASN;ISP=$topology.ISP;ExpectedMatch=$topology.ExpectedMatch
            ApiDelayMs=$(if($null -eq $apiDelay){"NA"}else{[Math]::Round($apiDelay,2)});TlsHttpsMs=$tlsProbe.TlsReadyMs
            HttpAvgMs=$stability.AvgMs;HttpP50Ms=$stability.P50Ms;HttpP95Ms=$stability.P95Ms;HttpJitterMs=$stability.JitterMs;HttpLossPercent=$stability.LossPercent
            SingleDown=$capacity.SingleDown;MultiDown=$capacity.MultiDown;MaxDown=$capacity.MaxDown;SingleUp=$capacity.SingleUp;MultiUp=$capacity.MultiUp;MaxUp=$capacity.MaxUp
            CapacityThreads=$capacity.Threads;DownTrafficMB=$capacity.DownMB;UpTrafficMB=$capacity.UpMB
            UnlockSuccess=$services.Success;UnlockTotal=$services.Total;Score=$score;Grade=(Get-Grade $score);Status="完成"
        }
        $results.Add($result)
        Save-Csv -Rows $results.ToArray() -Path (Join-Path $script:OutDir "summary_checkpoint.csv")
        Write-Host
        Write-Ui ("[$($index+1)/$($nodes.Count)] $node  Score $score  Max D/U $($capacity.MaxDown)/$($capacity.MaxUp) Mb/s  P95 $($stability.P95Ms) ms  Exit $($topology.ExitIP)") Green
    }

    $runInfo = @{
        version=$Version;mode=$Mode;started_at=(Get-Date).ToString("s");controller=$script:Controller;proxy=$script:Proxy
        group=$script:Group;node_count=$nodes.Count;expected_exit_ip=$(if($script:RedactReportIp -and $script:ExpectedExitIp){"REDACTED"}else{$script:ExpectedExitIp});node_pattern=$script:NodePattern
        capacity_endpoint=$script:CapacityEndpoint;threads=$profile.Threads;seconds=$profile.Seconds;http_samples=$profile.HttpSamples
        config_supplied=[bool]$ConfigPath;secret_configured=[bool]$script:Secret;report_ip_redacted=[bool]$script:RedactReportIp
    }
    Save-AllReports -Results $results.ToArray() -RunInfo $runInfo
    Show-FinalDashboard -Results $results.ToArray()
} catch {
    Write-Host
    Write-Ui ("[错误] " + $_.Exception.Message) Red
    if ($_.InvocationInfo.PositionMessage) { Write-Ui ("[位置] " + $_.InvocationInfo.PositionMessage.Trim()) Dim }
    Write-Ui "建议先运行 setup_mihomo.cmd，或确认 FLClash 的 External Controller / mixed-port / secret。" Yellow
    exit 1
} finally {
    Stop-ConfigRuntime
}
