[CmdletBinding()]
param(
    [string]$Model,
    [string]$BaseUrl
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $ProjectRoot 'config\settings.json'
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Не найден файл конфигурации: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
Import-Module (Join-Path $ProjectRoot 'src\ContentFactory.Ollama.psm1') -Force
if ([string]::IsNullOrWhiteSpace($Model)) { $Model = [string]$config.ollama.model }
if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = [string]$config.ollama.base_url }
$think = [bool]$config.ollama.thinking_mode

$schema = @{
    type = 'object'
    properties = @{ status = @{ type = 'string'; enum = @('ok') } }
    required = @('status')
    additionalProperties = $false
}
$payload = @{
    model = $Model
    stream = $false
    think = $think
    format = $schema
    messages = @(
        @{ role = 'system'; content = 'Верни только объект JSON, соответствующий схеме. Не добавляй пояснений.' },
        @{ role = 'user'; content = 'Проверка структурированного вывода. Верни status со значением ok.' }
    )
    options = @{ temperature = 0.1; num_ctx = 4096; num_predict = 1536 }
    keep_alive = '2m'
}
$uri = '{0}/api/chat' -f $BaseUrl.TrimEnd('/')
$body = $payload | ConvertTo-Json -Depth 20 -Compress
$bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
Write-Host "Тестирую $Model | think=$($think.ToString().ToLowerInvariant()) | JSON Schema" -ForegroundColor Cyan
try {
    $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 300
}
catch {
    throw "Запрос к Ollama завершился ошибкой: $($_.Exception.Message)"
}
$message = Get-CfOptionalPropertyValue -InputObject $response -Name 'message' -DefaultValue $null
$content = [string](Get-CfOptionalPropertyValue -InputObject $message -Name 'content' -DefaultValue '')
$thinkingProperty = $null
if ($null -ne $message) { $thinkingProperty = $message.PSObject.Properties['thinking'] }
$thinking = [string](Get-CfOptionalPropertyValue -InputObject $message -Name 'thinking' -DefaultValue '')
$doneReason = [string](Get-CfOptionalPropertyValue -InputObject $response -Name 'done_reason' -DefaultValue 'не указан')
$evalCount = Get-CfOptionalPropertyValue -InputObject $response -Name 'eval_count' -DefaultValue 0
$evalDuration = Get-CfOptionalPropertyValue -InputObject $response -Name 'eval_duration' -DefaultValue 0
if ([string]::IsNullOrWhiteSpace($content)) {
    throw "Тест не пройден: content пуст; done_reason=$doneReason; thinking_chars=$($thinking.Length); eval_count=$evalCount. Это означает, что Ollama не перешла к финальному JSON."
}
try { $parsed = $content | ConvertFrom-Json -ErrorAction Stop }
catch { throw "Тест не пройден: content не является JSON. Начало ответа: $($content.Substring(0, [Math]::Min(300, $content.Length)))" }
if ($parsed.status -ne 'ok') { throw "Тест не пройден: ожидалось status='ok', получено '$($parsed.status)'. Ответ: $content" }
if ($doneReason -eq 'length') { throw "Тест не пройден: JSON получен, но генерация остановлена по length." }
Write-Host "OK  Gemma вернула корректный JSON." -ForegroundColor Green
$thinkingStatus = if ($null -eq $thinkingProperty) { 'поле отсутствует (нормально при think=false)' } else { 'поле присутствует' }
Write-Host "done_reason=$doneReason; thinking_chars=$($thinking.Length); thinking_field=$thinkingStatus; eval_count=$evalCount; eval_duration=$evalDuration"
