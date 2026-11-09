$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $Root 'src\ContentFactory.Repair.psm1') -Force

$sample = @'
{
  "script": {
    "full_text": "Бедность увеличивает расходы. Дешёвые товары приходится заменять чаще."
  },
  "visual_style": {
    "negative_prompt": "no camera shake, no handheld shots",
    "continuity_entities": [
      {
        "entity_id": "person_01",
        "entity_type": "person",
        "canonical_description": "A middle-aged man with short dark hair, wearing a charcoal grey sweater."
      }
    ]
  },
  "scenes": [
    {
      "scene_id": 1,
      "duration_seconds": 12.0,
      "asset_type": "ai_video",
      "image_prompt": "A cinematic portrait in a modest apartment, vertical 9:16.",
      "video_prompt": "The man looks out of the window; handheld shot with subtle camera shake.",
      "motion_prompt": "",
      "continuity_entity_ids": ["person_01"]
    },
    {
      "scene_id": 2,
      "duration_seconds": 13.0,
      "asset_type": "generated_image",
      "image_prompt": "Close-up of worn inexpensive shoes on a wooden floor, vertical 9:16.",
      "video_prompt": "",
      "motion_prompt": "",
      "continuity_entity_ids": []
    },
    {
      "scene_id": 3,
      "duration_seconds": 36.5,
      "asset_type": "generated_image",
      "image_prompt": "A quiet city street at dusk, vertical 9:16.",
      "video_prompt": "",
      "motion_prompt": "",
      "continuity_entity_ids": []
    }
  ],
  "research_brief": {
    "factual_claims": [
      {
        "claim_id": "claim_01",
        "claim": "Дешёвые товары приходится заменять чаще.",
        "used_in_script": true,
        "script_excerpt": "Доступные товары часто ломаются быстрее."
      }
    ]
  },
  "human_review": []
}
'@

# Regression: 36.5-second source scene must not become 35.61 seconds after scaling.
$package = $sample | ConvertFrom-Json -Depth 30
$changes = @(Repair-CfPackageStructure -Package $package -TargetDurationSeconds 60)
$actualDurations = @($package.scenes | ForEach-Object { [Math]::Round([double]$_.duration_seconds, 2) })
$expectedDurations = @(14.4, 15.6, 30.0)
if ($actualDurations.Count -ne $expectedDurations.Count) { throw 'Нормализатор изменил количество сцен.' }
for ($i = 0; $i -lt $expectedDurations.Count; $i++) {
    if ([Math]::Abs($actualDurations[$i] - $expectedDurations[$i]) -gt 0.001) {
        throw "Неверная bounded-нормализация сцены $($i + 1): ожидалось $($expectedDurations[$i]), получено $($actualDurations[$i])."
    }
    if ($actualDurations[$i] -lt 1 -or $actualDurations[$i] -gt 30) {
        throw "Сцена $($i + 1) оказалась вне допустимого диапазона 1–30 секунд."
    }
}
$total = [Math]::Round(($actualDurations | Measure-Object -Sum).Sum, 2)
if ($total -ne 60.0) { throw "Хронометраж после нормализации должен быть 60.00, получено $total." }
if ($changes.Count -eq 0) { throw 'Ожидались записи об автоматической нормализации.' }
Write-Host 'OK  61,5 секунды нормализованы до 60,0 с ограничением 1–30 секунд на сцену.' -ForegroundColor Green


# Narration must be re-segmented from script.full_text, never paraphrased, when scene fragments drift.
$joinedNarration = [string]::Join(' ', [string[]]@($package.scenes | ForEach-Object { [string]$_.voiceover_text }))
$normalizedJoined = ([regex]::Replace($joinedNarration, '\s+', ' ')).Trim()
$normalizedScript = ([regex]::Replace([string]$package.script.full_text, '\s+', ' ')).Trim()
if ($normalizedJoined -cne $normalizedScript) { throw 'Сегменты voiceover_text не собираются обратно в script.full_text.' }
if (@($changes | Where-Object { $_ -match 'Озвучка сцен синхронизирована' }).Count -ne 1) {
    throw 'Ожидалась одна запись о синхронизации фрагментов озвучки.'
}
Write-Host 'OK  voiceover_text дословно пересобирается из script.full_text без перефразирования.' -ForegroundColor Green

# Regression: PowerShell source must parse quote-aware sentence-boundary regex safely,
# and Russian guillemets around a sentence must remain part of exact narration text.
$quotedPackage = $sample | ConvertFrom-Json -Depth 30
$quotedPackage.script.full_text = 'Автор сказал: «Проверь сценарий.» Затем он ушёл.'
foreach ($scene in $quotedPackage.scenes) {
    $voiceoverProperty = $scene.PSObject.Properties['voiceover_text']
    if ($null -eq $voiceoverProperty) {
        $scene | Add-Member -MemberType NoteProperty -Name 'voiceover_text' -Value 'старый текст' -Force
    }
    else {
        $scene.voiceover_text = 'старый текст'
    }
}
$null = Repair-CfPackageStructure -Package $quotedPackage -TargetDurationSeconds 60
$quotedJoined = [string]::Join(' ', [string[]]@($quotedPackage.scenes | ForEach-Object { [string]$_.voiceover_text }))
$quotedJoinedNormalized = ([regex]::Replace($quotedJoined, '\s+', ' ')).Trim()
$quotedScriptNormalized = ([regex]::Replace([string]$quotedPackage.script.full_text, '\s+', ' ')).Trim()
if ($quotedJoinedNormalized -cne $quotedScriptNormalized) {
    throw 'Синхронизация озвучки нарушила текст с русскими кавычками.'
}
Write-Host 'OK  Границы предложений с русскими кавычками обрабатываются корректно.' -ForegroundColor Green

# Global negative prompt forbids shake/handheld, so sanitize conflicting scene prompts.
if ($package.scenes[0].video_prompt -match '(?i)camera\s*shakes?|shaky[\s-]*cam|hand[\s-]*held') {
    throw 'Противоречащая camera-shake/handheld формулировка осталась в video_prompt.'
}
if ($package.scenes[0].video_prompt -notmatch '(?i)stabilized') {
    throw 'Ожидалась замена конфликтующего движения на стабилизированное.'
}
Write-Host 'OK  Конфликт camera shake/handheld с global negative_prompt автоматически устранён.' -ForegroundColor Green

# Even when the original total is exact, an overlong scene must be bounded.
$exactButOutOfRange = $sample | ConvertFrom-Json -Depth 30
$exactButOutOfRange.scenes = @($exactButOutOfRange.scenes[0], $exactButOutOfRange.scenes[1])
$exactButOutOfRange.scenes[0].duration_seconds = 20.0
$exactButOutOfRange.scenes[1].duration_seconds = 40.0
$null = Repair-CfPackageStructure -Package $exactButOutOfRange -TargetDurationSeconds 60
$boundedExact = @($exactButOutOfRange.scenes | ForEach-Object { [Math]::Round([double]$_.duration_seconds, 2) })
if ($boundedExact[0] -ne 30.0 -or $boundedExact[1] -ne 30.0) {
    throw "Сумма 60 секунд с исходной сценой 40 секунд должна быть безопасно ограничена до 30/30, получено: $($boundedExact -join '/')."
}
Write-Host 'OK  Сцена >30 секунд корректируется даже при уже точной общей сумме.' -ForegroundColor Green

$canonical = [string]$package.visual_style.continuity_entities[0].canonical_description
if ($package.scenes[0].image_prompt.IndexOf($canonical, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw 'Canonical description не добавлено в image_prompt.'
}
if ($package.scenes[0].video_prompt.IndexOf($canonical, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw 'Canonical description не добавлено в video_prompt.'
}
$beforeImagePrompt = [string]$package.scenes[0].image_prompt
$secondChanges = @(Repair-CfPackageStructure -Package $package -TargetDurationSeconds 60)
if ($secondChanges.Count -ne 0) { throw 'Повторный запуск ремонта не должен вносить новые изменения.' }
if ([string]$package.scenes[0].image_prompt -ne $beforeImagePrompt) {
    throw 'Повторный запуск ремонта создал дубликат canonical description.'
}
Write-Host 'OK  Canonical description добавляется в image/video prompts; повторный запуск идемпотентен.' -ForegroundColor Green


# v2.2: a person reused across multiple scenes receives one stable reference image path and prompt.
$characterPackage = $sample | ConvertFrom-Json -Depth 30
$characterPackage.scenes[1].continuity_entity_ids = @('person_01')
$null = Repair-CfPackageStructure -Package $characterPackage -TargetDurationSeconds 60
$characterEntity = $characterPackage.visual_style.continuity_entities[0]
if ($characterEntity.reference_asset_path -ne 'assets/characters/person_01_reference.png') { throw 'Для повторяющегося персонажа не создан reference_asset_path.' }
if ([string]::IsNullOrWhiteSpace([string]$characterEntity.reference_image_prompt)) { throw 'Для повторяющегося персонажа не создан reference_image_prompt.' }
if (@($characterPackage.human_review | Where-Object { $_ -match 'единый референс' }).Count -eq 0) { throw 'Создание reference PNG не добавлено в human_review.' }
Write-Host 'OK  Повторяющийся персонаж получает единый reference PNG и инструкцию ручного утверждения.' -ForegroundColor Green

# Non-person continuity entities must not receive a portrait identity-reference path.
$objectPackage = $sample | ConvertFrom-Json -Depth 30
$objectPackage.visual_style.continuity_entities[0].entity_type = 'object'
$objectPackage.scenes[1].continuity_entity_ids = @('person_01')
$null = Repair-CfPackageStructure -Package $objectPackage -TargetDurationSeconds 60
$objectEntity = $objectPackage.visual_style.continuity_entities[0]
if ($null -ne $objectEntity.PSObject.Properties['reference_asset_path']) {
    throw 'Неперсональная continuity entity ошибочно получила портретный reference_asset_path.'
}
Write-Host 'OK  Неперсональные continuity entities не получают портретный identity reference.' -ForegroundColor Green

$candidates = @(Get-CfClaimsNeedingExcerptRepair -Package $package)
if ($candidates.Count -ne 1 -or $candidates[0].claim_id -ne 'claim_01') {
    throw 'Поиск claim с неточным script_excerpt вернул неверный результат.'
}
$applied = @(Set-CfClaimExcerptRepairs -Package $package -Repairs @(
    [pscustomobject]@{
        claim_id = 'claim_01'
        script_excerpt = 'Дешёвые товары приходится заменять чаще.'
    }
))
if ($applied.Count -ne 1 -or $applied[0] -ne 'claim_01') { throw 'Точная цитата не была применена.' }
$remainingCandidates = @(Get-CfClaimsNeedingExcerptRepair -Package $package)
if ($remainingCandidates.Count -ne 0) {
    throw 'После применения точной цитаты claim всё ещё отмечается для ремонта.'
}
Write-Host 'OK  Claim excerpt исправляется только на дословный фрагмент сценария.' -ForegroundColor Green

$unchanged = Set-CfClaimExcerptRepairs -Package $package -Repairs @(
    [pscustomobject]@{
        claim_id = 'claim_01'
        script_excerpt = 'Фраза, которой нет в сценарии.'
    }
)
if (@($unchanged).Count -ne 0) { throw 'Недословная цитата не должна применяться.' }
Write-Host 'OK  Недословная цитата отбрасывается.' -ForegroundColor Green

if (@($package.human_review).Count -lt 2) { throw 'Автокоррекции не добавили запись в human_review.' }
Write-Host 'OK  Все автоматические правки отражены в human_review.' -ForegroundColor Green

# An infeasible target (one scene cannot cover a 60-second short under a 30-second cap) must fail clearly.
$oneScenePackage = $sample | ConvertFrom-Json -Depth 30
$oneScenePackage.scenes = @($oneScenePackage.scenes[0])
$infeasibleRejected = $false
try {
    $null = Repair-CfPackageStructure -Package $oneScenePackage -TargetDurationSeconds 60
}
catch {
    if ($_.Exception.Message -match 'не могут вместить целевые') { $infeasibleRejected = $true }
    else { throw }
}
if (-not $infeasibleRejected) { throw 'Невозможное распределение на одну сцену должно отклоняться с понятной причиной.' }
Write-Host 'OK  Невозможное распределение по числу сцен отклоняется с понятной ошибкой.' -ForegroundColor Green

# Large overall runtime changes are still rejected rather than silently repaired.
$tooLongPackage = $sample | ConvertFrom-Json -Depth 30
$tooLongPackage.scenes[0].duration_seconds = 30.0
$tooLongPackage.scenes[1].duration_seconds = 30.0
$tooLongPackage.scenes[2].duration_seconds = 40.0
$largeChangeRejected = $false
try {
    $null = Repair-CfPackageStructure -Package $tooLongPackage -TargetDurationSeconds 60
}
catch {
    if ($_.Exception.Message -match 'больше допустимых 15%') { $largeChangeRejected = $true }
    else { throw }
}
if (-not $largeChangeRejected) { throw 'Слишком большая коррекция хронометража должна быть отклонена.' }
Write-Host 'OK  Чрезмерная общая коррекция хронометража не применяется автоматически.' -ForegroundColor Green
Write-Host 'OK  Базовые регрессионные тесты нормализации пройдены.' -ForegroundColor Green


# v2.2: word-weighted pacing prevents a long final narration segment from being squeezed into a short scene.
$pacingPackage = @'
{
  "script": {"full_text": "Один два три четыре пять. шесть семь восемь девять десять. одиннадцать двенадцать тринадцать четырнадцать пятнадцать шестнадцать семнадцать восемнадцать девятнадцать двадцать."},
  "visual_style": {"negative_prompt": "no shaky camera", "continuity_entities": []},
  "scenes": [
    {"scene_id":1,"duration_seconds":10,"voiceover_text":"Один два три четыре пять." ,"asset_type":"generated_image","image_prompt":"five words visible","video_prompt":"","motion_prompt":"","continuity_entity_ids":[]},
    {"scene_id":2,"duration_seconds":10,"voiceover_text":"шесть семь восемь девять десять." ,"asset_type":"generated_image","image_prompt":"five words visible","video_prompt":"","motion_prompt":"","continuity_entity_ids":[]},
    {"scene_id":3,"duration_seconds":40,"voiceover_text":"одиннадцать двенадцать тринадцать четырнадцать пятнадцать шестнадцать семнадцать восемнадцать девятнадцать двадцать." ,"asset_type":"generated_image","image_prompt":"ten words visible","video_prompt":"","motion_prompt":"","continuity_entity_ids":[]}
  ],
  "editing_plan": {"opening_ending_inside_scene_durations":true},
  "human_review": []
}
'@ | ConvertFrom-Json -Depth 20
$null = Repair-CfPackageStructure -Package $pacingPackage -TargetDurationSeconds 60 -MaxAiVideoScenes 2 -RebalanceTimingBySpeech
$pacing = @($pacingPackage.scenes | ForEach-Object { [double]$_.duration_seconds })
$rates = @()
foreach ($scene in $pacingPackage.scenes) { $wordCountForScene = [regex]::Matches([string]$scene.voiceover_text, "[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*").Count
    $rates += ($wordCountForScene / [double]$scene.duration_seconds) }
if ([Math]::Abs($rates[0] - $rates[2]) -gt 0.15) { throw ('Речевой темп не выровнен: {0:N2} против {1:N2} слов/с.' -f $rates[0],$rates[2]) }
if ([Math]::Round(($pacing | Measure-Object -Sum).Sum,2) -ne 60.0) { throw 'Речевое распределение нарушило общую длительность.' }
Write-Host 'OK  Речевой тайминг распределяется по словам, а не сохраняет перегруженную финальную сцену.' -ForegroundColor Green

# v2.2: regression using the actual seven-scene/137-word pacing pattern observed in a user project.
$realScriptSegments = @(
    'Бедность — это не просто отсутствие денег в кошельке. Это самый дорогой налог, который можно заплатить.',
    'Посмотрите на это с точки зрения экономики. Когда у вас мало средств, вы вынуждены покупать товары в маленьких упаковках.',
    'Вы платите за каждый грамм или литр больше, чем тот, кто может позволить себе оптовую партию. Это прямой налог на нехватку капитала.',
    'Но есть и скрытые расходы. Когда мозг постоянно занят вопросом ''как выжить сегодня'', у него просто не остается ресурсов на долгосрочные стратегии.',
    'Постоянный стресс от нехватки денег буквально снижает когнитивные способности, заставляя человека совершать импульсивные решения.',
    'В итоге, вместо того чтобы инвестировать в будущее, человек тратит остатки сил на тушение пожаров в настоящем.',
    'Бедность обходится дорого, потому что она крадет ваше время, ваше здоровье и вашу способность планировать. Богатство — это возможность покупать время, а бедность — это обязанность продавать его за выживание.'
)
$realTimingPackage = [pscustomobject]@{
    script = [pscustomobject]@{ full_text = ($realScriptSegments -join ' '); estimated_word_count = 137 }
    visual_style = [pscustomobject]@{ negative_prompt = 'no shaky camera'; continuity_entities = @() }
    scenes = @(
        [pscustomobject]@{ scene_id=1; duration_seconds=7.39; voiceover_text=$realScriptSegments[0]; asset_type='ai_video'; image_prompt='portrait'; video_prompt='A man turns'; motion_prompt=''; continuity_entity_ids=@(); visual_anchor_terms=@('portrait','man'); motion_target='' },
        [pscustomobject]@{ scene_id=2; duration_seconds=8.70; voiceover_text=$realScriptSegments[1]; asset_type='motion_graphic'; image_prompt='small package and large package'; video_prompt=''; motion_prompt='Small package moves'; continuity_entity_ids=@(); visual_anchor_terms=@('small package','large package'); motion_target='' },
        [pscustomobject]@{ scene_id=3; duration_seconds=9.13; voiceover_text=$realScriptSegments[2]; asset_type='image_animation'; image_prompt='gold coin'; video_prompt=''; motion_prompt='Slow camera zoom toward gold coin'; continuity_entity_ids=@(); visual_anchor_terms=@('gold coin','dark background'); motion_target='gold coin' },
        [pscustomobject]@{ scene_id=4; duration_seconds=10.42; voiceover_text=$realScriptSegments[3]; asset_type='image_animation'; image_prompt='human brain'; video_prompt=''; motion_prompt='Slow camera push-in toward human brain'; continuity_entity_ids=@(); visual_anchor_terms=@('human brain','dark background'); motion_target='human brain' },
        [pscustomobject]@{ scene_id=5; duration_seconds=8.70; voiceover_text=$realScriptSegments[4]; asset_type='image_animation'; image_prompt='man and bills'; video_prompt=''; motion_prompt='Slow camera push-in toward man'; continuity_entity_ids=@(); visual_anchor_terms=@('man','bills'); motion_target='man' },
        [pscustomobject]@{ scene_id=6; duration_seconds=7.83; voiceover_text=$realScriptSegments[5]; asset_type='image_animation'; image_prompt='hands and fire'; video_prompt=''; motion_prompt='Slow camera pan toward hands'; continuity_entity_ids=@(); visual_anchor_terms=@('hands','fire'); motion_target='hands' },
        [pscustomobject]@{ scene_id=7; duration_seconds=7.83; voiceover_text=$realScriptSegments[6]; asset_type='ai_video'; image_prompt='portrait'; video_prompt='A man nods'; motion_prompt=''; continuity_entity_ids=@(); visual_anchor_terms=@('portrait','man'); motion_target='' }
    )
    editing_plan = [pscustomobject]@{ opening_ending_inside_scene_durations = $true }
    human_review = @()
}
$null = Repair-CfPackageStructure -Package $realTimingPackage -TargetDurationSeconds 60 -MaxAiVideoScenes 2 -RebalanceTimingBySpeech
$realRates = @()
foreach ($scene in $realTimingPackage.scenes) {
    $wordCountForScene = [regex]::Matches([string]$scene.voiceover_text, "[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*").Count
    $realRates += ($wordCountForScene / [double]$scene.duration_seconds)
}
$realTotal = [Math]::Round((($realTimingPackage.scenes | Measure-Object -Property duration_seconds -Sum).Sum), 2)
if ($realTotal -ne 60.0) { throw "Реальный 7-сценный тест нарушил хронометраж: $realTotal." }
if (($realRates | Measure-Object -Maximum).Maximum -gt 2.8) { throw ('Реальный тест оставил слишком быстрый фрагмент: {0:N2} слов/с.' -f ($realRates | Measure-Object -Maximum).Maximum) }
if ((($realRates | Measure-Object -Maximum).Maximum - ($realRates | Measure-Object -Minimum).Minimum) -gt 0.35) { throw 'Речевой темп реального 7-сценного теста распределён неравномерно.' }
Write-Host 'OK  Регрессия на семисценном сценарии из 137 слов: финальная сцена не перегружена, общий тайминг 60,00 с.' -ForegroundColor Green

# v2.2: deterministic Wan budget keeps hook/ending and downgrades intermediate scenes to FFmpeg image animation.
$budgetPackage = @'
{
  "script":{"full_text":"Один два три четыре пять шесть семь восемь."},
  "visual_style":{"negative_prompt":"no shaky camera","continuity_entities":[]},
  "scenes":[
    {"scene_id":1,"duration_seconds":15,"voiceover_text":"Один два.","asset_type":"ai_video","visual_purpose":"A hero wallet casts a large shadow across a table.","image_prompt":"hero wallet and large shadow on a table","video_prompt":"A wallet moves.","motion_prompt":"","visual_anchor_terms":["hero wallet","large shadow"],"continuity_entity_ids":[]},
    {"scene_id":2,"duration_seconds":15,"voiceover_text":"три четыре.","asset_type":"ai_video","visual_purpose":"A small yogurt cup stands beside a price tag.","image_prompt":"small yogurt cup beside a price tag","video_prompt":"A yogurt cup moves.","motion_prompt":"","visual_anchor_terms":["small yogurt cup","price tag"],"continuity_entity_ids":[]},
    {"scene_id":3,"duration_seconds":15,"voiceover_text":"пять шесть.","asset_type":"ai_video","visual_purpose":"A gold coin falls beside a ground crack.","image_prompt":"gold coin and ground crack","video_prompt":"A coin falls.","motion_prompt":"","visual_anchor_terms":["gold coin","ground crack"],"continuity_entity_ids":[]},
    {"scene_id":4,"duration_seconds":15,"voiceover_text":"семь восемь.","asset_type":"ai_video","visual_purpose":"A man stands in a dark room.","image_prompt":"man in a dark room","video_prompt":"A man turns.","motion_prompt":"","visual_anchor_terms":["man","dark room"],"continuity_entity_ids":[]}
  ],
  "editing_plan":{"opening_ending_inside_scene_durations":true},"human_review":[]
}
'@ | ConvertFrom-Json -Depth 20
# The source scenes intentionally omit optional motion_target properties, as real model JSON may do.
foreach ($sceneIndex in @(1, 2)) {
    if ($null -ne $budgetPackage.scenes[$sceneIndex].PSObject.Properties['motion_target']) {
        throw "Тестовая сцена $($sceneIndex + 1) должна изначально не содержать motion_target."
    }
}
$budgetNotes = @(Repair-CfPackageStructure -Package $budgetPackage -TargetDurationSeconds 60 -MaxAiVideoScenes 2)
foreach ($sceneIndex in @(1, 2)) {
    if ($null -eq $budgetPackage.scenes[$sceneIndex].PSObject.Properties['motion_target']) {
        throw "Repair-CfrAiVideoBudget не добавил отсутствующее свойство motion_target для сцены $($sceneIndex + 1)."
    }
}
$remainingAi = @($budgetPackage.scenes | Where-Object { $_.asset_type -eq 'ai_video' }).Count
if ($remainingAi -ne 2) { throw "Лимит Wan не соблюдён: осталось $remainingAi сцен ai_video." }
if ($budgetPackage.scenes[1].asset_type -ne 'image_animation' -or $budgetPackage.scenes[2].asset_type -ne 'image_animation') { throw 'Промежуточные AI-видео не были переведены в image_animation.' }
if ([string]::IsNullOrWhiteSpace($budgetPackage.scenes[1].motion_target)) { throw 'Для downgrade image_animation не создан motion_target.' }
foreach ($index in @(1,2)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$budgetPackage.scenes[$index].video_prompt)) { throw "Downgrade сцены $($index + 1) оставил video_prompt." }
    if ([string]::IsNullOrWhiteSpace([string]$budgetPackage.scenes[$index].motion_prompt)) { throw "Downgrade сцены $($index + 1) не создал motion_prompt." }
    if ([string]$budgetPackage.scenes[$index].motion_prompt -notmatch '(?i)camera') { throw "Downgrade сцены $($index + 1) не описывает движение камеры." }
    if ([string]$budgetPackage.scenes[$index].motion_prompt -notmatch [regex]::Escape([string]$budgetPackage.scenes[$index].motion_target)) { throw "Downgrade сцены $($index + 1) не направляет камеру на motion_target." }
}
Write-Host 'OK  Лимит Wan: отсутствующие motion_target добавляются безопасно; промежуточные сцены становятся camera-only image_animation.' -ForegroundColor Green


# v2.2.4: repair literal anchor mismatches without relaxing the validator or changing asset routes.
$visualRepairPackage = @'
{
  "visual_style": {
    "negative_prompt": "no shaky camera, no handheld",
    "continuity_entities": [
      {"entity_id":"person_01","entity_type":"person","canonical_description":"An adult man with short dark hair wearing a charcoal turtleneck."}
    ]
  },
  "scenes": [
    {
      "scene_id":1,"asset_type":"ai_video","voiceover_text":"Бедность забирает время.",
      "visual_purpose":"A nearly empty wallet casts a heavy shadow across a table, illustrating the burden of financial scarcity.",
      "visual_anchor_terms":["sophisticated man","charcoal turtleneck"],
      "image_prompt":"Portrait of a sophisticated man wearing a charcoal turtleneck.",
      "video_prompt":"The man nods slowly.","motion_prompt":"","motion_target":"",
      "continuity_entity_ids":["person_01"]
    },
    {
      "scene_id":2,"asset_type":"image_animation","voiceover_text":"Счета требуют постоянного внимания.",
      "visual_purpose":"A stack of unpaid bills rests beside a cracked wall, illustrating accumulating financial pressure.",
      "visual_anchor_terms":["cracked wall","dark void"],
      "image_prompt":"A stack of unpaid bills beside a cracked wall in a dim room.",
      "video_prompt":"","motion_prompt":"Slow camera push-in toward the person's face.","motion_target":"cracked wall",
      "continuity_entity_ids":[]
    }
  ],
  "human_review":[]
}
'@ | ConvertFrom-Json -Depth 30
$visualCandidates = @(Get-CfrVisualSceneRepairCandidates -Package $visualRepairPackage)
if ($visualCandidates.Count -ne 2) { throw "Ожидались 2 сцены для ремонта якорей, получено $($visualCandidates.Count)." }
Write-Host 'OK  Несогласованные visual anchors и motion_target обнаруживаются до строгой проверки.' -ForegroundColor Green

$visualRepairs = @(
    [pscustomobject]@{
        scene_id = 1
        visual_purpose = 'A nearly empty wallet casts an oversized shadow across a dark table, illustrating the burden of financial scarcity.'
        visual_anchor_terms = @('nearly empty wallet','oversized shadow','dark table')
        image_prompt = 'Foreground: a nearly empty wallet with two coins on a dark table; an oversized shadow stretches clearly across the tabletop; vertical cinematic close-up.'
        video_prompt = 'The nearly empty wallet slowly moves a few centimeters while the oversized shadow remains across the dark table; smooth stabilized push-in.'
        motion_prompt = ''
        motion_target = ''
    },
    [pscustomobject]@{
        scene_id = 2
        visual_purpose = 'A stack of unpaid bills rests beside a cracked wall, illustrating accumulating financial pressure.'
        visual_anchor_terms = @('stack of unpaid bills','cracked wall')
        image_prompt = 'A stack of unpaid bills in the foreground rests beside a cracked wall in a dim room; vertical medium close-up.'
        video_prompt = 'This field is intentionally wrong for image_animation and must be discarded.'
        motion_prompt = 'Slow stabilized camera push-in toward the stack of unpaid bills; keep all papers and the cracked wall completely still.'
        motion_target = 'stack of unpaid bills'
    }
)
$visualRepairNotes = @(Set-CfrVisualSceneRepairs -Package $visualRepairPackage -Repairs $visualRepairs)
if (@($visualRepairNotes | Where-Object { $_ -match 'визуальная согласованность исправлена вторым проходом Gemma' }).Count -ne 2) { throw 'Не все две визуальные сцены были обработаны вторым проходом.' }
$remainingVisualCandidates = @(Get-CfrVisualSceneRepairCandidates -Package $visualRepairPackage)
if ($remainingVisualCandidates.Count -ne 0) { throw "После ремонта остались несогласованные сцены: $($remainingVisualCandidates.scene_id -join ', ')." }
if ($visualRepairPackage.scenes[0].asset_type -ne 'ai_video' -or $visualRepairPackage.scenes[1].asset_type -ne 'image_animation') {
    throw 'Визуальный ремонт не должен менять asset_type.'
}
if (-not [string]::IsNullOrWhiteSpace([string]$visualRepairPackage.scenes[1].video_prompt)) {
    throw 'Лишний video_prompt должен быть очищен для image_animation.'
}
if (@($visualRepairNotes | Where-Object { $_ -match 'лишний video_prompt удалён' }).Count -ne 1) {
    throw 'Очистка чужого prompt-поля не отражена в human_review.'
}
if (@($visualRepairPackage.human_review | Where-Object { $_ -match 'визуальная согласованность исправлена' }).Count -ne 2) {
    throw 'Автоматический визуальный ремонт не записан в human_review.'
}
Write-Host 'OK  Второй проход Gemma применяет только согласованные визуальные поля, сохраняет asset_type и пишет human_review.' -ForegroundColor Green

$badVisualRepairs = @(
    [pscustomobject]@{
        scene_id = 1
        visual_purpose = 'A nearly empty wallet casts an oversized shadow across a dark table.'
        visual_anchor_terms = @('gold checkmark','dark void')
        image_prompt = 'A nearly empty wallet on a dark table.'
        video_prompt = 'The wallet moves.'
        motion_prompt = ''
        motion_target = ''
    }
)
$badPackage = $visualRepairPackage | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$badPackage.scenes[0].visual_anchor_terms = @('sophisticated man','charcoal turtleneck')
$badPackage.scenes[0].visual_purpose = 'A nearly empty wallet casts an oversized shadow across a dark table.'
$badBeforePrompt = [string]$badPackage.scenes[0].image_prompt
$badNotes = @(Set-CfrVisualSceneRepairs -Package $badPackage -Repairs $badVisualRepairs)
if ([string]$badPackage.scenes[0].image_prompt -cne $badBeforePrompt) { throw 'Невалидный результат второго прохода был применён.' }
if (@($badNotes | Where-Object { $_ -match 'не применено' }).Count -ne 1) { throw 'Невалидное исправление должно быть отклонено и отмечено.' }
Write-Host 'OK  Непроверенное/несогласованное исправление модели отклоняется, а исходная сцена сохраняется.' -ForegroundColor Green

# v2.3: regression for the real failure (scene 7, run 20261108203325401): the model copied the canonical
# description "A worn, leather brown wallet" (comma) while the anchor was "worn leather brown wallet".
$commaPackage = @'
{
  "visual_style": { "negative_prompt": "no shaky camera", "continuity_entities": [] },
  "scenes": [
    {
      "scene_id":1,"asset_type":"image_animation","voiceover_text":"Итог.",
      "visual_purpose":"A worn leather brown wallet rests on a dark wooden table.",
      "visual_anchor_terms":["worn leather brown wallet","dark wooden table"],
      "image_prompt":"A worn, leather brown wallet on a dark wooden table.",
      "video_prompt":"","motion_prompt":"Slow stabilized camera zoom-out from the worn leather brown wallet.","motion_target":"worn leather brown wallet",
      "continuity_entity_ids":[]
    }
  ],
  "human_review":[]
}
'@ | ConvertFrom-Json -Depth 30
$commaCandidates = @(Get-CfrVisualSceneRepairCandidates -Package $commaPackage)
if ($commaCandidates.Count -ne 0) { throw "Запятая внутри якоря ошибочно считается рассогласованием: $($commaCandidates[0].issues -join '; ')." }
Write-Host 'OK  Различие в запятой внутри якоря не создаёт лишнюю работу для второго прохода Gemma.' -ForegroundColor Green

# v2.3: anchors that appear in visual_purpose but were forgotten in image_prompt are appended deterministically,
# while anchors absent from visual_purpose are still rejected.
$injectPackage = @'
{
  "visual_style": { "negative_prompt": "no shaky camera", "continuity_entities": [] },
  "scenes": [
    {
      "scene_id":1,"asset_type":"generated_image","voiceover_text":"Итог.",
      "visual_purpose":"An old key lies next to a locked door.",
      "visual_anchor_terms":["old key","locked door"],
      "image_prompt":"A quiet hallway in warm light.",
      "video_prompt":"","motion_prompt":"","motion_target":"",
      "continuity_entity_ids":[]
    }
  ],
  "human_review":[]
}
'@ | ConvertFrom-Json -Depth 30
$injectRepair = @([pscustomobject]@{
    scene_id = 1
    visual_purpose = 'An old key lies next to a locked door.'
    visual_anchor_terms = @('old key','locked door')
    image_prompt = 'A quiet hallway in warm light, vertical 9:16.'
    video_prompt = ''
    motion_prompt = ''
    motion_target = ''
})
$injectNotes = @(Set-CfrVisualSceneRepairs -Package $injectPackage -Repairs $injectRepair)
if (@($injectNotes | Where-Object { $_ -match 'недостающие якоря дописаны' }).Count -ne 1) { throw 'Недостающие якоря не были дописаны в image_prompt.' }
if (@(Get-CfrVisualSceneRepairCandidates -Package $injectPackage).Count -ne 0) { throw 'После дописывания якорей сцена всё ещё считается несогласованной.' }
if ([string]$injectPackage.scenes[0].image_prompt -notmatch 'old key' -or [string]$injectPackage.scenes[0].image_prompt -notmatch 'locked door') { throw 'image_prompt не содержит дописанные якоря.' }
Write-Host 'OK  Якоря из visual_purpose, пропущенные в image_prompt, дописываются детерминированно.' -ForegroundColor Green

# v2.3: last-resort purpose/anchor reconciliation (real scene 7). Only when EVERY missing anchor is visible in image_prompt.
$gapPackage = @'
{
  "scenes": [
    { "scene_id":1, "visual_purpose":"The worn leather wallet from the first scene, now in a very dark frame.",
      "visual_anchor_terms":["worn leather brown wallet","dark wooden table"],
      "image_prompt":"A worn, leather brown wallet on a dark wooden table; extreme low light; vertical 9:16." },
    { "scene_id":2, "visual_purpose":"A coin rests on a plate.",
      "visual_anchor_terms":["silver coin","blue plate"],
      "image_prompt":"A coin on a plate in warm light." }
  ],
  "human_review": []
}
'@ | ConvertFrom-Json -Depth 30
$gapNotes = @(Repair-CfrPurposeAnchorGap -Package $gapPackage)
if ($gapNotes.Count -ne 1) { throw "Repair-CfrPurposeAnchorGap должен изменить ровно одну сцену, изменил: $($gapNotes.Count)." }
if ([string]$gapPackage.scenes[0].visual_purpose -notmatch 'Key visible elements: worn leather brown wallet, dark wooden table\.$') { throw 'Недостающие якоря не дописаны в visual_purpose.' }
if ([string]$gapPackage.scenes[1].visual_purpose -cne 'A coin rests on a plate.') { throw 'Сцена, где якорей нет и в image_prompt, не должна меняться автоматически.' }
if (@($gapPackage.human_review | Where-Object { $_ -match 'дописаны в visual_purpose механически' }).Count -ne 1) { throw 'Механическая правка visual_purpose не записана в human_review.' }
Write-Host 'OK  Последняя детерминированная правка visual_purpose работает только когда якоря реально видны в image_prompt.' -ForegroundColor Green

# v2.3: stale "repair not applied" notes can be removed after a successful retry.
$staleNotePackage = [pscustomobject]@{ human_review = @('Сцена 7: предложенное Gemma исправление не применено: x. Сцена требует ручной правки.', 'Сцена 2: оставь эту заметку.') }
Remove-CfHumanReviewNotes -Package $staleNotePackage -Pattern '^Сцена 7: предложенное Gemma исправление не применено'
if (@($staleNotePackage.human_review).Count -ne 1 -or [string]$staleNotePackage.human_review[0] -notmatch 'Сцена 2') { throw 'Remove-CfHumanReviewNotes удалил не те заметки.' }
Write-Host 'OK  Устаревшие заметки о неудачном ремонте удаляются после успешной повторной попытки.' -ForegroundColor Green

# v2.2.5: default Wan budget is reserved for the actual first/last timeline scenes,
# not the first/last entries among an arbitrary subset of AI-labelled scenes.
$interiorOnlyPackage = $budgetPackage | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
$interiorOnlyPackage.scenes[0].asset_type = 'generated_image'
$interiorOnlyPackage.scenes[0].video_prompt = ''
$interiorOnlyPackage.scenes[0].motion_prompt = ''
Add-Member -InputObject $interiorOnlyPackage.scenes[0] -MemberType NoteProperty -Name motion_target -Value '' -Force
$interiorOnlyPackage.scenes[3].asset_type = 'generated_image'
$interiorOnlyPackage.scenes[3].video_prompt = ''
$interiorOnlyPackage.scenes[3].motion_prompt = ''
Add-Member -InputObject $interiorOnlyPackage.scenes[3] -MemberType NoteProperty -Name motion_target -Value '' -Force
$interiorOnlyPackage.scenes[1].asset_type = 'ai_video'
$interiorOnlyPackage.scenes[1].video_prompt = 'A yogurt cup moves slightly.'
$interiorOnlyPackage.scenes[1].motion_prompt = ''
Add-Member -InputObject $interiorOnlyPackage.scenes[1] -MemberType NoteProperty -Name motion_target -Value '' -Force
$interiorOnlyPackage.scenes[2].asset_type = 'ai_video'
$interiorOnlyPackage.scenes[2].video_prompt = 'A gold coin falls slowly.'
$interiorOnlyPackage.scenes[2].motion_prompt = ''
Add-Member -InputObject $interiorOnlyPackage.scenes[2] -MemberType NoteProperty -Name motion_target -Value '' -Force
$null = Repair-CfPackageStructure -Package $interiorOnlyPackage -TargetDurationSeconds 60 -MaxAiVideoScenes 2
$interiorWanCount = @($interiorOnlyPackage.scenes | Where-Object { $_.asset_type -eq 'ai_video' }).Count
if ($interiorWanCount -ne 0) { throw "Промежуточные Wan-сцены не были переведены в camera-only маршрут: осталось $interiorWanCount." }
foreach ($idx in @(1,2)) {
    if ($interiorOnlyPackage.scenes[$idx].asset_type -ne 'image_animation') { throw "Промежуточная сцена $($idx + 1) не стала image_animation." }
    if ([string]::IsNullOrWhiteSpace([string]$interiorOnlyPackage.scenes[$idx].motion_target)) { throw "Промежуточная сцена $($idx + 1) не получила motion_target." }
}
Write-Host 'OK  Wan по умолчанию зарезервирован только для фактических первой/последней сцен; внутренние camera-only клипы переводятся в FFmpeg.' -ForegroundColor Green

# v2.2.5: when a proposed Wan prompt contains only camera movement, safely downgrade
# that scene to image_animation instead of passing a camera-only task to Wan.
$cameraOnlyAiPackage = $visualRepairPackage | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$cameraOnlyAiPackage.scenes[0].video_prompt = 'Static portrait with slow stabilized camera push-in toward the nearly empty wallet.'
$cameraOnlyCandidates = @(Get-CfrVisualSceneRepairCandidates -Package $cameraOnlyAiPackage)
$cameraOnlyRepair = @(
    [pscustomobject]@{
        scene_id = 1
        visual_purpose = 'A nearly empty wallet casts an oversized shadow across a dark table, illustrating the burden of financial scarcity.'
        visual_anchor_terms = @('nearly empty wallet','oversized shadow','dark table')
        image_prompt = 'Foreground: a nearly empty wallet with two coins on a dark table; an oversized shadow stretches clearly across the tabletop; vertical cinematic close-up.'
        video_prompt = 'Static composition with only a slow stabilized camera push-in toward the nearly empty wallet.'
        motion_prompt = ''
        motion_target = ''
    }
)
$cameraOnlyNotes = @(Set-CfrVisualSceneRepairs -Package $cameraOnlyAiPackage -Repairs $cameraOnlyRepair)
if ($cameraOnlyAiPackage.scenes[0].asset_type -ne 'image_animation') { throw 'AI-видео без наблюдаемого действия не было безопасно переведено в image_animation.' }
if (-not [string]::IsNullOrWhiteSpace([string]$cameraOnlyAiPackage.scenes[0].video_prompt)) { throw 'Camera-only fallback сохранил video_prompt.' }
if ([string]::IsNullOrWhiteSpace([string]$cameraOnlyAiPackage.scenes[0].motion_target) -or [string]$cameraOnlyAiPackage.scenes[0].motion_prompt -notmatch [regex]::Escape([string]$cameraOnlyAiPackage.scenes[0].motion_target)) {
    throw 'Camera-only fallback не создал корректную пару motion_target/motion_prompt.'
}
if (@($cameraOnlyNotes | Where-Object { $_ -match 'ai_video без наблюдаемого действия безопасно переведено' }).Count -ne 1) {
    throw 'Безопасное переключение Wan на FFmpeg не записано в human_review.'
}
Write-Host 'OK  AI-видео без наблюдаемого действия безопасно переводится в image_animation; движение выполняется FFmpeg.' -ForegroundColor Green

Write-Host 'Все тесты нормализации ContentFactory v2.3.0 пройдены.' -ForegroundColor Green
