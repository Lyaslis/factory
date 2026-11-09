# ContentFactory 2.3.0 — этап рассуждений, устойчивый ремонт сцен

Патч-оверлей поверх 2.2.7. Папка `projects/` не затрагивается.

## Установка

1. Закрой запущенные процессы, сделай резервную копию папки `ContentFactory_v2.2`.
2. Распакуй архив в её корень с заменой файлов. Свои значения в `config/settings.json` перенеси вручную: файл заменяется целиком (добавлены `planning`, `ollama.unload_after_run`, `ollama.repair_attempts`).
3. Проверка:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Test-Factory.ps1 -RunTests -CheckOllama
```

4. Новый проект:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\factory.ps1 -Topic "Почему бедность обходится дороже богатства"
```

Для быстрого запуска без рассуждений поставь `planning.enabled=false`.

## Что исправлено

| Проблема в 2.2.7 | Исправление |
|---|---|
| `think=true` с JSON-схемой съедал весь `num_predict`, `content` пуст | Рассуждения вынесены в отдельный вызов без схемы (`Invoke-CfOllamaPlan`); JSON-вызов остаётся `think=false` |
| Якорь «worn leather brown wallet» не совпадал с «A worn, leather brown wallet» | Сравнение без учёта регистра, пунктуации и пробелов; порядок слов по-прежнему обязателен |
| Ремонт сцены при `temperature=0` повторял отклонённый ответ | До `ollama.repair_attempts` попыток; повтор получает причину отказа и `temperature=0.3` |
| Устаревшая заметка «требует ручной правки» оставалась после успешного ремонта | `Remove-CfHumanReviewNotes` |
| Якорь есть в `visual_purpose`, но забыт в `image_prompt` | Дописывается детерминированно: «key visible elements: …» |
| Якоря есть в `image_prompt`, но не в `visual_purpose` (последний случай) | `Repair-CfrPurposeAnchorGap` дописывает их в `visual_purpose` и пишет заметку в `human_review` |
| Ремонтные вызовы с другим `num_ctx` заставляли Ollama перезагружать модель | Тот же `num_ctx`, что у основного вызова |
| Gemma оставалась в VRAM 5 минут после работы | `ollama.unload_after_run` → `keep_alive=0` |

## Новые предупреждения валидатора (не блокируют)

- надпись `on_screen_text` не на языке озвучки;
- `motion_graphic` без `on_screen_text`;
- `visual_purpose` ссылается на другую сцену.

## Новые настройки

```json
"ollama":   { "unload_after_run": true, "repair_attempts": 2 },
"planning": { "enabled": true, "thinking_mode": true, "temperature": 0.6,
              "context_tokens": 12288, "max_output_tokens": 9000, "timeout_seconds": 1800 }
```

`planning.context_tokens` должен быть минимум на 1 500 больше `planning.max_output_tokens`. Иначе Ollama молча сдвигает контекст и теряет начало промпта. Test-Factory проверяет это условие.

## Что не менялось

Строгий валидатор (кроме нормализации сравнения), JSON Schema, `schema_version=2.1`, лимит Wan, экспорт.

## Ограничение проверки

PowerShell и Ollama в среде разработки патча недоступны. Запусти `Test-Factory.ps1 -RunTests` и один пробный запуск; если что-то падает, пришли вывод.
