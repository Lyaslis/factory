$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ProjectRoot 'src\ContentFactory.Ollama.psm1') -Force

# Ollama may omit message.thinking entirely when think=false.
$responseWithoutThinking = [pscustomobject]@{
    message = [pscustomobject]@{ content = '{"status":"ok"}' }
    done_reason = 'stop'
    eval_count = 12
}
$message = Get-CfOptionalPropertyValue -InputObject $responseWithoutThinking -Name 'message' -DefaultValue $null
$content = [string](Get-CfOptionalPropertyValue -InputObject $message -Name 'content' -DefaultValue '')
$thinking = [string](Get-CfOptionalPropertyValue -InputObject $message -Name 'thinking' -DefaultValue '')
if ($content -ne '{"status":"ok"}') { throw 'Не удалось прочитать content из ответа без thinking.' }
if ($thinking.Length -ne 0) { throw 'Отсутствующее thinking должно трактоваться как пустая строка.' }
Write-Host 'OK  Отсутствующее message.thinking обрабатывается как необязательное поле.' -ForegroundColor Green

# Existing optional fields must still be returned unchanged.
$responseWithThinking = [pscustomobject]@{
    message = [pscustomobject]@{ content = '{}'; thinking = 'trace' }
    done_reason = 'stop'
}
$message2 = Get-CfOptionalPropertyValue -InputObject $responseWithThinking -Name 'message' -DefaultValue $null
$thinking2 = [string](Get-CfOptionalPropertyValue -InputObject $message2 -Name 'thinking' -DefaultValue '')
if ($thinking2 -ne 'trace') { throw 'Существующее поле thinking прочитано некорректно.' }
Write-Host 'OK  Существующее message.thinking читается без изменений.' -ForegroundColor Green

$missing = Get-CfOptionalPropertyValue -InputObject $responseWithoutThinking -Name 'missing_field' -DefaultValue 'fallback'
if ($missing -ne 'fallback') { throw 'Значение по умолчанию для отсутствующего поля не сработало.' }
Write-Host 'OK  Значение по умолчанию для отсутствующих полей работает.' -ForegroundColor Green
Write-Host 'Все тесты необязательных полей ответа Ollama пройдены.' -ForegroundColor Green
