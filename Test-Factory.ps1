[CmdletBinding()]
param(
    [switch]$CheckOllama,
    [switch]$RunTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = $PSScriptRoot

$requiredFiles = @(
    'factory.ps1',
    'VERSION.txt',
    'INSTALL_v2.2_RU.md',
    'PATCH_NOTES_v2.2_RU.md',
    'INSTALL_v2.2.5_RU.md',
    'PATCH_NOTES_v2.2.5_RU.md',
    'INSTALL_v2.2.4_RU.md',
    'PATCH_NOTES_v2.2.4_RU.md',
    'docs\DATA_CONTRACT_RU.md',
    'config\settings.json',
    'prompts\director_ru.txt',
    'schemas\production_package.schema.json',
    'src\ContentFactory.Ollama.psm1',
    'src\ContentFactory.Validation.psm1',
    'src\ContentFactory.Export.psm1',
    'src\ContentFactory.Repair.psm1',
    'tests\Test-Repair.ps1',
    'tests\Test-Validation.ps1',
    'tests\Test-Export.ps1',
    'tests\Test-Migration.ps1',
    'examples\legacy_package_v20_example.json',
    'tools\Validate-Package.ps1',
    'tools\Convert-LegacyPackage.ps1',
    'tools\Test-OptionalResponse.ps1',
    'examples\production_package_v21_example.json'
)

foreach ($relative in $requiredFiles) {
    $path = Join-Path $Root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Не найден файл: $relative"
    }
    Write-Host "OK  $relative" -ForegroundColor Green
}

# Parse every PowerShell source file before importing or executing project code.
# This catches syntax regressions with an exact file/line/column diagnostic.
$powerShellFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object {
    $_.Extension -in @('.ps1', '.psm1') -and $_.FullName -notmatch '[\\/](projects|.git)[\\/]'
})
$syntaxErrors = [System.Collections.Generic.List[string]]::new()
foreach ($powerShellFile in $powerShellFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $powerShellFile.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
        foreach ($parseError in $parseErrors) {
            $relativePath = [System.IO.Path]::GetRelativePath($Root, $powerShellFile.FullName)
            $syntaxErrors.Add(('{0}:{1}:{2}: {3}' -f $relativePath, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message))
        }
    }
}
if ($syntaxErrors.Count -gt 0) {
    throw ("Синтаксическая проверка PowerShell не пройдена:`n - " + ($syntaxErrors -join "`n - "))
}
Write-Host ("OK  Синтаксис PowerShell: {0} файлов прошли парсер." -f $powerShellFiles.Count) -ForegroundColor Green

$config = Get-Content -LiteralPath (Join-Path $Root 'config\settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($null -eq $config.production_profile) { throw 'В settings.json отсутствует production_profile v2.2.' }
if ([int]$config.production_profile.max_ai_video_scenes -ne 2) { throw 'Профиль v2.2 должен ограничивать Wan максимум двумя сценами по умолчанию.' }
if ($config.production_profile.require_visual_anchor_terms -ne $true) { throw 'Профиль v2.2 должен требовать visual_anchor_terms для новых генераций.' }
if ($config.ollama.thinking_mode -ne $false) { throw 'Для Gemma JSON production pipeline требуется ollama.thinking_mode=false.' }
if ($null -eq $config.planning) { throw 'В settings.json отсутствует раздел planning (этап рассуждений v2.3).' }
if ($config.planning.enabled -isnot [bool]) { throw 'planning.enabled должен быть boolean.' }
if ([int]$config.planning.context_tokens -lt ([int]$config.planning.max_output_tokens + 1500)) {
    throw 'planning.context_tokens должен быть минимум на 1500 больше planning.max_output_tokens: иначе Ollama молча сдвигает контекст и теряет начало промпта.'
}
if ([double]$config.production_profile.max_scene_words_per_second -gt 3) { throw 'Профиль речевого темпа не должен разрешать более 3 слов/с на сцену по умолчанию.' }
$versionText = Get-Content -LiteralPath (Join-Path $Root 'VERSION.txt') -Encoding UTF8 | Select-Object -First 1
if ($versionText -notmatch '^ContentFactory \d+\.\d+\.\d+$') { throw "VERSION.txt должен содержать семантическую версию ContentFactory, получено: $versionText" }
Write-Host ("OK  Профиль ресурсов и единый источник версии {0} проверены." -f $versionText) -ForegroundColor Green
$schema = Get-Content -LiteralPath (Join-Path $Root 'schemas\production_package.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($schema.type -ne 'object' -or $schema.additionalProperties -ne $false) {
    throw 'JSON Schema не прошла базовую проверку корневого объекта.'
}

Import-Module (Join-Path $Root 'src\ContentFactory.Ollama.psm1') -Force
Import-Module (Join-Path $Root 'src\ContentFactory.Validation.psm1') -Force
Import-Module (Join-Path $Root 'src\ContentFactory.Export.psm1') -Force
Import-Module (Join-Path $Root 'src\ContentFactory.Repair.psm1') -Force
if (-not (Get-Command Invoke-CfOllamaVisualSceneRepair -ErrorAction SilentlyContinue)) { throw 'В ContentFactory.Ollama.psm1 отсутствует Invoke-CfOllamaVisualSceneRepair.' }
if (-not (Get-Command Get-CfrVisualSceneRepairCandidates -ErrorAction SilentlyContinue)) { throw 'В ContentFactory.Repair.psm1 отсутствует Get-CfrVisualSceneRepairCandidates.' }
if (-not (Get-Command Set-CfrVisualSceneRepairs -ErrorAction SilentlyContinue)) { throw 'В ContentFactory.Repair.psm1 отсутствует Set-CfrVisualSceneRepairs.' }
if (-not (Get-Command Invoke-CfOllamaPlan -ErrorAction SilentlyContinue)) { throw 'В ContentFactory.Ollama.psm1 отсутствует Invoke-CfOllamaPlan.' }
if (-not (Get-Command Invoke-CfOllamaUnload -ErrorAction SilentlyContinue)) { throw 'В ContentFactory.Ollama.psm1 отсутствует Invoke-CfOllamaUnload.' }
if (-not (Get-Command Remove-CfHumanReviewNotes -ErrorAction SilentlyContinue)) { throw 'В ContentFactory.Repair.psm1 отсутствует Remove-CfHumanReviewNotes.' }
$wordCount = Get-CfWordCount -Text 'Проверка слов: AI-видео, 2 сцены.'
if ($wordCount -ne 5) { throw "Get-CfWordCount вернул неверное значение: $wordCount." }
Write-Host 'OK  JSON читается, модули импортируются, счётчик слов работает.' -ForegroundColor Green

if ($RunTests) {
    Write-Host "`nЗапускаю тесты валидатора..." -ForegroundColor Cyan
    & (Join-Path $Root 'tests\Test-Validation.ps1')
    Write-Host "`nЗапускаю интеграционные тесты экспорта..." -ForegroundColor Cyan
    & (Join-Path $Root 'tests\Test-Export.ps1')
    Write-Host "`nЗапускаю тесты миграции старого пакета..." -ForegroundColor Cyan
    & (Join-Path $Root 'tests\Test-Migration.ps1')
    Write-Host "`nЗапускаю тесты нормализации производственного пакета..." -ForegroundColor Cyan
    & (Join-Path $Root 'tests\Test-Repair.ps1')
    Write-Host "`nПроверяю необязательные поля ответа Ollama..." -ForegroundColor Cyan
    & (Join-Path $Root 'tools\Test-OptionalResponse.ps1')
}

if ($CheckOllama) {
    $models = @(Get-CfOllamaModels -BaseUrl ([string]$config.ollama.base_url))
    Write-Host "OK  Ollama отвечает. Установленные модели: $($models -join ', ')" -ForegroundColor Green
    if (($models -notcontains [string]$config.ollama.model) -and ($models -notcontains "$($config.ollama.model):latest")) {
        Write-Warning "Модель по умолчанию $($config.ollama.model) не найдена. Установи её командой: ollama pull $($config.ollama.model)"
    }
}
else {
    Write-Host 'Ollama не проверялась. Для проверки добавь ключ -CheckOllama.' -ForegroundColor Yellow
}

$versionLine = Get-Content -LiteralPath (Join-Path $Root 'VERSION.txt') -Encoding UTF8 | Select-Object -First 1
Write-Host "`nПроверка $versionLine завершена." -ForegroundColor Green
