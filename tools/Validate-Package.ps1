[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PackageFile,
    [Parameter(Mandatory)][ValidateRange(15, 180)][int]$TargetDurationSeconds,
    [string]$ReportFile,
    [ValidateRange(0,20)][int]$MaxAiVideoScenes = 20,
    [switch]$RequireVisualAnchors
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\ContentFactory.Validation.psm1') -Force

if (-not (Test-Path -LiteralPath $PackageFile -PathType Leaf)) {
    throw "Файл пакета не найден: $PackageFile"
}
$resolvedPackage = (Resolve-Path -LiteralPath $PackageFile).Path
$package = Get-Content -LiteralPath $resolvedPackage -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
$actualWords = Get-CfWordCount -Text ([string]$package.script.full_text)
if ($null -ne $package.script) { $package.script.estimated_word_count = $actualWords }

$result = Test-CfProductionPackage -Package $package -TargetDurationSeconds $TargetDurationSeconds -MaxAiVideoScenes $MaxAiVideoScenes -RequireVisualAnchors:$RequireVisualAnchors
if ([string]::IsNullOrWhiteSpace($ReportFile)) {
    $directory = Split-Path -Parent $resolvedPackage
    $ReportFile = Join-Path $directory 'validation_report_manual.json'
}
$versionFile = Join-Path $root 'VERSION.txt'
$versionLine = 'unknown'
if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
    $firstVersionLine = Get-Content -LiteralPath $versionFile -Encoding UTF8 | Select-Object -First 1
    if ([string]$firstVersionLine -match '^ContentFactory\s+(.+)$') { $versionLine = [string]$Matches[1].Trim() }
}
$report = [ordered]@{
    contentfactory_version = $versionLine
    checked_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    package_file = $resolvedPackage
    is_valid = [bool]$result.is_valid
    errors = @($result.errors)
    warnings = @($result.warnings)
    checks = @($result.checks)
}
$report | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $ReportFile -Encoding UTF8

Write-Host "Отчёт: $ReportFile"
foreach ($errorItem in @($result.errors)) { Write-Host "ERROR  $errorItem" -ForegroundColor Red }
foreach ($warning in @($result.warnings)) { Write-Host "WARN   $warning" -ForegroundColor Yellow }
if ($result.is_valid) {
    Write-Host 'Пакет прошёл обязательные проверки.' -ForegroundColor Green
    exit 0
}
Write-Host 'Пакет не прошёл обязательные проверки.' -ForegroundColor Red
exit 2
