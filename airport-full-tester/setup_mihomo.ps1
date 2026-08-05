[CmdletBinding()]
param(
    [string]$Destination = "",
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path -Path $scriptRoot -ChildPath "bin"
}
$Destination = [System.IO.Path]::GetFullPath($Destination)

if ($SelfTest) {
    if ([string]::IsNullOrWhiteSpace($Destination)) { throw "Mihomo 安裝目錄解析失敗。" }
    if ((Split-Path -Leaf $Destination) -ne "bin") { throw "預設安裝目錄應以 bin 結尾：$Destination" }
    Write-Host "Mihomo setup path self-test OK: $Destination" -ForegroundColor Green
    return
}

Write-Host "LazyVPS Mihomo 官方核心安装器" -ForegroundColor Cyan
Write-Host "来源：MetaCubeX/mihomo GitHub Releases" -ForegroundColor DarkGray

if (-not [Environment]::Is64BitOperatingSystem) {
    throw "当前只支持 64 位 Windows。"
}

Write-Host "安裝目錄：$Destination" -ForegroundColor DarkGray
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" -Headers @{"User-Agent"="LazyVPS-Airport-Tester"}

$patterns = @(
    '^mihomo-windows-amd64-v3-.*\.zip$',
    '^mihomo-windows-amd64-compatible-.*\.zip$',
    '^mihomo-windows-amd64-.*\.zip$'
)
$asset = $null
foreach ($pattern in $patterns) {
    $asset = $release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if ($asset) { break }
}
if (-not $asset) { throw "最新 Release 中找不到 Windows AMD64 ZIP。" }

$zip = Join-Path $env:TEMP $asset.name
Write-Host "下载 $($asset.name)..." -ForegroundColor Yellow
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing

$extract = Join-Path $env:TEMP ("lazyvps-mihomo-" + [guid]::NewGuid().ToString("N"))
Expand-Archive -Path $zip -DestinationPath $extract -Force
$exe = Get-ChildItem -Path $extract -Recurse -Filter "mihomo*.exe" | Select-Object -First 1
if (-not $exe) { throw "压缩包内找不到 mihomo.exe。" }

$target = Join-Path $Destination "mihomo.exe"
Copy-Item $exe.FullName $target -Force
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue

& $target -v
Write-Host "安装完成：$target" -ForegroundColor Green
