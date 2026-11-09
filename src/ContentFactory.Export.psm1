Set-StrictMode -Version Latest

function Write-CfTextFile {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Content)
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-CfJsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Value)
    $json = $Value | ConvertTo-Json -Depth 100
    Write-CfTextFile -Path $Path -Content $json
}

function ConvertTo-CfSlug {
    param([Parameter(Mandatory)][string]$Text)
    $slug = $Text -replace '[<>:"/\\|?*\x00-\x1F]', ' '
    $slug = $slug -replace '[^\p{L}\p{Nd}_ -]', ' '
    $slug = $slug -replace '\s+', '_'
    $slug = $slug.Trim('_')
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'video' }
    if ($slug.Length -gt 48) { $slug = $slug.Substring(0, 48).Trim('_') }
    return $slug
}

function Get-CfAssetRoute {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$AssetType, [Parameter(Mandatory)][string]$BaseName)

    switch ($AssetType) {
        'generated_image' {
            return [pscustomobject]@{
                generator = 'ComfyUI image workflow (Flux 3 Klein)'
                acquisition = 'generate_image_locally'
                expected_outputs = @("assets/images/$BaseName.png")
                steps = @('Создать статичное изображение по image_prompt.', 'Сохранить PNG в указанное место.')
            }
        }
        'image_animation' {
            return [pscustomobject]@{
                generator = 'ComfyUI image workflow + FFmpeg Ken Burns'
                acquisition = 'generate_image_then_animate'
                expected_outputs = @("assets/images/$BaseName.png", "assets/videos/$BaseName.mp4")
                steps = @('Создать статичное изображение по image_prompt.', 'Анимировать только движение камеры по motion_prompt средствами FFmpeg; не запускать Wan.')
            }
        }
        'ai_video' {
            return [pscustomobject]@{
                generator = 'ComfyUI reference image workflow + Wan 2.2'
                acquisition = 'generate_reference_then_video'
                expected_outputs = @("assets/images/$($BaseName)_reference.png", "assets/videos/$BaseName.mp4")
                steps = @('Создать исходный кадр по image_prompt.', 'Передать исходный кадр и video_prompt в Wan 2.2.', 'Сохранить короткий видеоклип.')
            }
        }
        'motion_graphic' {
            return [pscustomobject]@{
                generator = 'FFmpeg motion-graphics workflow'
                acquisition = 'render_graphic_locally'
                expected_outputs = @("assets/videos/$($BaseName)_graphic.mp4")
                steps = @('Собрать композицию по image_prompt средствами SVG/FFmpeg.', 'Анимировать элементы по motion_prompt.', 'Все реальные надписи брать из on_screen_text, не генерировать их в изображении.')
            }
        }
        'stock_or_archive' {
            return [pscustomobject]@{
                generator = 'Human-selected stock/archive material'
                acquisition = 'human_source_required'
                expected_outputs = @("assets/videos/$($BaseName)_source_asset")
                steps = @('Найти материал по image_prompt.', 'Проверить лицензию, права и допустимость использования.', 'Сохранить исходный файл в указанную папку.')
            }
        }
        default {
            return [pscustomobject]@{
                generator = 'Invalid route — inspect validation_report.json'
                acquisition = 'blocked_by_validation'
                expected_outputs = @()
                steps = @('Исправить asset_type в production_package.json и повторно проверить пакет.')
            }
        }
    }
}

function Save-CfProductionProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectsRoot,
        [Parameter(Mandatory)][object]$Package,
        [Parameter(Mandatory)][object]$Validation,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Topic,
        [Parameter(Mandatory)][string]$Platform,
        [Parameter(Mandatory)][int]$TargetDurationSeconds,
        [Parameter(Mandatory)][object]$OllamaResponse,
        [int]$ModelReportedWordCount = 0
    )

    $slug = ConvertTo-CfSlug -Text $Topic
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $projectDir = Join-Path $ProjectsRoot ('{0}_{1}' -f $stamp, $slug)
    $null = New-Item -ItemType Directory -Force -Path $projectDir

    foreach ($folder in @('assets\images', 'assets\videos', 'assets\audio', 'assets\characters', 'exports')) {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $projectDir $folder)
    }

    $project = $Package.project
    $research = $Package.research_brief
    $script = $Package.script
    $visualStyle = $Package.visual_style
    $scenes = @($Package.scenes)
    $editingPlan = $Package.editing_plan

    # production_package.json is the only canonical source of truth.
    Write-CfJsonFile -Path (Join-Path $projectDir 'production_package.json') -Value $Package
    Write-CfTextFile -Path (Join-Path $projectDir 'script.txt') -Content ([string]$script.full_text)
    Write-CfJsonFile -Path (Join-Path $projectDir 'research_brief.json') -Value $research

    $storyboard = [ordered]@{
        project = $project
        visual_style = $visualStyle
        scenes = $scenes
    }
    Write-CfJsonFile -Path (Join-Path $projectDir 'storyboard.json') -Value $storyboard

    $visualPromptScenes = foreach ($scene in $scenes) {
        $baseName = 'scene_{0:D3}' -f [int]$scene.scene_id
        $route = Get-CfAssetRoute -AssetType ([string]$scene.asset_type) -BaseName $baseName
        $imagePromptKind = switch ([string]$scene.asset_type) {
            'stock_or_archive' { 'search_query' }
            'motion_graphic' { 'layout_specification' }
            default { 'generation_prompt' }
        }
        $anchorProperty = $scene.PSObject.Properties['visual_anchor_terms']
        $motionTargetProperty = $scene.PSObject.Properties['motion_target']
        $anchorValues = @()
        if ($null -ne $anchorProperty -and $null -ne $anchorProperty.Value) { $anchorValues = @($anchorProperty.Value) }
        $motionTargetValue = ''
        if ($null -ne $motionTargetProperty -and $null -ne $motionTargetProperty.Value) { $motionTargetValue = [string]$motionTargetProperty.Value }
        $sceneEntityIds = @($scene.continuity_entity_ids)
        $sceneReferenceAssets = [System.Collections.Generic.List[object]]::new()
        foreach ($entity in @($visualStyle.continuity_entities)) {
            $entityId = [string]$entity.entity_id
            if ($sceneEntityIds -notcontains $entityId) { continue }
            $referencePathProperty = $entity.PSObject.Properties['reference_asset_path']
            if ($null -eq $referencePathProperty -or [string]::IsNullOrWhiteSpace([string]$referencePathProperty.Value)) { continue }
            $sceneReferenceAssets.Add([ordered]@{
                entity_id = $entityId
                reference_asset_path = [string]$referencePathProperty.Value
                usage = 'identity_reference'
            })
        }
        [ordered]@{
            scene_id = $scene.scene_id
            asset_id = $baseName
            asset_type = $scene.asset_type
            generator = $route.generator
            visual_purpose = $scene.visual_purpose
            visual_anchor_terms = $anchorValues
            motion_target = $motionTargetValue
            image_prompt = $scene.image_prompt
            image_prompt_kind = $imagePromptKind
            video_prompt = $scene.video_prompt
            motion_prompt = $scene.motion_prompt
            negative_prompt = $visualStyle.negative_prompt
            continuity_entity_ids = $sceneEntityIds
            continuity_reference_assets = @($sceneReferenceAssets.ToArray())
            continuity_notes = $scene.continuity_notes
            expected_outputs = @($route.expected_outputs)
        }
    }
    $visualPrompts = [ordered]@{
        project = [ordered]@{
            working_title = $project.working_title
            aspect_ratio = $project.aspect_ratio
            language = $project.language
        }
        global_visual_style = $visualStyle
        scenes = @($visualPromptScenes)
    }
    Write-CfJsonFile -Path (Join-Path $projectDir 'visual_prompts.json') -Value $visualPrompts

    $styleGuide = [ordered]@{
        project_title = $project.working_title
        aspect_ratio = $project.aspect_ratio
        visual_style = $visualStyle
    }
    Write-CfJsonFile -Path (Join-Path $projectDir 'visual_style_guide.json') -Value $styleGuide

    $continuityItems = [System.Collections.Generic.List[object]]::new()
    foreach ($scene in $scenes) {
        $sceneEntityCount = @($scene.continuity_entity_ids).Count
        if (-not [string]::IsNullOrWhiteSpace([string]$scene.continuity_notes) -or $sceneEntityCount -gt 0) {
            $continuityItems.Add([ordered]@{
                scene_id = $scene.scene_id
                continuity_entity_ids = @($scene.continuity_entity_ids)
                notes = $scene.continuity_notes
            })
        }
    }
    $continuityGuide = [ordered]@{
        project_title = $project.working_title
        entities = @($visualStyle.continuity_entities)
        global_rules = @($visualStyle.continuity_rules)
        scene_specific_rules = @($continuityItems.ToArray())
    }
    Write-CfJsonFile -Path (Join-Path $projectDir 'continuity_guide.json') -Value $continuityGuide

    $assetCounts = [ordered]@{}
    $assetItems = [System.Collections.Generic.List[object]]::new()
    foreach ($scene in $scenes) {
        $type = [string]$scene.asset_type
        if (-not $assetCounts.Contains($type)) { $assetCounts[$type] = 0 }
        $assetCounts[$type] = [int]$assetCounts[$type] + 1
        $baseName = 'scene_{0:D3}' -f [int]$scene.scene_id
        $route = Get-CfAssetRoute -AssetType $type -BaseName $baseName
        $assetItems.Add([ordered]@{
            scene_id = $scene.scene_id
            asset_id = $baseName
            asset_type = $type
            generator = $route.generator
            acquisition = $route.acquisition
            expected_outputs = @($route.expected_outputs)
            generation_steps = @($route.steps)
            scene_duration_seconds = [double]$scene.duration_seconds
            visual_purpose = $scene.visual_purpose
        })
    }
    $characterReferenceItems = [System.Collections.Generic.List[object]]::new()
    foreach ($entity in @($visualStyle.continuity_entities)) {
        $referencePathProperty = $entity.PSObject.Properties['reference_asset_path']
        $referencePromptProperty = $entity.PSObject.Properties['reference_image_prompt']
        if ($null -ne $referencePathProperty -and -not [string]::IsNullOrWhiteSpace([string]$referencePathProperty.Value)) {
            $referenceImagePrompt = ''
            if ($null -ne $referencePromptProperty) { $referenceImagePrompt = [string]$referencePromptProperty.Value }
            $characterReferenceItems.Add([ordered]@{
                entity_id = [string]$entity.entity_id
                entity_type = [string]$entity.entity_type
                canonical_description = [string]$entity.canonical_description
                reference_image_prompt = $referenceImagePrompt
                reference_asset_path = [string]$referencePathProperty.Value
                generator = 'ComfyUI image workflow (Flux 3 Klein)'
                acquisition = 'generate_and_human_approve_before_scene_generation'
                generation_steps = @(
                    'Создать один нейтральный портрет персонажа по reference_image_prompt.',
                    'Вручную утвердить лицо, причёску, одежду и возрастной облик.',
                    'Сохранить утверждённый PNG по reference_asset_path.',
                    'Использовать этот PNG как identity reference во всех сценах, где указан entity_id.'
                )
            })
        }
    }

    $assetRequirements = [ordered]@{
        project_title = $project.working_title
        scene_count = $scenes.Count
        asset_counts_by_type = $assetCounts
        assets = @($assetItems.ToArray())
        character_references = @($characterReferenceItems.ToArray())
        audio_requirements = [ordered]@{
            narration_source = 'script.txt'
            narration_output = 'assets/audio/voice.wav'
            subtitles_output = 'assets/audio/subtitles.srt'
            optional_music = 'assets/audio/music.wav'
        }
        note = 'План создания ресурсов, автоматически выведенный из production_package.json. Наличие записи не означает, что файл уже создан.'
    }
    Write-CfJsonFile -Path (Join-Path $projectDir 'asset_requirements.json') -Value $assetRequirements

    # Deterministic scene-level timeline. Exact word/subtitle timing is deferred until TTS exists.
    $timelineItems = [System.Collections.Generic.List[object]]::new()
    $cursor = 0.0
    foreach ($scene in $scenes) {
        $duration = [double]$scene.duration_seconds
        $start = [Math]::Round($cursor, 2)
        $end = [Math]::Round(($cursor + $duration), 2)
        $baseName = 'scene_{0:D3}' -f [int]$scene.scene_id
        $route = Get-CfAssetRoute -AssetType ([string]$scene.asset_type) -BaseName $baseName
        $timelineItems.Add([ordered]@{
            scene_id = $scene.scene_id
            asset_id = $baseName
            asset_type = $scene.asset_type
            start_seconds = $start
            end_seconds = $end
            duration_seconds = $duration
            expected_outputs = @($route.expected_outputs)
            voiceover_text = $scene.voiceover_text
            on_screen_text = $scene.on_screen_text
            transition = $scene.transition
            sound_effect = $scene.sound_effect
        })
        $cursor += $duration
    }
    $timeline = [ordered]@{
        project_title = $project.working_title
        timeline_type = 'scene_level_plan'
        timing_status = 'preliminary_until_tts_alignment'
        target_duration_seconds = $TargetDurationSeconds
        planned_duration_seconds = [Math]::Round($cursor, 2)
        opening_and_ending_included_in_scene_durations = [bool]$editingPlan.opening_ending_inside_scene_durations
        note = 'Таймкоды рассчитаны по длительности сцен. После генерации voice.wav необходимо проверить речь, паузы и границы сцен; это ещё не frame-accurate монтажный таймлайн.'
        scenes = @($timelineItems.ToArray())
    }
    Write-CfJsonFile -Path (Join-Path $projectDir 'timeline.json') -Value $timeline

    Write-CfJsonFile -Path (Join-Path $projectDir 'editing_plan.json') -Value $editingPlan

    $reviewLines = [System.Collections.Generic.List[string]]::new()
    $reviewLines.Add('ПРОВЕРКА ЧЕЛОВЕКОМ')
    $reviewLines.Add('==================')
    $reviewLines.Add('1. Прослушать тестовую озвучку целиком; проверить темп, ударения и произношение.')
    $reviewLines.Add('2. Сверить границы сцен с фактической озвучкой; timeline.json пока предварительный.')
    $reviewLines.Add('3. Проверить каждый визуал на соответствие фразе, стиль и непрерывность персонажей/предметов.')
    $reviewLines.Add('4. Проверить все права на stock/archive и сторонние материалы.')
    $reviewLines.Add('5. Просмотреть итоговый ролик целиком до публикации.')
    foreach ($item in @($Package.human_review)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$item)) { $reviewLines.Add("- $item") }
    }
    foreach ($claim in @($research.factual_claims)) {
        if ($claim.verification_status -eq 'verified_in_user_material') {
            $reviewLines.Add("- Сверить утверждение [$($claim.claim_id)] с исходным пользовательским материалом: $($claim.claim). Статус модели сам по себе не подтверждает истинность утверждения.")
        }
        else {
            $reviewLines.Add("- Проверить утверждение [$($claim.claim_id)] по надёжным источникам: $($claim.claim) [$($claim.verification_status)]")
        }
    }
    foreach ($missing in @($research.missing_information)) {
        $reviewLines.Add("- Закрыть пробел в информации: $missing")
    }
    foreach ($warning in @($Validation.warnings)) {
        $reviewLines.Add("- Автоматическая проверка: $warning")
    }
    Write-CfTextFile -Path (Join-Path $projectDir 'human_review.txt') -Content ($reviewLines -join [Environment]::NewLine)

    $validationReport = [ordered]@{
        is_valid = [bool]$Validation.is_valid
        errors = @($Validation.errors)
        warnings = @($Validation.warnings)
        checks = @($Validation.checks)
    }
    Write-CfJsonFile -Path (Join-Path $projectDir 'validation_report.json') -Value $validationReport

    $doneReason = ''
    $promptTokens = $null
    $outputTokens = $null
    if ($OllamaResponse.PSObject.Properties['done_reason']) { $doneReason = [string]$OllamaResponse.done_reason }
    if ($OllamaResponse.PSObject.Properties['prompt_eval_count']) { $promptTokens = $OllamaResponse.prompt_eval_count }
    if ($OllamaResponse.PSObject.Properties['eval_count']) { $outputTokens = $OllamaResponse.eval_count }

    $versionFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'VERSION.txt'
    $versionLine = 'ContentFactory 2.2.0'
    if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
        $firstVersionLine = (Get-Content -LiteralPath $versionFile -Encoding UTF8 | Select-Object -First 1)
        if ([string]$firstVersionLine -match '^ContentFactory\s+(.+)$') { $versionLine = [string]$Matches[1].Trim() }
    }
    $runInfo = [ordered]@{
        created_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        contentfactory_version = $versionLine
        model = $Model
        topic = $Topic
        platform = $Platform
        target_duration_seconds = $TargetDurationSeconds
        package_schema_version = [string]$Package.schema_version
        ai_video_scene_count = @($Package.scenes | Where-Object { $_.asset_type -eq 'ai_video' }).Count
        model_estimated_word_count = $ModelReportedWordCount
        actual_word_count = [int]$script.estimated_word_count
        ollama_done_reason = $doneReason
        ollama_prompt_tokens = $promptTokens
        ollama_output_tokens = $outputTokens
        package_valid = [bool]$Validation.is_valid
    }
    Write-CfJsonFile -Path (Join-Path $projectDir 'run_info.json') -Value $runInfo

    $projectReadme = @"
ПРОЕКТ: $($project.working_title)

КАНОНИЧЕСКИЙ ФАЙЛ
- production_package.json — единственный основной источник данных.

ЭКСПОРТЫ ДЛЯ ИНСТРУМЕНТОВ
- script.txt — текст озвучки.
- research_brief.json — тезисы и реестр утверждений с привязкой к фрагментам сценария.
- storyboard.json — сцены, длительности и текст сцен.
- visual_prompts.json — промпты и маршруты генераторов.
- visual_style_guide.json — единое визуальное руководство.
- continuity_guide.json — канонические повторяющиеся сущности и ссылки сцен.
- asset_requirements.json — ресурсы для сцен и единые reference PNG повторяющихся персонажей.
- timeline.json — предварительная временная шкала уровня сцен.
- editing_plan.json — высокоуровневые настройки монтажа.
- human_review.txt — обязательные ручные проверки.
- validation_report.json — автоматические проверки.
- run_info.json — параметры генерации и статистика запуска.

Папки assets/images, assets/videos и assets/audio зарезервированы для последующих этапов.
Экспортные файлы построены из production_package.json. Не редактируй их независимо друг от друга: сначала измени канонический пакет и повторно создай экспорты.
"@
    Write-CfTextFile -Path (Join-Path $projectDir 'PROJECT_README.txt') -Content $projectReadme

    return $projectDir
}

Export-ModuleMember -Function Save-CfProductionProject
