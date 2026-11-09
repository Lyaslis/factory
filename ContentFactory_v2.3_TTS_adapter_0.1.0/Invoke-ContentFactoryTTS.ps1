[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ProjectPath,

    [Parameter(Mandatory = $false)]
    [string]$Speaker,

    [Parameter(Mandatory = $false)]
    [string]$Language = 'Russian',

    [Parameter(Mandatory = $false)]
    [string]$Instruct,

    [Parameter(Mandatory = $false)]
    [string]$SpeechTextFile,

    [Parameter(Mandatory = $false)]
    [string]$QwenRoot = 'E:\bce\qwen3_tts_gui_1.0',

    [Parameter(Mandatory = $false)]
    [ValidateSet('float16', 'bfloat16', 'float32')]
    [string]$DType = 'float16',

    [Parameter(Mandatory = $false)]
    [ValidateSet('sdpa', 'default')]
    [string]$Attention = 'sdpa',

    [switch]$ListSpeakers,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Stop-WithMessage {
    param([Parameter(Mandatory)][string]$Message)
    Write-Error $Message
    exit 1
}

$PythonPath = Join-Path $QwenRoot 'qwen3-tts-env\Scripts\python.exe'
$PythonRunner = Join-Path $PSScriptRoot 'tools\qwen3_tts_generate.py'
$ModelPath = Join-Path $QwenRoot 'models\Qwen---Qwen3-TTS-12Hz-1.7B-CustomVoice'

if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
    Stop-WithMessage "Python окружения Qwen3-TTS не найден: $PythonPath`nПроверь параметр -QwenRoot."
}
if (-not (Test-Path -LiteralPath $PythonRunner -PathType Leaf)) {
    Stop-WithMessage "Python-адаптер не найден: $PythonRunner`nРаспакуй архив адаптера поверх корня ContentFactory."
}
if (-not (Test-Path -LiteralPath $ModelPath -PathType Container)) {
    Stop-WithMessage "Локальная папка модели не найдена: $ModelPath`nОжидается каталог, который использует Qwen3-TTS GUI. Проверь -QwenRoot."
}
foreach ($RequiredModelFile in @('config.json', 'model.safetensors', 'speech_tokenizer')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModelPath $RequiredModelFile))) {
        Stop-WithMessage "В локальной модели отсутствует компонент '$RequiredModelFile': $ModelPath"
    }
}

$PythonArgs = @(
    $PythonRunner,
    '--model-id', 'Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice',
    '--model-path', $ModelPath,
    '--device', 'cuda:0',
    '--dtype', $DType,
    '--attention', $Attention
)

if ($ListSpeakers) {
    $PythonArgs += '--list-speakers'
    & $PythonPath @PythonArgs
    if ($LASTEXITCODE -ne 0) {
        Stop-WithMessage "Получение списка голосов завершилось с кодом $LASTEXITCODE."
    }
    exit 0
}

if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    Stop-WithMessage 'Укажи -ProjectPath с каталогом проекта ContentFactory либо используй -ListSpeakers.'
}
if ([string]::IsNullOrWhiteSpace($Speaker)) {
    Stop-WithMessage 'Укажи голос параметром -Speaker. Сначала можно выполнить -ListSpeakers.'
}

try {
    $ProjectFullPath = (Resolve-Path -LiteralPath $ProjectPath -ErrorAction Stop).Path
}
catch {
    Stop-WithMessage "Каталог проекта не найден: $ProjectPath"
}

$CanonicalTextFile = Join-Path $ProjectFullPath 'script.txt'
$TextFile = $CanonicalTextFile
$AudioDir = Join-Path $ProjectFullPath 'assets\audio'
$OutputWav = Join-Path $AudioDir 'voice.wav'
$MetadataFile = Join-Path $AudioDir 'voice_metadata.json'

if (-not (Test-Path -LiteralPath $CanonicalTextFile -PathType Leaf)) {
    Stop-WithMessage "Не найден канонический script.txt: $CanonicalTextFile`nСначала экспортируй или подготовь утверждённый текст сценария."
}

if (-not [string]::IsNullOrWhiteSpace($SpeechTextFile)) {
    try {
        $TextFile = (Resolve-Path -LiteralPath $SpeechTextFile -ErrorAction Stop).Path
    }
    catch {
        Stop-WithMessage "Файл альтернативного текста для TTS не найден: $SpeechTextFile"
    }
    if (-not (Test-Path -LiteralPath $TextFile -PathType Leaf)) {
        Stop-WithMessage "Файл альтернативного текста для TTS не найден: $SpeechTextFile"
    }
}

if (-not $Force -and ((Test-Path -LiteralPath $OutputWav) -or (Test-Path -LiteralPath $MetadataFile))) {
    Stop-WithMessage "Озвучка или метаданные уже существуют в $AudioDir. Используй -Force только если действительно хочешь перезаписать их."
}

$null = New-Item -ItemType Directory -Force -Path $AudioDir
$PythonArgs += @(
    '--text-file', $TextFile,
    '--output', $OutputWav,
    '--speaker', $Speaker,
    '--language', $Language
)
if (-not [string]::IsNullOrWhiteSpace($Instruct)) {
    $PythonArgs += @('--instruct', $Instruct)
}

Write-Host "Проект: $ProjectFullPath" -ForegroundColor Cyan
Write-Host "Модель: $ModelPath" -ForegroundColor Cyan
Write-Host "Голос: $Speaker | Язык: $Language | dtype: $DType | attention: $Attention" -ForegroundColor Cyan
Write-Host "Текст для синтеза: $TextFile" -ForegroundColor Cyan
if ($TextFile -ne $CanonicalTextFile) {
    Write-Host "Используется отдельный TTS-текст; script.txt не изменяется." -ForegroundColor Yellow
}
Write-Host 'Запускаю Qwen3-TTS. Первая загрузка модели может занять некоторое время...' -ForegroundColor Yellow

& $PythonPath @PythonArgs
$ExitCode = $LASTEXITCODE
if ($ExitCode -ne 0) {
    Stop-WithMessage "Qwen3-TTS завершился с кодом $ExitCode. Проверь сообщение Python выше."
}

if (-not (Test-Path -LiteralPath $OutputWav -PathType Leaf)) {
    Stop-WithMessage "Python завершился без ошибки, но WAV не найден: $OutputWav"
}
if ((Get-Item -LiteralPath $OutputWav).Length -le 44) {
    Stop-WithMessage "Полученный WAV подозрительно мал: $OutputWav"
}

Write-Host "`nWAV создан: $OutputWav" -ForegroundColor Green
if (Test-Path -LiteralPath $MetadataFile) {
    Write-Host "Метаданные: $MetadataFile" -ForegroundColor Green
}
Write-Host 'Таймлайн ContentFactory не изменён. Сначала прослушай WAV и подтверди голос/произношение.' -ForegroundColor Yellow
