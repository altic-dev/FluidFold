# FluidFold

Your desktop folds with your MacBook lid. A tiny menu bar app that tilts, blurs, and dims the screen in sync with the hinge angle.

[**Download**](https://github.com/altic-dev/FluidFold/releases/latest) · macOS 15.2+ · MacBooks with a hinge sensor (2019 and later)

Nothing is recorded or uploaded. One snapshot of your desktop is taken as the lid starts to close and rendered on the GPU.

## How it works

- The hinge sensor drives a fixed timeline: closing plays forward, opening rewinds. Same angle, same frame.
- One screenshot is frozen per fold, so forward and reverse are identical.
- A Metal shader reprojects the desktop through a tilting sheet of glass, blurring and darkening with the gap.

## Settings

- Style (Silk, Shade, Frost), blur, shadow.
- Start angle, launch at login, automatic updates.
- While folded: mute audio.
- Click or press Esc to dismiss a fold until the lid reopens.

## Build

```bash
brew install xcodegen
cp xcconfig/LocalSigning.example.xcconfig xcconfig/LocalSigning.xcconfig   # your dev signing identity
./build_dev.sh                                                             # builds, installs, launches
```

Release build (universal, notarized, DMG, Sparkle appcast):

```bash
cp release.env.example release.env   # Developer ID + notarytool profile
./build_and_notarize.sh
```

Then publish a GitHub release `vX.Y.Z` with the DMG and `build/release/updates/appcast.xml` as assets.

## Code

- `Sources/App` — menu bar, settings, onboarding
- `Sources/Pipeline` — lid sensor, screen capture, overlay window, controller
- `Sources/Effect` — the effect: `FoldParams.swift` (tunables and presets), `Shaders/FoldEffect.metal` (hot-reloaded at runtime), `FoldRenderer.swift`

Every fold writes a smoothness report to `~/Library/Logs/FluidFold/folds.log`. Dev helpers live in `scripts/`.

Effect adapted from [elijah-semyonov/DuoLikeAnimation](https://github.com/elijah-semyonov/DuoLikeAnimation). Inspired by [Bendy](https://trybendy.app).

## License

MIT. See [LICENSE](LICENSE).
