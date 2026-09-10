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

Frosted-glass reprojection, adapted from [elijah-semyonov/DuoLikeAnimation](https://github.com/elijah-semyonov/DuoLikeAnimation):
the desktop stays on the plane where the screen was when the effect started, the eye stays put, and only the
glass (the lid) rotates about the bottom hinge. Each pixel casts a ray from the eye through the tilted glass to the
desktop plane, samples there, and blurs/darkens in proportion to the glass-to-plane gap. The sensor uses its fine-angle report with a calibrated 0.20° resting deadband. Each accepted reading
sets the fold position directly; there is no playback timer, spring, interpolation, or prediction.
Capture refreshes the live desktop without advancing the fold. Metal drawable acquisition and encoding run on a dedicated
queue with a bounded, latest-request policy. Settings previews have separate renderers.

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
