# ContentFactory 2.3.0 — визуальная согласованность, production repair и этап рассуждений

> **v2.3.0:** добавлен этап рассуждений Gemma (`planning` в `config/settings.json`), повторный ремонт сцен с обратной связью и выгрузка модели из VRAM после работы. Разбор жизнеспособности проекта и пайплайна: `docs/ARCHITECTURE_REVIEW_RU.md`. Детали: `PATCH_NOTES_v2.3.0_RU.md`.

ContentFactory превращает тему и пользовательские материалы в структурированный производственный пакет для будущих модулей озвучки, ComfyUI и монтажа. Центральная модель — Gemma через локальную Ollama.

**Этот архив — патч-оверлей, а не отдельная полная установка.** Он накладывается поверх ContentFactory 2.2.4. Старые проекты не перезаписываются.

## Что изменилось в v2.2

1. Сохранены исправления Ollama/Gemma: `think=false`, JSON Schema и безопасное чтение необязательного `message.thinking`.
2. Фрагменты сцен синхронизируются с `script.full_text` без перефразирования.
3. Длительности распределяются по реальному числу слов и границам предложений; точная синхронизация подтверждается после WAV.
4. Локальный профиль ограничивает Wan двумя сценами. Лишние промежуточные видео переводятся в camera-only `image_animation` с записью в `human_review`.
5. Проверяется цепочка `visual_purpose → visual_anchor_terms → image_prompt → video_prompt/motion_prompt`.
6. Повторяющиеся персонажи получают план единого identity reference PNG; путь передаётся в `visual_prompts.json` непосредственно каждой использующей сцене.
7. Проверяется содержательное покрытие key_points о здоровье; общее упоминание слова «здоровье» не маскирует отсутствие обсуждения профилактики или лечения.
8. Добавлены монтажные defaults для субтитров/аудио и единый источник версии `VERSION.txt`.
9. В v2.2.4 добавлен второй проход Gemma для исправления несогласованных anchors/prompts. В v2.2.5 этот проход выполняется отдельно для каждой сцены, чтобы не смешивать маршруты и поля соседних сцен. Камера-only задания не передаются Wan: они переводятся в image_animation или generated_image.

## Совместимость

- Версия приложения: `2.2.5`.
- `schema_version` остаётся `2.1`, чтобы старые пакеты продолжали читаться.
- Основная фабрика использует строгий профиль визуальных якорей и лимит Wan из `config/settings.json`; по умолчанию Wan оставляется только для фактической первой/последней сцен.
- Ручной `tools/Validate-Package.ps1` по умолчанию совместим со старыми пакетами; для строгой проверки укажи `-RequireVisualAnchors -MaxAiVideoScenes 2`.
- Путь identity reference не означает, что PNG уже создан: его нужно сгенерировать в ComfyUI, вручную утвердить и сохранить.
- Локальная Gemma не ищет источники в интернете и не доказывает истинность claims. Неподтверждённые утверждения остаются в `human_review.txt`.

## Установка патча

1. Закрой запущенные процессы ContentFactory.
2. Сделай резервную копию всей папки проекта.
3. Распакуй содержимое ZIP с сохранением относительных путей прямо в корень существующего проекта `ContentFactory_v2.2` и подтверди замену файлов.
4. В PowerShell 7 из корня проекта выполни:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Test-Factory.ps1 -RunTests -CheckOllama
```

5. Только после успешных тестов создай новый проект:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\factory.ps1 -Topic "Почему бедность обходится дороже богатства"
```

## Архитектура

- `factory.ps1` — оркестратор.
- `config/settings.json` — настройки Ollama и локальный production profile.
- `prompts/director_ru.txt` — сценарная и режиссёрская инструкция.
- `schemas/production_package.schema.json` — контракт данных.
- `src/ContentFactory.Ollama.psm1` — API Ollama, claim excerpt repair и ограниченный visual-repair вызов с `think=false`.
- `src/ContentFactory.Repair.psm1` — детерминированные нормализации и проверяемое применение visual-repair результатов.
- `src/ContentFactory.Validation.psm1` — проверки структуры, фактовой трассируемости и визуальной связности.
- `src/ContentFactory.Export.psm1` — экспорт документов, asset requirements и таймлайна.

Будущие модули TTS, ComfyUI и FFmpeg следует подключать отдельно, не превращая `factory.ps1` в монолит.

## Выходной проект

```text
projects/<timestamp>_<topic>/
├── production_package.json
├── script.txt
├── research_brief.json
├── storyboard.json
├── visual_prompts.json
├── visual_style_guide.json
├── continuity_guide.json
├── asset_requirements.json
├── editing_plan.json
├── timeline.json
├── human_review.txt
├── validation_report.json
├── run_info.json
├── PROJECT_README.txt
└── assets/
    ├── characters/   # identity reference PNG, утверждённые человеком
    ├── images/
    ├── videos/
    └── audio/
```

`production_package.json` — единственный канонический источник; не редактируй экспортные файлы по отдельности.

## Ограничения

v2.2 пока не создаёт PNG/WAV/MP4, не запускает TTS, ComfyUI/Wan или FFmpeg и не собирает финальный ролик. `timeline.json` предварительный; после генерации озвучки границы сцен необходимо сверить с реальным WAV.
