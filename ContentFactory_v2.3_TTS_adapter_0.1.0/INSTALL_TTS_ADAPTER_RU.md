# ContentFactory 2.3 — Qwen3-TTS Adapter 0.1.2

Это обновление адаптера поверх версии 0.1.1. Оно добавляет параметр `-SpeechTextFile`, позволяющий синтезировать отдельную TTS-редакцию текста, не перезаписывая канонический `script.txt`.

## Установка

Распакуйте архив поверх папки, где уже находится `Invoke-ContentFactoryTTS.ps1`, с заменой двух файлов:

- `Invoke-ContentFactoryTTS.ps1`
- `tools/qwen3_tts_generate.py`

Сам ContentFactory, проект, `script.txt` и `timeline.json` не меняются.

## Использование обычного текста

Без `-SpeechTextFile` адаптер, как и раньше, читает `<ProjectPath>\script.txt`:

```powershell
.\Invoke-ContentFactoryTTS.ps1 `
    -ProjectPath '.\projects\PROJECT_ID' `
    -Speaker 'eric' `
    -Language 'Russian'
```

## Использование отдельной TTS-редакции

Создайте в проекте отдельный `script_tts.txt` и передайте его явно:

```powershell
.\Invoke-ContentFactoryTTS.ps1 `
    -ProjectPath '.\projects\PROJECT_ID' `
    -SpeechTextFile '.\projects\PROJECT_ID\script_tts.txt' `
    -Speaker 'eric' `
    -Language 'Russian' `
    -Instruct 'Говори энергично и естественно, в живом темпе, без длинных пауз между связанными фразами.' `
    -Force
```

`script.txt` по-прежнему обязателен как канонический сценарий проекта, но фактический текст для синтеза берётся из `-SpeechTextFile`. В `voice_metadata.json` поле `text_file` и SHA-256 будут указывать на реально озвученный файл.

Путь `-SpeechTextFile` разрешается относительно текущего каталога PowerShell, из которого запущена команда. Можно передать абсолютный путь.

## Важные ограничения

- Адаптер не переписывает `script.txt`.
- Адаптер не изменяет `timeline.json` и `production_package.json`.
- При редактуре `script_tts.txt` сохраняйте все произносимые слова в том же порядке, что и в каноническом тексте. Менять можно прежде всего пунктуацию и границы фраз.
- Это экспериментальная редакция для проверки пунктуации и просодии; прослушайте WAV до массового использования.
