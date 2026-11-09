[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$InputPackage,
    [string]$OutputPackage
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-CfMigrationProperty {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Name, [AllowNull()][object]$DefaultValue = $null)
    if ($null -eq $InputObject) { return $DefaultValue }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function Set-CfMigrationProperty {
    param([Parameter(Mandatory)][object]$InputObject, [Parameter(Mandatory)][string]$Name, [AllowNull()][object]$Value)
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $property.Value = $Value
    }
}

function Get-CfLegacyVisualAnchors {
    param([string]$ImagePrompt)
    $text = [string]$ImagePrompt
    $candidates = @(
        'product', 'workbench', 'table', 'shoe', 'wallet', 'coin', 'cup', 'bottle',
        'book', 'phone', 'car', 'face', 'hands', 'brain', 'package', 'box', 'close-up',
        'desk', 'chair', 'window', 'room', 'screen', 'bill', 'paper', 'tree', 'building',
        'street', 'bus', 'train', 'food', 'bread', 'man', 'woman', 'person', 'object', 'fire'
    )
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        if ($text.IndexOf($candidate, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $overlaps = $false
        foreach ($existing in $found) {
            if ($existing.IndexOf($candidate, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $candidate.IndexOf($existing, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $overlaps = $true
                break
            }
        }
        if (-not $overlaps) { $found.Add($candidate) }
        if ($found.Count -ge 2) { break }
    }
    return @($found.ToArray())
}

function Get-CfLegacyMotionTarget {
    param([string]$ImagePrompt, [string]$MotionPrompt)
    $image = [string]$ImagePrompt
    $motion = [string]$MotionPrompt
    $candidates = @('product', 'shoe', 'wallet', 'coin', 'cup', 'bottle', 'book', 'phone', 'car', 'table', 'workbench', 'desk', 'face', 'hands', 'brain', 'package', 'box', 'person', 'man', 'woman', 'object', 'fire')
    foreach ($candidate in $candidates) {
        if ($image.IndexOf($candidate, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            $motion.IndexOf($candidate, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $candidate
        }
    }
    return ''
}

function Test-CfLegacyCameraOnlyPrompt {
    param([string]$Prompt)
    $text = [string]$Prompt
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    $hasCameraMove = $text -match '(?i)\b(?:(?:slow|smooth|gentle|gradual)\s+)?(?:camera\s+)?(?:push[- ]?in|pull[- ]?back|zoom(?:\s+(?:in|out))?|pan(?:\s+(?:left|right|up|down))?|dolly(?:\s+(?:in|out))?|tracking\s+shot|track(?:ing)?|tilt(?:ing)?|orbit(?:ing)?)\b'
    $hasSubjectAction = $text -match '(?i)\b(?:man|woman|person|subject|product|shoe|wallet|coin|cup|bottle|book|phone|car|face|hands|brain|package|box|object|fire)\b.{0,45}\b(?:turns?|moves?|nods?|walks?|falls?|flows?|flickers?|shifts?|opens?|closes?|rises?|descends?|looks?|reaches?|lifts?|burns?|sways?|shakes?|rotates?)\b'
    return ($hasCameraMove -and -not $hasSubjectAction)
}

if (-not (Test-Path -LiteralPath $InputPackage -PathType Leaf)) {
    throw "Файл старого пакета не найден: $InputPackage"
}
$sourcePath = (Resolve-Path -LiteralPath $InputPackage).Path
$package = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100

if ($null -eq $package -or
    $null -eq $package.PSObject.Properties['project'] -or $null -eq $package.project -or
    $null -eq $package.PSObject.Properties['script'] -or $null -eq $package.script -or
    $null -eq $package.PSObject.Properties['visual_style'] -or $null -eq $package.visual_style -or
    $null -eq $package.PSObject.Properties['scenes'] -or $null -eq $package.scenes -or
    $null -eq $package.PSObject.Properties['editing_plan'] -or $null -eq $package.editing_plan) {
    throw 'Legacy-пакет неполный: требуются непустые project, script, visual_style, scenes и editing_plan.'
}

$review = [System.Collections.Generic.List[string]]::new()
Set-CfMigrationProperty -InputObject $package -Name 'schema_version' -Value '2.1'

if ($null -eq $package.PSObject.Properties['research_brief'] -or $null -eq $package.research_brief) {
    Set-CfMigrationProperty -InputObject $package -Name 'research_brief' -Value ([pscustomobject]@{})
}
foreach ($arrayName in @('factual_claims', 'source_material_used', 'missing_information', 'key_points')) {
    $arrayProperty = $package.research_brief.PSObject.Properties[$arrayName]
    if ($null -eq $arrayProperty) {
        Set-CfMigrationProperty -InputObject $package.research_brief -Name $arrayName -Value ([object[]]@())
    }
    elseif ($null -eq $arrayProperty.Value -or $arrayProperty.Value -isnot [array]) {
        Set-CfMigrationProperty -InputObject $package.research_brief -Name $arrayName -Value ([object[]]@())
        $review.Add("Legacy migration: research_brief.$arrayName отсутствовал или не был массивом; создан пустой массив. Проверь вручную.")
    }
}

$entityProperty = $package.visual_style.PSObject.Properties['continuity_entities']
if ($null -eq $entityProperty) {
    Set-CfMigrationProperty -InputObject $package.visual_style -Name 'continuity_entities' -Value ([object[]]@())
    $review.Add('Legacy migration: проверь повторяющихся персонажей/объекты и заполни visual_style.continuity_entities и scenes[].continuity_entity_ids.')
}
elseif ($null -eq $entityProperty.Value -or $entityProperty.Value -isnot [array]) {
    Set-CfMigrationProperty -InputObject $package.visual_style -Name 'continuity_entities' -Value ([object[]]@())
    $review.Add('Legacy migration: continuity_entities было null/не массивом; создан пустой реестр. Заполни повторяющиеся сущности вручную.')
}

$fullText = [string](Get-CfMigrationProperty -InputObject $package.script -Name 'full_text' -DefaultValue '')
$index = 0
foreach ($claim in @($package.research_brief.factual_claims)) {
    if ($null -eq $claim) {
        $review.Add('Legacy migration: найден null в factual_claims; этот элемент пропущен, проверь исходный реестр.')
        continue
    }
    $index++
    if ($null -eq $claim.PSObject.Properties['claim_id']) { Set-CfMigrationProperty -InputObject $claim -Name 'claim_id' -Value ('claim_{0:D2}' -f $index) }
    elseif ([string]::IsNullOrWhiteSpace([string]$claim.claim_id)) { $claim.claim_id = ('claim_{0:D2}' -f $index) }
    if ($null -eq $claim.PSObject.Properties['claim_type']) { Set-CfMigrationProperty -InputObject $claim -Name 'claim_type' -Value 'other' }
    elseif ([string]::IsNullOrWhiteSpace([string]$claim.claim_type)) { $claim.claim_type = 'other' }

    $claimText = [string](Get-CfMigrationProperty -InputObject $claim -Name 'claim' -DefaultValue '')
    $used = (-not [string]::IsNullOrWhiteSpace($claimText) -and $fullText.IndexOf($claimText, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    Set-CfMigrationProperty -InputObject $claim -Name 'used_in_script' -Value ([bool]$used)
    Set-CfMigrationProperty -InputObject $claim -Name 'script_excerpt' -Value $(if ($used) { $claimText } else { '' })
    if ($null -eq $claim.PSObject.Properties['verification_note'] -or [string]::IsNullOrWhiteSpace([string]$claim.verification_note)) {
        Set-CfMigrationProperty -InputObject $claim -Name 'verification_note' -Value 'Перенесено из старой версии; требуется ручная проверка источника и соответствия сценарию.'
    }
}
$review.Add('Legacy migration: реестр factual_claims создан автоматически только для точных совпадений с текстом. Проверь каждое утверждение вручную.')

if ($package.scenes -isnot [array] -or $package.scenes.Count -eq 0) {
    throw 'Legacy-пакет scenes должен быть непустым массивом объектов.'
}
foreach ($scene in @($package.scenes)) {
    if ($null -eq $scene) {
        $review.Add('Legacy migration: в scenes найден null; удалите пустую сцену вручную.')
        continue
    }

    $sceneId = Get-CfMigrationProperty -InputObject $scene -Name 'scene_id' -DefaultValue '?'
    $assetType = [string](Get-CfMigrationProperty -InputObject $scene -Name 'asset_type' -DefaultValue '')
    $imagePrompt = [string](Get-CfMigrationProperty -InputObject $scene -Name 'image_prompt' -DefaultValue '')
    $videoPrompt = [string](Get-CfMigrationProperty -InputObject $scene -Name 'video_prompt' -DefaultValue '')
    $motionPrompt = [string](Get-CfMigrationProperty -InputObject $scene -Name 'motion_prompt' -DefaultValue '')
    $visualPurpose = [string](Get-CfMigrationProperty -InputObject $scene -Name 'visual_purpose' -DefaultValue '')

    $sceneEntityProperty = $scene.PSObject.Properties['continuity_entity_ids']
    if ($null -eq $sceneEntityProperty -or $null -eq $sceneEntityProperty.Value -or $sceneEntityProperty.Value -isnot [array]) {
        Set-CfMigrationProperty -InputObject $scene -Name 'continuity_entity_ids' -Value ([object[]]@())
        $review.Add("Legacy migration: continuity_entity_ids сцены ${sceneId} нормализован в массив; проверь персонажей/объекты.")
    }

    # v2.2 needs explicit visual anchors. Extract only terms that are already present
    # in the legacy image prompt; append them to the visual purpose for traceability.
    $anchors = @(Get-CfLegacyVisualAnchors -ImagePrompt $imagePrompt)
    if ($anchors.Count -lt 2) {
        $review.Add("Legacy migration: сцена ${sceneId} не имеет двух надёжных визуальных якорей. Добавь их вручную в visual_anchor_terms.")
    }
    if ($anchors.Count -gt 0) {
        $missingFromPurpose = @($anchors | Where-Object { $visualPurpose.IndexOf([string]$_, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 })
        if ($missingFromPurpose.Count -gt 0) {
            if ([string]::IsNullOrWhiteSpace($visualPurpose)) { $visualPurpose = 'Legacy visual intent.' }
            $visualPurpose = $visualPurpose.TrimEnd() + ' Visible elements: ' + ($anchors -join '; ') + '.'
            Set-CfMigrationProperty -InputObject $scene -Name 'visual_purpose' -Value $visualPurpose
            $review.Add("Legacy migration: visual_purpose сцены ${sceneId} дополнен извлечёнными из image_prompt якорями ($($anchors -join ', ')); проверь смысловое соответствие.")
        }
    }
    Set-CfMigrationProperty -InputObject $scene -Name 'visual_anchor_terms' -Value ([string[]]$anchors)
    Set-CfMigrationProperty -InputObject $scene -Name 'motion_target' -Value ''

    switch ($assetType) {
        'generated_image' {
            Set-CfMigrationProperty -InputObject $scene -Name 'video_prompt' -Value ''
            Set-CfMigrationProperty -InputObject $scene -Name 'motion_prompt' -Value ''
        }
        'image_animation' {
            Set-CfMigrationProperty -InputObject $scene -Name 'video_prompt' -Value ''
            $target = Get-CfLegacyMotionTarget -ImagePrompt $imagePrompt -MotionPrompt $motionPrompt
            if (-not [string]::IsNullOrWhiteSpace($target)) {
                Set-CfMigrationProperty -InputObject $scene -Name 'motion_target' -Value $target
            }
            else {
                # Do not invent a target. A still image is safer than a camera move
                # whose focal object cannot be identified from both legacy fields.
                Set-CfMigrationProperty -InputObject $scene -Name 'asset_type' -Value 'generated_image'
                Set-CfMigrationProperty -InputObject $scene -Name 'motion_prompt' -Value ''
                $review.Add("Legacy migration: сцена ${sceneId} переведена в generated_image: нельзя надёжно определить motion_target из image_prompt и motion_prompt.")
            }
        }
        'ai_video' {
            if (Test-CfLegacyCameraOnlyPrompt -Prompt $videoPrompt) {
                $target = Get-CfLegacyMotionTarget -ImagePrompt $imagePrompt -MotionPrompt $videoPrompt
                if (-not [string]::IsNullOrWhiteSpace($target)) {
                    Set-CfMigrationProperty -InputObject $scene -Name 'asset_type' -Value 'image_animation'
                    Set-CfMigrationProperty -InputObject $scene -Name 'motion_prompt' -Value $videoPrompt
                    Set-CfMigrationProperty -InputObject $scene -Name 'video_prompt' -Value ''
                    Set-CfMigrationProperty -InputObject $scene -Name 'motion_target' -Value $target
                    $review.Add("Legacy migration: сцена ${sceneId} переведена из ai_video в image_animation: старый video_prompt описывал только движение камеры, а не самостоятельное действие объекта. Проверь motion_target '$target'.")
                }
                else {
                    Set-CfMigrationProperty -InputObject $scene -Name 'motion_prompt' -Value ''
                    $review.Add("Legacy migration: сцена ${sceneId} содержит только движение камеры, но motion_target не удалось извлечь. Маршрут ai_video оставлен для ручной переработки; добавь простое действие объекта в video_prompt или уточни image_prompt.")
                }
            }
            else {
                Set-CfMigrationProperty -InputObject $scene -Name 'motion_prompt' -Value ''
                if ($videoPrompt -match '(?i)\b(turns?|moves?|nods?|walks?|falls?|flows?|flickers?|shifts?|opens?|closes?|rises?|descends?|looks?|reaches?|lifts?)\b') {
                    foreach ($anchor in $anchors) {
                        if ($videoPrompt.IndexOf([string]$anchor, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                            $videoPrompt = $videoPrompt.TrimEnd() + ' Visible subject: ' + [string]$anchor + '.'
                        }
                    }
                    Set-CfMigrationProperty -InputObject $scene -Name 'video_prompt' -Value $videoPrompt
                }
                else {
                    $review.Add("Legacy migration: сцена ${sceneId} оставлена как ai_video, но video_prompt не содержит однозначного действия из поддерживаемого списка. Проверь и перепиши video_prompt вручную.")
                }
            }
        }
        'motion_graphic' {
            Set-CfMigrationProperty -InputObject $scene -Name 'video_prompt' -Value ''
        }
        'stock_or_archive' {
            Set-CfMigrationProperty -InputObject $scene -Name 'video_prompt' -Value ''
            Set-CfMigrationProperty -InputObject $scene -Name 'motion_prompt' -Value ''
        }
        default {
            throw "Legacy migration: неизвестный asset_type='$assetType' у сцены ${sceneId}. Исправь тип ресурса вручную."
        }
    }
}
$review.Add('Legacy migration: visual anchors и маршруты ресурсов сформированы консервативно из старых промптов. Проверь визуальное соответствие каждой сцены вручную.')

if ($null -eq $package.editing_plan.PSObject.Properties['opening_ending_inside_scene_durations']) {
    Set-CfMigrationProperty -InputObject $package.editing_plan -Name 'opening_ending_inside_scene_durations' -Value $false
}
else {
    $package.editing_plan.opening_ending_inside_scene_durations = $false
}
$review.Add('Legacy migration: opening_ending_inside_scene_durations намеренно установлен в false. Убедись, что заставка и финальная выдержка входят в длительности сцен, затем вручную поставь true.')

$humanReviewProperty = $package.PSObject.Properties['human_review']
if ($null -eq $humanReviewProperty -or $null -eq $humanReviewProperty.Value -or $humanReviewProperty.Value -isnot [array]) {
    Set-CfMigrationProperty -InputObject $package -Name 'human_review' -Value ([object[]]@())
    if ($null -ne $humanReviewProperty) { $review.Add('Legacy migration: прежний human_review был null/не массивом; сформирован новый список проверок.') }
}
foreach ($item in $review) { $package.human_review += $item }

$scriptWordCount = [regex]::Matches($fullText, "[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*").Count
Set-CfMigrationProperty -InputObject $package.script -Name 'estimated_word_count' -Value $scriptWordCount

if ([string]::IsNullOrWhiteSpace($OutputPackage)) {
    $directory = Split-Path -Parent $sourcePath
    $OutputPackage = Join-Path $directory 'production_package_v2.2_migrated.json'
}
$package | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $OutputPackage -Encoding UTF8
Write-Host "Мигрированный пакет сохранён: $OutputPackage" -ForegroundColor Green
Write-Host 'Важно: миграция не подтверждает факты, не создаёт отсутствующие источники и не принимает монтажный хронометраж автоматически. Проверь human_review и затем пакет через tools\Validate-Package.ps1.' -ForegroundColor Yellow
