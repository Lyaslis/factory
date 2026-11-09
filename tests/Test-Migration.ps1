$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\ContentFactory.Validation.psm1') -Force

function Assert-CfMigrationTest {
    param([bool]$Condition, [string]$FailureMessage, [string]$SuccessMessage)
    if (-not $Condition) { throw $FailureMessage }
    Write-Host "OK  $SuccessMessage" -ForegroundColor Green
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ContentFactory_v22_migration_test_' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $tempRoot
$inputPath = Join-Path $tempRoot 'legacy_v20.json'
$outputPath = Join-Path $tempRoot 'migrated_v22.json'
$fixturePath = Join-Path $root 'examples\legacy_package_v20_example.json'

try {
    Copy-Item -LiteralPath $fixturePath -Destination $inputPath
    & (Join-Path $root 'tools\Convert-LegacyPackage.ps1') -InputPackage $inputPath -OutputPackage $outputPath
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw 'Мигратор не создал выходной JSON.'
    }

    $migrated = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
    Assert-CfMigrationTest -Condition ($migrated.schema_version -eq '2.1') -FailureMessage 'Мигратор не сохранил schema_version=2.1 для совместимости.' -SuccessMessage 'Мигратор сохраняет schema_version=2.1 для совместимости со старыми пакетами.'
    Assert-CfMigrationTest -Condition ($migrated.human_review -is [array] -and $migrated.human_review.Count -ge 1) -FailureMessage 'Мигратор не сформировал human_review.' -SuccessMessage 'Мигратор создаёт список обязательной ручной проверки.'
    Assert-CfMigrationTest -Condition ($migrated.editing_plan.opening_ending_inside_scene_durations -eq $false) -FailureMessage 'Мигратор автоматически принял монтажный хронометраж.' -SuccessMessage 'Монтажный хронометраж остаётся неподтверждённым до ручной проверки.'
    Assert-CfMigrationTest -Condition ($migrated.visual_style.continuity_entities -is [array]) -FailureMessage 'Не создан continuity registry.' -SuccessMessage 'Создаётся массив continuity_entities.'

    Assert-CfMigrationTest -Condition ($migrated.scenes[0].video_prompt -eq '' -and $migrated.scenes[0].motion_prompt -eq '' -and $migrated.scenes[0].motion_target -eq '') -FailureMessage 'Маршрут generated_image мигрирован неверно.' -SuccessMessage 'generated_image очищен от лишних prompt-полей и motion_target.'
    Assert-CfMigrationTest -Condition ($migrated.scenes[1].asset_type -eq 'image_animation' -and $migrated.scenes[1].video_prompt -eq '' -and -not [string]::IsNullOrWhiteSpace($migrated.scenes[1].motion_prompt) -and $migrated.scenes[1].motion_target -eq 'shoe') -FailureMessage 'Старый image_animation или его motion_target мигрирован неверно.' -SuccessMessage 'Старый image_animation получает корректный motion_target.'
    Assert-CfMigrationTest -Condition ($migrated.scenes[2].asset_type -eq 'image_animation' -and $migrated.scenes[2].video_prompt -eq '' -and -not [string]::IsNullOrWhiteSpace($migrated.scenes[2].motion_prompt) -and $migrated.scenes[2].motion_target -eq 'product') -FailureMessage 'Камера-only ai_video не был безопасно переведён в image_animation.' -SuccessMessage 'Камера-only ai_video переведён в image_animation без выдумывания действия Wan.'

    $anchorsValid = $true
    foreach ($scene in @($migrated.scenes)) {
        if ($scene.visual_anchor_terms -isnot [array] -or $scene.visual_anchor_terms.Count -lt 2) { $anchorsValid = $false; continue }
        foreach ($anchor in @($scene.visual_anchor_terms)) {
            if ($scene.visual_purpose.IndexOf([string]$anchor, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -or
                $scene.image_prompt.IndexOf([string]$anchor, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                $anchorsValid = $false
            }
        }
    }
    Assert-CfMigrationTest -Condition $anchorsValid -FailureMessage 'Visual anchors не перенесены консервативно из image_prompt в visual_purpose.' -SuccessMessage 'Каждая мигрированная сцена получает 2+ якоря из исходного image_prompt.'

    $cameraConversionNoted = @($migrated.human_review | Where-Object { ([string]$_) -match 'camera-only|только движение камеры' }).Count -gt 0
    Assert-CfMigrationTest -Condition $cameraConversionNoted -FailureMessage 'Автоматическая смена camera-only маршрута не записана в human_review.' -SuccessMessage 'Смена camera-only маршрута явно записывается в human_review.'

    Assert-CfMigrationTest -Condition ($migrated.research_brief.factual_claims[0].claim_id -eq 'claim_01' -and $migrated.research_brief.factual_claims[0].used_in_script -eq $false -and $migrated.research_brief.factual_claims[0].script_excerpt -eq '') -FailureMessage 'Реестр фактов не мигрирован консервативно.' -SuccessMessage 'Реестр фактов переносится с точной, консервативной привязкой.'

    # Simulate an editor confirming the timing only; visual anchor checks remain enabled.
    $migrated.editing_plan.opening_ending_inside_scene_durations = $true
    $validation = Test-CfProductionPackage -Package $migrated -TargetDurationSeconds 15 -RequireVisualAnchors
    Assert-CfMigrationTest -Condition $validation.is_valid -FailureMessage "Мигрированный пакет не проходит строгие проверки v2.2: $($validation.errors -join '; ')" -SuccessMessage 'Мигрированный пакет проходит строгие проверки v2.2 после ручного подтверждения тайминга.'

    Write-Host 'Все тесты миграции ContentFactory v2.2 пройдены.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
