# ContentFactory 2.2.6 — исправление Wan-budget repair

## Причина

У некоторых сцен, сгенерированных Gemma, отсутствует необязательное свойство `motion_target`. `Repair-CfrAiVideoBudget` присваивал его напрямую (`$scene.motion_target = ...`), что завершалось ошибкой при `Set-StrictMode -Version Latest`.

## Исправление

- Добавлен `Set-CfrPropertyValue`: обновляет существующее свойство или безопасно создаёт `NoteProperty`, если его нет.
- Wan-budget repair использует безопасную запись для `asset_type`, `video_prompt`, `motion_prompt` и `motion_target`.
- Добавлен регрессионный тест, в котором промежуточные `ai_video` сцены изначально не содержат `motion_target`.

## Что не менялось

- Строгий валидатор и JSON Schema.
- Лимит Wan по умолчанию.
- Логика выбора визуальных anchors и маршрутов ComfyUI/FFmpeg.
