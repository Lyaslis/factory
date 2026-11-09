# ContentFactory 2.2.4 — hotfix PowerShell parser

## Установка
1. Закройте текущие запуски ContentFactory.
2. Распакуйте архив в корень `ContentFactory_v2.2`, сохранив структуру папок.
3. Разрешите заменить `src/ContentFactory.Repair.psm1`.
4. Запустите из корня проекта:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Test-Factory.ps1 -RunTests -CheckOllama
```

## Исправление
В четырёх интерполируемых строках использована форма `${idText}:` вместо `$idText:`. Это устраняет ошибку PowerShell, где двоеточие сразу после имени переменной интерпретируется как часть синтаксиса scoped/drive-variable.

Изменён только `src/ContentFactory.Repair.psm1`. Номер версии приложения не меняется; это исправление синтаксиса для текущей сборки 2.2.4.
