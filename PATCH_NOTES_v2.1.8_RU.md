# v2.1.8

- Исправлена подготовка quotedPackage в `tests/Test-Repair.ps1`.
- Если `voiceover_text` отсутствует, тест теперь добавляет NoteProperty через `Add-Member`; если существует — обновляет значение.
- Production-код и валидатор не изменялись.
