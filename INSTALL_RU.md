# ContentFactory 2.2.x — hotfix для теста экспорта

## Причина

`tests/Test-Export.ps1` сравнивал `run_info.json` с жёстко заданной версией `2.2.0`, хотя проект получает номер текущей версии из `VERSION.txt`. После обновления до 2.2.4 тест ошибочно падал при корректном экспорте.

## Установка

1. Сделайте резервную копию `tests/Test-Export.ps1`.
2. Распакуйте архив поверх корневой папки ContentFactory 2.2.
3. Замените только `tests/Test-Export.ps1`.
4. Выполните:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Export.ps1
```

Затем запустите полный набор:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Test-Factory.ps1 -RunTests -CheckOllama
```

## Что изменено

Тест теперь читает первую строку `VERSION.txt`, извлекает версию из формата `ContentFactory <version>` и сравнивает с `run_info.json`. Проверка фактического количества слов осталась.

Производственный экспорт, валидатор, Gemma и JSON-контракт не изменялись.
