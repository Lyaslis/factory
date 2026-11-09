Set-StrictMode -Version Latest

function Get-CfValue {
    param([object]$InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-CfWordCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }
    # Count Russian/Latin words and common hyphenated forms; punctuation is not a word.
    return [int][regex]::Matches($Text, "[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*").Count
}

function ConvertTo-CfComparableText {
    # Case-, punctuation- and whitespace-insensitive form used for literal phrase checks.
    # Gemma often copies "A worn, leather wallet" while the anchor is "worn leather wallet":
    # the words are identical, only the comma differs. Words and their order must still match.
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return ([regex]::Replace($Text.ToLowerInvariant(), '[^\p{L}\p{N}]+', ' ')).Trim()
}

function Test-CfTextContainsPhrase {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string]$Text, [AllowEmptyString()][string]$Phrase)
    if ([string]::IsNullOrWhiteSpace($Phrase)) { return $false }
    $needle = ConvertTo-CfComparableText -Text $Phrase
    if ($needle.Length -eq 0) { return $false }
    $haystack = ConvertTo-CfComparableText -Text $Text
    return ($haystack.IndexOf($needle, [System.StringComparison]::Ordinal) -ge 0)
}

function Test-CfProductionPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Package,
        [Parameter(Mandatory)][ValidateRange(15, 180)][int]$TargetDurationSeconds,
        [ValidateRange(0,20)][int]$MaxAiVideoScenes = 20,
        [switch]$RequireVisualAnchors,
        [double]$MaximumWordsPerSecond = 2.8,
        [double]$MinimumWordsPerSecond = 1.2
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $checks = [System.Collections.Generic.List[object]]::new()
    $requiredSectionsPassed = $true
    $assetRoutingPassed = $true
    $continuityPassed = $true
    $visualPromptConsistencyPassed = $true
    $claimLedgerPassed = $true
    $sceneOrderPassed = $true
    $visualAnchorsPassed = $true
    $speechPacingPassed = $true
    $characterReferencePassed = $true

    # 1. Required root properties. Empty arrays are valid; null/missing properties are not.
    $requiredRoot = @('schema_version', 'project', 'research_brief', 'script', 'visual_style', 'scenes', 'editing_plan', 'human_review')
    foreach ($name in $requiredRoot) {
        $property = $Package.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value) {
            $requiredSectionsPassed = $false
            $errors.Add("В пакете отсутствует обязательный раздел: $name")
        }
    }

    $schemaVersion = [string](Get-CfValue $Package 'schema_version')
    if ($schemaVersion -ne '2.1') { $errors.Add("Неподдерживаемая schema_version='$schemaVersion'; ожидается 2.1.") }

    $project = Get-CfValue $Package 'project'
    $reportedDuration = Get-CfValue $project 'target_duration_seconds'
    if ($null -ne $reportedDuration -and [int]$reportedDuration -ne $TargetDurationSeconds) {
        $errors.Add("Внутри пакета указана длительность $reportedDuration с, а в запросе — $TargetDurationSeconds с.")
    }

    # 2. Script integrity and calculated word count.
    $script = Get-CfValue $Package 'script'
    $fullText = [string](Get-CfValue $script 'full_text')
    $hook = [string](Get-CfValue $script 'hook')
    $closingLine = [string](Get-CfValue $script 'closing_line')
    $wordCount = Get-CfWordCount -Text $fullText

    if ([string]::IsNullOrWhiteSpace($fullText)) {
        $errors.Add('script.full_text пуст: нет текста озвучки.')
    }
    else {
        if ([string]::IsNullOrWhiteSpace($hook) -or -not $fullText.StartsWith($hook, [System.StringComparison]::Ordinal)) {
            $warnings.Add('script.hook не совпадает с началом script.full_text.')
        }
        if ([string]::IsNullOrWhiteSpace($closingLine) -or -not $fullText.TrimEnd().EndsWith($closingLine, [System.StringComparison]::Ordinal)) {
            $warnings.Add('script.closing_line не совпадает с концом script.full_text.')
        }

        $reportedWordCount = Get-CfValue $script 'estimated_word_count'
        if ($null -ne $reportedWordCount -and [int]$reportedWordCount -ne $wordCount) {
            $warnings.Add("Количество слов исправляется автоматически: модель указала $reportedWordCount, фактически $wordCount.")
        }
    }

    # 3. Global visual style and stable entity registry.
    $visualStyle = Get-CfValue $Package 'visual_style'
    $globalNegativePrompt = [string](Get-CfValue $visualStyle 'negative_prompt')
    $entityProperty = $null
    if ($null -ne $visualStyle) { $entityProperty = $visualStyle.PSObject.Properties['continuity_entities'] }
    if ($null -eq $entityProperty -or $null -eq $entityProperty.Value -or $entityProperty.Value -isnot [array]) {
        $continuityPassed = $false
        $errors.Add('visual_style.continuity_entities должен присутствовать как массив; пустой массив допустим.')
    }
    $entityValue = Get-CfValue $visualStyle 'continuity_entities'
    $entities = @()
    if ($null -ne $entityValue) { $entities = @($entityValue) }

    $entityMap = @{}
    foreach ($entity in $entities) {
        $entityId = [string](Get-CfValue $entity 'entity_id')
        $canonical = [string](Get-CfValue $entity 'canonical_description')
        if ([string]::IsNullOrWhiteSpace($entityId)) {
            $continuityPassed = $false
            $errors.Add('В visual_style.continuity_entities найден объект без entity_id.')
            continue
        }
        if ($entityMap.ContainsKey($entityId)) {
            $continuityPassed = $false
            $errors.Add("Повторяется continuity entity ID '$entityId'.")
            continue
        }
        $entityMap[$entityId] = $canonical
        if ([string]::IsNullOrWhiteSpace($canonical)) {
            $continuityPassed = $false
            $errors.Add("У continuity entity '$entityId' отсутствует canonical_description.")
        }
    }

    # 4. Scenes, exact narration sequence, timing and unambiguous asset routing.
    $scenesProperty = $Package.PSObject.Properties['scenes']
    if ($null -eq $scenesProperty -or $null -eq $scenesProperty.Value -or $scenesProperty.Value -isnot [array]) {
        $errors.Add('scenes должен присутствовать как массив.')
    }
    $scenesValue = Get-CfValue $Package 'scenes'
    $scenes = @()
    if ($null -ne $scenesValue) { $scenes = @($scenesValue) }
    if ($RequireVisualAnchors -and $scenes.Count -gt 0) {
        $entitySceneUsage = @{}
        foreach ($sceneForUsage in $scenes) {
            $idsForUsage = @(Get-CfValue $sceneForUsage 'continuity_entity_ids')
            $uniqueIdsForScene = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($idForUsage in $idsForUsage) {
                $idTextForUsage = [string]$idForUsage
                if ([string]::IsNullOrWhiteSpace($idTextForUsage)) { continue }
                [void]$uniqueIdsForScene.Add($idTextForUsage)
            }
            foreach ($idTextForUsage in $uniqueIdsForScene) {
                if (-not $entitySceneUsage.ContainsKey($idTextForUsage)) { $entitySceneUsage[$idTextForUsage] = 0 }
                $entitySceneUsage[$idTextForUsage]++
            }
        }
        foreach ($entity in $entities) {
            $entityId = [string](Get-CfValue $entity 'entity_id')
            $entityType = [string](Get-CfValue $entity 'entity_type')
            if ($entityType -ne 'person' -or -not $entitySceneUsage.ContainsKey($entityId) -or $entitySceneUsage[$entityId] -lt 2) { continue }
            $referencePath = [string](Get-CfValue $entity 'reference_asset_path')
            $referencePrompt = [string](Get-CfValue $entity 'reference_image_prompt')
            $canonicalDescription = [string](Get-CfValue $entity 'canonical_description')
            $expectedPath = "assets/characters/${entityId}_reference.png"
            if ($referencePath -cne $expectedPath) {
                $characterReferencePassed = $false
                $errors.Add("Повторяющийся персонаж '$entityId' должен иметь reference_asset_path='$expectedPath'.")
            }
            if ([string]::IsNullOrWhiteSpace($referencePrompt) -or $referencePrompt.IndexOf($canonicalDescription, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                $characterReferencePassed = $false
                $errors.Add("Повторяющийся персонаж '$entityId' должен иметь reference_image_prompt с дословным canonical_description.")
            }
        }
    }

    if ($scenes.Count -lt 3) {
        $errors.Add('В раскадровке должно быть не менее трёх сцен.')
    }
    else {
        $sceneIds = [System.Collections.Generic.HashSet[int]]::new()
        $durationTotal = 0.0
        $sceneNarration = [System.Collections.Generic.List[string]]::new()
        $aiVideoCount = 0

        for ($i = 0; $i -lt $scenes.Count; $i++) {
            $scene = $scenes[$i]
            if ($null -eq $scene) {
                $sceneOrderPassed = $false
                $errors.Add("Сцена с индексом $($i + 1) имеет значение null.")
                continue
            }
            $sceneId = Get-CfValue $scene 'scene_id'
            $sceneDuration = Get-CfValue $scene 'duration_seconds'
            $sceneText = [string](Get-CfValue $scene 'voiceover_text')
            $assetType = [string](Get-CfValue $scene 'asset_type')
            $imagePrompt = [string](Get-CfValue $scene 'image_prompt')
            $videoPrompt = [string](Get-CfValue $scene 'video_prompt')
            $motionPrompt = [string](Get-CfValue $scene 'motion_prompt')
            $continuityNotes = [string](Get-CfValue $scene 'continuity_notes')
            $visualPurpose = [string](Get-CfValue $scene 'visual_purpose')
            $visualAnchorsValue = Get-CfValue $scene 'visual_anchor_terms'
            $visualAnchors = @()
            if ($null -ne $visualAnchorsValue) { $visualAnchors = @($visualAnchorsValue) }
            $motionTargetProperty = $scene.PSObject.Properties['motion_target']
            $motionTarget = [string](Get-CfValue $scene 'motion_target')
            if ($RequireVisualAnchors -and $null -eq $motionTargetProperty) {
                $visualAnchorsPassed = $false
                $errors.Add("Сцена ${sceneId}: поле motion_target обязательно в контракте v2.2; для маршрутов кроме image_animation укажи пустую строку.")
            }

            if ($null -eq $sceneId) {
                $sceneOrderPassed = $false
                $errors.Add("У сцены с индексом $($i + 1) отсутствует scene_id.")
            }
            else {
                $idNumber = 0
                if ([int]::TryParse([string]$sceneId, [ref]$idNumber)) {
                    if (-not $sceneIds.Add($idNumber)) { $sceneOrderPassed = $false; $errors.Add("Повторяется scene_id=$sceneId.") }
                    if ($idNumber -ne ($i + 1)) { $sceneOrderPassed = $false; $errors.Add("scene_id должны идти подряд от 1. Ожидался $($i + 1), получен $idNumber.") }
                }
                else {
                    $sceneOrderPassed = $false
                    $errors.Add("scene_id='$sceneId' должен быть целым числом.")
                }
            }

            if ($null -eq $sceneDuration -or [double]$sceneDuration -le 0) {
                $errors.Add("У сцены ${sceneId} отсутствует положительная duration_seconds.")
            }
            else {
                $durationTotal += [double]$sceneDuration
            }

            if ([string]::IsNullOrWhiteSpace($sceneText)) {
                $errors.Add("У сцены ${sceneId} отсутствует voiceover_text.")
            }
            else {
                $sceneNarration.Add($sceneText)
                if ($null -ne $sceneDuration -and [double]$sceneDuration -gt 0) {
                    $sceneWps = (Get-CfWordCount -Text $sceneText) / [double]$sceneDuration
                    if ($sceneWps -gt $MaximumWordsPerSecond) {
                        $speechPacingPassed = $false
                        $errors.Add(('Сцена {0}: речевой темп {1:N2} слов/с превышает профильный максимум {2:N2}. Перераспредели время или сократи текст.' -f $sceneId, $sceneWps, $MaximumWordsPerSecond))
                    }
                    elseif ($sceneWps -lt $MinimumWordsPerSecond) {
                        $warnings.Add(('Сцена {0}: темп около {1:N2} слов/с — проверь, оправдана ли длинная пауза.' -f $sceneId, $sceneWps))
                    }
                }
            }

            if ([string]::IsNullOrWhiteSpace($imagePrompt)) {
                $errors.Add("У сцены ${sceneId} отсутствует image_prompt. Для stock_or_archive он используется как поисковое описание.")
            }

            if ($visualAnchors.Count -lt 2 -or $visualAnchors.Count -gt 5) {
                if ($RequireVisualAnchors) { $visualAnchorsPassed = $false; $errors.Add("Сцена ${sceneId}: требуется 2–5 visual_anchor_terms, извлечённых из visual_purpose.") }
                else { $warnings.Add("Сцена ${sceneId}: visual_anchor_terms отсутствуют или содержат неверное количество элементов.") }
            }
            elseif ($RequireVisualAnchors) {
                foreach ($anchor in $visualAnchors) {
                    $anchorText = [string]$anchor
                    if ([string]::IsNullOrWhiteSpace($anchorText)) {
                        $visualAnchorsPassed = $false
                        $errors.Add("Сцена ${sceneId}: visual_anchor_term не может быть пустым.")
                        continue
                    }
                    if (-not (Test-CfTextContainsPhrase -Text $visualPurpose -Phrase $anchorText)) {
                        $visualAnchorsPassed = $false
                        $errors.Add("Сцена ${sceneId}: visual_anchor_term '$anchorText' отсутствует дословно в visual_purpose. Якоря должны быть извлечены из визуального замысла.")
                    }
                    if (-not (Test-CfTextContainsPhrase -Text $imagePrompt -Phrase $anchorText)) {
                        $visualAnchorsPassed = $false
                        $errors.Add("Сцена ${sceneId}: visual_anchor_term '$anchorText' отсутствует дословно в image_prompt.")
                    }
                }
            }
            if ($assetType -eq 'image_animation') {
                if ($RequireVisualAnchors -and [string]::IsNullOrWhiteSpace($motionTarget)) {
                    $visualAnchorsPassed = $false
                    $errors.Add("Сцена ${sceneId}: image_animation требует motion_target — видимый объект для движения камеры.")
                }
                elseif (-not [string]::IsNullOrWhiteSpace($motionTarget)) {
                    if ($RequireVisualAnchors) {
                        $motionTargetIsAnchor = $false
                        foreach ($anchor in $visualAnchors) {
                            if ([string]$anchor -ieq $motionTarget) { $motionTargetIsAnchor = $true; break }
                        }
                        if (-not $motionTargetIsAnchor) {
                            $visualAnchorsPassed = $false
                            $errors.Add("Сцена ${sceneId}: motion_target '$motionTarget' должен совпадать с одним из visual_anchor_terms.")
                        }
                    }
                    if (-not (Test-CfTextContainsPhrase -Text $imagePrompt -Phrase $motionTarget)) {
                        $visualAnchorsPassed = $false
                        $errors.Add("Сцена ${sceneId}: motion_target '$motionTarget' отсутствует в image_prompt.")
                    }
                    if (-not (Test-CfTextContainsPhrase -Text $motionPrompt -Phrase $motionTarget)) {
                        $visualAnchorsPassed = $false
                        $errors.Add("Сцена ${sceneId}: motion_prompt не направляет камеру на motion_target '$motionTarget'.")
                    }
                }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($motionTarget)) {
                if ($RequireVisualAnchors) {
                    $visualAnchorsPassed = $false
                    $errors.Add("Сцена ${sceneId}: motion_target должен быть пустым для asset_type='$assetType'.")
                }
                else {
                    $warnings.Add("Сцена ${sceneId}: motion_target применяется только к image_animation; очисти это поле.")
                }
            }

            switch ($assetType) {
                'generated_image' {
                    if ([string]::IsNullOrWhiteSpace($imagePrompt)) { $assetRoutingPassed = $false; $errors.Add("У сцены ${sceneId} типа generated_image пуст image_prompt.") }
                    if (-not [string]::IsNullOrWhiteSpace($videoPrompt) -or -not [string]::IsNullOrWhiteSpace($motionPrompt)) {
                        $assetRoutingPassed = $false
                        $errors.Add("Сцена ${sceneId}: generated_image допускает только image_prompt; video_prompt и motion_prompt должны быть пустыми.")
                    }
                }
                'image_animation' {
                    if ([string]::IsNullOrWhiteSpace($imagePrompt)) { $assetRoutingPassed = $false; $errors.Add("У сцены ${sceneId} типа image_animation пуст image_prompt.") }
                    if ([string]::IsNullOrWhiteSpace($motionPrompt)) { $assetRoutingPassed = $false; $errors.Add("У сцены ${sceneId} типа image_animation пуст motion_prompt.") }
                    if (-not [string]::IsNullOrWhiteSpace($videoPrompt)) { $assetRoutingPassed = $false; $errors.Add("Сцена ${sceneId}: image_animation не использует video_prompt; оставь поле пустым.") }
                    if (-not [string]::IsNullOrWhiteSpace($motionPrompt) -and $motionPrompt -notmatch '(?i)\b(camera|push-?in|pull-?back|zoom|pan|dolly)\b') {
                        $assetRoutingPassed = $false
                        $errors.Add("Сцена ${sceneId}: motion_prompt для image_animation должен описывать движение камеры (pan/zoom/push-in/dolly), а не просто действие.")
                    }
                    if ($motionPrompt -match '(?i)\b(?:the\s+)?(?:person|man|woman|subject|object|coin|fire|smoke|water|hands|brain|face|eyes|shoe|cup|wallet)\s+(?:moves?|turns?|falls?|flickers?|changes?|opens?|closes?|flows?|burns?|sways?|shakes?|rotates?)\b') {
                        $assetRoutingPassed = $false
                        $errors.Add("Сцена ${sceneId}: image_animation описывает движение объекта. Для этого маршрута разрешено только движение камеры; перенеси физическое действие в ai_video или сделай статичный кадр.")
                    }
                }
                'ai_video' {
                    $aiVideoCount++
                    if ([string]::IsNullOrWhiteSpace($imagePrompt)) { $assetRoutingPassed = $false; $errors.Add("У сцены ${sceneId} типа ai_video пуст image_prompt для исходного кадра.") }
                    if ([string]::IsNullOrWhiteSpace($videoPrompt)) { $assetRoutingPassed = $false; $errors.Add("У сцены ${sceneId} типа ai_video пуст video_prompt.") }
                    elseif ($videoPrompt -notmatch '(?i)\b(turns?|moves?|nods?|walks?|falls?|flows?|flickers?|shifts?|opens?|closes?|rises?|descends?|looks?|reaches?|lifts?)\b') {
                        $assetRoutingPassed = $false
                        $errors.Add("Сцена ${sceneId}: video_prompt не содержит одного простого наблюдаемого действия для Wan.")
                    }
                    if (-not [string]::IsNullOrWhiteSpace($motionPrompt)) { $assetRoutingPassed = $false; $errors.Add("Сцена ${sceneId}: ai_video использует video_prompt; motion_prompt должен быть пустым.") }
                    if ($RequireVisualAnchors -and $visualAnchors.Count -ge 2) {
                        foreach ($anchor in $visualAnchors) {
                            if (-not (Test-CfTextContainsPhrase -Text $videoPrompt -Phrase ([string]$anchor))) {
                                $visualAnchorsPassed = $false
                                $errors.Add("Сцена ${sceneId}: video_prompt не содержит visual_anchor_term '$anchor'; видеоклип может подменить визуальную идею исходного кадра.")
                            }
                        }
                    }
                }
                'motion_graphic' {
                    if ([string]::IsNullOrWhiteSpace($imagePrompt)) { $assetRoutingPassed = $false; $errors.Add("У сцены ${sceneId} типа motion_graphic пуст image_prompt.") }
                    if ([string]::IsNullOrWhiteSpace($motionPrompt)) { $assetRoutingPassed = $false; $errors.Add("У сцены ${sceneId} типа motion_graphic пуст motion_prompt.") }
                    if (-not [string]::IsNullOrWhiteSpace($videoPrompt)) { $assetRoutingPassed = $false; $errors.Add("Сцена ${sceneId}: motion_graphic не использует video_prompt; оставь поле пустым.") }
                }
                'stock_or_archive' {
                    if ([string]::IsNullOrWhiteSpace($imagePrompt)) { $assetRoutingPassed = $false; $errors.Add("У сцены ${sceneId} типа stock_or_archive отсутствует поисковое описание в image_prompt.") }
                    if (-not [string]::IsNullOrWhiteSpace($videoPrompt) -or -not [string]::IsNullOrWhiteSpace($motionPrompt)) {
                        $assetRoutingPassed = $false
                        $errors.Add("Сцена ${sceneId}: stock_or_archive требует ручной подбор; video_prompt и motion_prompt должны быть пустыми.")
                    }
                }
                default {
                    $assetRoutingPassed = $false
                    $errors.Add("У сцены ${sceneId} неизвестный asset_type='$assetType'.")
                }
            }

            # The global negative prompt must not conflict with individual scene prompts.
            $allScenePrompts = "$imagePrompt`n$videoPrompt`n$motionPrompt"
            if ($globalNegativePrompt -match '(?i)shaky\s*cam|camera\s*shake' -and $allScenePrompts -match '(?i)handheld|camera\s*shake|shaky\s*camera') {
                $visualPromptConsistencyPassed = $false
                $errors.Add("Сцена ${sceneId}: промпт требует тряску камеры, запрещённую общим negative_prompt.")
            }
            if ($globalNegativePrompt -match '(?i)(no text|without text|no lettering|no readable text)' -and $imagePrompt -match '(?i)(readable text|the word|letters spelling|label reading|visible text|subtitle)') {
                $visualPromptConsistencyPassed = $false
                $errors.Add("Сцена ${sceneId}: image_prompt требует читаемый текст, запрещённый общим negative_prompt. Добавляй надписи при монтаже.")
            }
            if ($continuityNotes -match '(?i)(same .*previous scene|same .*preceding scene|тот же .*предыдущей сцены|как в предыдущей сцене)') {
                $warnings.Add("Сцена ${sceneId}: continuity_notes использует неоднозначную ссылку на предыдущую сцену; укажи конкретную сущность.")
            }

            # v2.3 hygiene checks. They are advisory: the program cannot translate a caption or
            # re-route a scene on its own, but a human must see the problem before assets are generated.
            $sceneOnScreenText = [string](Get-CfValue $scene 'on_screen_text')
            if ($sceneOnScreenText -match '\p{L}' -and $sceneOnScreenText -notmatch '[\u0400-\u04FF]' -and $fullText -match '[\u0400-\u04FF]') {
                $warnings.Add("Сцена ${sceneId}: on_screen_text '$sceneOnScreenText' написан не по-русски, хотя озвучка русская. Исправь надпись при монтаже.")
            }
            if ($assetType -eq 'motion_graphic' -and [string]::IsNullOrWhiteSpace($sceneOnScreenText)) {
                $warnings.Add("Сцена ${sceneId}: motion_graphic без on_screen_text. FFmpeg умеет анимировать графику и текст, но не рисовать фотореалистичные объекты; для такой сцены нужен generated_image или image_animation.")
            }
            if ($visualPurpose -match '(?i)\b(?:from|in|of|as in)\s+the\s+(?:first|previous|last|preceding|earlier|opening|same)\s+(?:scene|shot|frame)\b|\bsame\s+as\s+(?:before|earlier)\b') {
                $warnings.Add("Сцена ${sceneId}: visual_purpose ссылается на другую сцену. Каждый кадр генерируется отдельно, поэтому описание должно быть самодостаточным.")
            }

            # Structured continuity: every scene reference must exist and the canonical description must be copied.
            $sceneEntityProperty = $scene.PSObject.Properties['continuity_entity_ids']
            if ($null -eq $sceneEntityProperty -or $null -eq $sceneEntityProperty.Value -or $sceneEntityProperty.Value -isnot [array]) {
                $continuityPassed = $false
                $errors.Add("У сцены ${sceneId} отсутствует массив continuity_entity_ids.")
            }
            $sceneEntityValue = Get-CfValue $scene 'continuity_entity_ids'
            $sceneEntityIds = @()
            if ($null -ne $sceneEntityValue) { $sceneEntityIds = @($sceneEntityValue) }
            foreach ($entityIdValue in $sceneEntityIds) {
                $entityId = [string]$entityIdValue
                if (-not $entityMap.ContainsKey($entityId)) {
                    $continuityPassed = $false
                    $errors.Add("Сцена ${sceneId} ссылается на неизвестную continuity entity '$entityId'.")
                    continue
                }
                $canonicalDescription = [string]$entityMap[$entityId]
                if (-not [string]::IsNullOrWhiteSpace($canonicalDescription)) {
                    if ($imagePrompt.IndexOf($canonicalDescription, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                        $continuityPassed = $false
                        $errors.Add("Сцена ${sceneId}: image_prompt не содержит каноническое описание '$entityId'.")
                    }
                    if ($assetType -eq 'ai_video' -and $videoPrompt.IndexOf($canonicalDescription, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                        $warnings.Add("Сцена ${sceneId}: video_prompt не повторяет каноническое описание '$entityId'; проверь непрерывность персонажа.")
                    }
                }
            }
        }

        if ($aiVideoCount -gt $MaxAiVideoScenes) {
            $assetRoutingPassed = $false
            $errors.Add("В пакете $aiVideoCount сцен ai_video, а локальный профиль разрешает максимум $MaxAiVideoScenes. Переведи часть сцен в image_animation или увеличь лимит в config/settings.json осознанно.")
        }

        # Strict timing: opening/ending effects must be included in scenes, not added after them.
        $durationTolerance = 0.01
        $durationPassed = ([Math]::Abs($durationTotal - $TargetDurationSeconds) -le $durationTolerance)
        if (-not $durationPassed) {
            $errors.Add(('Сумма длительностей сцен — {0:N2} с при цели {1} с. Допуск — 0,01 секунды. Перераспредели duration_seconds.' -f $durationTotal, $TargetDurationSeconds))
        }
        $checks.Add([ordered]@{
            name = 'scene_duration_total'
            passed = $durationPassed
            actual_seconds = [Math]::Round($durationTotal, 2)
            target_seconds = $TargetDurationSeconds
            tolerance_seconds = $durationTolerance
        })

        $narrationMatches = $false
        if (-not [string]::IsNullOrWhiteSpace($fullText) -and $sceneNarration.Count -gt 0) {
            $joinedScenes = ($sceneNarration -join ' ')
            $normalize = { param($value) ([regex]::Replace([string]$value, '\s+', ' ')).Trim() }
            $narrationMatches = ((& $normalize $joinedScenes) -ceq (& $normalize $fullText))
            if (-not $narrationMatches) {
                $errors.Add('Тексты scenes[].voiceover_text не собираются дословно в script.full_text.')
            }
        }
        $checks.Add([ordered]@{ name = 'scene_narration_matches_script'; passed = $narrationMatches })
        $checks.Add([ordered]@{ name = 'scene_ids_unique_and_sequential'; passed = ($sceneOrderPassed -and $sceneIds.Count -eq $scenes.Count) })
        $checks.Add([ordered]@{ name = 'asset_routes_unambiguous'; passed = $assetRoutingPassed })
        $checks.Add([ordered]@{ name = 'visual_prompt_consistency'; passed = $visualPromptConsistencyPassed })
        $checks.Add([ordered]@{ name = 'continuity_references_valid'; passed = $continuityPassed })
    }

    # 5. Overall narration speed is advisory; TTS playback is the final authority.
    if (-not [string]::IsNullOrWhiteSpace($fullText)) {
        $wordsPerSecond = $wordCount / [double]$TargetDurationSeconds
        if ($wordsPerSecond -lt 1.4 -or $wordsPerSecond -gt 2.8) {
            $warnings.Add(('Общий темп около {0:N2} слов/с ({1} слов на {2} с). Прослушай тестовую озвучку.' -f $wordsPerSecond, $wordCount, $TargetDurationSeconds))
        }
        $modelWordCountForCheck = Get-CfValue $script 'estimated_word_count'
        $checks.Add([ordered]@{
            name = 'script_word_count'
            passed = $true
            actual_word_count = $wordCount
            model_word_count = $modelWordCountForCheck
            words_per_second = [Math]::Round($wordsPerSecond, 2)
        })
    }

    # 6. Fact ledger: every claim marked as used must point to an exact excerpt of the narration.
    $research = Get-CfValue $Package 'research_brief'
    $claimsProperty = $null
    if ($null -ne $research) { $claimsProperty = $research.PSObject.Properties['factual_claims'] }
    if ($null -eq $claimsProperty -or $null -eq $claimsProperty.Value -or $claimsProperty.Value -isnot [array]) {
        $claimLedgerPassed = $false
        $errors.Add('research_brief.factual_claims должен присутствовать как массив.')
    }

    $sourcesProperty = $null
    if ($null -ne $research) { $sourcesProperty = $research.PSObject.Properties['source_material_used'] }
    if ($null -eq $sourcesProperty -or $null -eq $sourcesProperty.Value -or $sourcesProperty.Value -isnot [array]) {
        $claimLedgerPassed = $false
        $errors.Add('research_brief.source_material_used должен присутствовать как массив строк; пустой массив допустим.')
    }

    $missingInfoProperty = $null
    if ($null -ne $research) { $missingInfoProperty = $research.PSObject.Properties['missing_information'] }
    if ($null -eq $missingInfoProperty -or $null -eq $missingInfoProperty.Value -or $missingInfoProperty.Value -isnot [array]) {
        $claimLedgerPassed = $false
        $errors.Add('research_brief.missing_information должен присутствовать как массив; пустой массив допустим.')
    }

    $claimsValue = Get-CfValue $research 'factual_claims'
    $claims = @()
    if ($null -ne $claimsValue) { $claims = @($claimsValue) }
    $claimIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $usedClaimCount = 0
    foreach ($claim in $claims) {
        if ($null -eq $claim) {
            $claimLedgerPassed = $false
            $errors.Add('research_brief.factual_claims содержит null вместо объекта утверждения.')
            continue
        }
        $requiredClaimFields = @('claim_id', 'claim', 'claim_type', 'used_in_script', 'script_excerpt', 'verification_status', 'verification_note')
        foreach ($fieldName in $requiredClaimFields) {
            if ($null -eq $claim.PSObject.Properties[$fieldName]) {
                $claimLedgerPassed = $false
                $errors.Add("У factual claim отсутствует обязательное поле '$fieldName'.")
            }
        }
        $usedProperty = $claim.PSObject.Properties['used_in_script']
        if ($null -ne $usedProperty -and $usedProperty.Value -isnot [bool]) {
            $claimLedgerPassed = $false
            $errors.Add('factual_claim.used_in_script должен иметь тип boolean.')
        }
        $claimId = [string](Get-CfValue $claim 'claim_id')
        $claimText = [string](Get-CfValue $claim 'claim')
        $claimType = [string](Get-CfValue $claim 'claim_type')
        $usedInScript = [bool](Get-CfValue $claim 'used_in_script')
        $excerpt = [string](Get-CfValue $claim 'script_excerpt')
        $status = [string](Get-CfValue $claim 'verification_status')

        if ([string]::IsNullOrWhiteSpace($claimId)) {
            $claimLedgerPassed = $false
            $errors.Add('В factual_claims найдено утверждение без claim_id.')
        }
        elseif (-not $claimIds.Add($claimId)) {
            $claimLedgerPassed = $false
            $errors.Add("Повторяется claim_id '$claimId'.")
        }
        if ([string]::IsNullOrWhiteSpace($claimText)) {
            $claimLedgerPassed = $false
            $errors.Add("У factual claim '${claimId}' отсутствует текст claim.")
        }
        if ($claimType -notin @('statistical', 'scientific', 'medical', 'historical', 'legal', 'economic', 'causal', 'other')) {
            $claimLedgerPassed = $false
            $errors.Add("У factual claim '${claimId}' неизвестный claim_type='$claimType'.")
        }
        if ($status -notin @('needs_external_check', 'present_in_user_notes_unverified', 'verified_in_user_material')) {
            $claimLedgerPassed = $false
            $errors.Add("У factual claim '${claimId}' неизвестный verification_status='$status'.")
        }
        if ($usedInScript) {
            $usedClaimCount++
            if ($claimText -match '(?i)\bIQ\b|intelligence quotient|коэффициент интеллекта' -and $excerpt -notmatch '(?i)\bIQ\b|intelligence quotient|коэффициент интеллекта') {
                $claimLedgerPassed = $false
                $errors.Add("Claim '${claimId}': формулировка утверждения содержит IQ/коэффициент интеллекта, но script_excerpt этого не утверждает. Не усиливай claim по сравнению с озвучкой.")
            }
            if ([string]::IsNullOrWhiteSpace($excerpt)) {
                $claimLedgerPassed = $false
                $errors.Add("Claim '${claimId}' помечен used_in_script=true, но script_excerpt пуст.")
            }
            elseif ($fullText.IndexOf($excerpt, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                $claimLedgerPassed = $false
                $errors.Add("Claim '${claimId}': script_excerpt не найден дословно в script.full_text.")
            }
            if ($status -eq 'verified_in_user_material') {
                # This status is only legitimate when the user supplied source material.
                $sourceValue = Get-CfValue $research 'source_material_used'
                $sourceItems = @()
                if ($null -ne $sourceValue) { $sourceItems = @($sourceValue) }
                $usableSources = @($sourceItems | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and [string]$_ -notmatch '(?i)(не предоставлен|не передан|no user material|not provided)' })
                if ($usableSources.Count -eq 0) {
                    $claimLedgerPassed = $false
                    $errors.Add("Claim '${claimId}' помечен verified_in_user_material, но реальный source_material_used не указан.")
                }
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($excerpt)) {
            $claimLedgerPassed = $false
            $errors.Add("Claim '${claimId}' имеет script_excerpt, но used_in_script=false.")
        }
        if ($status -ne 'verified_in_user_material') {
            $warnings.Add("Проверить утверждение ${claimId}: $claimText")
        }
    }

    # Lightweight heuristic only: this flags possible missed claims; it cannot prove factual completeness.
    $claimRiskPattern = '(?i)(\d[\d\s,.]*\s?%|\b\d{4}\b|в (?:два|три|четыре|пять|десять) раз|исследован\w*|уч[её]н\w*|по данным|доказал\w*|согласно|процент\w*|статистик\w*)'
    if ($fullText -match $claimRiskPattern -and $usedClaimCount -eq 0) {
        $warnings.Add('Сценарий содержит возможные числовые/научные/статистические утверждения, но ни одно не связано с ним через factual_claims. Проверь полноту досье.')
    }
    if ($claims.Count -gt 0) {
        $warnings.Add("В research_brief находится утверждений: $($claims.Count). Все непроверенные утверждения проверяются человеком до публикации.")
    }
    $keyPointsValue = Get-CfValue $research 'key_points'
    $healthConceptPatterns = @(
        '(?i)профилактик\w*',
        '(?i)лечен\w*',
        '(?i)медицин\w*',
        '(?i)врач\w*',
        '(?i)осмотр\w*',
        '(?i)диагностик\w*',
        '(?i)болезн\w*',
        '(?i)лекарств\w*',
        '(?i)стоматолог\w*',
        '(?i)питани\w*',
        '(?i)рацион\w*',
        '(?i)страхов\w*'
    )
    foreach ($keyPoint in @($keyPointsValue)) {
        $keyPointText = [string]$keyPoint
        if ($keyPointText -notmatch '(?i)(здоров|лечен|профилактик|болезн|медицин|врач|осмотр|диагностик|лекарств|питани|рацион)') { continue }

        $specificHealthConcepts = @($healthConceptPatterns | Where-Object { $keyPointText -match $_ })
        if ($specificHealthConcepts.Count -gt 0) {
            $uncoveredSpecificConcepts = @($specificHealthConcepts | Where-Object { $fullText -notmatch $_ })
            if ($uncoveredSpecificConcepts.Count -gt 0) {
                $warnings.Add("В research_brief.key_points есть конкретный тезис о профилактике, лечении или медицинских расходах, который script.full_text не раскрывает полностью: '$keyPointText'. Удали тезис или добавь содержательное объяснение.")
                break
            }
        }
        elseif ($fullText -notmatch '(?i)(здоров|лечен|профилактик|болезн|медицин|врач|осмотр|диагностик|лекарств|питани|рацион)') {
            $warnings.Add('В research_brief.key_points есть тезис о здоровье/лечении, который не раскрыт в script.full_text. Удали его или добавь содержательное объяснение.')
            break
        }
    }

    $missingValue = Get-CfValue $research 'missing_information'
    $missingInfo = @()
    if ($null -ne $missingValue) { $missingInfo = @($missingValue) }
    if ($missingInfo.Count -gt 0) {
        $warnings.Add("В research_brief отмечены пробелы в информации: $($missingInfo.Count).")
    }

    # 7. Edit-plan timing contract.
    $editingPlan = Get-CfValue $Package 'editing_plan'
    $openingEndingIncluded = Get-CfValue $editingPlan 'opening_ending_inside_scene_durations'
    $timingContractPassed = ($openingEndingIncluded -eq $true)
    if (-not $timingContractPassed) {
        $errors.Add('editing_plan.opening_ending_inside_scene_durations должен быть true: заставка и финальная выдержка входят в длительности сцен.')
    }
    $checks.Add([ordered]@{ name = 'opening_ending_inside_scene_durations'; passed = $timingContractPassed })

    # 8. Human review section: an empty array is permitted, null/missing is not.
    $humanReviewProperty = $Package.PSObject.Properties['human_review']
    $humanReviewPassed = ($null -ne $humanReviewProperty -and $null -ne $humanReviewProperty.Value -and $humanReviewProperty.Value -is [array])
    if (-not $humanReviewPassed) {
        $errors.Add('human_review должен присутствовать как массив; пустой массив [] допустим.')
    }
    $checks.Add([ordered]@{ name = 'human_review_array'; passed = $humanReviewPassed })

    $checks.Add([ordered]@{ name = 'required_sections_present'; passed = $requiredSectionsPassed })
    $checks.Add([ordered]@{ name = 'research_claim_traceability'; passed = $claimLedgerPassed })
    $checks.Add([ordered]@{ name = 'visual_anchor_consistency'; passed = $visualAnchorsPassed })
    $checks.Add([ordered]@{ name = 'speech_pacing'; passed = $speechPacingPassed })
    $checks.Add([ordered]@{ name = 'character_reference_plan'; passed = $characterReferencePassed })

    return [pscustomobject]@{
        is_valid = ($errors.Count -eq 0)
        errors = @($errors.ToArray())
        warnings = @($warnings.ToArray())
        checks = @($checks.ToArray())
    }
}

Export-ModuleMember -Function Test-CfProductionPackage, Get-CfWordCount
