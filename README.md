# Duofy

Lightweight macOS menu bar app that animates your desktop as the MacBook lid closes
(a recreation of [Bendy](https://trybendy.app)). Reads the hinge angle from the built-in
sensor, captures the screen with ScreenCaptureKit, and renders a perspective fold with Metal.
Nothing is recorded or uploaded. macOS 14+, Apple Silicon.

## Build & run

```bash
./build_dev.sh          # xcodegen → xcodebuild (Release) → /Applications/Duofy.app → launch
```

- Requires a full Xcode in `/Applications` (picked automatically) and `brew install xcodegen`.
- Signing: `xcconfig/LocalSigning.xcconfig` (Apple Development, team TEAMID). Copy the
  `.example` file to change identity.
- Env knobs: `CONFIGURATION=Debug`, `INSTALL_APP=0`, `LAUNCH_APP=0`.
- First launch asks for Screen Recording. Grant it, then relaunch.

## Using it

- Menu bar icon → **Live lid preview** anchors the effect at the current lid angle. Lower the lid to fold; hold it still to hold the fold; reopen to reverse. There is no autoplay.
- Click the screen or press Esc to pause until the lid is reopened.
- Settings: Appearance (style, live preview, sliders), General (trigger angles, sound, login item), Tuning.

## How the effect works

**Timeline model.** The fold is a fixed timeline from the start angle A (frame 0, flat) to the end angle B
(last frame). The lid is the playhead: closing plays forward, opening rewinds, and the same angle always shows
the same frame. One desktop snapshot is frozen when the fold appears, and every frame is computed from it, so
forward and rewind are identical. Frames are computed on demand (~2.5 ms on the GPU) instead of being stored,
which gives the same result as pre-rendering without the ~3 GB of memory.

| Setting | Default | Meaning |
|---|---|---|
| `degreesPerFrame` | 0.05° | Timeline resolution. A=95°, B=25° gives 1400 frames |
| Tracker deadband | 0.2° | Resting sensor jitter never moves the playhead |

**Playhead.** The hinge sensor publishes ~10 readings/s. Between readings the playhead follows a cubic glide:
it passes exactly through each reading, keeps speed continuous, eases into a stop, and never overshoots.
It trails the lid by about one sensor interval (~110 ms). A frame is drawn only when the frame number changes.

**Look.** Frosted-glass reprojection, adapted from [elijah-semyonov/DuoLikeAnimation](https://github.com/elijah-semyonov/DuoLikeAnimation):
the glass (lid) rotates about the bottom hinge; each pixel casts a ray from the eye through the tilted glass to the
desktop plane and blurs/darkens in proportion to the glass-to-plane gap.

## Tuning the graphics (the part meant to be iterated on)

Everything visual lives in `Sources/Effect` and knows nothing about lids or capture:

| File | What |
|---|---|
| `FoldParams.swift` | All tunables + the Silk / Shade / Frost presets |
| `Shaders/FoldEffect.metal` | The shader. Compiled at runtime, **not** by Xcode |
| `FoldRenderer.swift` | Metal renderer: source texture in, fold out |
| `TuningPanel.swift` | One slider per parameter, preset JSON copy/paste, shader hot reload |

Workflow:

1. Settings → Tuning. Drag sliders while watching the preview, or run `scripts/preview.sh` to see it full screen.
2. For shader edits: Tuning → Shader → **Choose…** and pick `Sources/Effect/Shaders/FoldEffect.metal` in the repo
   (the picker grants file access). Save the file and the app reloads it instantly; compile errors show in the panel.
3. Happy? **Copy JSON** and paste the values into the presets in `FoldParams.swift`.

Key knobs: `eyeDistanceMM` (perspective), `blurSpread` (blur per px of gap), `rampDegrees` (ease-in of the frost), `darkening` + `minLight`, `frost`, `sheen`, `vignette`. Responsiveness: `LidTracker.Configuration` (resting deadband) and `EffectController.prewarmDegrees`.
See `TRACKING.md` for the measured calibration, diagnostic schema, and remaining latency limits.

Adding a uniform: add a field to `FoldParams`, to `FoldParams.Uniforms`, and to `FoldUniforms` in the `.metal` file (same order, 16-byte aligned).

Note: MTKView presents stale surfaces on macOS 27 beta, so `FoldMetalView` drives a `CAMetalLayer` directly.

## Debugging

```bash
scripts/sweep.sh 1.5                                      # fake lid sweep at the real sensor cadence
scripts/trace_tracking.sh && scripts/sweep.sh && python3 scripts/analyze_sweep.py   # frames, stalls
defaults write com.altic.Duofy debugHUD -bool true        # on-screen frame / sensor readout (costs frames)
defaults write com.altic.Duofy debugLog -bool true        # ~/Library/Logs/Duofy.log
defaults write com.altic.Duofy debugDumpDir "$PWD/build"  # writes build/duofy_frame.png at mid-sweep
./scripts/preview.sh
```

`scripts/preview.sh` + `screencapture -x` captures the real overlay for review.

## Layout

- `Sources/App` — menu bar, settings, persisted state
- `Sources/Pipeline` — `LidAngleSensor`, `ScreenCapturer`, `OverlayWindow`, `EffectController`
- `Sources/Effect` — the fold effect (see above)
- `PLAN.md` — milestones
