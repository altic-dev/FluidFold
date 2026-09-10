# Lid tracking calibration — 2026-09-10

## Current behavior: direct lid control

The old **Preview on screen** action called `simulateClose()`: a three-second timer replaced the real
lid angle and ignored sensor updates until playback completed. That path has been removed, including
the developer notification hook. **Live lid preview** now fixes its reference plane at the current
lid angle and follows actual sensor input until dismissed. Holding the lid does not advance progress.

The intermediate 8 ms filter and legacy spring have also been removed. `LidPose` maps each accepted
angle directly to tilt/progress. Capture callbacks update pixels while preserving that pose. There is
no display-link-driven progress update, timed settling, or automatic preview ending. Escape or
**End live lid preview** ends the preview. The normal automatic effect still begins below the saved
start angle. Angle readouts observe the controller directly and show two decimal places.

Every sensor poll now records `controller_state` and `controller_mapping`, even while the overlay is
hidden. `effect_update` records every applied pose. Tests cover immediate closing, holding through
36,000 noisy readings, immediate reversal, and replay of the recorded stationary sensor data.

Installed direct-control check: the live preview remained at its starting pose for 86 seconds across
4,966 rendered frames. Exactly one `effect_update` occurred (initial display); capture frames did not
advance the fold. This verifies logged pose behavior, not an independent visual recording. The
physical close/hold/reopen path remains available to test in the active live preview.

## Earlier calibration and retained changes

- Fine HID report is the angle source when available. The old rule could reject a newer fine reading
  simply because the coarse reading disagreed, then move backward when it switched sources.
- The target stays anchored until movement exceeds 0.20°. Coarse-only fallback uses 1.05° to suppress
  whole-degree toggling. These are displacement thresholds, not thresholds between adjacent samples:
  slow, cumulative motion still releases the lock.
- An 8 ms exponential response was tested initially; the current implementation uses direct position
  updates instead, following the clarified requirement to stop at the reported lid position.
- A dedicated serial render queue acquires Metal drawables and encodes commands. Main-thread inputs
  are immutable snapshots. One submission is in flight; one coalesced request retains the newest
  inputs. The layer uses two drawables. Preview renderers are separate from the live overlay.
- High-frequency telemetry is buffered and written off the main and sensor queues. Sessions stop
  automatically after 90 seconds. Buffer capacity is bounded; losses are counted explicitly.

## Earlier evidence and limits (before direct-position update)

Evidence files are under `build/lid-calibration/` (intentionally untracked).

| Measurement | Result |
| --- | --- |
| Stationary sensor recording | 10,800 polls over 90 seconds at 120 Hz |
| Fine reading at rest | 104.41–104.57°, a 0.16° range |
| Coarse reading at rest | Toggles between 104° and 105° |
| Replaying that recording through the new tracker | Exactly 0° rendered drift |
| Installed overlay, physical lid held at its existing position | 1,043 rendered frames after initial settling; tilt stayed exactly 8.0° while fine readings ranged 116.34–116.47° |
| 10° step, 95% software response at 120 FPS | Old spring: 133 ms; new filter: 25 ms (deterministic simulation) |
| 10° step, 95% software response at 60 FPS | Old spring: 150 ms; new filter: 33 ms (deterministic simulation) |
| Pre-render-queue preview trace, sensor callback p95 | 6.85 ms |
| Post-render-queue preview trace, sensor callback p95 | 0.054 ms |
| Post-render-queue preview trace, GPU p50 / p95 | 2.75 / 3.34 ms |
| Post-render-queue preview trace, commit-to-presentation p50 | 23.83 ms |

Both reports changed around every 100 ms on this Mac in the stationary capture and a short opening
movement. Polling faster does not make these values update faster. This is observed report cadence,
not proof of the sensor's internal acquisition frequency. The reports expose no hardware timestamp;
we cannot measure physical movement-to-photon latency with these host timestamps alone.

The before/after pipeline runs are synthetic on-screen sweeps, not matched physical lid sweeps.
Large startup/main-thread scheduling outliers still occur, including roughly 200 ms at app launch.
Presentation still contributes about 24 ms in the measured run. A sustained physical close/reopen
and reversal sweep remains necessary to validate motion feel and calibration over the full range.
Do not describe the 8 ms filter setting as total end-to-end latency.

## Run diagnostics

```bash
scripts/trace_tracking.sh                 # 90-second trace in the running app
python3 scripts/analyze_tracking.py       # summarize newest trace
scripts/preview.sh                       # live lid preview; move the physical lid, Esc to exit
swiftc Sources/Pipeline/LidTracker.swift Tests/LidTrackerTests.swift -o build/tracker-tests
build/tracker-tests
# Optional: also replay the stationary recording captured during calibration.
build/tracker-tests build/lid-calibration/baseline-sensor.csv
```

Traces are written to `~/Library/Logs/DuskTracking/tracking-*.csv`. Set the `trackingTrace` default
only when startup tracing is needed; normal use leaves it disabled. The old `legacyTracking`
default, synthetic sweep, and timed stationary-check hook are no longer used.

## Trace schema

All `time` values use `CACurrentMediaTime()` with sub-millisecond precision. Numeric payload columns
are `a` through `h`, in the order below. Rows can arrive out of timestamp order from separate queues;
join by IDs or sort by timestamp. `session.a` is Unix wall time for external correlation. No desktop
pixels, window names, or screenshots are included.

| Event | ID | Payload columns in order |
| --- | --- | --- |
| session | 0 | Unix wall time, requested duration |
| sensor | sample | coarse, fine (nan if absent), legacy fused, coarse-read end, fine-read end; row time is read start |
| sensor_failure | 0 | row time is failed read start |
| sensor_main | sample | read completion time, legacy deadband changed flag |
| tracking_target | sample | anchored target, using fine flag, fine deadband |
| controller_state | sample | accepted angle, applied tilt, applied progress, overlay visible, waiting for capture, enabled, paused, live preview |
| controller_mapping | sample | reference angle, end angle, armed |
| effect_update | effective sample | accepted angle, tilt, progress, reference angle, end angle |
| live_preview_start / live_preview_end | 0 | current angle |
| display_link (historical) | effective sample | display timestamp, target presentation timestamp |
| filter (historical) | effective sample | target angle, rendered angle, velocity, frame delta |
| render_request | frame | effective sample ID |
| draw | frame | effective sample ID, drawable-acquired time, tilt (-1 for preview), progress, capture PTS, width, height; row time is encode entry |
| commit | frame | effective sample ID |
| gpu | frame | effective sample ID, GPU start, GPU end, command status |
| presented | frame | effective sample ID, drawable presented time (0 means unavailable) |
| render_dropped | 0 | effective sample ID; request coalesced because a submission is in flight |
| drawable_failure | frame | no drawable/command buffer available |
| capture_start / capture_ready | 0 | lifecycle boundary |
| capture_frame | 0 | capture presentation timestamp |
| capture_main | 0 | capture callback arrival time |
| overlay_show / overlay_hide | 0 | sensor target, rendered angle on hide |
| simulation_start / simulation_end (historical) | 0 | duration on start; sample ID 0 identifies synthetic frames |
| stationary_check_start / stationary_check_end (historical) | 0 | current angle, original threshold |
| trace_dropped | 0 | buffer overflow count |

An effective sample ID on a rendered frame identifies the sample which last changed the target.
Its age grows intentionally at rest. It is not a measure of sensor transport delay; use `sensor_main`
for transport. Capture PTS may remain old for an unchanged desktop. Shader motion uses the lid angle
on every render and does not wait for a new captured desktop image.
