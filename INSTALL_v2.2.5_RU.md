# Установка ContentFactory 2.2.5

Это накопительный patch-over для существующего ContentFactory 2.2.4. Проекты в `projects/` не перезаписываются.

1. Закрой текущие запуски фабрики.
2. Скопируй всю папку `ContentFactory_v2.2` в резервное место.
3. Распакуй архив `ContentFactory_v2.2.5_patch.zip` непосредственно в корень `ContentFactory_v2.2`, сохранив относительные пути и разрешив замену файлов.
4. Выполни полный preflight: 

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Test-Factory.ps1 -RunTests -CheckOllama
```

5. Только после успешного прохождения тестов создай новый проект: 

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\factory.ps1 -Topic "Почему бедность обходится дороже богатства"
```

`schema_version` остаётся `2.1` для обратной совместимости. Версия приложения записана в `VERSION.txt` и переносится в `run_info.json`.

## Что меняется

- `VERSION.txt` обновляется до `ContentFactory 2.2.5`; `Test-Factory.ps1` выводит версию из этого файла, не из жёстко прописанной строки.

- Wan по умолчанию оставляется только на первой и последней сценах, если они действительно размечены `ai_video`. Промежуточные сцены переводятся в `image_animation` только при наличии пригодного визуального anchor в `visual_purpose` и `image_prompt`.
- Второй проход Gemma запускается отдельно для каждой сцены, а не одним большим пакетом.
- Лишний `video_prompt` удаляется для `image_animation`; если Wan prompt описывает только движение камеры, он безопасно переводится в camera-only `image_animation`.
- Continuity/identity description не считается визуальным сюжетным anchor.
- Все маршрутизационные изменения отмечаются в `human_review`; валидатор не ослабляется.

## Ограничения

Патч не запускает ComfyUI, Wan, TTS или FFmpeg. Он готовит и проверяет производственные задания. Визуальную композицию и сгенерированные кадры по-прежнему необходимо утверждать вручную.
