# Установка ContentFactory 2.2.4

Это накопительный патч поверх установленной ContentFactory 2.2.0 с исправлениями 2.2.1–2.2.3. Полная переустановка не нужна.

## Перед установкой

1. Закрой незавершённые запуски ContentFactory.
2. Скопируй всю папку проекта в резервное место.
3. Убедись, что предыдущая версия проходит `Test-Factory.ps1 -RunTests -CheckOllama`.

## Установка

Распакуй архив в корень `ContentFactory_v2.2`, сохранив структуру папок и разрешив замену файлов.

Патч обновляет:
- `VERSION.txt`
- `factory.ps1`
- `Test-Factory.ps1`
- `prompts/director_ru.txt`
- `src/ContentFactory.Ollama.psm1`
- `src/ContentFactory.Repair.psm1`
- `tests/Test-Repair.ps1`

## Проверка

Сначала выполни полный тест:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Test-Factory.ps1 -RunTests -CheckOllama
```

Затем запусти пробную генерацию:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\factory.ps1 -Topic "Почему бедность обходится дороже богатства"
```

## Что изменилось

Если после первого прохода Gemma оставляет несовместимые визуальные якоря или `motion_target`, фабрика делает один короткий дополнительный запрос к Gemma с `think=false` и строгой JSON Schema. Ответ применяется только после локальной проверки:

- `visual_anchor_terms` — 2–5 сюжетных объектов, дословно присутствующих в `visual_purpose` и `image_prompt`;
- для `ai_video` все якоря также должны присутствовать в `video_prompt`;
- для `image_animation` `motion_target` обязан быть одним из якорей, присутствовать в исходном изображении и в camera-only `motion_prompt`;
- `asset_type`, `voiceover_text`, длительность и фактические утверждения не меняются;
- continuity-описания персонажей сохраняются отдельно от визуальных якорей.

Если второй проход не возвращает корректный JSON или сцена остаётся несогласованной, она не исправляется молча: строгий валидатор продолжает блокировать пакет, а причина попадает в `human_review.txt`.

Автокоррекция не доказывает художественное качество кадра. Перед генерацией/публикацией всё равно проверь `visual_purpose`, `image_prompt`, `video_prompt` и итоговое изображение.
