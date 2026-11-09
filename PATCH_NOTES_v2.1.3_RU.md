# ContentFactory v2.1.3 — исправление совместимости ответа Ollama

## Причина

При `think=false` Ollama может не включать `message.thinking` в объект ответа. При `Set-StrictMode -Version Latest` прямое обращение к отсутствующему свойству вызывает ошибку PowerShell:

`The property 'thinking' cannot be found on this object.`

Это нормальный вариант ответа API, а не ошибка модели.

## Исправления

- Добавлена функция `Get-CfOptionalPropertyValue` в модуль Ollama.
- `tools/Test-GemmaJson.ps1` теперь безопасно читает `message.content`, необязательное `message.thinking` и метаданные.
- `factory.ps1` использует безопасное чтение всех необязательных полей ответа.
- Если поле `thinking` отсутствует при `think=false`, тест показывает это как нормальное поведение.

## Установка

Распаковать архив в корень `ContentFactory_v2.1`, разрешив заменить файлы. Затем выполнить:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-GemmaJson.ps1
```

Ожидаемо: корректный JSON и строка `thinking_field=поле отсутствует (нормально при think=false)` либо `поле присутствует`.

Если короткий тест проходит, повторить запуск `factory.ps1`.
