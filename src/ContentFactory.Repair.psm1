Set-StrictMode -Version Latest

function Get-CfrPropertyValue {
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

function Set-CfrPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Value
    )

    # ConvertFrom-Json does not create optional properties that are absent in source JSON.
    # Under StrictMode, assigning $InputObject.$Name would throw. Add a NoteProperty when
    # missing; otherwise update the existing property in place.
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        Add-Member -InputObject $InputObject -MemberType NoteProperty -Name $Name -Value $Value -Force
    }
    else {
        $property.Value = $Value
    }
}

function Add-CfHumanReviewNote {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Package,
        [Parameter(Mandatory)][string]$Note
    )

    if ([string]::IsNullOrWhiteSpace($Note)) { return }
    $property = $Package.PSObject.Properties['human_review']
    if ($null -eq $property -or $null -eq $property.Value -or $property.Value -isnot [array]) {
        throw 'Нельзя добавить human_review: в пакете отсутствует корректный массив human_review.'
    }

    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($property.Value)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$item)) { $items.Add([string]$item) }
    }
    if (-not $items.Contains($Note)) { $items.Add($Note) }
    $Package.human_review = @($items.ToArray())
}


function ConvertTo-CfrComparableText {
    # Case-, punctuation- and whitespace-insensitive form used for literal phrase checks.
    # The canonical description "A worn, leather brown wallet" contains a comma, so the anchor
    # "worn leather brown wallet" was rejected as "missing" although all words and their order match.
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return ([regex]::Replace($Text.ToLowerInvariant(), '[^\p{L}\p{N}]+', ' ')).Trim()
}

function Test-CfrTextContainsPhrase {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string]$Text, [AllowEmptyString()][string]$Phrase)
    if ([string]::IsNullOrWhiteSpace($Phrase)) { return $false }
    $needle = ConvertTo-CfrComparableText -Text $Phrase
    if ($needle.Length -eq 0) { return $false }
    $haystack = ConvertTo-CfrComparableText -Text $Text
    return ($haystack.IndexOf($needle, [System.StringComparison]::Ordinal) -ge 0)
}

function Remove-CfHumanReviewNotes {
    # Removes stale automatic notes (for example "repair not applied") after a later retry succeeded.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Package,
        [Parameter(Mandatory)][string]$Pattern
    )
    $property = $Package.PSObject.Properties['human_review']
    if ($null -eq $property -or $null -eq $property.Value -or $property.Value -isnot [array]) { return }
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($property.Value)) {
        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match $Pattern) { continue }
        $kept.Add($text)
    }
    $Package.human_review = @($kept.ToArray())
}


function Get-CfrNormalizedWhitespace {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    return ([regex]::Replace([string]$Text, '\s+', ' ')).Trim()
}

function Repair-CfrSceneNarration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Package)

    $scriptObject = Get-CfrPropertyValue -InputObject $Package -Name 'script' -DefaultValue $null
    $fullText = [string](Get-CfrPropertyValue -InputObject $scriptObject -Name 'full_text' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($fullText)) { return @() }

    $scenesProperty = $Package.PSObject.Properties['scenes']
    if ($null -eq $scenesProperty -or $null -eq $scenesProperty.Value -or $scenesProperty.Value -isnot [array]) {
        throw 'Синхронизация озвучки остановлена: scenes отсутствует или не является массивом.'
    }
    $scenes = @($scenesProperty.Value)
    if ($scenes.Count -lt 1) { throw 'Синхронизация озвучки остановлена: scenes пуст.' }

    $currentParts = [System.Collections.Generic.List[string]]::new()
    foreach ($scene in $scenes) {
        $currentParts.Add([string](Get-CfrPropertyValue -InputObject $scene -Name 'voiceover_text' -DefaultValue ''))
    }
    $currentJoined = [string]::Join(' ', [string[]]$currentParts.ToArray())
    if ((Get-CfrNormalizedWhitespace $currentJoined) -ceq (Get-CfrNormalizedWhitespace $fullText)) {
        return @()
    }

    # Keep script.full_text as the single source of truth. Re-segment its exact words
    # across existing scenes; do not ask the model to paraphrase or invent narration.
    $normalizedScript = Get-CfrNormalizedWhitespace $fullText
    $tokens = @([regex]::Matches($normalizedScript, '\S+') | ForEach-Object { $_.Value })
    if ($tokens.Count -lt $scenes.Count) {
        throw ('Синхронизация озвучки остановлена: в сценарии {0} словесных фрагментов, но сцен {1}. Нельзя заполнить все сцены без пустой озвучки.' -f $tokens.Count, $scenes.Count)
    }

    $weights = [double[]]::new($scenes.Count)
    $weightTotal = 0.0
    for ($i = 0; $i -lt $scenes.Count; $i++) {
        $duration = Get-CfrPropertyValue -InputObject $scenes[$i] -Name 'duration_seconds' -DefaultValue 1
        $weight = 1.0
        try {
            if ($null -ne $duration -and [double]$duration -gt 0) { $weight = [double]$duration }
        }
        catch { $weight = 1.0 }
        $weights[$i] = $weight
        $weightTotal += $weight
    }
    if ($weightTotal -le 0) {
        for ($i = 0; $i -lt $weights.Length; $i++) { $weights[$i] = 1.0 }
        $weightTotal = [double]$weights.Length
    }

    $sentenceBoundaries = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt ($tokens.Count - 1); $i++) {
        if ([string]$tokens[$i] -match '[.!?…]["\u00BB\u201D\u2019)]*$') {
            $sentenceBoundaries.Add($i + 1)
        }
    }
    # Sentence-aware cuts are used only when there are enough sentence ends to
    # create at least one segment per scene. Otherwise use balanced word cuts.
    $useSentenceBoundaries = ($sentenceBoundaries.Count -ge ($scenes.Count - 1))

    $segments = [string[]]::new($scenes.Count)
    $previousBoundary = 0
    $cumulativeWeight = 0.0
    for ($sceneIndex = 0; $sceneIndex -lt ($scenes.Count - 1); $sceneIndex++) {
        $cumulativeWeight += $weights[$sceneIndex]
        $minimumBoundary = $previousBoundary + 1
        $maximumBoundary = $tokens.Count - ($scenes.Count - $sceneIndex - 1)
        $targetBoundary = [int][Math]::Round(($tokens.Count * $cumulativeWeight / $weightTotal), 0, [MidpointRounding]::AwayFromZero)
        if ($targetBoundary -lt $minimumBoundary) { $targetBoundary = $minimumBoundary }
        if ($targetBoundary -gt $maximumBoundary) { $targetBoundary = $maximumBoundary }

        $bestBoundary = -1
        $bestDistance = [int]::MaxValue
        if ($useSentenceBoundaries) {
            foreach ($candidate in $sentenceBoundaries) {
                if ($candidate -lt $minimumBoundary -or $candidate -gt $maximumBoundary) { continue }
                $distance = [Math]::Abs($candidate - $targetBoundary)
                if ($distance -lt $bestDistance) {
                    $bestDistance = $distance
                    $bestBoundary = $candidate
                }
            }
        }
        if ($bestBoundary -lt 0) { $bestBoundary = $targetBoundary }

        $part = @($tokens[$previousBoundary..($bestBoundary - 1)])
        $segments[$sceneIndex] = [string]::Join(' ', [string[]]$part)
        $previousBoundary = $bestBoundary
    }
    $lastPart = @($tokens[$previousBoundary..($tokens.Count - 1)])
    $segments[$scenes.Count - 1] = [string]::Join(' ', [string[]]$lastPart)

    for ($i = 0; $i -lt $scenes.Count; $i++) {
        $property = $scenes[$i].PSObject.Properties['voiceover_text']
        if ($null -eq $property) {
            $scenes[$i] | Add-Member -NotePropertyName 'voiceover_text' -NotePropertyValue $segments[$i] -Force
        }
        else {
            $scenes[$i].voiceover_text = $segments[$i]
        }
    }

    return @("Озвучка сцен синхронизирована с script.full_text: текст без перефразирования распределён по $($scenes.Count) сценам; визуальное соответствие требует ручной проверки.")
}

function Repair-CfrCameraPromptConflicts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Package)

    $visualStyle = Get-CfrPropertyValue -InputObject $Package -Name 'visual_style' -DefaultValue $null
    $negativePrompt = [string](Get-CfrPropertyValue -InputObject $visualStyle -Name 'negative_prompt' -DefaultValue '')
    if ($negativePrompt -notmatch '(?i)(camera\s*shakes?|shaky[\s-]*cam(?:era)?|hand[\s-]*held)') { return @() }

    $changes = [System.Collections.Generic.List[string]]::new()
    $scenesProperty = $Package.PSObject.Properties['scenes']
    if ($null -eq $scenesProperty -or $null -eq $scenesProperty.Value -or $scenesProperty.Value -isnot [array]) { return @() }

    $replacements = @(
        @{ Pattern = '(?i)\b(?:subtle|gentle|slight|mild|small|minor)\s+camera\s+shakes?\b'; Value = 'subtle stabilized camera movement' },
        @{ Pattern = '(?i)\bcamera\s+shakes?\b'; Value = 'smooth stabilized camera movement' },
        @{ Pattern = '(?i)\bshaky[\s-]*camera\b'; Value = 'stabilized camera' },
        @{ Pattern = '(?i)\bshaky[\s-]*cam\b'; Value = 'stabilized camera' },
        @{ Pattern = '(?i)\bhand[\s-]*held(?:\s+(?:camera|shot|footage|video|style|look))?\b'; Value = 'stabilized' },
        @{ Pattern = '(?i)\bcamera\s+is\s+shaking\b'; Value = 'camera moves smoothly' },
        @{ Pattern = '(?i)\bshaking\s+camera\b'; Value = 'smooth camera movement' }
    )

    foreach ($scene in @($scenesProperty.Value)) {
        $sceneId = Get-CfrPropertyValue -InputObject $scene -Name 'scene_id' -DefaultValue '?'
        $changedFields = [System.Collections.Generic.List[string]]::new()
        foreach ($fieldName in @('image_prompt', 'video_prompt', 'motion_prompt')) {
            $property = $scene.PSObject.Properties[$fieldName]
            if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { continue }
            $original = [string]$property.Value
            $repaired = $original
            foreach ($rule in $replacements) {
                $repaired = [regex]::Replace($repaired, [string]$rule.Pattern, [string]$rule.Value)
            }
            if ($repaired -cne $original) {
                $scene.$fieldName = $repaired
                $changedFields.Add($fieldName)
            }
        }
        if ($changedFields.Count -gt 0) {
            $change = "Сцена ${sceneId}: противоречащая negative_prompt формулировка движения камеры заменена на стабилизированное движение в полях $($changedFields -join ', ')."
            $changes.Add("$change Проверь, что художественный замысел кадра сохранился.")
        }
    }
    return @($changes.ToArray())
}



function Get-CfrLocalWordCount {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }
    return [int][regex]::Matches($Text, "[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*").Count
}

function Repair-CfrSpeechPacing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Scenes,
        [Parameter(Mandatory)][ValidateRange(15,180)][int]$TargetDurationSeconds,
        [double]$MinimumSeconds = 1.0,
        [double]$MaximumSeconds = 30.0
    )

    $count = @($Scenes).Count
    if ($count -lt 1) { throw 'Распределение речевого темпа остановлено: список сцен пуст.' }
    if ($TargetDurationSeconds -lt ($count * $MinimumSeconds) -or $TargetDurationSeconds -gt ($count * $MaximumSeconds)) {
        throw 'Распределение речевого темпа невозможно: число сцен не помещается в допустимый диапазон длительности.'
    }

    $weights = [double[]]::new($count)
    $weightTotal = 0.0
    for ($i = 0; $i -lt $count; $i++) {
        $text = [string](Get-CfrPropertyValue -InputObject $Scenes[$i] -Name 'voiceover_text' -DefaultValue '')
        $words = Get-CfrLocalWordCount -Text $text
        $sentenceEnds = [regex]::Matches($text, '[.!?…]+').Count
        # Add a small pause allowance for sentence boundaries, not for every comma.
        $weight = [double]$words + (0.35 * [double]$sentenceEnds)
        if ($weight -le 0) { $weight = 1.0 }
        $weights[$i] = $weight
        $weightTotal += $weight
    }

    $low = 0.0
    $high = [Math]::Max(1.0, ($TargetDurationSeconds / $weightTotal) * 2.0)
    for ($expand = 0; $expand -lt 64; $expand++) {
        $totalAtHigh = 0.0
        foreach ($weight in $weights) { $totalAtHigh += [Math]::Min($MaximumSeconds, [Math]::Max($MinimumSeconds, ($weight * $high))) }
        if ($totalAtHigh -ge $TargetDurationSeconds) { break }
        $high *= 2.0
    }
    for ($iteration = 0; $iteration -lt 80; $iteration++) {
        $mid = ($low + $high) / 2.0
        $candidateTotal = 0.0
        foreach ($weight in $weights) { $candidateTotal += [Math]::Min($MaximumSeconds, [Math]::Max($MinimumSeconds, ($weight * $mid))) }
        if ($candidateTotal -lt $TargetDurationSeconds) { $low = $mid } else { $high = $mid }
    }

    $allocated = [System.Collections.Generic.List[decimal]]::new()
    for ($i = 0; $i -lt $count; $i++) {
        $seconds = [Math]::Min($MaximumSeconds, [Math]::Max($MinimumSeconds, ($weights[$i] * (($low + $high) / 2.0))))
        $allocated.Add([decimal]::Round([decimal]$seconds, 2, [MidpointRounding]::AwayFromZero))
    }

    $sum = [decimal]0
    foreach ($value in $allocated) { $sum += $value }
    $cents = [int][decimal]::Round((([decimal]$TargetDurationSeconds - $sum) * [decimal]100), 0, [MidpointRounding]::AwayFromZero)
    while ($cents -ne 0) {
        $best = -1
        $bestWeight = [double]::NegativeInfinity
        for ($i = 0; $i -lt $count; $i++) {
            $slack = if ($cents -gt 0) { [decimal]$MaximumSeconds - $allocated[$i] } else { $allocated[$i] - [decimal]$MinimumSeconds }
            if ($slack -ge [decimal]0.01 -and $weights[$i] -gt $bestWeight) { $best = $i; $bestWeight = $weights[$i] }
        }
        if ($best -lt 0) { throw 'Не удалось распределить остаток округления по речевым длительностям без нарушения лимитов сцен.' }
        if ($cents -gt 0) { $allocated[$best] += [decimal]0.01; $cents-- }
        else { $allocated[$best] -= [decimal]0.01; $cents++ }
    }

    $changed = $false
    for ($i = 0; $i -lt $count; $i++) {
        $old = [double](Get-CfrPropertyValue -InputObject $Scenes[$i] -Name 'duration_seconds' -DefaultValue 0)
        $new = [double]$allocated[$i]
        if ([Math]::Abs($old - $new) -ge 0.01) { $changed = $true }
        $Scenes[$i].duration_seconds = $new
    }
    if ($changed) {
        return ('Длительности сцен перераспределены по количеству слов и границам предложений: целевой темп выровнен; точная сумма {0:N2} с.' -f $TargetDurationSeconds)
    }
    return $null
}

function Repair-CfrAiVideoBudget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Package,
        [Parameter(Mandatory)][object[]]$Scenes,
        [ValidateRange(0,20)][int]$MaximumAiVideoScenes = 2
    )

    $sceneArray = @($Scenes)
    $sceneCount = $sceneArray.Count
    $aiIndices = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $sceneCount; $i++) {
        if ([string](Get-CfrPropertyValue -InputObject $sceneArray[$i] -Name 'asset_type' -DefaultValue '') -eq 'ai_video') {
            $aiIndices.Add($i)
        }
    }
    if ($aiIndices.Count -eq 0) { return @() }
    if ($MaximumAiVideoScenes -eq 0) {
        # A zero-video profile is valid: every AI-video scene becomes a still plus camera move.
        $keep = [System.Collections.Generic.HashSet[int]]::new()
    }
    else {
        # The local profile reserves Wan for the actual opening and closing scenes,
        # not merely the first/last entries among whichever scenes Gemma happened to label ai_video.
        $keep = [System.Collections.Generic.HashSet[int]]::new()
        if ($sceneCount -gt 0 -and [string](Get-CfrPropertyValue -InputObject $sceneArray[0] -Name 'asset_type' -DefaultValue '') -eq 'ai_video') {
            [void]$keep.Add(0)
        }
        $lastIndex = $sceneCount - 1
        if ($MaximumAiVideoScenes -ge 2 -and $lastIndex -ge 0 -and [string](Get-CfrPropertyValue -InputObject $sceneArray[$lastIndex] -Name 'asset_type' -DefaultValue '') -eq 'ai_video') {
            [void]$keep.Add($lastIndex)
        }

        # For explicitly larger profiles (>2), fill remaining capacity with interior AI scenes
        # in script order. The default two-scene profile never spends Wan on middle scenes.
        if ($MaximumAiVideoScenes -gt 2) {
            foreach ($index in $aiIndices) {
                if ($keep.Count -ge $MaximumAiVideoScenes) { break }
                [void]$keep.Add([int]$index)
            }
        }
    }

    $notes = [System.Collections.Generic.List[string]]::new()
    foreach ($index in $aiIndices) {
        if ($keep.Contains([int]$index)) { continue }
        $scene = $sceneArray[$index]
        $sceneId = Get-CfrPropertyValue -InputObject $scene -Name 'scene_id' -DefaultValue ($index + 1)
        $imagePrompt = [string](Get-CfrPropertyValue -InputObject $scene -Name 'image_prompt' -DefaultValue '')
        $visualPurpose = [string](Get-CfrPropertyValue -InputObject $scene -Name 'visual_purpose' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($imagePrompt)) {
            throw "Сцену $sceneId нельзя перевести в image_animation: image_prompt пуст."
        }

        $anchors = @(Get-CfrPropertyValue -InputObject $scene -Name 'visual_anchor_terms' -DefaultValue @())
        # At this early normalization stage visual_purpose may still need the second-pass
        # repair. Select a camera target only from an anchor already visible in image_prompt;
        # the strict purpose/anchor relationship is checked after the scene-level Gemma pass.
        $usableTargets = @($anchors | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_) -and
            (Test-CfrTextContainsPhrase -Text $imagePrompt -Phrase ([string]$_))
        })
        if ($usableTargets.Count -eq 0) {
            # If the current prompt has no reliable visible anchor, do not invent a camera target.
            # Downgrade to a still image so the scene-level Gemma pass can repair its composition.
            Set-CfrPropertyValue -InputObject $scene -Name 'asset_type' -Value 'generated_image'
            Set-CfrPropertyValue -InputObject $scene -Name 'video_prompt' -Value ''
            Set-CfrPropertyValue -InputObject $scene -Name 'motion_prompt' -Value ''
            Set-CfrPropertyValue -InputObject $scene -Name 'motion_target' -Value ''
            $note = "Сцена ${sceneId}: промежуточная ai_video-сцена переведена в generated_image: исходный image_prompt не содержит ни одного подтверждённого visual anchor для безопасного camera-only движения. Gemma может исправить композицию; motion target не выдумывался. Проверь кадр вручную."
            Add-CfHumanReviewNote -Package $Package -Note $note
            $notes.Add($note)
            continue
        }

        $target = [string]$usableTargets[0]
        Set-CfrPropertyValue -InputObject $scene -Name 'asset_type' -Value 'image_animation'
        Set-CfrPropertyValue -InputObject $scene -Name 'video_prompt' -Value ''
        Set-CfrPropertyValue -InputObject $scene -Name 'motion_target' -Value $target
        Set-CfrPropertyValue -InputObject $scene -Name 'motion_prompt' -Value "Slow stabilized camera push-in toward $target; camera movement only; keep all visible people and objects static and unchanged."

        $note = "Сцена ${sceneId}: промежуточная ai_video-сцена переведена в image_animation, поскольку локальный профиль сохраняет Wan только для первой/последней сцены. Используй FFmpeg camera-only animation; motion_target='$target'. Проверь, что статичный исходный кадр передаёт весь смысл сцены."
        Add-CfHumanReviewNote -Package $Package -Note $note
        $notes.Add($note)
    }
    return @($notes.ToArray())
}

function Repair-CfrEditingDefaults {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Package)
    $editing = Get-CfrPropertyValue -InputObject $Package -Name 'editing_plan' -DefaultValue $null
    if ($null -eq $editing) { return $null }
    $defaults = [ordered]@{
        subtitle_font_family = 'Noto Sans'
        subtitle_font_size_px = 54
        subtitle_max_chars_per_line = 32
        subtitle_safe_margin_percent = 8
        subtitle_highlight_color = '#D6B45C'
        voice_target_lufs = -16.0
        music_target_lufs = -29.0
        music_ducking_db = -14.0
        audio_true_peak_dbfs = -1.0
    }
    $added = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $defaults.Keys) {
        $prop = $editing.PSObject.Properties[$key]
        if ($null -eq $prop -or $null -eq $prop.Value) {
            $editing | Add-Member -MemberType NoteProperty -Name $key -Value $defaults[$key] -Force
            $added.Add($key)
        }
    }
    if ($added.Count -gt 0) { return ('Добавлены производственные настройки субтитров/звука по профилю v2.2: {0}. Проверь уровни громкости на тестовом WAV.' -f ($added -join ', ')) }
    return $null
}

function Repair-CfrCharacterReferenceAssets {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Package, [Parameter(Mandatory)][object[]]$Scenes)

    $visualStyle = Get-CfrPropertyValue -InputObject $Package -Name 'visual_style' -DefaultValue $null
    $entitiesProperty = $null
    if ($null -ne $visualStyle) { $entitiesProperty = $visualStyle.PSObject.Properties['continuity_entities'] }
    if ($null -eq $entitiesProperty -or $null -eq $entitiesProperty.Value) { return @() }

    $notes = [System.Collections.Generic.List[string]]::new()
    foreach ($entity in @($entitiesProperty.Value)) {
        if ([string](Get-CfrPropertyValue -InputObject $entity -Name 'entity_type' -DefaultValue '') -ne 'person') { continue }
        $entityId = [string](Get-CfrPropertyValue -InputObject $entity -Name 'entity_id' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($entityId)) { continue }

        $referenceCount = 0
        foreach ($scene in $Scenes) {
            $ids = @(Get-CfrPropertyValue -InputObject $scene -Name 'continuity_entity_ids' -DefaultValue @())
            if (@($ids | Where-Object { [string]$_ -ieq $entityId }).Count -gt 0) { $referenceCount++ }
        }
        if ($referenceCount -lt 2) { continue }

        $canonical = [string](Get-CfrPropertyValue -InputObject $entity -Name 'canonical_description' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($canonical)) { continue }

        $assetPath = "assets/characters/${entityId}_reference.png"
        $pathProperty = $entity.PSObject.Properties['reference_asset_path']
        if ($null -eq $pathProperty -or [string]::IsNullOrWhiteSpace([string]$pathProperty.Value)) {
            $entity | Add-Member -MemberType NoteProperty -Name 'reference_asset_path' -Value $assetPath -Force
        }
        else { $assetPath = [string]$pathProperty.Value }

        $promptProperty = $entity.PSObject.Properties['reference_image_prompt']
        if ($null -eq $promptProperty -or [string]::IsNullOrWhiteSpace([string]$promptProperty.Value)) {
            $referencePrompt = ($canonical.Trim() + ' Single-subject identity reference portrait, head-and-shoulders framing, face clearly visible, neutral relaxed expression, simple charcoal studio background, soft even key light, front three-quarter view, same exact clothing and facial features, vertical 9:16, no text, no watermark.')
            $entity | Add-Member -MemberType NoteProperty -Name 'reference_image_prompt' -Value $referencePrompt -Force
        }

        $note = "Повторяющийся персонаж '$entityId' используется в $referenceCount сценах. Создай и вручную утверди единый референс $assetPath по reference_image_prompt; используй его при генерации всех сцен с этой сущностью. Текстовое описание само по себе не гарантирует идентичность лица."
        Add-CfHumanReviewNote -Package $Package -Note $note
        $notes.Add($note)
    }
    return @($notes.ToArray())
}

function Repair-CfPackageStructure {
    <#
      Applies only deterministic, auditable normalizations:
      1) proportionally bounds initial scene durations to the requested runtime;
      2) copies canonical continuity descriptions into prompts for referenced entities;
      3) re-segments voiceover_text from script.full_text without changing wording;
      4) removes camera-motion wording forbidden by the global negative prompt;
      5) optionally reallocates time by word count and sentence boundaries;
      6) enforces the local Wan scene budget and fills editing defaults.
      It does not paraphrase narration or alter factual claims.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Package,
        [Parameter(Mandatory)][ValidateRange(15, 180)][int]$TargetDurationSeconds,
        [ValidateRange(0,20)][int]$MaxAiVideoScenes = 2,
        [switch]$RebalanceTimingBySpeech
    )

    $changes = [System.Collections.Generic.List[string]]::new()
    $scenesProperty = $Package.PSObject.Properties['scenes']
    if ($null -eq $scenesProperty -or $null -eq $scenesProperty.Value -or $scenesProperty.Value -isnot [array]) {
        throw 'Автонормализация остановлена: scenes отсутствует или не является массивом.'
    }
    $scenes = @($scenesProperty.Value)
    if ($scenes.Count -lt 1) { throw 'Автонормализация остановлена: scenes пуст.' }

    # Timing normalization: bounded proportional scaling.
    # Each scene must remain in [1, 30] seconds. We solve for one common scale
    # factor while clamping scenes at those bounds, so a long scene cannot exceed
    # 30 seconds after normalization. Rounding residue is distributed in 0.01s steps.
    $durations = [System.Collections.Generic.List[decimal]]::new()
    $total = [decimal]0
    $hasOutOfRangeDuration = $false
    foreach ($scene in $scenes) {
        $durationValue = Get-CfrPropertyValue -InputObject $scene -Name 'duration_seconds' -DefaultValue $null
        if ($null -eq $durationValue) {
            throw 'Автонормализация хронометража остановлена: обнаружена сцена без duration_seconds.'
        }
        try {
            $duration = [decimal]$durationValue
        }
        catch {
            throw 'Автонормализация хронометража остановлена: duration_seconds содержит нечисловое значение.'
        }
        if ($duration -le 0) {
            throw 'Автонормализация хронометража остановлена: обнаружена сцена без положительной duration_seconds.'
        }
        if ($duration -lt [decimal]1 -or $duration -gt [decimal]30) { $hasOutOfRangeDuration = $true }
        $durations.Add($duration)
        $total += $duration
    }

    $difference = [Math]::Abs([double]($total - [decimal]$TargetDurationSeconds))
    $needsTimingNormalization = ($difference -gt 0.01) -or $hasOutOfRangeDuration
    if ($needsTimingNormalization) {
        $sceneCount = $durations.Count
        $minimumPossible = [decimal]$sceneCount
        $maximumPossible = [decimal]($sceneCount * 30)
        if ([decimal]$TargetDurationSeconds -lt $minimumPossible -or [decimal]$TargetDurationSeconds -gt $maximumPossible) {
            throw ('Автонормализация хронометража остановлена: {0} сцен(ы) не могут вместить целевые {1} секунд при ограничении 1–30 секунд на сцену. Увеличь число сцен или измени длительность ролика.' -f $sceneCount, $TargetDurationSeconds)
        }

        # Reject large changes to the overall runtime; bounded scaling is only
        # intended to repair small timing drift and enforce per-scene limits.
        if ($difference -gt 0.01) {
            if ($total -le 0) { throw 'Автонормализация хронометража остановлена: сумма длительностей неположительная.' }
            $overallScale = [decimal]$TargetDurationSeconds / $total
            if ($overallScale -lt [decimal]0.85 -or $overallScale -gt [decimal]1.15) {
                throw ('Автонормализация хронометража остановлена: общая длительность требует изменения на {0:P1}. Это больше допустимых 15%; нужна повторная генерация или ручная правка.' -f ([double]$overallScale - 1.0))
            }
        }

        # Find a bounded common multiplier using binary search:
        # result[i] = min(30, max(1, original[i] * factor)).
        $lowFactor = [decimal]0
        $highFactor = [decimal]1
        $highTotal = [decimal]0
        for ($expand = 0; $expand -lt 100; $expand++) {
            $highTotal = [decimal]0
            foreach ($duration in $durations) {
                $candidate = $duration * $highFactor
                if ($candidate -lt [decimal]1) { $candidate = [decimal]1 }
                elseif ($candidate -gt [decimal]30) { $candidate = [decimal]30 }
                $highTotal += $candidate
            }
            if ($highTotal -ge [decimal]$TargetDurationSeconds) { break }
            $highFactor *= [decimal]2
        }
        if ($highTotal -lt [decimal]$TargetDurationSeconds) {
            throw 'Автонормализация хронометража остановлена: не удалось подобрать коэффициент в допустимых пределах.'
        }

        for ($iteration = 0; $iteration -lt 100; $iteration++) {
            $midFactor = ($lowFactor + $highFactor) / [decimal]2
            if ($midFactor -eq $lowFactor -or $midFactor -eq $highFactor) { break }

            $midTotal = [decimal]0
            foreach ($duration in $durations) {
                $candidate = $duration * $midFactor
                if ($candidate -lt [decimal]1) { $candidate = [decimal]1 }
                elseif ($candidate -gt [decimal]30) { $candidate = [decimal]30 }
                $midTotal += $candidate
            }

            if ($midTotal -lt [decimal]$TargetDurationSeconds) { $lowFactor = $midFactor }
            else { $highFactor = $midFactor }
        }

        $factor = ($lowFactor + $highFactor) / [decimal]2
        $scaled = [System.Collections.Generic.List[decimal]]::new()
        foreach ($duration in $durations) {
            $candidate = $duration * $factor
            if ($candidate -lt [decimal]1) { $candidate = [decimal]1 }
            elseif ($candidate -gt [decimal]30) { $candidate = [decimal]30 }
            $scaled.Add([decimal]::Round($candidate, 2, [MidpointRounding]::AwayFromZero))
        }

        # Correct cent-level rounding residue without violating scene limits.
        $scaledTotal = [decimal]0
        foreach ($value in $scaled) { $scaledTotal += $value }
        $remainderCents = [int][decimal]::Round((([decimal]$TargetDurationSeconds - $scaledTotal) * [decimal]100), 0, [MidpointRounding]::AwayFromZero)
        while ($remainderCents -ne 0) {
            $bestIndex = -1
            $bestSlack = [decimal]-1
            for ($index = 0; $index -lt $scaled.Count; $index++) {
                if ($remainderCents -gt 0) { $slack = [decimal]30 - $scaled[$index] }
                else { $slack = $scaled[$index] - [decimal]1 }
                if ($slack -gt $bestSlack -and $slack -ge [decimal]0.01) {
                    $bestSlack = $slack
                    $bestIndex = $index
                }
            }
            if ($bestIndex -lt 0) {
                throw 'Автонормализация хронометража остановлена: округление нельзя скорректировать без нарушения диапазона 1–30 секунд.'
            }
            if ($remainderCents -gt 0) {
                $scaled[$bestIndex] = $scaled[$bestIndex] + [decimal]0.01
                $remainderCents--
            }
            else {
                $scaled[$bestIndex] = $scaled[$bestIndex] - [decimal]0.01
                $remainderCents++
            }
        }

        $newTotal = [decimal]0
        for ($index = 0; $index -lt $scenes.Count; $index++) {
            if ($scaled[$index] -lt [decimal]1 -or $scaled[$index] -gt [decimal]30) {
                throw "Автонормализация хронометража остановлена: сцена $($index + 1) получила длительность $($scaled[$index]) с вне допустимого диапазона 1–30 секунд."
            }
            $scenes[$index].duration_seconds = [double]$scaled[$index]
            $newTotal += $scaled[$index]
        }
        if ($newTotal -ne [decimal]$TargetDurationSeconds) {
            throw "Автонормализация хронометража не смогла получить точную сумму. Получено: $newTotal секунд."
        }

        $note = ('Первичная нормализация хронометража: исходные длительности ограничены диапазоном 1–30 секунд; сумма изменена с {0:N2} до {1:N2} секунд. После создания WAV проверь фактические границы сцен.' -f [double]$total, [double]$TargetDurationSeconds)
        Add-CfHumanReviewNote -Package $Package -Note $note
        $changes.Add($note)
    }

    # Continuity normalization: the canonical entity description is prepended verbatim.
    $visualStyle = Get-CfrPropertyValue -InputObject $Package -Name 'visual_style' -DefaultValue $null
    $entityList = @(Get-CfrPropertyValue -InputObject $visualStyle -Name 'continuity_entities' -DefaultValue @())
    $entityMap = @{}
    foreach ($entity in $entityList) {
        $entityId = [string](Get-CfrPropertyValue -InputObject $entity -Name 'entity_id' -DefaultValue '')
        $canonical = [string](Get-CfrPropertyValue -InputObject $entity -Name 'canonical_description' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($entityId) -and -not [string]::IsNullOrWhiteSpace($canonical)) {
            $entityMap[$entityId] = $canonical
        }
    }

    foreach ($scene in $scenes) {
        $sceneId = Get-CfrPropertyValue -InputObject $scene -Name 'scene_id' -DefaultValue '?'
        $entityIds = @(Get-CfrPropertyValue -InputObject $scene -Name 'continuity_entity_ids' -DefaultValue @())
        foreach ($entityIdValue in $entityIds) {
            $entityId = [string]$entityIdValue
            if (-not $entityMap.ContainsKey($entityId)) { continue }
            $canonical = [string]$entityMap[$entityId]

            $imagePrompt = [string](Get-CfrPropertyValue -InputObject $scene -Name 'image_prompt' -DefaultValue '')
            if ($imagePrompt.IndexOf($canonical, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                $scene.image_prompt = ($canonical.Trim() + "`n" + $imagePrompt.Trim())
                $changes.Add("Сцена ${sceneId}: в image_prompt автоматически добавлено каноническое описание '$entityId'.")
            }

            $assetType = [string](Get-CfrPropertyValue -InputObject $scene -Name 'asset_type' -DefaultValue '')
            if ($assetType -eq 'ai_video') {
                $videoPrompt = [string](Get-CfrPropertyValue -InputObject $scene -Name 'video_prompt' -DefaultValue '')
                if ($videoPrompt.IndexOf($canonical, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    $scene.video_prompt = ($canonical.Trim() + "`n" + $videoPrompt.Trim())
                    $changes.Add("Сцена ${sceneId}: в video_prompt автоматически добавлено каноническое описание '$entityId'.")
                }
            }
        }
    }

    # v2.2: repeated people receive one reusable, manually approved reference-image asset.
    foreach ($referenceNote in @(Repair-CfrCharacterReferenceAssets -Package $Package -Scenes $scenes)) {
        $changes.Add([string]$referenceNote)
    }

    # Resolve two deterministic consistency failures before the strict validator:
    # narration segments are re-cut from the canonical script without paraphrasing,
    # and camera-motion prompts are sanitized when the global negative prompt forbids them.
    foreach ($narrationChange in @(Repair-CfrSceneNarration -Package $Package)) {
        $changes.Add($narrationChange)
    }
    foreach ($cameraChange in @(Repair-CfrCameraPromptConflicts -Package $Package)) {
        $changes.Add($cameraChange)
    }

    # v2.2: allocate scene time from the actual word count after narration has been synchronized.
    if ($RebalanceTimingBySpeech) {
        $pacingNote = Repair-CfrSpeechPacing -Scenes $scenes -TargetDurationSeconds $TargetDurationSeconds
        if (-not [string]::IsNullOrWhiteSpace([string]$pacingNote)) { $changes.Add([string]$pacingNote) }
    }

    # v2.2: keep Wan usage within the configured local hardware budget.
    foreach ($resourceNote in @(Repair-CfrAiVideoBudget -Package $Package -Scenes $scenes -MaximumAiVideoScenes $MaxAiVideoScenes)) {
        $changes.Add([string]$resourceNote)
    }

    $editingNote = Repair-CfrEditingDefaults -Package $Package
    if (-not [string]::IsNullOrWhiteSpace([string]$editingNote)) { $changes.Add([string]$editingNote) }

    foreach ($change in $changes) {
        if ($change -notmatch '^Автоматическая нормализация хронометража:') {
            Add-CfHumanReviewNote -Package $Package -Note $change
        }
    }

    return @($changes.ToArray())
}

function Get-CfrVisualSceneRepairCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Package)

    $scenes = @(Get-CfrPropertyValue -InputObject $Package -Name 'scenes' -DefaultValue @())
    $style = Get-CfrPropertyValue -InputObject $Package -Name 'visual_style' -DefaultValue $null
    $entities = @(Get-CfrPropertyValue -InputObject $style -Name 'continuity_entities' -DefaultValue @())
    $entityMap = @{}
    foreach ($entity in $entities) {
        $id = [string](Get-CfrPropertyValue -InputObject $entity -Name 'entity_id' -DefaultValue '')
        $canonical = [string](Get-CfrPropertyValue -InputObject $entity -Name 'canonical_description' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($id)) { $entityMap[$id] = $canonical }
    }

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($scene in $scenes) {
        if ($null -eq $scene) { continue }
        $sceneId = [int](Get-CfrPropertyValue -InputObject $scene -Name 'scene_id' -DefaultValue 0)
        $assetType = [string](Get-CfrPropertyValue -InputObject $scene -Name 'asset_type' -DefaultValue '')
        $purpose = [string](Get-CfrPropertyValue -InputObject $scene -Name 'visual_purpose' -DefaultValue '')
        $image = [string](Get-CfrPropertyValue -InputObject $scene -Name 'image_prompt' -DefaultValue '')
        $video = [string](Get-CfrPropertyValue -InputObject $scene -Name 'video_prompt' -DefaultValue '')
        $motion = [string](Get-CfrPropertyValue -InputObject $scene -Name 'motion_prompt' -DefaultValue '')
        $target = [string](Get-CfrPropertyValue -InputObject $scene -Name 'motion_target' -DefaultValue '')
        $anchors = @(Get-CfrPropertyValue -InputObject $scene -Name 'visual_anchor_terms' -DefaultValue @())
        $issues = [System.Collections.Generic.List[string]]::new()

        if ([string]::IsNullOrWhiteSpace($purpose)) { $issues.Add('visual_purpose is empty') }
        if ($anchors.Count -lt 2 -or $anchors.Count -gt 5) { $issues.Add('visual_anchor_terms must contain 2-5 entries') }
        foreach ($anchorValue in $anchors) {
            $anchor = [string]$anchorValue
            if ([string]::IsNullOrWhiteSpace($anchor)) {
                $issues.Add('an anchor is empty')
                continue
            }
            if (-not (Test-CfrTextContainsPhrase -Text $purpose -Phrase $anchor)) { $issues.Add("anchor '$anchor' is not a literal substring of visual_purpose") }
            if (-not (Test-CfrTextContainsPhrase -Text $image -Phrase $anchor)) { $issues.Add("anchor '$anchor' is not a literal substring of image_prompt") }
            if ($assetType -eq 'ai_video' -and -not (Test-CfrTextContainsPhrase -Text $video -Phrase $anchor)) { $issues.Add("anchor '$anchor' is not a literal substring of video_prompt") }
        }

        if ($assetType -eq 'image_animation') {
            if ([string]::IsNullOrWhiteSpace($target)) { $issues.Add('image_animation requires motion_target') }
            else {
                if (@($anchors | Where-Object { [string]$_ -ieq $target }).Count -eq 0) { $issues.Add("motion_target '$target' is not one of the anchors") }
                if (-not (Test-CfrTextContainsPhrase -Text $image -Phrase $target)) { $issues.Add("motion_target '$target' is absent from image_prompt") }
                if (-not (Test-CfrTextContainsPhrase -Text $motion -Phrase $target)) { $issues.Add("motion_prompt does not name motion_target '$target'") }
            }
            if ($motion -notmatch '(?i)\b(camera|push-?in|pull-?back|zoom|pan|dolly)\b') { $issues.Add('image_animation motion_prompt must specify camera-only motion') }
            if (-not [string]::IsNullOrWhiteSpace($video)) { $issues.Add('image_animation must not have video_prompt') }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($target)) {
            $issues.Add("motion_target must be empty for asset_type '$assetType'")
        }

        switch ($assetType) {
            'ai_video' {
                if ([string]::IsNullOrWhiteSpace($video)) { $issues.Add('ai_video requires video_prompt') }
                elseif ($video -notmatch '(?i)\b(turns?|moves?|nods?|walks?|falls?|flows?|flickers?|shifts?|opens?|closes?|rises?|descends?|looks?|reaches?|lifts?)\b') {
                    $issues.Add('ai_video video_prompt requires one simple observable action')
                }
                if (-not [string]::IsNullOrWhiteSpace($motion)) { $issues.Add('ai_video must not have motion_prompt') }
            }
            'image_animation' {
                if ([string]::IsNullOrWhiteSpace($motion)) { $issues.Add('image_animation requires motion_prompt') }
                if (-not [string]::IsNullOrWhiteSpace($video)) { $issues.Add('image_animation must not have video_prompt') }
            }
            'generated_image' {
                if (-not [string]::IsNullOrWhiteSpace($video) -or -not [string]::IsNullOrWhiteSpace($motion)) { $issues.Add('generated_image must not have video_prompt or motion_prompt') }
            }
            'motion_graphic' {
                if ([string]::IsNullOrWhiteSpace($motion)) { $issues.Add('motion_graphic requires motion_prompt') }
                if (-not [string]::IsNullOrWhiteSpace($video)) { $issues.Add('motion_graphic must not have video_prompt') }
            }
            'stock_or_archive' {
                if (-not [string]::IsNullOrWhiteSpace($video) -or -not [string]::IsNullOrWhiteSpace($motion)) { $issues.Add('stock_or_archive must not have video_prompt or motion_prompt') }
            }
        }

        if ($issues.Count -gt 0) {
            $continuityDescriptions = [System.Collections.Generic.List[string]]::new()
            $entityIds = @(Get-CfrPropertyValue -InputObject $scene -Name 'continuity_entity_ids' -DefaultValue @())
            foreach ($entityIdValue in $entityIds) {
                $entityId = [string]$entityIdValue
                if ($entityMap.ContainsKey($entityId) -and -not [string]::IsNullOrWhiteSpace([string]$entityMap[$entityId])) {
                    $continuityDescriptions.Add([string]$entityMap[$entityId])
                }
            }
            $result.Add([pscustomobject][ordered]@{
                scene_id = $sceneId
                asset_type = $assetType
                voiceover_text = [string](Get-CfrPropertyValue -InputObject $scene -Name 'voiceover_text' -DefaultValue '')
                visual_purpose = $purpose
                visual_anchor_terms = @($anchors)
                image_prompt = $image
                video_prompt = $video
                motion_prompt = $motion
                motion_target = $target
                continuity_descriptions = @($continuityDescriptions.ToArray())
                issues = @($issues.ToArray())
            })
        }
    }
    return @($result.ToArray())
}

function Set-CfrVisualSceneRepairs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Package,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Repairs
    )

    $candidates = @(Get-CfrVisualSceneRepairCandidates -Package $Package)
    $allowed = @{}
    foreach ($candidate in $candidates) { $allowed[[string]$candidate.scene_id] = $true }

    $repairMap = @{}
    foreach ($repair in @($Repairs)) {
        if ($null -eq $repair) { continue }
        $id = [string](Get-CfrPropertyValue -InputObject $repair -Name 'scene_id' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($id) -or -not $allowed.ContainsKey($id)) { continue }
        if ($repairMap.ContainsKey($id)) { $repairMap.Remove($id) | Out-Null; continue }
        $repairMap[$id] = $repair
    }

    $scenes = @(Get-CfrPropertyValue -InputObject $Package -Name 'scenes' -DefaultValue @())
    $visualStyle = Get-CfrPropertyValue -InputObject $Package -Name 'visual_style' -DefaultValue $null
    $entityMap = @{}
    foreach ($entity in @(Get-CfrPropertyValue -InputObject $visualStyle -Name 'continuity_entities' -DefaultValue @())) {
        $id = [string](Get-CfrPropertyValue -InputObject $entity -Name 'entity_id' -DefaultValue '')
        $canonical = [string](Get-CfrPropertyValue -InputObject $entity -Name 'canonical_description' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($id)) { $entityMap[$id] = $canonical }
    }

    $notes = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        $idText = [string]$candidate.scene_id
        if (-not $repairMap.ContainsKey($idText)) {
            $note = "Сцена ${idText}: Gemma не вернула исправление визуальной согласованности; сцена оставлена без изменений и требует ручной проверки."
            Add-CfHumanReviewNote -Package $Package -Note $note
            $notes.Add($note)
            continue
        }

        $scene = $null
        foreach ($candidateScene in $scenes) {
            if ([string](Get-CfrPropertyValue -InputObject $candidateScene -Name 'scene_id' -DefaultValue '') -eq $idText) {
                $scene = $candidateScene
                break
            }
        }
        if ($null -eq $scene) {
            $note = "Сцена ${idText}: объект сцены не найден во время применения визуального ремонта; изменения пропущены."
            Add-CfHumanReviewNote -Package $Package -Note $note
            $notes.Add($note)
            continue
        }

        $repair = $repairMap[$idText]
        $purpose = [string](Get-CfrPropertyValue -InputObject $repair -Name 'visual_purpose' -DefaultValue '')
        $image = [string](Get-CfrPropertyValue -InputObject $repair -Name 'image_prompt' -DefaultValue '')
        $video = [string](Get-CfrPropertyValue -InputObject $repair -Name 'video_prompt' -DefaultValue '')
        $motion = [string](Get-CfrPropertyValue -InputObject $repair -Name 'motion_prompt' -DefaultValue '')
        $target = [string](Get-CfrPropertyValue -InputObject $repair -Name 'motion_target' -DefaultValue '')
        $anchors = @((Get-CfrPropertyValue -InputObject $repair -Name 'visual_anchor_terms' -DefaultValue @()) | ForEach-Object { [string]$_ })
        $assetTypeBefore = [string]$candidate.asset_type
        $assetType = $assetTypeBefore
        $problems = [System.Collections.Generic.List[string]]::new()
        $routeNotes = [System.Collections.Generic.List[string]]::new()

        if ([string]::IsNullOrWhiteSpace($purpose)) { $problems.Add('visual_purpose is empty') }
        if ([string]::IsNullOrWhiteSpace($image)) { $problems.Add('image_prompt is empty') }

        # Remove duplicate/empty anchors deterministically, but never invent a new visual subject.
        $cleanAnchors = [System.Collections.Generic.List[string]]::new()
        $seenAnchors = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($anchorValue in $anchors) {
            $anchor = [string]$anchorValue
            if ([string]::IsNullOrWhiteSpace($anchor)) { continue }
            if ($seenAnchors.Add($anchor)) { $cleanAnchors.Add($anchor) }
        }
        $anchors = @($cleanAnchors.ToArray())

        # v2.3 deterministic safety net: an anchor that Gemma wrote into visual_purpose but forgot to repeat
        # in image_prompt is a mechanical omission, not a creative error. Name the missing objects
        # explicitly instead of discarding an otherwise correct scene.
        if (-not [string]::IsNullOrWhiteSpace($image)) {
            $missingInImage = @($anchors | Where-Object {
                (Test-CfrTextContainsPhrase -Text $purpose -Phrase ([string]$_)) -and
                -not (Test-CfrTextContainsPhrase -Text $image -Phrase ([string]$_))
            })
            if ($missingInImage.Count -gt 0) {
                $image = $image.TrimEnd().TrimEnd('.', ';') + '; key visible elements: ' + ($missingInImage -join ', ') + '.'
                $routeNotes.Add("недостающие якоря дописаны в image_prompt: $($missingInImage -join ', ')")
            }
        }

        # Route-specific cleanup is deterministic. The model may accidentally return
        # a field belonging to another route; the trusted asset_type from the package wins.
        if ($assetType -eq 'image_animation') {
            if (-not [string]::IsNullOrWhiteSpace($video)) {
                $video = ''
                $routeNotes.Add('лишний video_prompt удалён: image_animation использует только camera-only motion_prompt')
            }

            $usableTargets = @($anchors | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_) -and
                (Test-CfrTextContainsPhrase -Text $purpose -Phrase ([string]$_)) -and
                (Test-CfrTextContainsPhrase -Text $image -Phrase ([string]$_))
            })
            if ($usableTargets.Count -gt 0) {
                $targetIsUsable = $false
                foreach ($usableTarget in $usableTargets) {
                    if ([string]$usableTarget -ieq $target) { $targetIsUsable = $true; break }
                }
                if (-not $targetIsUsable) {
                    $target = [string]$usableTargets[0]
                    $routeNotes.Add("motion_target автоматически выбран из подтверждённых anchors: '$target'")
                }
                if ($motion -notmatch '(?i)\b(camera|push-?in|pull-?back|zoom|pan|dolly)\b' -or -not (Test-CfrTextContainsPhrase -Text $motion -Phrase $target) -or $motion -match '(?i)\b(?:the\s+)?(?:person|man|woman|subject|object|coin|fire|smoke|water|hands|brain|face|eyes|shoe|cup|wallet|wall|bill|shadow)\s+(?:moves?|turns?|falls?|flickers?|changes?|opens?|closes?|flows?|burns?|sways?|shakes?|rotates?)\b') {
                    $motion = "Slow stabilized camera push-in toward $target; camera movement only; keep all visible people and objects static and unchanged."
                    $routeNotes.Add("motion_prompt нормализован в безопасное camera-only движение к '$target'")
                }
            }
        }
        elseif ($assetType -eq 'ai_video') {
            $hasObservableAction = (-not [string]::IsNullOrWhiteSpace($video)) -and ($video -match '(?i)\b(turns?|moves?|nods?|walks?|falls?|flows?|flickers?|shifts?|opens?|closes?|rises?|descends?|looks?|reaches?|lifts?)\b')
            if (-not $hasObservableAction) {
                $usableTargets = @($anchors | Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_) -and
                    (Test-CfrTextContainsPhrase -Text $purpose -Phrase ([string]$_)) -and
                    (Test-CfrTextContainsPhrase -Text $image -Phrase ([string]$_))
                })
                if ($usableTargets.Count -gt 0) {
                    # A camera-only prompt is not a Wan action. Fall back to FFmpeg animation
                    # rather than inventing physical motion or failing with a misleading Wan prompt.
                    $assetType = 'image_animation'
                    $target = [string]$usableTargets[0]
                    $video = ''
                    $motion = "Slow stabilized camera push-in toward $target; camera movement only; keep all visible people and objects static and unchanged."
                    $routeNotes.Add("ai_video без наблюдаемого действия безопасно переведено в image_animation; motion_target='$target'")
                }
            }
            if ($assetType -eq 'ai_video') {
                $motion = ''
                $target = ''
            }
        }
        elseif ($assetType -eq 'motion_graphic') {
            if (-not [string]::IsNullOrWhiteSpace($video)) {
                $video = ''
                $routeNotes.Add('лишний video_prompt удалён: motion_graphic анимируется локально')
            }
            $target = ''
        }
        elseif ($assetType -in @('generated_image', 'stock_or_archive')) {
            if (-not [string]::IsNullOrWhiteSpace($video) -or -not [string]::IsNullOrWhiteSpace($motion) -or -not [string]::IsNullOrWhiteSpace($target)) {
                $video = ''
                $motion = ''
                $target = ''
                $routeNotes.Add("лишние поля движения очищены для маршрута '$assetType'")
            }
        }

        if ($anchors.Count -lt 2 -or $anchors.Count -gt 5) { $problems.Add('visual_anchor_terms must contain 2-5 entries after cleanup') }
        foreach ($anchor in $anchors) {
            if (-not (Test-CfrTextContainsPhrase -Text $purpose -Phrase $anchor)) { $problems.Add("anchor '$anchor' is missing from visual_purpose") }
            if (-not (Test-CfrTextContainsPhrase -Text $image -Phrase $anchor)) { $problems.Add("anchor '$anchor' is missing from image_prompt") }
            if ($assetType -eq 'ai_video' -and -not (Test-CfrTextContainsPhrase -Text $video -Phrase $anchor)) { $problems.Add("anchor '$anchor' is missing from video_prompt") }
        }

        switch ($assetType) {
            'ai_video' {
                if ([string]::IsNullOrWhiteSpace($video)) { $problems.Add('video_prompt is empty') }
                elseif ($video -notmatch '(?i)\b(turns?|moves?|nods?|walks?|falls?|flows?|flickers?|shifts?|opens?|closes?|rises?|descends?|looks?|reaches?|lifts?)\b') { $problems.Add('video_prompt has no simple observable action') }
                if (-not [string]::IsNullOrWhiteSpace($motion)) { $problems.Add('ai_video must not have motion_prompt') }
                if (-not [string]::IsNullOrWhiteSpace($target)) { $problems.Add('ai_video motion_target must be empty') }
            }
            'image_animation' {
                if ([string]::IsNullOrWhiteSpace($target)) { $problems.Add('motion_target is empty') }
                if (@($anchors | Where-Object { [string]$_ -ieq $target }).Count -eq 0) { $problems.Add('motion_target is not one of visual_anchor_terms') }
                if (-not (Test-CfrTextContainsPhrase -Text $image -Phrase $target)) { $problems.Add('motion_target is missing from image_prompt') }
                if (-not (Test-CfrTextContainsPhrase -Text $motion -Phrase $target)) { $problems.Add('motion_target is missing from motion_prompt') }
                if ($motion -notmatch '(?i)\b(camera|push-?in|pull-?back|zoom|pan|dolly)\b') { $problems.Add('motion_prompt does not specify camera movement') }
                if (-not [string]::IsNullOrWhiteSpace($video)) { $problems.Add('image_animation must not have video_prompt') }
                if ($motion -match '(?i)\b(?:the\s+)?(?:person|man|woman|subject|object|coin|fire|smoke|water|hands|brain|face|eyes|shoe|cup|wallet|wall|bill|shadow)\s+(?:moves?|turns?|falls?|flickers?|changes?|opens?|closes?|flows?|burns?|sways?|shakes?|rotates?)\b') { $problems.Add('motion_prompt describes object motion, not camera-only motion') }
            }
            'generated_image' {
                if (-not [string]::IsNullOrWhiteSpace($video) -or -not [string]::IsNullOrWhiteSpace($motion)) { $problems.Add('generated_image must not have video_prompt or motion_prompt') }
                if (-not [string]::IsNullOrWhiteSpace($target)) { $problems.Add('generated_image motion_target must be empty') }
            }
            'motion_graphic' {
                if ([string]::IsNullOrWhiteSpace($motion)) { $problems.Add('motion_graphic requires motion_prompt') }
                if (-not [string]::IsNullOrWhiteSpace($video) -or -not [string]::IsNullOrWhiteSpace($target)) { $problems.Add('motion_graphic must not have video_prompt or motion_target') }
            }
            'stock_or_archive' {
                if (-not [string]::IsNullOrWhiteSpace($video) -or -not [string]::IsNullOrWhiteSpace($motion) -or -not [string]::IsNullOrWhiteSpace($target)) { $problems.Add('stock_or_archive must not have video_prompt, motion_prompt or motion_target') }
            }
            default { $problems.Add("unknown asset_type '$assetType'") }
        }

        if ($problems.Count -gt 0) {
            $note = "Сцена ${idText}: предложенное Gemma исправление не применено: $($problems -join '; '). Сцена требует ручной правки."
            Add-CfHumanReviewNote -Package $Package -Note $note
            $notes.Add($note)
            continue
        }

        # Preserve canonical identity details independently from visual anchors.
        $entityIds = @(Get-CfrPropertyValue -InputObject $scene -Name 'continuity_entity_ids' -DefaultValue @())
        $canonicalPrefix = [System.Collections.Generic.List[string]]::new()
        foreach ($entityIdValue in $entityIds) {
            $entityId = [string]$entityIdValue
            if ($entityMap.ContainsKey($entityId)) {
                $canonical = [string]$entityMap[$entityId]
                if (-not [string]::IsNullOrWhiteSpace($canonical) -and $image.IndexOf($canonical, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { $canonicalPrefix.Add($canonical) }
                if ($assetType -eq 'ai_video' -and -not [string]::IsNullOrWhiteSpace($canonical) -and $video.IndexOf($canonical, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    $video = $canonical.Trim() + "`n" + $video.Trim()
                }
            }
        }
        if ($canonicalPrefix.Count -gt 0) { $image = ([string]::Join("`n", [string[]]$canonicalPrefix.ToArray()) + "`n" + $image.Trim()) }

        $updates = [ordered]@{
            visual_purpose = $purpose
            visual_anchor_terms = @($anchors | ForEach-Object { [string]$_ })
            image_prompt = $image
            video_prompt = $video
            motion_prompt = $motion
            motion_target = $target
        }
        foreach ($key in $updates.Keys) {
            $property = $scene.PSObject.Properties[[string]$key]
            if ($null -eq $property) { $scene | Add-Member -MemberType NoteProperty -Name ([string]$key) -Value ($updates[$key]) -Force }
            else { $property.Value = $updates[$key] }
        }
        if ($assetType -ne $assetTypeBefore) { $scene.asset_type = $assetType }

        foreach ($routeNote in $routeNotes) {
            $routeRecord = "Сцена ${idText}: $routeNote. Проверь результат визуально перед генерацией ресурсов."
            Add-CfHumanReviewNote -Package $Package -Note $routeRecord
            $notes.Add($routeRecord)
        }

        $note = "Сцена ${idText}: визуальная согласованность исправлена вторым проходом Gemma; visual_purpose, anchors и prompt-поля согласованы по строгому контракту. Проверь смысловое соответствие и итоговый кадр вручную."
        Add-CfHumanReviewNote -Package $Package -Note $note
        $notes.Add($note)
    }
    return @($notes.ToArray())
}


function Repair-CfrPurposeAnchorGap {
    <#
    .SYNOPSIS
        Last-resort, fully deterministic repair run after the Gemma retries.

    .DESCRIPTION
        Real run 20261108203325401, scene 7: the anchors "worn leather brown wallet" and "dark wooden table"
        were present in image_prompt, but visual_purpose was written as "The worn leather wallet from the first scene".
        The frame itself was fine; only the bookkeeping fields disagreed. When EVERY missing anchor is demonstrably
        visible in image_prompt, append the anchors to visual_purpose and record the change in human_review.
        If any anchor is absent from image_prompt as well, the scene is left untouched for a human.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Package)

    $notes = [System.Collections.Generic.List[string]]::new()
    foreach ($scene in @(Get-CfrPropertyValue -InputObject $Package -Name 'scenes' -DefaultValue @())) {
        if ($null -eq $scene) { continue }
        $sceneId = [string](Get-CfrPropertyValue -InputObject $scene -Name 'scene_id' -DefaultValue '')
        $purpose = [string](Get-CfrPropertyValue -InputObject $scene -Name 'visual_purpose' -DefaultValue '')
        $image = [string](Get-CfrPropertyValue -InputObject $scene -Name 'image_prompt' -DefaultValue '')
        $anchors = @((Get-CfrPropertyValue -InputObject $scene -Name 'visual_anchor_terms' -DefaultValue @()) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($anchors.Count -lt 2 -or $anchors.Count -gt 5 -or [string]::IsNullOrWhiteSpace($purpose)) { continue }

        $missingInPurpose = @($anchors | Where-Object { -not (Test-CfrTextContainsPhrase -Text $purpose -Phrase $_) })
        if ($missingInPurpose.Count -eq 0) { continue }
        $missingInImage = @($missingInPurpose | Where-Object { -not (Test-CfrTextContainsPhrase -Text $image -Phrase $_) })
        if ($missingInImage.Count -gt 0) { continue }

        $newPurpose = $purpose.TrimEnd().TrimEnd('.', ';') + '. Key visible elements: ' + ($missingInPurpose -join ', ') + '.'
        Set-CfrPropertyValue -InputObject $scene -Name 'visual_purpose' -Value $newPurpose
        $note = "Сцена ${sceneId}: якоря ($($missingInPurpose -join ', ')) уже есть в image_prompt, но отсутствовали в visual_purpose; они дописаны в visual_purpose механически. Проверь, что замысел кадра по-прежнему верен."
        Add-CfHumanReviewNote -Package $Package -Note $note
        $notes.Add($note)
    }
    return @($notes.ToArray())
}


function Get-CfClaimsNeedingExcerptRepair {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Package)

    $scriptText = [string](Get-CfrPropertyValue -InputObject (Get-CfrPropertyValue -InputObject $Package -Name 'script' -DefaultValue $null) -Name 'full_text' -DefaultValue '')
    $research = Get-CfrPropertyValue -InputObject $Package -Name 'research_brief' -DefaultValue $null
    $claims = @(Get-CfrPropertyValue -InputObject $research -Name 'factual_claims' -DefaultValue @())
    $result = [System.Collections.Generic.List[object]]::new()

    foreach ($claim in $claims) {
        if ($null -eq $claim) { continue }
        $used = Get-CfrPropertyValue -InputObject $claim -Name 'used_in_script' -DefaultValue $false
        if ($used -isnot [bool] -or -not $used) { continue }
        $excerpt = [string](Get-CfrPropertyValue -InputObject $claim -Name 'script_excerpt' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($excerpt) -or $scriptText.IndexOf($excerpt, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            $result.Add([pscustomobject]@{
                claim_id = [string](Get-CfrPropertyValue -InputObject $claim -Name 'claim_id' -DefaultValue '')
                claim = [string](Get-CfrPropertyValue -InputObject $claim -Name 'claim' -DefaultValue '')
                current_excerpt = $excerpt
            })
        }
    }
    return @($result.ToArray())
}

function Set-CfClaimExcerptRepairs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Package,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Repairs
    )

    $scriptText = [string](Get-CfrPropertyValue -InputObject (Get-CfrPropertyValue -InputObject $Package -Name 'script' -DefaultValue $null) -Name 'full_text' -DefaultValue '')
    $research = Get-CfrPropertyValue -InputObject $Package -Name 'research_brief' -DefaultValue $null
    $claims = @(Get-CfrPropertyValue -InputObject $research -Name 'factual_claims' -DefaultValue @())
    $repairCandidates = @(Get-CfClaimsNeedingExcerptRepair -Package $Package)
    $allowedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $repairCandidates) { [void]$allowedIds.Add([string]$candidate.claim_id) }
    $applied = [System.Collections.Generic.List[string]]::new()

    foreach ($repair in @($Repairs)) {
        $claimId = [string](Get-CfrPropertyValue -InputObject $repair -Name 'claim_id' -DefaultValue '')
        $excerpt = [string](Get-CfrPropertyValue -InputObject $repair -Name 'script_excerpt' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($claimId) -or [string]::IsNullOrWhiteSpace($excerpt)) { continue }
        if (-not $allowedIds.Contains($claimId)) { continue }
        if ($scriptText.IndexOf($excerpt, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

        foreach ($claim in $claims) {
            if ([string](Get-CfrPropertyValue -InputObject $claim -Name 'claim_id' -DefaultValue '') -eq $claimId) {
                if ([bool](Get-CfrPropertyValue -InputObject $claim -Name 'used_in_script' -DefaultValue $false)) {
                    $claim.script_excerpt = $excerpt
                    $applied.Add($claimId)
                }
                break
            }
        }
    }

    foreach ($claimId in $applied) {
        Add-CfHumanReviewNote -Package $Package -Note "Связка factual claim '$claimId' автоматически привязана к дословному фрагменту сценария. Всё равно проверь, что цитата действительно подтверждает формулировку утверждения."
    }
    return @($applied.ToArray())
}

Export-ModuleMember -Function Repair-CfPackageStructure, Get-CfClaimsNeedingExcerptRepair, Set-CfClaimExcerptRepairs, Add-CfHumanReviewNote, Get-CfrVisualSceneRepairCandidates, Set-CfrVisualSceneRepairs, Remove-CfHumanReviewNotes, Test-CfrTextContainsPhrase, Repair-CfrPurposeAnchorGap
