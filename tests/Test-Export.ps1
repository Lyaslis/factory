$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot

Import-Module (Join-Path $root 'src\ContentFactory.Validation.psm1') -Force
Import-Module (Join-Path $root 'src\ContentFactory.Export.psm1') -Force
Import-Module (Join-Path $root 'src\ContentFactory.Repair.psm1') -Force

function Assert-CfExportTest {
    param([bool]$Condition, [string]$FailureMessage, [string]$SuccessMessage)
    if (-not $Condition) { throw $FailureMessage }
    Write-Host "OK  $SuccessMessage" -ForegroundColor Green
}

$fixturePath = Join-Path $root 'examples\production_package_v21_example.json'
$package = Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
$package.script.estimated_word_count = Get-CfWordCount -Text ([string]$package.script.full_text)
$null = Repair-CfPackageStructure -Package $package -TargetDurationSeconds 15 -MaxAiVideoScenes 2
$validation = Test-CfProductionPackage -Package $package -TargetDurationSeconds 15
if (-not $validation.is_valid) {
    throw "Тестовый пакет не прошёл валидатор: $($validation.errors -join '; ')"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ContentFactory_v21_export_test_' + [guid]::NewGuid().ToString('N'))
$mockResponse = [pscustomobject]@{
    done_reason = 'stop'
    prompt_eval_count = 123
    eval_count = 456
}

try {
    $projectDir = Save-CfProductionProject `
        -ProjectsRoot $tempRoot `
        -Package $package `
        -Validation $validation `
        -Model 'test-model' `
        -Topic 'Тест экспорта' `
        -Platform 'TikTok' `
        -TargetDurationSeconds 15 `
        -OllamaResponse $mockResponse `
        -ModelReportedWordCount 15

    $requiredExports = @(
        'production_package.json',
        'script.txt',
        'research_brief.json',
        'storyboard.json',
        'visual_prompts.json',
        'visual_style_guide.json',
        'continuity_guide.json',
        'asset_requirements.json',
        'editing_plan.json',
        'timeline.json',
        'human_review.txt',
        'validation_report.json',
        'run_info.json',
        'PROJECT_README.txt'
    )

    foreach ($name in $requiredExports) {
        $path = Join-Path $projectDir $name
        Assert-CfExportTest -Condition (Test-Path -LiteralPath $path -PathType Leaf) -FailureMessage "Экспорт не создан: $name" -SuccessMessage "Экспорт создан: $name"
    }

    $characterFolder = Join-Path $projectDir 'assets\characters'
    Assert-CfExportTest -Condition (Test-Path -LiteralPath $characterFolder -PathType Container) -FailureMessage 'Не создана папка assets/characters.' -SuccessMessage 'Создана папка assets/characters для identity references.'

    $timeline = Get-Content -LiteralPath (Join-Path $projectDir 'timeline.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
    $timelineScenes = @($timeline.scenes)
    $firstScene = $timelineScenes[0]
    $lastScene = $timelineScenes[$timelineScenes.Count - 1]
    Assert-CfExportTest -Condition ([double]$firstScene.start_seconds -eq 0) -FailureMessage 'Таймлайн начинается не с 0 секунд.' -SuccessMessage 'Таймлайн начинается с 0 секунд.'
    Assert-CfExportTest -Condition ([Math]::Abs([double]$lastScene.end_seconds - 15) -le 0.01) -FailureMessage 'Таймлайн не заканчивается на целевой отметке 15 секунд.' -SuccessMessage 'Таймлайн заканчивается ровно на 15 секундах.'

    $assets = Get-Content -LiteralPath (Join-Path $projectDir 'asset_requirements.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
    $videoAsset = @($assets.assets | Where-Object { $_.asset_type -eq 'ai_video' }) | Select-Object -First 1
    $videoOutputs = @($videoAsset.expected_outputs)
    Assert-CfExportTest -Condition ($videoOutputs -contains 'assets/images/scene_003_reference.png' -and $videoOutputs -contains 'assets/videos/scene_003.mp4') -FailureMessage 'Маршрут ai_video не содержит reference PNG и MP4.' -SuccessMessage 'Маршрут ai_video включает reference PNG и MP4.'

    $animatedAsset = @($assets.assets | Where-Object { $_.asset_type -eq 'image_animation' }) | Select-Object -First 1
    $animatedOutputs = @($animatedAsset.expected_outputs)
    Assert-CfExportTest -Condition ($animatedOutputs -contains 'assets/images/scene_002.png' -and $animatedOutputs -contains 'assets/videos/scene_002.mp4') -FailureMessage 'Маршрут image_animation не содержит PNG и MP4.' -SuccessMessage 'Маршрут image_animation включает PNG и MP4.'

    $characterReferences = @($assets.character_references)
    Assert-CfExportTest -Condition ($characterReferences.Count -ge 1 -and $characterReferences[0].reference_asset_path -eq 'assets/characters/person_main_reference.png') -FailureMessage 'Не экспортировано требование identity reference для повторяющегося персонажа.' -SuccessMessage 'asset_requirements.json содержит единый identity reference для повторяющегося персонажа.'

    $visualPrompts = Get-Content -LiteralPath (Join-Path $projectDir 'visual_prompts.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
    $sceneWithPerson = @($visualPrompts.scenes | Where-Object { $_.scene_id -eq 1 }) | Select-Object -First 1
    $sceneReferences = @($sceneWithPerson.continuity_reference_assets)
    Assert-CfExportTest -Condition (@($sceneReferences | Where-Object { $_.entity_id -eq 'person_main' -and $_.reference_asset_path -eq 'assets/characters/person_main_reference.png' }).Count -eq 1) -FailureMessage 'visual_prompts.json не передаёт персонажный reference asset в ComfyUI-сцену.' -SuccessMessage 'visual_prompts.json напрямую связывает сцену с identity reference PNG.'

    $runInfo = Get-Content -LiteralPath (Join-Path $projectDir 'run_info.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
    $versionFile = Join-Path $root 'VERSION.txt'
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
        throw 'Не найден VERSION.txt: невозможно проверить версию в run_info.json.'
    }
    $versionLine = [string](Get-Content -LiteralPath $versionFile -Encoding UTF8 | Select-Object -First 1)
    if ($versionLine -notmatch '^ContentFactory\s+(.+)$') {
        throw "VERSION.txt имеет неверный формат: '$versionLine'. Ожидается 'ContentFactory <version>'."
    }
    $expectedVersion = $Matches[1].Trim()
    $versionMatches = [string]$runInfo.contentfactory_version -eq $expectedVersion
    $wordCountMatches = [int]$runInfo.actual_word_count -eq 15
    Assert-CfExportTest -Condition ($versionMatches -and $wordCountMatches) -FailureMessage ("run_info.json содержит неверную версию или подсчёт слов. Ожидалась версия {0}, получена {1}; слов: {2}." -f $expectedVersion, $runInfo.contentfactory_version, $runInfo.actual_word_count) -SuccessMessage ("run_info.json содержит версию {0} из VERSION.txt и фактическую статистику." -f $expectedVersion)

    Write-Host 'Все тесты экспорта ContentFactory v2.2 пройдены.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
