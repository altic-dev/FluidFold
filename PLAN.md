# Duofy — Plan & Milestones

Goal: a lightweight macOS menu bar app that animates the desktop as the MacBook lid closes
(recreating trybendy.app). The visual effect is an isolated, hot-reloadable module so the
graphics can be tuned without touching the sensor / capture / window pipeline.

## Architecture

| Layer | Folder | Knows about |
|---|---|---|
| Effect | `Sources/Effect` | Metal only. `FoldParams` (tunables) → `FoldRenderer` (runtime-compiled `Shaders/FoldEffect.metal`) → `FoldPreviewView` / `TuningPanel` |
| Pipeline | `Sources/Pipeline` | `LidAngleSensor` (IOHID), `ScreenCapturer` (ScreenCaptureKit), `OverlayWindow`, `EffectController` (angle → progress → show/hide) |
| App | `Sources/App` | Menu bar, Settings (Appearance / General / Tuning), sound, launch at login |

Contract between Pipeline and Effect: `renderer.setSource(pixelBuffer:)`, `renderer.progress`, `renderer.params`.

## Milestones

| # | Milestone | Status |
|---|---|---|
| M0 | Build & signing: xcodegen `project.yml`, `build_dev.sh` (copied pattern from FluidVoice), local Apple Development cert via `xcconfig/LocalSigning.xcconfig` | done |
| M1 | Effect module: params struct + 3 presets, runtime shader with file-watch hot reload, tuning panel with a slider per uniform, preset JSON copy/paste | done |
| M2 | Pipeline: hinge sensor polling, display capture excluding own windows, shielding-level overlay window, controller with start/end angles, pause (click / Esc) | in progress |
| M3 | App shell: menu bar extra, Settings with live MacBook preview + lid slider, sound click, launch at login | todo |
| M4 | First install + verify on this MacBook (permission prompt, lid close/open, pause) | todo |
| M5 | Graphics tuning loop: edit `.metal` / sliders → ship defaults into `FoldParams` presets | todo |
| Later | Developer ID + notarization + DMG (needs Barath's Developer ID cert), licensing (skipped for personal build) | later |

## Tuning workflow (M5)

1. `./build_dev.sh` installs to /Applications and points the app at the repo's `FoldEffect.metal` for hot reload.
2. Menu bar → Settings → Tuning: drag sliders, or edit the `.metal` file and save.
3. Copy JSON → paste values into `FoldParams` presets in `FoldParams.swift`.
