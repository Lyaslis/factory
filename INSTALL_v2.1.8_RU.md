# ContentFactory v2.1.8 — Hotfix теста нормализации

## Причина

В `tests/Test-Repair.ps1` тестовый сценарий напрямую присваивал `voiceover_text` объектам сцен, в которых этого свойства изначально нет. При `Set-StrictMode -Version Latest` PowerShell выдаёт ошибку `The property 'voiceover_text' cannot be found ... and cannot be set`.

Сам модуль `ContentFactory.Repair.psm1` уже умеет безопасно добавлять отсутствующее свойство через `Add-Member`. Ошибка возникала в подготовке тестовой фикстуры, до проверки следующего сценария.

## Установка

Распаковать архив поверх корня `ContentFactory_v2.1` и заменить:

`tests/Test-Repair.ps1`

Другие файлы не меняются.

## Проверка

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Repair.ps1
```

Затем полный набор:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Test-Factory.ps1 -RunTests -CheckOllama
```

Патч не меняет валидатор, генератор, схему пакета или правила автокоррекции. Он исправляет только тестовую фикстуру, чтобы проверка отсутствующего свойства выполнялась корректно при строгом режиме PowerShell.
