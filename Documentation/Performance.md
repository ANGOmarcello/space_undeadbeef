# Performance pass — 26 October 2026

The original simulation remains fixed at 60 updates per second. MetalKit now
drives simulation and presentation in the same 60 Hz callback on iPhone, iPad,
and Mac. Catch-up performs at most four original updates and renders once;
suspension resets the clock. Watch retains the software renderer and its timer.
Metal frames no longer invalidate SwiftUI or produce a CGImage every update.

Instruments Time Profiler identified repeated import-name scans and audio
preparation/start/stop work in the original restoration's frame path. Import
comparisons now preserve literal lengths. Bounded guest memory accesses retain
their validation while avoiding repeated cold fault-formatting work. Metal
reuses three bounded vertex buffers and releases each only after GPU completion.
Software bilinear sampling interpolates RGBA together with the same formula.

## Audio

All twelve original PCM WAVs are decoded before gameplay into a bounded cache.
One persistent AVAudioSourceNode mixes the original eight round-robin effect
voices and independent music voice. Play, stop, pause, gain and looping publish
atomic controls; the real-time callback owns playback cursors and performs no
allocation, Objective-C messaging, locks, decoding or file access. A serial
control queue coalesces asynchronous engine wake requests after interruptions.
Initial preparation and lifecycle resume remain explicit operations.

The decoded cache allocates 28,047,496 bytes (26.75 MiB), excluding framework
objects, within a 64 MiB limit. This trades bounded resident memory for removal
of repeated decoder/player creation during gameplay. Sound preference, silent
mode policy, music fades, source stealing and pause/resume behavior are retained.
Measured source controls took at most 0.002 ms in the local comparison; the
discarded AVAudioPlayerNode prototype still spent up to 10.609 ms in play.

## Matched local benchmark

Machine: Apple M4 Max, 64 GiB RAM; Xcode 27.2; optimized native arm64 command-line
builds. Baseline engine/CPU/renderer are from `a7431c3`, before this performance
pass. The baseline was instrumented only to expose the same simulation/render
boundaries. Both runs used isolated empty temporary saves, process-local muted
audio, 90 warm-up steps, original Game Start and the same repeating pointer
holds, releases and targeting sweep. The Mac was shared with other sessions;
thermal state and machine-wide load were not controlled.

Each Metal run measured 1,800 steps paced over 30 seconds at 2622×1206. Both
executed exactly 39,198,324 guest instructions, 106,693 draw calls and 69 audio
events, including 940 gameplay samples, 95 transition/menu samples and 765 title
samples. The game followed its ordinary death/menu path; no health, scenario,
score or instruction modifications were made.

| Gameplay CPU work, 940 samples | Baseline | Updated |
| --- | ---: | ---: |
| Mean simulation + render/submit | 3.104 ms | 1.416 ms |
| 99th percentile | 26.309 ms | 3.825 ms |
| Maximum | 36.530 ms | 4.721 ms |
| Samples above 16.667 ms | 56 | 0 |

Across all 1,800 samples, CPU-work budget overruns fell from 57 to zero and
paced CPU deadline misses from 78 to zero. Whole-run 99th percentile was
22.560 → 3.609 ms. Input/bookkeeping/sleep are outside the CPU-stage timings;
the paced deadline counter includes input/bookkeeping and scheduling lateness.

A separate 600-step unpaced Mac software-renderer comparison at 416×496
executed identical 12,222,876 guest instructions, 42,834 draws and 30 audio
events. Gameplay CPU 99th percentile fell from 16.297 to 4.945 ms; render-only
mean fell from 3.888 to 3.743 ms. This is a Mac proxy for the Watch rendering
path, not a Watch hardware performance measurement.

`script/test_performance.sh [frames=1800] [metal|watch] [paced|unpaced]` reproduces
the candidate workload with temporary state and reports each original menu
phase separately. It measures CPU work and Metal submission, not GPU completion
or physical display scanout. Metal unavailability is reported as a skip.

## Correctness and host verification

- Guest CPU: 376 sanitizer checks and 496,608 differential states against the
  prior interpreter matched registers, flags, memory, faults and instruction
  counts, including every Thumb encoding in three initial states.
- Timing: 30/60/120 Hz, submillisecond 60 Hz jitter, faster callbacks, borrowed
  scheduling time with repayment, bounded catch-up, suspend/resume and ten-minute
  uptime checks pass. Callback leeway never discards time debt.
- Audio: 143 offline checks pass under AddressSanitizer, UndefinedBehaviorSanitizer
  and float-cast-overflow checks. They cover full original WAV durations, exact
  stereo samples, one-shot endpoints, seamless loops, gain, mute, nine voices,
  stop/replay, pause/resume, cached playback after deleting a copied input, and
  asynchronous stopped-engine wake. Tests do not open an audio output device.
- Renderer: eleven software/actual Mac GPU fixtures agree within one byte,
  including independent RGBA/alpha and original font/shadow fixtures. GPU buffer
  reuse passed 2,989 ownership/growth/queue/destruction checks. Software game
  output remained byte-identical in a matched 600-step run.
- Render skipping: 2,641 original updates, 663 checkpoints and 3,303 renders
  preserved persistent game state, allocator state, RNG, all 305 audio events
  and the final 256-byte save. This isolated semantic check stubbed native pixel
  and playback work; it is not an end-to-end performance result.
- Final runtime sanitizer smoke passes original title/Options, immediate audio
  preference persistence, Game Start, 600 gameplay steps, drag/cancel, lifecycle
  save/resume, engine recreation and Continue. Geometry (4,712), bitmap contours
  (10,472), and guarded display patches (1,559) also pass.
- iPhone 18 Pro Simulator, native Mac and Watch Simulator builds pass. Actual
  iPhone Simulator gameplay logged 60.0 Hz callbacks, simulation and submissions,
  with zero callbacks above 25 ms in sampled two-second intervals. Native Mac
  title and Game Start/gameplay were visually checked and logged the same 60 Hz
  rates. These diagnostics are opt-in with `SDB_PERFORMANCE_LOG=1`.

Physical-device sustained frame delivery, thermals, audible mixing quality,
hardware silent mode and every later stage/boss remain unverified. No further
Apple TV discovery or testing was performed after the user's stop request.
