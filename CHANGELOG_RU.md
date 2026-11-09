# CHANGELOG

## 2.3.0 — 2026-11-08
- "Think longer": new two-stage run. Stage 1 = free-text editorial plan with thinking enabled and no JSON schema (`planning` in settings.json); stage 2 = strict JSON package with `think=false`. Fixes the empty-content / `done_reason=length` runs that happened when thinking and the large schema shared one token budget.
- Anchor checks ignore case, punctuation and extra whitespace (word order still must match). Fixes the "worn, leather brown wallet" vs "worn leather brown wallet" rejection.
- Visual repair: up to `ollama.repair_attempts` rounds; a retry gets the rejection reason and temperature 0.3 (an identical temperature-0 prompt repeated the same rejected answer). Stale "needs manual edit" notes are removed after a successful retry.
- Deterministic safety nets: anchors missing from `image_prompt` are appended; anchors visible in `image_prompt` but missing from `visual_purpose` are appended after retries, with a `human_review` note.
- Repair calls use the same `num_ctx` as the main call (a different `num_ctx` makes Ollama reload the model).
- `ollama.unload_after_run` releases VRAM (keep_alive=0) after the last Gemma call so TTS/ComfyUI can use the GPU.
- New advisory warnings: caption not in the narration language, `motion_graphic` without `on_screen_text`, `visual_purpose` that refers to another scene.
- Prompt: v2.3 rules (no cross-scene references, comma-free anchors, Russian captions only, motion_graphic only for text/graphics, no split-screen).
- New docs: `docs/ARCHITECTURE_REVIEW_RU.md`, `PATCH_NOTES_v2.3.0_RU.md`.

## 2.2.7 — 2026-11-08
- Fixed the Test-Repair fixture: optional `motion_target` is created with Add-Member before assigning an empty value.
- No production module logic changed from 2.2.6.


## 2.2.5 — 2026-11-08
- Wan budget reserved for actual timeline opening/closing scenes, not first/last among AI-labelled scenes.
- Scene-level Gemma visual repair calls reduce cross-scene and cross-route contamination.
- Route-safe repair clears stray video_prompt from image_animation and downgrades camera-only AI-video prompts to FFmpeg camera animation.
- Identity descriptions remain continuity details, not visual anchors.
- Added regression tests for intermediate-only Wan scenes and invalid route fields.
- Test-Factory version check now reads semantic version from VERSION.txt.

# Журнал изменений ContentFactory

## 2.2.4
- Добавлен ограниченный второй проход Gemma для исправления несогласованных визуальных якорей и целей движения.
- Continuity-описания отделены от сюжетных visual anchors.
- Добавлены проверки применения ремонта и регрессионные тесты.
- Единый номер версии обновлён до 2.2.4.

## 2.2.0
- Единый контракт производственного пакета, режиссёрские визуальные якоря, профиль локальных ресурсов, identity reference и расширенные проверки.

## 2.2.6 — 2026-11-08
- Added safe property setter for JSON-derived scene objects when optional fields are absent.
- Wan budget repair now creates/updates motion_target, video_prompt, motion_prompt and route fields without StrictMode property-assignment errors.
- Added regression coverage for intermediate ai_video scenes whose source JSON omits motion_target.
