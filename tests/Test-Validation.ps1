$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\ContentFactory.Validation.psm1') -Force

function Copy-CfTestPackage {
    param([Parameter(Mandatory)][object]$Package)
    return ($Package | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100)
}

function Assert-CfTest {
    param([bool]$Condition, [string]$FailureMessage, [string]$SuccessMessage)
    if (-not $Condition) { throw $FailureMessage }
    Write-Host "OK  $SuccessMessage" -ForegroundColor Green
}

$sampleJson = @'
{
  "schema_version": "2.1",
  "project": {
    "topic": "Тестовая тема",
    "working_title": "Тестовый ролик",
    "platform": "TikTok",
    "language": "ru",
    "target_duration_seconds": 15,
    "target_audience": "Взрослая аудитория",
    "editorial_angle": "Одна проверяемая мысль",
    "tone": "Разговорный",
    "aspect_ratio": "9:16"
  },
  "research_brief": {
    "central_thesis": "Дешёвая покупка не всегда экономит деньги.",
    "key_points": ["Нужно учитывать длительность использования."],
    "factual_claims": [
      {
        "claim_id": "claim_01",
        "claim": "Дешёвая покупка не всегда экономит деньги.",
        "claim_type": "economic",
        "used_in_script": true,
        "script_excerpt": "Дешёвая покупка не всегда экономит деньги.",
        "verification_status": "needs_external_check",
        "verification_note": "Общее экономическое утверждение; конкретные примеры требуют источников."
      }
    ],
    "source_material_used": [],
    "missing_information": []
  },
  "script": {
    "hook": "Сегодня разберём одну мысль.",
    "full_text": "Сегодня разберём одну мысль. Дешёвая покупка не всегда экономит деньги. Важно считать расходы на дистанции.",
    "closing_line": "Важно считать расходы на дистанции.",
    "estimated_word_count": 15
  },
  "visual_style": {
    "overall_direction": "Спокойная кинематографичная редакционная фотография.",
    "palette": ["графитовый", "молочный"],
    "lighting": "Мягкий боковой свет.",
    "camera_language": "Спокойные устойчивые планы.",
    "texture_and_detail": "Естественные фактуры, умеренное зерно.",
    "continuity_rules": ["Если появляется главный персонаж, его внешность неизменна."],
    "negative_prompt": "No text, no logos, no watermark, no shaky camera, no distorted faces.",
    "continuity_entities": [
      {
        "entity_id": "person_main",
        "entity_type": "person",
        "canonical_description": "an adult man with short dark hair wearing a charcoal grey sweater",
        "consistency_rules": ["Одинаковая одежда и причёска во всех сценах."]
      }
    ]
  },
  "scenes": [
    {
      "scene_id": 1,
      "duration_seconds": 5,
      "voiceover_text": "Сегодня разберём одну мысль.",
      "visual_purpose": "Вступительный портрет автора.",
      "asset_type": "generated_image",
      "image_prompt": "Cinematic portrait of an adult man with short dark hair wearing a charcoal grey sweater, thoughtful expression, soft side lighting, vertical portrait 9:16.",
      "video_prompt": "",
      "motion_prompt": "",
      "on_screen_text": "Одна мысль",
      "transition": "Cut",
      "sound_effect": "",
      "production_note": "Надпись добавляется при монтаже.",
      "continuity_notes": "Главный персонаж.",
      "continuity_entity_ids": ["person_main"]
    },
    {
      "scene_id": 2,
      "duration_seconds": 5,
      "voiceover_text": "Дешёвая покупка не всегда экономит деньги.",
      "visual_purpose": "Показать изношенную дешёвую вещь.",
      "asset_type": "image_animation",
      "image_prompt": "Close-up of a worn inexpensive shoe on a neutral workbench, realistic material texture, soft side lighting, vertical portrait 9:16.",
      "video_prompt": "",
      "motion_prompt": "Slow camera push-in toward the worn sole; the shoe remains still.",
      "on_screen_text": "Цена покупки",
      "transition": "Cut",
      "sound_effect": "Soft object tap",
      "production_note": "Движение только камеры.",
      "continuity_notes": "Предметный кадр, без персонажа.",
      "continuity_entity_ids": []
    },
    {
      "scene_id": 3,
      "duration_seconds": 5,
      "voiceover_text": "Важно считать расходы на дистанции.",
      "visual_purpose": "Завершающий кадр с тем же автором.",
      "asset_type": "ai_video",
      "image_prompt": "Cinematic portrait of an adult man with short dark hair wearing a charcoal grey sweater, looking toward a window, soft side lighting, vertical portrait 9:16.",
      "video_prompt": "An adult man with short dark hair wearing a charcoal grey sweater slowly turns his gaze toward the window; stable slow camera pull-back, cinematic muted palette, vertical portrait 9:16.",
      "motion_prompt": "",
      "on_screen_text": "Считай на дистанции",
      "transition": "Fade",
      "sound_effect": "Soft closing tone",
      "production_note": "Короткая спокойная видеовставка.",
      "continuity_notes": "Внешность персонажа фиксирована реестром.",
      "continuity_entity_ids": ["person_main"]
    }
  ],
  "editing_plan": {
    "resolution": "1080x1920",
    "fps": 30,
    "pacing": "Ровный, без спешки.",
    "subtitle_style": "Крупный белый шрифт без декоративных эффектов.",
    "subtitle_position": "Нижняя безопасная зона.",
    "music_mood": "Нейтральная атмосферная музыка.",
    "audio_mix_notes": "Голос заметно громче музыки.",
    "opening_treatment": "Короткая заставка внутри первой сцены.",
    "ending_treatment": "Финальная выдержка внутри последней сцены.",
    "opening_ending_inside_scene_durations": true
  },
  "human_review": []
}
'@

$sample = $sampleJson | ConvertFrom-Json -Depth 100
$sample.script.estimated_word_count = Get-CfWordCount -Text $sample.script.full_text

# 1. Baseline package and empty human_review array.
$result = Test-CfProductionPackage -Package $sample -TargetDurationSeconds 15
Assert-CfTest -Condition $result.is_valid -FailureMessage "Корректный пакет не прошёл проверку: $($result.errors -join '; ')" -SuccessMessage 'Корректный пакет и пустой human_review: [] принимаются.'

# 2. Package schema version must be explicit.
$wrongVersion = Copy-CfTestPackage $sample
$wrongVersion.schema_version = '2.0'
$versionResult = Test-CfProductionPackage -Package $wrongVersion -TargetDurationSeconds 15
Assert-CfTest -Condition (-not $versionResult.is_valid) -FailureMessage 'Пакет версии 2.0 был принят как 2.1.' -SuccessMessage 'Несовместимая версия пакета отклоняется.'

# 3. Missing and null human_review must be rejected.
$missingReview = Copy-CfTestPackage $sample
[void]$missingReview.PSObject.Properties.Remove('human_review')
$missingResult = Test-CfProductionPackage -Package $missingReview -TargetDurationSeconds 15
Assert-CfTest -Condition (-not $missingResult.is_valid) -FailureMessage 'Отсутствующий human_review был принят.' -SuccessMessage 'Отсутствующий human_review отклоняется.'

$nullReview = Copy-CfTestPackage $sample
$nullReview.human_review = $null
$nullResult = Test-CfProductionPackage -Package $nullReview -TargetDurationSeconds 15
Assert-CfTest -Condition (-not $nullResult.is_valid) -FailureMessage 'human_review=null был принят.' -SuccessMessage 'human_review=null отклоняется.'

# 3. Exact scene duration; a 0.5-second drift must fail.
$wrongDuration = Copy-CfTestPackage $sample
$wrongDuration.scenes[2].duration_seconds = 5.5
$durationResult = Test-CfProductionPackage -Package $wrongDuration -TargetDurationSeconds 15
Assert-CfTest -Condition (-not $durationResult.is_valid) -FailureMessage 'Расхождение 0,5 секунды было принято.' -SuccessMessage 'Расхождение хронометража более 0,01 секунды блокируется.'

# 4. Scene narration must reproduce the full script.
$wrongNarration = Copy-CfTestPackage $sample
$wrongNarration.scenes[2].voiceover_text = 'Иной финальный текст.'
$narrationResult = Test-CfProductionPackage -Package $wrongNarration -TargetDurationSeconds 15
Assert-CfTest -Condition (-not $narrationResult.is_valid) -FailureMessage 'Несовпадение озвучки не обнаружено.' -SuccessMessage 'Несовпадение озвучки обнаруживается.'

# 5. Asset routes must be unambiguous.
$extraImageVideoPrompt = Copy-CfTestPackage $sample
$extraImageVideoPrompt.scenes[0].video_prompt = 'A video prompt that must not be present.'
$routeResult = Test-CfProductionPackage -Package $extraImageVideoPrompt -TargetDurationSeconds 15
Assert-CfTest -Condition (-not $routeResult.is_valid) -FailureMessage 'generated_image с video_prompt был принят.' -SuccessMessage 'Лишний video_prompt у generated_image блокируется.'

$missingVideoPrompt = Copy-CfTestPackage $sample
$missingVideoPrompt.scenes[2].video_prompt = ''
$videoResult = Test-CfProductionPackage -Package $missingVideoPrompt -TargetDurationSeconds 15
Assert-CfTest -Condition (-not $videoResult.is_valid) -FailureMessage 'ai_video без video_prompt был принят.' -SuccessMessage 'ai_video без video_prompt отклоняется.'

# 6. Continuity references must resolve and canonical descriptions must be copied.
$unknownEntity = Copy-CfTestPackage $sample
$unknownEntity.scenes[0].continuity_entity_ids = @('missing_entity')
$unknownResult = Test-CfProductionPackage -Package $unknownEntity -TargetDurationSeconds 15
Assert-CfTest -Condition (-not $unknownResult.is_valid) -FailureMessage 'Неизвестная continuity entity была принята.' -SuccessMessage 'Неизвестная continuity entity отклоняется.'

$missingCanonical = Copy-CfTestPackage $sample
$missingCanonical.scenes[2].image_prompt = 'A portrait of an unrelated person, vertical 9:16.'
$canonicalResult = Test-CfProductionPackage -Package $missingCanonical -TargetDurationSeconds 15
Assert-CfTest -Condition (-not $canonicalResult.is_valid) -FailureMessage 'Промпт без канонического описания персонажа был принят.' -SuccessMessage 'Отсутствие канонического описания персонажа обнаруживается.'

# 7. Fact ledger excerpt must match the exact script.
$badClaimExcerpt = Copy-CfTestPackage $sample
$badClaimExcerpt.research_brief.factual_claims[0].script_excerpt = 'В сценарии этого нет.'
$claimResult = Test-CfProductionPackage -Package $badClaimExcerpt -TargetDurationSeconds 15
Assert-CfTest -Condition (-not $claimResult.is_valid) -FailureMessage 'Несовпадающий script_excerpt был принят.' -SuccessMessage 'Ошибочная привязка фактического утверждения к сценарию отклоняется.'

# 8. Opening and ending effects may not extend total duration.
$extraEnding = Copy-CfTestPackage $sample
$extraEnding.editing_plan.opening_ending_inside_scene_durations = $false
$endingResult = Test-CfProductionPackage -Package $extraEnding -TargetDurationSeconds 15
Assert-CfTest -Condition (-not $endingResult.is_valid) -FailureMessage 'Монтажный план с дополнительным хронометражом был принят.' -SuccessMessage 'Дополнительная заставка/финальная выдержка сверх длительности блокируется.'

# 9. Prompt conflicts with global negative prompt must be rejected.
$conflict = Copy-CfTestPackage $sample
$conflict.scenes[0].image_prompt += ' Add readable text on the image.'
$conflictResult = Test-CfProductionPackage -Package $conflict -TargetDurationSeconds 15
Assert-CfTest -Condition (-not $conflictResult.is_valid) -FailureMessage 'Промпт с запрещённым текстом был принят.' -SuccessMessage 'Конфликт визуального промпта с negative_prompt обнаруживается.'

# 10. Word counter ignores punctuation and counts Russian/English words.
$wordCount = Get-CfWordCount -Text 'Привет, мир! AI-видео: 2 сцены.'
Assert-CfTest -Condition ($wordCount -eq 5) -FailureMessage "Подсчёт слов неверен: ожидалось 5, получено $wordCount." -SuccessMessage 'Подсчёт слов не зависит от пунктуации.'

# v2.2: new production runs require visible anchors and a real camera target for image_animation.
$anchored = Copy-CfTestPackage $sample
$anchored.visual_style.continuity_entities[0] | Add-Member -MemberType NoteProperty -Name 'reference_asset_path' -Value 'assets/characters/person_main_reference.png' -Force
$anchored.visual_style.continuity_entities[0] | Add-Member -MemberType NoteProperty -Name 'reference_image_prompt' -Value ('Cinematic identity portrait. ' + [string]$anchored.visual_style.continuity_entities[0].canonical_description) -Force
$anchored.scenes[0].visual_purpose = 'Cinematic portrait of an adult man in a charcoal grey sweater.'
$anchored.scenes[0] | Add-Member -MemberType NoteProperty -Name 'visual_anchor_terms' -Value @('Cinematic portrait', 'charcoal grey sweater') -Force
$anchored.scenes[0] | Add-Member -MemberType NoteProperty -Name 'motion_target' -Value '' -Force
$anchored.scenes[1].visual_purpose = 'A worn inexpensive shoe rests on a neutral workbench.'
$anchored.scenes[1] | Add-Member -MemberType NoteProperty -Name 'visual_anchor_terms' -Value @('worn inexpensive shoe', 'neutral workbench') -Force
$anchored.scenes[1] | Add-Member -MemberType NoteProperty -Name 'motion_target' -Value 'worn inexpensive shoe' -Force
$anchored.scenes[1].motion_prompt = 'Slow stabilized camera push-in toward worn inexpensive shoe; the shoe remains still.'
$anchored.scenes[2].visual_purpose = 'Closing shot of the same adult man looking toward a window.'
$anchored.scenes[2] | Add-Member -MemberType NoteProperty -Name 'visual_anchor_terms' -Value @('adult man', 'window') -Force
$anchored.scenes[2] | Add-Member -MemberType NoteProperty -Name 'motion_target' -Value '' -Force
$anchorResult = Test-CfProductionPackage -Package $anchored -TargetDurationSeconds 15 -RequireVisualAnchors -MaxAiVideoScenes 2
Assert-CfTest -Condition $anchorResult.is_valid -FailureMessage "Корректные visual anchors не прошли проверку: $($anchorResult.errors -join '; ')" -SuccessMessage 'Визуальные якоря и motion_target проходят строгую проверку.'

$missingMotionTarget = Copy-CfTestPackage $anchored
$null = $missingMotionTarget.scenes[0].PSObject.Properties.Remove('motion_target')
$missingMotionTargetResult = Test-CfProductionPackage -Package $missingMotionTarget -TargetDurationSeconds 15 -RequireVisualAnchors -MaxAiVideoScenes 2
Assert-CfTest -Condition (-not $missingMotionTargetResult.is_valid) -FailureMessage 'Сцена без обязательного motion_target была принята.' -SuccessMessage 'Отсутствующий motion_target блокируется строгим контрактом v2.2.'

$unexpectedMotionTarget = Copy-CfTestPackage $anchored
$unexpectedMotionTarget.scenes[0].motion_target = 'adult man'
$unexpectedMotionTargetResult = Test-CfProductionPackage -Package $unexpectedMotionTarget -TargetDurationSeconds 15 -RequireVisualAnchors -MaxAiVideoScenes 2
Assert-CfTest -Condition (-not $unexpectedMotionTargetResult.is_valid) -FailureMessage 'motion_target у generated_image был принят.' -SuccessMessage 'motion_target должен быть пустым вне image_animation.'

$badAnchor = Copy-CfTestPackage $anchored
$badAnchor.scenes[0].image_prompt = 'A cinematic portrait in a dark empty studio, vertical 9:16.'
$badAnchorResult = Test-CfProductionPackage -Package $badAnchor -TargetDurationSeconds 15 -RequireVisualAnchors -MaxAiVideoScenes 2
Assert-CfTest -Condition (-not $badAnchorResult.is_valid) -FailureMessage 'Несоответствующий visual_anchor_term был принят.' -SuccessMessage 'Якорь, отсутствующий в image_prompt, блокирует пакет.'

$badPurpose = Copy-CfTestPackage $anchored
$badPurpose.scenes[0].visual_purpose = 'An empty studio with dramatic lighting.'
$badPurposeResult = Test-CfProductionPackage -Package $badPurpose -TargetDurationSeconds 15 -RequireVisualAnchors -MaxAiVideoScenes 2
Assert-CfTest -Condition (-not $badPurposeResult.is_valid) -FailureMessage 'Якорь, отсутствующий в visual_purpose, был принят.' -SuccessMessage 'Якоря обязаны соответствовать visual_purpose, а не только image_prompt.'

$badVideoAnchor = Copy-CfTestPackage $anchored
$badVideoAnchor.scenes[2].video_prompt = 'An adult man slowly turns his gaze; stable slow camera pull-back.'
$badVideoAnchorResult = Test-CfProductionPackage -Package $badVideoAnchor -TargetDurationSeconds 15 -RequireVisualAnchors -MaxAiVideoScenes 2
Assert-CfTest -Condition (-not $badVideoAnchorResult.is_valid) -FailureMessage 'ai_video без всех visual anchors был принят.' -SuccessMessage 'video_prompt обязан сохранять все ключевые визуальные якоря.'

$tooManyWan = Copy-CfTestPackage $anchored
$tooManyWan.scenes[0].asset_type = 'ai_video'
$tooManyWan.scenes[0].video_prompt = 'Cinematic portrait of an adult man in a charcoal grey sweater slowly turns toward camera.'
$tooManyWan.scenes[1].asset_type = 'ai_video'
$tooManyWan.scenes[1].video_prompt = 'A worn inexpensive shoe on a neutral workbench slowly shifts in frame.'
$tooManyWan.scenes[1].motion_prompt = ''
$tooManyWan.scenes[1].motion_target = ''
$tooManyWanResult = Test-CfProductionPackage -Package $tooManyWan -TargetDurationSeconds 15 -RequireVisualAnchors -MaxAiVideoScenes 2
Assert-CfTest -Condition (@($tooManyWanResult.errors | Where-Object { $_ -match 'локальный профиль разрешает максимум 2' }).Count -gt 0) -FailureMessage 'Валидатор принял больше двух Wan-сцен.' -SuccessMessage 'Превышение локального лимита Wan блокируется.'






# v2.3: a comma or letter-case difference inside an otherwise identical phrase must not block the package.
# Real run: canonical description "A worn, leather brown wallet" vs anchor "worn leather brown wallet".
$commaTolerant = Copy-CfTestPackage $anchored
$commaTolerant.scenes[1].image_prompt = 'Close-up of a Worn, Inexpensive shoe on a neutral workbench, soft side lighting, vertical portrait 9:16.'
$commaTolerantResult = Test-CfProductionPackage -Package $commaTolerant -TargetDurationSeconds 15 -RequireVisualAnchors -MaxAiVideoScenes 2
Assert-CfTest -Condition $commaTolerantResult.is_valid -FailureMessage "Запятая/регистр внутри якоря блокирует пакет: $($commaTolerantResult.errors -join '; ')" -SuccessMessage 'Различия в пунктуации и регистре внутри якоря не блокируют пакет.'

$wrongWordOrder = Copy-CfTestPackage $anchored
$wrongWordOrder.scenes[1].image_prompt = 'Close-up of an inexpensive worn shoe on a neutral workbench, soft side lighting, vertical portrait 9:16.'
$wrongWordOrderResult = Test-CfProductionPackage -Package $wrongWordOrder -TargetDurationSeconds 15 -RequireVisualAnchors -MaxAiVideoScenes 2
Assert-CfTest -Condition (-not $wrongWordOrderResult.is_valid) -FailureMessage 'Перестановка слов внутри якоря была принята.' -SuccessMessage 'Нормализация не ослабляет проверку: порядок слов в якоре обязателен.'

# v2.3 advisory hygiene checks.
$englishCaption = Copy-CfTestPackage $sample
$englishCaption.scenes[0].on_screen_text = 'High Interest'
$englishCaptionResult = Test-CfProductionPackage -Package $englishCaption -TargetDurationSeconds 15
Assert-CfTest -Condition (@($englishCaptionResult.warnings | Where-Object { $_ -match 'не по-русски' }).Count -gt 0) -FailureMessage 'Английская надпись в русском ролике не отмечена.' -SuccessMessage 'Надпись не на языке озвучки попадает в предупреждения.'

$crossSceneReference = Copy-CfTestPackage $sample
$crossSceneReference.scenes[0].visual_purpose = 'The worn leather wallet from the first scene, now in a very dark frame.'
$crossSceneReferenceResult = Test-CfProductionPackage -Package $crossSceneReference -TargetDurationSeconds 15
Assert-CfTest -Condition (@($crossSceneReferenceResult.warnings | Where-Object { $_ -match 'ссылается на другую сцену' }).Count -gt 0) -FailureMessage 'Ссылка visual_purpose на другую сцену не отмечена.' -SuccessMessage 'Ссылка визуального замысла на другую сцену попадает в предупреждения.'

$emptyMotionGraphic = Copy-CfTestPackage $sample
$emptyMotionGraphic.scenes[1].asset_type = 'motion_graphic'
$emptyMotionGraphic.scenes[1].on_screen_text = ''
$emptyMotionGraphicResult = Test-CfProductionPackage -Package $emptyMotionGraphic -TargetDurationSeconds 15
Assert-CfTest -Condition (@($emptyMotionGraphicResult.warnings | Where-Object { $_ -match 'motion_graphic без on_screen_text' }).Count -gt 0) -FailureMessage 'motion_graphic без текста не отмечен как подозрительный маршрут.' -SuccessMessage 'motion_graphic без on_screen_text попадает в предупреждения.'

# v2.2: claim wording may not be stronger than the script excerpt (IQ overclaim guard).
$iqOverclaim = Copy-CfTestPackage $sample
$iqOverclaim.research_brief.factual_claims[0].claim = 'Бедность снижает IQ.'
$iqOverclaim.research_brief.factual_claims[0].script_excerpt = 'Дешёвая покупка не всегда экономит деньги.'
$iqResult = Test-CfProductionPackage -Package $iqOverclaim -TargetDurationSeconds 15
Assert-CfTest -Condition (-not $iqResult.is_valid) -FailureMessage 'Claim про IQ без соответствующего утверждения в excerpt был принят.' -SuccessMessage 'Чрезмерное научное утверждение о IQ блокируется.'

# v2.2: a research key point should not promise a health topic absent from the narration.
$uncoveredKeyPoint = Copy-CfTestPackage $sample
$uncoveredKeyPoint.research_brief.key_points += 'Профилактика здоровья снижает будущие медицинские расходы.'
$keyPointResult = Test-CfProductionPackage -Package $uncoveredKeyPoint -TargetDurationSeconds 15
Assert-CfTest -Condition (@($keyPointResult.warnings | Where-Object { $_ -match 'key_points.*здоровья' }).Count -gt 0) -FailureMessage 'Неосвещённый тезис о здоровье не был отмечен.' -SuccessMessage 'Неосвещённый тезис о здоровье попадает в предупреждения.'

$healthOnlyMention = Copy-CfTestPackage $sample
$healthOnlyMention.script.full_text = 'Сегодня разберём одну мысль. Дешёвая покупка не всегда экономит деньги. Важно считать расходы на дистанции. Здоровье тоже важно.'
$healthOnlyMention.script.closing_line = 'Здоровье тоже важно.'
$healthOnlyMention.research_brief.key_points = @('Профилактика здоровья снижает будущие медицинские расходы.')
$healthOnlyResult = Test-CfProductionPackage -Package $healthOnlyMention -TargetDurationSeconds 15
Assert-CfTest -Condition (@($healthOnlyResult.warnings | Where-Object { $_ -match 'конкретный тезис о профилактике' }).Count -gt 0) -FailureMessage 'Общее слово «здоровье» ошибочно засчитано как раскрытие профилактики и лечения.' -SuccessMessage 'Общее упоминание здоровья не маскирует нераскрытый тезис о профилактике/лечении.'

Write-Host 'Все тесты ContentFactory v2.3.0 пройдены.' -ForegroundColor Green
