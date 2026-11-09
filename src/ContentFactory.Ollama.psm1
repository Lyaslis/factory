Set-StrictMode -Version Latest


function Get-CfOptionalPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) { return $DefaultValue }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function Get-CfOllamaModels {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [int]$TimeoutSeconds = 10
    )

    $uri = '{0}/api/tags' -f $BaseUrl.TrimEnd('/')
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $TimeoutSeconds
    }
    catch {
        throw "Ollama недоступна по адресу $uri. Запусти Ollama и повтори команду. Подробности: $($_.Exception.Message)"
    }

    return @($response.models | ForEach-Object { [string]$_.name })
}

function Invoke-CfOllamaChat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][string]$UserPrompt,
        [AllowNull()][object]$JsonSchema = $null,
        [Parameter(Mandatory)][double]$Temperature,
        [Parameter(Mandatory)][int]$ContextTokens,
        [Parameter(Mandatory)][int]$MaxOutputTokens,
        [Parameter(Mandatory)][object]$ThinkingMode,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [string]$KeepAlive = '5m'
    )

    if ($ThinkingMode -isnot [bool] -and -not ($ThinkingMode -is [string] -and $ThinkingMode -in @('low', 'medium', 'high', 'max'))) {
        throw "ThinkingMode должен быть Boolean или одной из строк low/medium/high/max. Получено: $($ThinkingMode.GetType().FullName)"
    }

    $payload = @{
        model = $Model
        stream = $false
        think = $ThinkingMode
        messages = @(
            @{ role = 'system'; content = $SystemPrompt },
            @{ role = 'user'; content = $UserPrompt }
        )
        options = @{
            temperature = $Temperature
            num_ctx = $ContextTokens
            num_predict = $MaxOutputTokens
        }
        keep_alive = $KeepAlive
    }
    # JSON Schema (structured output) is optional: the planning stage uses free text so that
    # the model can reason for as long as it needs without being forced into a JSON grammar.
    if ($null -ne $JsonSchema) { $payload['format'] = $JsonSchema }

    $body = $payload | ConvertTo-Json -Depth 100 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $uri = '{0}/api/chat' -f $BaseUrl.TrimEnd('/')

    try {
        return Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec $TimeoutSeconds
    }
    catch {
        throw "Ошибка запроса к Ollama ($uri): $($_.Exception.Message)"
    }
}


function Invoke-CfOllamaClaimExcerptRepair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$ScriptText,
        [Parameter(Mandatory)][object[]]$Claims,
        [Parameter(Mandatory)][int]$ContextTokens,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    if (@($Claims).Count -eq 0) { return @() }

    $schema = @{
        type = 'object'
        additionalProperties = $false
        properties = @{
            repairs = @{
                type = 'array'
                items = @{
                    type = 'object'
                    additionalProperties = $false
                    properties = @{
                        claim_id = @{ type = 'string' }
                        script_excerpt = @{ type = 'string' }
                    }
                    required = @('claim_id', 'script_excerpt')
                }
            }
        }
        required = @('repairs')
    }

    $claimPayload = @($Claims | ForEach-Object {
        [ordered]@{
            claim_id = [string]$_.claim_id
            claim = [string]$_.claim
        }
    })
    $claimsJson = ConvertTo-Json -InputObject $claimPayload -Depth 10 -Compress

    $systemPrompt = @'
Ты — точный редактор-сверщик цитат. Не переписывай сценарий и не пересказывай его. Для каждого утверждения найди минимальный непрерывный фрагмент, который дословно присутствует в тексте сценария и выражает это утверждение. Скопируй его с исходной пунктуацией и регистром. Нельзя исправлять грамматику, менять окончания, добавлять слова или использовать многоточие вместо пропуска. Если подходящего фрагмента нет, верни пустую строку. Возвращай только JSON по схеме.
'@

    $userPrompt = @"
ТЕКСТ СЦЕНАРИЯ — ИСТОЧНИК ИСТИНЫ. Копируй фрагменты только отсюда:
<<<SCRIPT
$ScriptText
SCRIPT>>>

УТВЕРЖДЕНИЯ:
$claimsJson

Для каждого claim_id верни script_excerpt — дословный, непрерывный фрагмент SCRIPT. Не создавай новую формулировку. Если сценарий не содержит утверждение, верни пустую строку.
"@

    # v2.3: use the same num_ctx as the main call. Ollama restarts the model runner when num_ctx changes
    # (a 12B model takes tens of seconds to load), so a smaller repair context made every repair call slow.
    $repairContext = $ContextTokens
    $response = Invoke-CfOllamaChat `
        -BaseUrl $BaseUrl `
        -Model $Model `
        -SystemPrompt $systemPrompt `
        -UserPrompt $userPrompt `
        -JsonSchema $schema `
        -Temperature 0.0 `
        -ContextTokens $repairContext `
        -MaxOutputTokens 1000 `
        -ThinkingMode $false `
        -TimeoutSeconds $TimeoutSeconds

    $message = Get-CfOptionalPropertyValue -InputObject $response -Name 'message' -DefaultValue $null
    $content = [string](Get-CfOptionalPropertyValue -InputObject $message -Name 'content' -DefaultValue '')
    $doneReason = [string](Get-CfOptionalPropertyValue -InputObject $response -Name 'done_reason' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($content) -or $doneReason -eq 'length') {
        throw "Gemma не смогла исправить точные цитаты factual claims. done_reason='$doneReason'."
    }

    try {
        $parsed = $content | ConvertFrom-Json -Depth 20
    }
    catch {
        throw "Gemma вернула некорректный JSON при исправлении factual claims: $($_.Exception.Message)"
    }

    return @($parsed.repairs)
}

function Invoke-CfOllamaVisualSceneRepair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][object[]]$Candidates,
        [Parameter(Mandatory)][object]$VisualStyle,
        [Parameter(Mandatory)][int]$ContextTokens,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [double]$Temperature = 0.0,
        [string]$PreviousFailure = ''
    )

    if (@($Candidates).Count -eq 0) { return @() }

    $sceneSchema = @{
        type = 'object'
        additionalProperties = $false
        properties = @{
            scene_id = @{ type = 'integer' }
            visual_purpose = @{ type = 'string'; minLength = 12 }
            visual_anchor_terms = @{
                type = 'array'
                minItems = 2
                maxItems = 5
                uniqueItems = $true
                items = @{ type = 'string'; minLength = 2; maxLength = 80 }
            }
            image_prompt = @{ type = 'string'; minLength = 20 }
            video_prompt = @{ type = 'string' }
            motion_prompt = @{ type = 'string' }
            motion_target = @{ type = 'string' }
        }
        required = @('scene_id', 'visual_purpose', 'visual_anchor_terms', 'image_prompt', 'video_prompt', 'motion_prompt', 'motion_target')
    }
    $schema = @{
        type = 'object'
        additionalProperties = $false
        properties = @{ scenes = @{ type = 'array'; items = $sceneSchema } }
        required = @('scenes')
    }

    $styleSummary = [ordered]@{
        overall_direction = [string](Get-CfOptionalPropertyValue -InputObject $VisualStyle -Name 'overall_direction' -DefaultValue '')
        palette = @(Get-CfOptionalPropertyValue -InputObject $VisualStyle -Name 'palette' -DefaultValue @())
        lighting = [string](Get-CfOptionalPropertyValue -InputObject $VisualStyle -Name 'lighting' -DefaultValue '')
        camera_language = [string](Get-CfOptionalPropertyValue -InputObject $VisualStyle -Name 'camera_language' -DefaultValue '')
        negative_prompt = [string](Get-CfOptionalPropertyValue -InputObject $VisualStyle -Name 'negative_prompt' -DefaultValue '')
    }
    $candidateJson = ConvertTo-Json -InputObject @($Candidates) -Depth 30 -Compress
    $styleJson = ConvertTo-Json -InputObject $styleSummary -Depth 10 -Compress

    $systemPrompt = @'
Ты — технический арт-директор коротких вертикальных видео. Исправляй ТОЛЬКО визуальную согласованность перечисленных сцен. Не меняй scene_id, asset_type, voiceover_text, длительность, факты, текст сценария или другие поля пакета. Верни только JSON по схеме.

ИЕРАРХИЯ: voiceover_text задаёт смысл сцены; visual_purpose формулирует один конкретный видимый образ для этой мысли; visual_anchor_terms фиксируют главные сюжетные объекты; image_prompt описывает статичную композицию; video_prompt/motion_prompt описывает только разрешённый маршрут.

ЯКОРЯ:
- Верни 2–5 коротких английских именных групп, дословно присутствующих одновременно в visual_purpose и image_prompt.
- Для ai_video каждый якорь должен дословно присутствовать и в video_prompt.
- Якоря — только главные сюжетные предметы/субъекты, которые зритель должен заметить в этой конкретной сцене. Это НЕ continuity metadata.
- Canonical description персонажа (лицо, возрастной облик, волосы, одежда) сохраняй отдельно как continuity details в image_prompt/video_prompt. Никогда не превращай внешность/одежду персонажа в anchors, если сам visual_purpose не является портретным планом, где персонаж — главный сюжетный объект.
- Пример: если visual_purpose говорит "A nearly empty wallet casts a heavy shadow", anchors должны описывать wallet и shadow. "sophisticated man" или "charcoal turtleneck" не являются anchors, даже если персонаж присутствует на заднем плане.
- Не используй пустые/декоративные якоря вроде abstract background, dark void, cinematic lighting или gold checkmark, если они не являются центральной частью visual_purpose и не показаны в кадре.
- Если purpose сформулирован слишком общо, уточни его одной конкретной фразой, не меняя смысл voiceover_text. Якоря затем возьми из обновлённого visual_purpose и включи дословно в image_prompt.

КОМПОЗИЦИЯ:
- image_prompt должен однозначно показывать указанные якоря: передний план, главный объект/субъект, фон, крупность и состояние.
- Не добавляй предметы, не связанные с voiceover_text или visual_purpose.
- Сохраняй цветовую палитру, свет и continuity descriptions, переданные во входе.

МАРШРУТЫ (asset_type из входа неизменяем):
- ai_video: video_prompt содержит все сюжетные anchors и одно простое наблюдаемое физическое действие субъекта/объекта, например wallet slowly opens, person turns, coin falls. Одно движение камеры (zoom/pan/push-in) НЕ является действием для Wan. motion_prompt и motion_target пустые.
- image_animation: video_prompt ОБЯЗАТЕЛЬНО пустая строка. motion_target — ровно один anchor, дословно присутствующий в image_prompt и motion_prompt. motion_prompt описывает ТОЛЬКО движение камеры к/от/вокруг этого видимого объекта; не двигай содержимое изображения.
- motion_graphic: image_prompt описывает чистую композицию без генерируемых надписей; motion_prompt описывает движение графических элементов; motion_target пустой; video_prompt пустой.
- generated_image и stock_or_archive: video_prompt, motion_prompt и motion_target пустые.
- Не копируй video_prompt из исходного кандидата, если маршрут image_animation. Не копируй motion_prompt в ai_video.
- Не меняй asset_type. Не придумывай цены, статистику, источники или новые фактические утверждения.

Если visual_purpose и voiceover_text конфликтуют, выбери визуальный образ, который прямо иллюстрирует voiceover_text, и переформулируй visual_purpose без добавления новой информации.
'@

    $userPrompt = @"
ГЛОБАЛЬНЫЙ ВИЗУАЛЬНЫЙ СТИЛЬ:
$styleJson

СЦЕНЫ, ТРЕБУЮЩИЕ ИСПРАВЛЕНИЯ:
$candidateJson

Верни массив scenes с исправленными полями только для перечисленных scene_id. Не возвращай другие сцены. Не меняй тип ресурса. Проверь для каждого scene_id цепочку visual_purpose → visual_anchor_terms → image_prompt → video_prompt/motion_prompt. Все соответствия должны быть дословными там, где это требует контракт.
Правила дословности: якорь копируется в visual_purpose и image_prompt побуквенно, одной и той же фразой, без запятых внутри фразы-якоря. visual_purpose и image_prompt не ссылаются на другие сцены («из первой сцены», «как раньше», «same as before»): каждый кадр описывается полностью сам по себе.
"@

    if (-not [string]::IsNullOrWhiteSpace($PreviousFailure)) {
        # Retry with feedback: an identical prompt at temperature 0 would reproduce the same rejected answer.
        $userPrompt += @"


ПРЕДЫДУЩАЯ ПОПЫТКА ОТКЛОНЕНА автоматической проверкой по причине:
$PreviousFailure
Исправь именно эту причину. Не повторяй отклонённый ответ. Если якорь не помещается в естественный image_prompt — замени якорь более короткой фразой и сначала впиши её в visual_purpose.
"@
    }

    # v2.3: use the same num_ctx as the main call. Ollama restarts the model runner when num_ctx changes
    # (a 12B model takes tens of seconds to load), so a smaller repair context made every repair call slow.
    $repairContext = $ContextTokens
    $response = Invoke-CfOllamaChat `
        -BaseUrl $BaseUrl `
        -Model $Model `
        -SystemPrompt $systemPrompt `
        -UserPrompt $userPrompt `
        -JsonSchema $schema `
        -Temperature $Temperature `
        -ContextTokens $repairContext `
        -MaxOutputTokens 4000 `
        -ThinkingMode $false `
        -TimeoutSeconds $TimeoutSeconds

    $message = Get-CfOptionalPropertyValue -InputObject $response -Name 'message' -DefaultValue $null
    $content = [string](Get-CfOptionalPropertyValue -InputObject $message -Name 'content' -DefaultValue '')
    $doneReason = [string](Get-CfOptionalPropertyValue -InputObject $response -Name 'done_reason' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($content) -or $doneReason -eq 'length') {
        throw "Gemma не завершила ремонт визуальной согласованности: done_reason='$doneReason', content_chars=$($content.Length)."
    }

    try {
        $parsed = $content | ConvertFrom-Json -Depth 40
    }
    catch {
        throw "Gemma вернула некорректный JSON при ремонте визуальных сцен: $($_.Exception.Message)"
    }
    if ($null -eq $parsed.PSObject.Properties['scenes'] -or $parsed.scenes -isnot [array]) {
        throw 'Gemma не вернула массив scenes при ремонте визуальной согласованности.'
    }
    return @($parsed.scenes)
}


function Invoke-CfOllamaPlan {
    <#
    .SYNOPSIS
        Stage 1 ("think longer"): free-text editorial plan with thinking enabled and NO JSON schema.

    .DESCRIPTION
        Combining think=true with a large JSON schema made Gemma spend the whole num_predict budget
        on reasoning (done_reason=length, empty content; see projects/diagnostics). The fix is to split
        the work: this call may reason as long as it needs and returns a plain-text plan; the structured
        JSON call that follows stays at think=false and only has to formalise the plan.
        The plan is optional. On any failure the function returns $null so the main run can continue.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Topic,
        [Parameter(Mandatory)][int]$DurationSeconds,
        [Parameter(Mandatory)][string]$Audience,
        [Parameter(Mandatory)][string]$Style,
        [Parameter(Mandatory)][string]$SourceNotes,
        [Parameter(Mandatory)][int]$MaxScenes,
        [Parameter(Mandatory)][object]$ThinkingMode,
        [Parameter(Mandatory)][double]$Temperature,
        [Parameter(Mandatory)][int]$ContextTokens,
        [Parameter(Mandatory)][int]$MaxOutputTokens,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $systemPrompt = @'
Ты — шеф-редактор коротких вертикальных видео на русском языке. Твоя задача — не писать JSON, а ПРОДУМАТЬ ролик: выбрать сильный угол, проверить логику и составить рабочий план для режиссёра. Рассуждай подробно, критикуй собственные идеи и выбирай лучшую.

Правила:
- Интернета нет. Не выдумывай цифры, исследования, имена, даты, цитаты. Если сильный тезис требует источника, пометь его «НУЖЕН ИСТОЧНИК» или замени осторожной формулировкой.
- Каждый тезис должен логически следовать из предыдущего. Проверь причинно-следственные связи: не выдавай корреляцию за причину и метафору за факт.
- Один ролик — одна центральная мысль.
- Образы должны быть простыми: один понятный предмет в кадре, который можно сгенерировать картинкой. Без текста в кадре, без сложной физики, без нескольких людей.

Верни ответ строго в такой структуре обычного текста (без JSON и без Markdown-таблиц):

УГОЛ: один из 3 рассмотренных вариантов и почему он лучший (2–3 предложения)
ЦЕНТРАЛЬНАЯ МЫСЛЬ: одно предложение
ЗАЦЕПКА: 3 варианта первой фразы, затем выбранный
ЛОГИКА: 4–6 шагов, каждый — одно проверяемое по смыслу утверждение
ОСТОРОЖНО: что в этой теме легко сказать неверно или слишком категорично; как сформулировать безопасно
СЦЕНЫ: нумерованный список сцен; для каждой — смысл фразы (по-русски), один конкретный видимый предмет (по-английски, 2–4 слова без запятых), рекомендуемый маршрут: generated_image / image_animation / motion_graphic / ai_video
САМОКРИТИКА: 3 слабых места плана и как они исправлены
'@

    $userPrompt = @"
ТЕМА: $Topic
ДЛИТЕЛЬНОСТЬ ОЗВУЧКИ: около $DurationSeconds секунд
МАКСИМУМ СЦЕН: $MaxScenes
АУДИТОРИЯ: $Audience
СТИЛЬ АВТОРА: $Style

МАТЕРИАЛЫ ПОЛЬЗОВАТЕЛЯ:
$SourceNotes

Составь план по заданной структуре.
"@

    try {
        $response = Invoke-CfOllamaChat `
            -BaseUrl $BaseUrl `
            -Model $Model `
            -SystemPrompt $systemPrompt `
            -UserPrompt $userPrompt `
            -Temperature $Temperature `
            -ContextTokens $ContextTokens `
            -MaxOutputTokens $MaxOutputTokens `
            -ThinkingMode $ThinkingMode `
            -TimeoutSeconds $TimeoutSeconds
    }
    catch {
        Write-Warning "Этап планирования не выполнен: $($_.Exception.Message)"
        return $null
    }

    $message = Get-CfOptionalPropertyValue -InputObject $response -Name 'message' -DefaultValue $null
    $content = [string](Get-CfOptionalPropertyValue -InputObject $message -Name 'content' -DefaultValue '')
    $doneReason = [string](Get-CfOptionalPropertyValue -InputObject $response -Name 'done_reason' -DefaultValue '')
    $thinkingChars = ([string](Get-CfOptionalPropertyValue -InputObject $message -Name 'thinking' -DefaultValue '')).Length

    if ([string]::IsNullOrWhiteSpace($content)) {
        Write-Warning "Этап планирования не дал текста плана (done_reason='$doneReason', thinking_chars=$thinkingChars). Увеличь planning.max_output_tokens или выключи planning.enabled. Основной проход продолжится без плана."
        return $null
    }
    if ($doneReason -eq 'length') {
        # A truncated plan is still useful, but the reader must know it is incomplete.
        Write-Warning 'План остановлен по лимиту токенов (done_reason=length) и может быть неполным; увеличь planning.max_output_tokens.'
    }

    return $content.Trim()
}

function Invoke-CfOllamaUnload {
    <#
    .SYNOPSIS
        Frees the VRAM held by the Ollama model (keep_alive=0) so ComfyUI/TTS can use the GPU.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Model
    )

    $body = @{ model = $Model; keep_alive = 0 } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $uri = '{0}/api/generate' -f $BaseUrl.TrimEnd('/')
    try {
        $null = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 30
        return $true
    }
    catch {
        Write-Warning "Не удалось выгрузить модель из памяти: $($_.Exception.Message)"
        return $false
    }
}

Export-ModuleMember -Function Get-CfOllamaModels, Invoke-CfOllamaChat, Get-CfOptionalPropertyValue, Invoke-CfOllamaClaimExcerptRepair, Invoke-CfOllamaVisualSceneRepair, Invoke-CfOllamaPlan, Invoke-CfOllamaUnload
