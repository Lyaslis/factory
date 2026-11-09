# Установка ContentFactory 2.2.7 — hotfix

Этот патч применяется поверх ContentFactory 2.2.6. Он исправляет только регрессионный тест; исходный модуль `src/ContentFactory.Repair.psm1` из версии 2.2.6 остаётся без изменений. Проекты в `projects/` не затрагиваются.

1. Распакуй архив в корень `ContentFactory_v2.2`, сохранив относительные пути и разрешив замену файлов.
2. Запусти отдельный тест:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Repair.ps1
```

3. Затем запусти полный набор проверок:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Test-Factory.ps1 -RunTests -CheckOllama
```

В тестовой фикстуре `motion_target` теперь создаётся через `Add-Member`, поэтому тест корректно моделирует необязательное JSON-поле и не падает при `Set-StrictMode -Version Latest`.
