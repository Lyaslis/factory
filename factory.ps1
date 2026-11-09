[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Topic,

    [ValidateSet('TikTok', 'Instagram Reels', 'YouTube Shorts')]
    [string]$Platform,

    [ValidateRange(15, 180)]
    [int]$DurationSeconds,

    [string]$Style,
    [string]$Audience,
    [string]$NotesFile,
    [string]$Model
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = $PSScriptRoot
$VersionLine = Get-Content -LiteralPath (Join-Path $ProjectRoot 'VERSION.txt') -Encoding UTF8 | Select-Object -First 1
$ContentFactoryVersion = if ([string]$VersionLine -match '^ContentFactory\s+(.+)$') { [string]$Matches[1].Trim() } else { 'unknown' }
$ConfigPath = Join-Path $ProjectRoot 'config\settings.json'
$PromptPath = Join-Path $ProjectRoot 'prompts\director_ru.txt'
$SchemaPath = Join-Path $ProjectRoot 'schemas\production_package.schema.json'

try {
    foreach ($path in @($ConfigPath, $PromptPath, $SchemaPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Не найден обязательный файл проекта: $path"
        }
    }

    Import-Module (Join-Path $ProjectRoot 'src\ContentFactory.Ollama.psm1') -Force
    Import-Module (Join-Path $ProjectRoot 'src\ContentFactory.Validation.psm1') -Force
    Import-Module (Join-Path $ProjectRoot 'src\ContentFactory.Export.psm1') -Force
    Import-Module (Join-Path $ProjectRoot 'src\ContentFactory.Repair.psm1') -Force

    $Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $SystemPrompt = Get-Content -LiteralPath $PromptPath -Raw -Encoding UTF8
    $JsonSchema = Get-Content -LiteralPath $SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json

    if ([string]::IsNullOrWhiteSpace($Platform)) { $Platform = [string]$Config.defaults.platform }
    if ($PSBoundParameters.ContainsKey('DurationSeconds') -eq $false) { $DurationSeconds = [int]$Config.defaults.duration_seconds }
    if ([string]::IsNullOrWhiteSpace($Style)) { $Style = [string]$Config.defaults.style }
    if ([string]::IsNullOrWhiteSpace($Audience)) { $Audience = [string]$Config.defaults.audience }
    if ([string]::IsNullOrWhiteSpace($Model)) { $Model = [string]$Config.ollama.model }

    $BaseUrl = [string]$Config.ollama.base_url
    $ProjectsSetting = [string]$Config.output.projects_directory
    if ([System.IO.Path]::IsPathRooted($ProjectsSetting)) {
        $ProjectsRoot = $ProjectsSetting
    }
    else {
        $ProjectsRoot = Join-Path $ProjectRoot $ProjectsSetting
    }
    $null = New-Item -ItemType Directory -Force -Path $ProjectsRoot

    $SourceNotes = '[Пользовательские материалы не переданы. В research_brief.source_material_used верни пустой массив; не утверждай, что проводил исследование.]'
    if (-not [string]::IsNullOrWhiteSpace($NotesFile)) {
        if (-not (Test-Path -LiteralPath $NotesFile -PathType Leaf)) {
            throw "Файл с материалами не найден: $NotesFile"
        }
        $SourceNotes = Get-Content -LiteralPath $NotesFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($SourceNotes)) {
            $SourceNotes = '[Переданный файл пуст.]'
        }
    }

    Write-Host "Проверяю Ollama и модель $Model..." -ForegroundColor Cyan
    $InstalledModels = @(Get-CfOllamaModels -BaseUrl $BaseUrl -TimeoutSeconds 10)
    $ModelFound = ($InstalledModels -contains $Model) -or ($InstalledModels -contains "${Model}:latest")
    if (-not $ModelFound) {
        $available = if ($InstalledModels.Count -gt 0) { $InstalledModels -join ', ' } else { '(модели не найдены)' }
        throw "Модель '$Model' не установлена. Выполни: ollama pull $Model`nУстановленные модели: $available"
    }

    $UserPrompt = @"
Подготовь производственный пакет короткого вертикального видео.

ТЕМА: $Topic
ПЛАТФОРМА: $Platform
ЦЕЛЕВАЯ ДЛИТЕЛЬНОСТЬ: $DurationSeconds секунд
АУДИТОРИЯ: $Audience
СТИЛЬ АВТОРА: $Style

МАТЕРИАЛЫ ПОЛЬЗОВАТЕЛЯ (если отсутствуют, source_material_used должен быть []; непроверенные материалы не считаются подтверждением):
$SourceNotes

Подготовь все разделы схемы. Помни: script.full_text — окончательный текст озвучки; фрагменты scenes[].voiceover_text должны дословно собираться в него. Для каждого проверяемого утверждения в сценарии создай factual_claim с точным script_excerpt. Строго соблюдай asset_type: неиспользуемые prompt-поля оставляй пустыми строками. Повторяющимся персонажам/объектам назначай continuity_entity_id и копируй canonical_description в каждый относящийся к ним промпт. Длительности сцен должны точно суммироваться в целевое время; opening/ending уже входят в это время. Не выдумывай источники. Верни только JSON.
"@

    Write-Host "ContentFactory $ContentFactoryVersion" -ForegroundColor DarkGray
    Write-Host "Создаю производственный пакет: $Topic" -ForegroundColor Cyan
    Write-Host "Платформа: $Platform | Цель: $DurationSeconds секунд | Модель: $Model`n"

    # v2.3 "think longer": stage 1 is a free-text editorial plan with thinking enabled and no JSON schema.
    # Stage 2 (below) stays at think=false and only formalises the plan into the strict JSON package.
    # Thinking together with the big JSON schema exhausted num_predict (see projects/diagnostics).
    $PlanText = $null
    $PlanningConfig = Get-CfOptionalPropertyValue -InputObject $Config -Name 'planning' -DefaultValue $null
    $PlanningEnabled = [bool](Get-CfOptionalPropertyValue -InputObject $PlanningConfig -Name 'enabled' -DefaultValue $false)
    if ($PlanningEnabled) {
        Write-Host 'Этап 1/2: Gemma продумывает ролик в режиме рассуждений (может занять несколько минут)...' -ForegroundColor Cyan
        $PlanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $PlanMaxScenes = [Math]::Min(10, [Math]::Max(4, [int][Math]::Round($DurationSeconds / 8.0)))
        $PlanText = Invoke-CfOllamaPlan `
            -BaseUrl $BaseUrl `
            -Model $Model `
            -Topic $Topic `
            -DurationSeconds $DurationSeconds `
            -Audience $Audience `
            -Style $Style `
            -SourceNotes $SourceNotes `
            -MaxScenes $PlanMaxScenes `
            -ThinkingMode (Get-CfOptionalPropertyValue -InputObject $PlanningConfig -Name 'thinking_mode' -DefaultValue $true) `
            -Temperature ([double](Get-CfOptionalPropertyValue -InputObject $PlanningConfig -Name 'temperature' -DefaultValue 0.6)) `
            -ContextTokens ([int](Get-CfOptionalPropertyValue -InputObject $PlanningConfig -Name 'context_tokens' -DefaultValue 12288)) `
            -MaxOutputTokens ([int](Get-CfOptionalPropertyValue -InputObject $PlanningConfig -Name 'max_output_tokens' -DefaultValue 9000)) `
            -TimeoutSeconds ([int](Get-CfOptionalPropertyValue -InputObject $PlanningConfig -Name 'timeout_seconds' -DefaultValue 1800))
        $PlanStopwatch.Stop()
        if ([string]::IsNullOrWhiteSpace($PlanText)) {
            Write-Host 'План не получен: продолжаю одним проходом без этапа рассуждений.' -ForegroundColor Yellow
        }
        else {
            Write-Host ('OK  План готов за {0:N0} с.' -f $PlanStopwatch.Elapsed.TotalSeconds) -ForegroundColor Green
            $UserPrompt += @"


РЕДАКТОРСКИЙ ПЛАН (результат этапа продумывания). Следуй выбранному углу, логике и осторожным формулировкам. Если сцена плана нарушает правила контракта (маршрут, якоря, язык надписей), исправь её, не меняя смысл. Не выходи за пределы фактов, которые в плане помечены как безопасные.
<<<PLAN
$PlanText
PLAN>>>
"@
        }
        Write-Host 'Этап 2/2: сборка структурированного пакета (JSON, без рассуждений)...' -ForegroundColor Cyan
    }

    $Response = Invoke-CfOllamaChat `
        -BaseUrl $BaseUrl `
        -Model $Model `
        -SystemPrompt $SystemPrompt `
        -UserPrompt $UserPrompt `
        -JsonSchema $JsonSchema `
        -Temperature ([double]$Config.ollama.temperature) `
        -ContextTokens ([int]$Config.ollama.context_tokens) `
        -MaxOutputTokens ([int]$Config.ollama.max_output_tokens) `
        -ThinkingMode $Config.ollama.thinking_mode `
        -TimeoutSeconds ([int]$Config.ollama.timeout_seconds)

    $ResponseMessage = Get-CfOptionalPropertyValue -InputObject $Response -Name 'message' -DefaultValue $null
    $JsonText = [string](Get-CfOptionalPropertyValue -InputObject $ResponseMessage -Name 'content' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        # Не считаем любой пустой content одной и той же ошибкой:
        # у reasoning-моделей Ollama отдельно возвращает message.thinking.
        # Сохраняем только технические метаданные, не записывая текст рассуждений.
        $ThinkingText = [string](Get-CfOptionalPropertyValue -InputObject $ResponseMessage -Name 'thinking' -DefaultValue '')
        $ResponseDoneReason = [string](Get-CfOptionalPropertyValue -InputObject $Response -Name 'done_reason' -DefaultValue '')
        $Diagnostic = [ordered]@{
            captured_at             = (Get-Date).ToString('o')
            model                   = [string](Get-CfOptionalPropertyValue -InputObject $Response -Name 'model' -DefaultValue $Model)
            done                    = (Get-CfOptionalPropertyValue -InputObject $Response -Name 'done' -DefaultValue $false)
            done_reason             = $ResponseDoneReason
            content_chars           = $JsonText.Length
            thinking_chars          = $ThinkingText.Length
            prompt_eval_count       = (Get-CfOptionalPropertyValue -InputObject $Response -Name 'prompt_eval_count' -DefaultValue 0)
            eval_count              = (Get-CfOptionalPropertyValue -InputObject $Response -Name 'eval_count' -DefaultValue 0)
            total_duration          = (Get-CfOptionalPropertyValue -InputObject $Response -Name 'total_duration' -DefaultValue 0)
            load_duration           = (Get-CfOptionalPropertyValue -InputObject $Response -Name 'load_duration' -DefaultValue 0)
            prompt_eval_duration    = (Get-CfOptionalPropertyValue -InputObject $Response -Name 'prompt_eval_duration' -DefaultValue 0)
            eval_duration           = (Get-CfOptionalPropertyValue -InputObject $Response -Name 'eval_duration' -DefaultValue 0)
            configured_num_ctx      = [int]$Config.ollama.context_tokens
            configured_num_predict  = [int]$Config.ollama.max_output_tokens
            configured_thinking_mode = $Config.ollama.thinking_mode
        }

        $DiagnosticDir = Join-Path $ProjectsRoot '_diagnostics'
        $null = New-Item -ItemType Directory -Force -Path $DiagnosticDir
        $DiagnosticName = 'empty_response_{0}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
        $DiagnosticPath = Join-Path $DiagnosticDir $DiagnosticName
        $Diagnostic | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $DiagnosticPath -Encoding UTF8

        $Reason = if ([string]::IsNullOrWhiteSpace($ResponseDoneReason)) { 'не указан' } else { $ResponseDoneReason }
        $Hint = if ($Reason -eq 'length') {
            'Модель исчерпала доступное окно контекста/генерации до начала финального JSON. Проверь context_tokens и max_output_tokens. Рассуждения вынесены в отдельный этап planning; для структурированного JSON ollama.thinking_mode должен оставаться false.'
        }
        elseif ($ThinkingText.Length -gt 0) {
            'Ollama вернула thinking, но не финальный content. Нужны метаданные из диагностического файла для выбора настройки.'
        }
        else {
            'Финальный content и thinking пусты. Проверь версию Ollama и результат короткого тестового запроса.'
        }

        throw "Ollama ответила, но message.content пуст. done_reason=$Reason; thinking_chars=$($ThinkingText.Length); eval_count=$(Get-CfOptionalPropertyValue -InputObject $Response -Name 'eval_count' -DefaultValue 0). $Hint Диагностика: $DiagnosticPath"
    }

    try {
        $Package = $JsonText | ConvertFrom-Json -Depth 100
    }
    catch {
        $failureName = 'failed_response_{0}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
        $failurePath = Join-Path $ProjectsRoot $failureName
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($failurePath, $JsonText, $utf8)
        throw "Ответ Ollama не является корректным JSON. Исходный ответ сохранён в: $failurePath"
    }

    # Deterministic repair pass: normalize scene timing and continuity text before validation.
    # Creative narration and factual claims are never rewritten by this pass.
    $MaxAiVideoScenes = [int]$Config.production_profile.max_ai_video_scenes
    $RepairNotes = @(Repair-CfPackageStructure -Package $Package -TargetDurationSeconds $DurationSeconds -MaxAiVideoScenes $MaxAiVideoScenes -RebalanceTimingBySpeech:$([bool]$Config.production_profile.rebalance_scene_timing_by_speech))
    foreach ($repairNote in $RepairNotes) {
        Write-Host "АВТОКОРРЕКЦИЯ: $repairNote" -ForegroundColor Yellow
    }

    # v2.2.5: constrained, no-thinking, per-scene visual repair for scenes that fail literal anchor/prompt
    # alignment. v2.3: up to ollama.repair_attempts rounds; a retry receives the rejection reason and a
    # slightly higher temperature, because an identical prompt at temperature 0 repeats the same rejected answer.
    $VisualRepairCandidates = @(Get-CfrVisualSceneRepairCandidates -Package $Package)
    if ($VisualRepairCandidates.Count -gt 0) {
        $MaxRepairAttempts = [Math]::Max(1, [int](Get-CfOptionalPropertyValue -InputObject $Config.ollama -Name 'repair_attempts' -DefaultValue 2))
        $RepairFailures = @{}
        $EverFailedSceneIds = [System.Collections.Generic.HashSet[string]]::new()
        try {
            for ($repairAttempt = 1; $repairAttempt -le $MaxRepairAttempts; $repairAttempt++) {
                $VisualRepairCandidates = @(Get-CfrVisualSceneRepairCandidates -Package $Package)
                if ($VisualRepairCandidates.Count -eq 0) { break }
                $candidateIds = @($VisualRepairCandidates | ForEach-Object { [string]$_.scene_id })
                Write-Host "Проверяю и согласую визуальные якоря сцен (попытка $repairAttempt из $MaxRepairAttempts): $($candidateIds -join ', ')..." -ForegroundColor Cyan

                # Repair each scene in its own small JSON-schema call. A single batch request
                # made Gemma copy fields between routes and mix identity details with scene anchors.
                $VisualSceneRepairList = [System.Collections.Generic.List[object]]::new()
                foreach ($visualCandidate in $VisualRepairCandidates) {
                    $currentSceneId = [string]$visualCandidate.scene_id
                    $previousFailure = ''
                    if ($RepairFailures.ContainsKey($currentSceneId)) { $previousFailure = [string]$RepairFailures[$currentSceneId] }
                    $repairTemperature = 0.0
                    if ($repairAttempt -gt 1) { $repairTemperature = 0.3 }
                    try {
                        $singleSceneRepairs = @(Invoke-CfOllamaVisualSceneRepair `
                            -BaseUrl $BaseUrl `
                            -Model $Model `
                            -Candidates @($visualCandidate) `
                            -VisualStyle $Package.visual_style `
                            -ContextTokens ([int]$Config.ollama.context_tokens) `
                            -TimeoutSeconds ([int]$Config.ollama.timeout_seconds) `
                            -Temperature $repairTemperature `
                            -PreviousFailure $previousFailure)
                        foreach ($singleRepair in $singleSceneRepairs) {
                            $VisualSceneRepairList.Add($singleRepair)
                        }
                    }
                    catch {
                        $singleFailure = "Сцена ${currentSceneId}: отдельный проход Gemma не завершился: $($_.Exception.Message). Исходные данные сохранены для ручной проверки."
                        Add-CfHumanReviewNote -Package $Package -Note $singleFailure
                        Write-Warning $singleFailure
                    }
                }

                $VisualSceneRepairs = @($VisualSceneRepairList.ToArray())
                $VisualRepairNotes = @(Set-CfrVisualSceneRepairs -Package $Package -Repairs $VisualSceneRepairs)
                foreach ($visualNote in $VisualRepairNotes) {
                    Write-Host "АВТОКОРРЕКЦИЯ: $visualNote" -ForegroundColor Yellow
                    # Remember why a scene was rejected so the next attempt can address that exact reason.
                    if ($visualNote -match '^Сцена (\d+): (предложенное Gemma исправление не применено|Gemma не вернула исправление)') {
                        $failedSceneId = [string]$Matches[1]
                        $RepairFailures[$failedSceneId] = ($visualNote -replace '^Сцена \d+: ', '')
                        [void]$EverFailedSceneIds.Add($failedSceneId)
                    }
                }
            }

            $StillInvalidVisualScenes = @(Get-CfrVisualSceneRepairCandidates -Package $Package)
            $StillInvalidIds = @($StillInvalidVisualScenes | ForEach-Object { [string]$_.scene_id })
            # A scene that failed once but was fixed by a retry must not keep a misleading "needs manual edit" note.
            foreach ($failedId in $EverFailedSceneIds) {
                if ($StillInvalidIds -notcontains $failedId) {
                    Remove-CfHumanReviewNotes -Package $Package -Pattern "^Сцена ${failedId}: (предложенное Gemma исправление не применено|Gemma не вернула исправление)"
                }
            }
            if ($StillInvalidVisualScenes.Count -gt 0) {
                Write-Warning "Визуальная согласованность не исправлена для сцен: $($StillInvalidIds -join ', '). Строгий валидатор заблокирует пакет до ручной правки."
            }
            else {
                Write-Host 'OK  Визуальные якоря, исходные кадры и маршруты движения согласованы.' -ForegroundColor Green
            }
        }
        catch {
            $repairFailureNote = "Автоматический второй проход визуальной согласованности не выполнен: $($_.Exception.Message). Сцены требуют ручной проверки."
            Add-CfHumanReviewNote -Package $Package -Note $repairFailureNote
            Write-Warning $repairFailureNote
        }
    }
    else {
        Write-Host 'OK  Первичная генерация уже согласовала visual_purpose, anchors и prompts.' -ForegroundColor Green
    }

    # v2.3 last resort after the Gemma retries: when every missing anchor is demonstrably present in image_prompt,
    # only the bookkeeping field visual_purpose disagrees; fix it mechanically and leave a note for the human.
    foreach ($gapNote in @(Repair-CfrPurposeAnchorGap -Package $Package)) {
        Write-Host "АВТОКОРРЕКЦИЯ: $gapNote" -ForegroundColor Yellow
    }

    # Repair only factual-claim excerpts that are not exact substrings of the final narration.
    # A second small no-thinking call is used; each returned excerpt is independently checked
    # against the script before it is applied. If it cannot be verified, the validator blocks the package.
    $ClaimsNeedingRepair = @(Get-CfClaimsNeedingExcerptRepair -Package $Package)
    if ($ClaimsNeedingRepair.Count -gt 0) {
        Write-Host "Исправляю точные цитаты для factual claims: $($ClaimsNeedingRepair.Count)..." -ForegroundColor Cyan
        try {
            $ScriptForClaims = [string]$Package.script.full_text
            $ClaimRepairs = @(Invoke-CfOllamaClaimExcerptRepair `
                -BaseUrl $BaseUrl `
                -Model $Model `
                -ScriptText $ScriptForClaims `
                -Claims $ClaimsNeedingRepair `
                -ContextTokens ([int]$Config.ollama.context_tokens) `
                -TimeoutSeconds ([int]$Config.ollama.timeout_seconds))
            $AppliedClaimRepairs = @(Set-CfClaimExcerptRepairs -Package $Package -Repairs $ClaimRepairs)
            if ($AppliedClaimRepairs.Count -gt 0) {
                Write-Host "OK  Исправлены точные цитаты: $($AppliedClaimRepairs -join ', ')" -ForegroundColor Green
            }
            else {
                Write-Warning 'Gemma не вернула ни одной цитаты, которая дословно присутствует в сценарии. Валидатор оставит эти claims заблокированными.'
            }
        }
        catch {
            Write-Warning "Не удалось автоматически исправить цитаты factual claims: $($_.Exception.Message). Валидатор проверит исходные значения и при необходимости заблокирует пакет."
        }
    }
    else {
        Write-Host 'OK  Все script_excerpt уже являются точными фрагментами сценария.' -ForegroundColor Green
    }

    # v2.3: all Gemma calls are finished. Release the VRAM now so TTS / ComfyUI can use the whole GPU
    # (an RTX 3060 12 GB cannot hold Gemma and Flux/Wan at the same time).
    if ([bool](Get-CfOptionalPropertyValue -InputObject $Config.ollama -Name 'unload_after_run' -DefaultValue $false)) {
        if (Invoke-CfOllamaUnload -BaseUrl $BaseUrl -Model $Model) {
            Write-Host 'OK  Gemma выгружена из видеопамяти: GPU свободен для озвучки и ComfyUI.' -ForegroundColor Green
        }
    }

    # Use the narration as source of truth. Recalculate the word count in code instead of trusting the model estimate.
    $ModelReportedWordCount = [int]$Package.script.estimated_word_count
    $ActualWordCount = Get-CfWordCount -Text ([string]$Package.script.full_text)
    $Package.script.estimated_word_count = $ActualWordCount

    $Validation = Test-CfProductionPackage `
        -Package $Package `
        -TargetDurationSeconds $DurationSeconds `
        -MaxAiVideoScenes $MaxAiVideoScenes `
        -RequireVisualAnchors:$([bool]$Config.production_profile.require_visual_anchor_terms) `
        -MaximumWordsPerSecond ([double]$Config.production_profile.max_scene_words_per_second)
    $ResponseDoneReason = [string](Get-CfOptionalPropertyValue -InputObject $Response -Name 'done_reason' -DefaultValue '')
    if ($ResponseDoneReason -eq 'length') {
        $extraWarning = 'Ответ остановлен по лимиту токенов (done_reason=length). Пакет может быть обрезан; увеличь max_output_tokens или сократи объём задания в config/settings.json.'
        $Validation.warnings = @($Validation.warnings) + $extraWarning
    }

    $ProjectDir = Save-CfProductionProject `
        -ProjectsRoot $ProjectsRoot `
        -Package $Package `
        -Validation $Validation `
        -Model $Model `
        -Topic $Topic `
        -Platform $Platform `
        -TargetDurationSeconds $DurationSeconds `
        -OllamaResponse $Response `
        -ModelReportedWordCount $ModelReportedWordCount

    if (-not [string]::IsNullOrWhiteSpace($PlanText)) {
        $PlanningNotesPath = Join-Path $ProjectDir 'planning_notes.txt'
        [System.IO.File]::WriteAllText($PlanningNotesPath, $PlanText, [System.Text.UTF8Encoding]::new($false))
    }

    Write-Host "`nПакет сохранён: $ProjectDir" -ForegroundColor Green
    Write-Host "Основные файлы:"
    @(
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
    ) | ForEach-Object { Write-Host "  - $_" }

    if (@($Validation.warnings).Count -gt 0) {
        Write-Host "`nПредупреждения проверки:" -ForegroundColor Yellow
        foreach ($warning in @($Validation.warnings)) { Write-Host "  - $warning" -ForegroundColor Yellow }
    }

    if (-not $Validation.is_valid) {
        Write-Host "`nПакет сохранён, но не прошёл обязательную проверку. Открой validation_report.json." -ForegroundColor Red
        exit 2
    }

    Write-Host "`nСтруктурная проверка пройдена. Следующий шаг — проверить script.txt и human_review.txt." -ForegroundColor Green
}
catch {
    Write-Host "ОШИБКА: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
