# FluidFold

Lightweight macOS menu bar app that animates your desktop as the MacBook lid closes
(a recreation of [Bendy](https://trybendy.app)). Reads the hinge angle from the built-in
sensor, captures the screen with ScreenCaptureKit, and renders a perspective fold with Metal.
Nothing is recorded or uploaded. macOS 15.2+ (needs the rect screenshot API), Apple Silicon, a MacBook with the hinge-angle sensor (2019 and later).

## Build & run

```bash
./build_dev.sh          # xcodegen → xcodebuild (Release) → /Applications/FluidFold.app → launch
```

- Requires a full Xcode in `/Applications` (picked automatically) and `brew install xcodegen`.
- Signing: `xcconfig/LocalSigning.xcconfig` (Apple Development, team TEAMID). Copy the
  `.example` file to change identity.
- Env knobs: `CONFIGURATION=Debug`, `INSTALL_APP=0`, `LAUNCH_APP=0`.
- Release: `./build_and_notarize.sh` → universal (arm64 + x86_64) app signed with Developer ID, notarized and
  stapled, packaged as `build/release/FluidFold-<version>.dmg`. Needs the `notarize` notarytool profile.
- First launch asks for Screen Recording. Grant it, then relaunch.

## Using it

- Menu bar icon → **Live lid preview** anchors the effect at the current lid angle. Lower the lid to fold; hold it still to hold the fold; reopen to reverse. There is no autoplay.
- Click the screen or press Esc to pause until the lid is reopened.
- Settings: Appearance (style, live preview, sliders), General (trigger angles, login item), Tuning.

## How the effect works

**Timeline model.** The fold is a fixed timeline from the start angle A (frame 0, flat) to the end angle B
(last frame). The lid is the playhead: closing plays forward, opening rewinds, and the same angle always shows
the same frame. One desktop snapshot is frozen when the fold appears, and every frame is computed from it, so
forward and rewind are identical. Frames are computed on demand (~2.5 ms on the GPU) instead of stored.

| Setting | Default | Meaning |
|---|---|---|
| `degreesPerFrame` | 0.05° | Timeline resolution. A=95°, B=25° gives 1400 frames |
| Tracker deadband | 0.2° | Resting sensor jitter never moves the playhead |

**Playhead.** The hinge sensor publishes ~10 readings/s. The playhead is a delay line: it plays the readings
`playheadDelayMs` (115 ms) behind real time, linearly between readings, with timestamps snapped to the sensor's
100 ms cadence (60 Hz polling would otherwise make alternate segments 17% faster or slower). So its speed between
two readings is exactly the lid's average speed over that interval, it can never pass a reading, it never
reverses unless the lid does, and it stops exactly where the lid stopped. If the next reading is late it keeps
the last speed for at most `maxExtrapolation` (0.35) of a cadence, then holds. A frame is drawn only when the
frame number changes, paced by a display link (120 Hz on ProMotion).

**Snapshot, not a stream.** The desktop is captured with the rect-based `SCScreenshotManager.captureImage(in:)`
(~40 ms, full Retina) while the lid moves in the pre-warm zone (10° above A), refreshed every 250 ms, and once
more at the threshold if the last one is older than 500 ms. There is no capture stream: any ScreenCaptureKit
*session* (streams, and the session-based screenshot APIs) keeps the window server compositing our window for
~0.8 s afterwards, which triples frame latency and drops one refresh in three. The rect screenshot does not.
The overlay window is ordered in invisibly when the zone is entered, so showing it is only an alpha change, and
keyboard focus (for Esc) is taken only once the lid is still. A launch-time warm-up exercises all of this once.

**Adaptive pacing** (`expAdaptive`, off): present on every other refresh while frames take >26 ms to reach the
glass. Off because in real closes latency alternates 8/16 ms and the toggle flapped, adding cadence breaks.

**Look.** Frosted-glass reprojection, adapted from [elijah-semyonov/DuoLikeAnimation](https://github.com/elijah-semyonov/DuoLikeAnimation):
the glass (lid) rotates about the bottom hinge; each pixel casts a ray from the eye through the tilted glass to the
desktop plane and blurs/darkens in proportion to the glass-to-plane gap.

## Smoothness reports (always on)

Every fold writes a report to `~/Library/Logs/FluidFold/folds.log` and a per-frame CSV to `~/Library/Logs/FluidFold/folds/`:

```
fold #131  2.73 s  lid 86.1° → 20.0° → 105.0°  readings 16  on screen 195 (71 fps)  never shown 1
  start  (0–300 ms)     30 frames  irregular  0/2   missed  0  holds  0  max gap   8.3 ms
  middle               137 frames  irregular  1/95  missed  1  holds  0  max gap  16.7 ms  ← compositor ×1
  end    (last 300 ms)  28 frames  irregular  0/22  missed  0  holds  0  max gap   8.3 ms
  worst: drawable wait 17.3 ms   GPU queue 0.8 ms   GPU 2.5 ms
  VERDICT: SMOOTH
```

- **irregular** = the on-screen cadence changed while the playhead was moving (e.g. 8 ms then 17 ms). This is
  what the eye sees as stutter. A steady 60 or 120 is not irregular.
- **missed / holds** = refreshes with no new frame while one was wanted; the arrow names the slow stage.
- **worst** = per-stage maxima: drawable wait (window server), GPU queue, GPU time.

```bash
scripts/last_fold.sh [n]                    # newest n reports
scripts/sweep.sh 0.9                        # fake lid: close in 0.9 s, hold 1 s, reopen (real sensor cadence)
nohup scripts/bench.sh "label" 5 -- key value ... &   # restart app, 5 sweeps, one summary line (run detached so
                                            # the terminal/Claude window is idle: its redraws show up as stutter)
```

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
scripts/trace_tracking.sh && scripts/sweep.sh && python3 scripts/analyze_sweep.py   # raw per-frame trace
defaults write com.altic.FluidFold debugHUD -bool true        # on-screen frame / sensor readout (costs frames)
defaults write com.altic.FluidFold debugLog -bool true        # ~/Library/Logs/FluidFold.log
defaults write com.altic.FluidFold debugDumpDir "$PWD/build"  # writes build/hinge_frame.png at mid-sweep
./scripts/preview.sh
```

`scripts/preview.sh` + `screencapture -x` captures the real overlay for review.

## Layout

- `Sources/App` — menu bar, settings, persisted state
- `Sources/Pipeline` — `LidAngleSensor`, `ScreenCapturer`, `OverlayWindow`, `EffectController`
- `Sources/Effect` — the fold effect (see above)
- `PLAN.md` — milestones

# Updates (Sparkle)
- Feed: `https://github.com/altic-dev/FluidFold/releases/latest/download/appcast.xml`; EdDSA key lives in the login keychain (account `FluidFold`, made with Sparkle's `generate_keys`).
- `./build_and_notarize.sh` also writes `build/release/updates/appcast.xml`. Publish a GitHub release `vX.Y.Z` with the DMG and `appcast.xml` as assets.
