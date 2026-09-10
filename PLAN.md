# FluidFold — Plan & Milestones

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
| M2 | Pipeline: hinge sensor polling, display capture excluding own windows, shielding-level overlay window, controller with start/end angles, pause (click / Esc) | done |
| M3 | App shell: menu bar extra, Settings with live MacBook preview + lid slider, sound click, launch at login | done |
| M4 | First install + verify: permission granted, overlay verified on the real screen via simulated sweep (MTKView bug on macOS 27 beta worked around) | done |
| M5 | Physically based effect: frosted-glass reprojection (ported from DuoLikeAnimation), spring-smoothed sensor | done |
| M6 | Smoothness: pre-warmed capture, tilt-0 first frame at Retina res, settle-before-hide, display-link pacing, GPU ~3 ms/frame, sleep/wake handling | done |
| M7 | Timeline model: fixed A→B frames, frozen snapshot, lid as playhead, cubic glide, 120 fps (drawable starvation fixed) | done |
| M8 | Smoothness from numbers: always-on per-fold report (`folds.log`), fake-sweep benchmark, root causes found and fixed: capture *sessions* force compositing (→ rect screenshot, no stream), cold start (→ launch warm-up), focus/teardown during motion (→ deferred to settle), pipeline starvation (→ release on GPU completion). ~120 fps while moving, ≤3 cadence blips per fold | done |
| M9 | Playhead as a delay line (115 ms): even speed, no overshoot, no reverse glide; velocity lead removed | done |
| M10 | Live refresh: update the snapshot mid-fold when the desktop changes, without moving the playhead | next |
| M11 | Feel tuning with Barath: blurSpread / ramp / darkening presets | later |
| Later | Developer ID + notarization + DMG (needs Barath's Developer ID cert), licensing (skipped for personal build) | later |

## Tuning workflow (M5)

1. `./build_dev.sh` installs to /Applications. In Settings → Tuning → Choose…, pick the repo's `FoldEffect.metal` once (grants file access) for hot reload.
2. Drag sliders, or edit the `.metal` file and save. `scripts/preview.sh` runs a full-screen sweep.
3. Copy JSON → paste values into `FoldParams` presets in `FoldParams.swift`.
