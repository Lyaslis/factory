# Установка ContentFactory v2.2.3 patch

1. Сделайте резервную копию `tests/Test-Repair.ps1`.
2. Распакуйте содержимое архива в корень `ContentFactory_v2.2`, сохранив структуру папок и разрешив замену файла.
3. Запустите сначала тест ремонта:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Repair.ps1
```

4. При успехе запустите полный набор:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Test-Factory.ps1 -RunTests -CheckOllama
```

Патч меняет только тестовую фикстуру и добавляет отрицательную проверку для entity типа `object`. Производственные модули не заменяются.
