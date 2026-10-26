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

## Second pass — version 1.1 (9)

Baseline: `87d21db`, including the first performance pass and Watch haptic
cadence. Two isolated 12-second Instruments Time Profiler captures identified
repeated `std::string` storage checks in import comparisons and software pixel
pattern fills. The renderer review also found repeated native draw/state work.

- Resolve each imported name to a string view once per bridge call. Reuse a
  bounded 4,096-vertex scratch vector and a fixed four-vertex title sky array.
- Keep software RGBA in vector registers. Textured REPLACE initializes its
  constant color directly, removing a pattern-fill call per covered pixel;
  barycentric math, sample order, blend math and byte conversion stay intact.
- Prewarm the three common Metal pipelines at startup. Merge only contiguous,
  adjacent triangle ranges with all nine render-state fields identical. Preserve
  original draw order, validate every original record and reuse encoder bindings.
  Other valid blend combinations retain lazy compilation. Invalid blend factors
  are checked before pipeline-cache lookup, including the opaque-key alias case.
- Confine software image observation to a SwiftUI leaf, so frame publication
  does not invalidate the enclosing gesture, Crown and toolbar view. This is
  source-level isolation; its standalone SwiftUI CPU saving was not measured.

The fixed-clock algorithm, game instructions, artwork, input and haptic policy
are unchanged. The software timer now anchors its epoch to its first actual
callback. Anchoring to activation could leave ordinary jitter straddling a
simulation boundary, repeatedly rendering zero then two steps. Metal retains its
existing epoch. A timing fixture reproduces that unfavorable phase and verifies
one step per subsequent 60 Hz callback with the same total simulation steps;
borrowed-time debt, catch-up limits and suspend/resume checks remain intact.

Opt-in `SDB_PERFORMANCE_LOG=1` now reports Metal submissions and software
image publications separately, plus simulations, callback gaps and CPU work.
Diagnostics use constant space and remain off in ordinary launches. Reports
cover completed two-second stable-menu windows; short phases and the first
callback after each phase change are omitted. They exclude later SwiftUI
composition, GPU completion and physical scanout.

### Matched native CPU workload

Same M4 Max/Xcode environment, optimized arm64 builds, isolated empty saves,
muted process-local audio, 90 warm-up steps and 600 identical original updates.
Metal workloads were paced for ten seconds; software was unpaced. Each pair
contained 571 gameplay samples and matched guest instruction, draw, allocation
and audio-event counts. These raster-size cases run on the Mac, not the named
devices. Shared machine load and thermals were uncontrolled.

| Raster/path proxy | Gameplay mean, baseline → updated | Gameplay p99, baseline → updated |
| --- | ---: | ---: |
| Watch, 416×496 software | 4.135 → 3.755 ms | 5.468 → 5.051 ms |
| iPhone, 2622×1206 Metal | 0.414 → 0.285 ms | 0.993 → 0.563 ms |
| iPad, 2732×2064 Metal | 0.417 → 0.306 ms | 0.809 → 0.636 ms |
| Mac, 1920×1280 Metal | 0.431 → 0.309 ms | 0.762 → 0.541 ms |
| TV, 3840×2160 Metal | 0.440 → 0.301 ms | 0.801 → 0.492 ms |

No gameplay CPU sample exceeded 16.667 ms in these paired workloads. Mean CPU
work fell approximately 25–35% in the Metal cases and 9% in software. An earlier
30-second baseline had title scheduling outliers up to 70.48 ms; these short
comparisons do not establish that every startup/transition stall is eliminated.

Reproduce the candidate with
`script/test_performance.sh [frames] [metal|watch] [paced|unpaced] [iphone|ipad|mac|tv|watch]`.
The optional preset sets raster size only. Timings cover simulation and
render/submission work, not presentation completion.

### Correctness evidence

`script/test_draw_assembly.sh` passes 99 checks with ASan/UBSan and strict
warnings: triangle/strip/fan order, offsets, empty/incomplete/bounded/rejected
draws, scratch reuse, sky tint/UVs, tall-background anchoring, independent
REPLACE/MODULATE pixels and fault behavior. `script/test_rendering.sh` passes
eleven software/actual-Mac-GPU comparisons within one byte, four byte-identical
packed/gapped batching fixtures (RGBA overlap, glyph atlas at vertex 7, menu
distance field and additive overlap), state/range barriers and seven malformed
trailing-record/recovery cases. Each 24-sprite batch becomes one native draw;
including its background, draw and pipeline-binding counts fall from 25 to 2.

`script/test_performance_equivalence.sh [watch|metal] [absolute engine source] [absolute renderer source]`
emits deterministic fingerprints for comparison across independently exported
baseline/current implementations. Full 32 MiB
guest memory, registers, flags, faults, instruction counts, RNG, allocator and
selected runtime state match at every 30-frame checkpoint. All 600 software images match
byte-for-byte; ten actual Metal readbacks across 300 frames also match. Each
pair writes the same original 256-byte lifecycle save. Hashing/readback overhead
is deliberately excluded from the performance benchmark. These fixtures exercise
the original game, including ordinary deaths; they do not patch health or stages.

### Actual native and Simulator hosts

The iPhone 18 Pro, iPad Pro 13-inch M5 and Apple TV 4K Simulator performance
UI tests each pass with a thirty-second workload that targets during gameplay
and retains original death/menu behavior, unique temporary saves and muted
process audio. The
first TV attempt used an extra Up input and failed to select Start; using the
existing interaction test's five Up inputs passed. Native Mac keyboard gameplay
and Watch Simulator touch/drag/Continue were visually reviewed separately.

The following ranges are from complete two-second gameplay windows in the
actual host logs, after the common runtime optimizations:

| Host | Windows | Simulations/s | Submissions or images/s | Mean CPU work range | Maximum CPU work |
| --- | ---: | ---: | ---: | ---: | ---: |
| iPhone 18 Pro Simulator | 9 | 60.0 | 58.5–60.0 submissions | 0.30–1.67 ms | 15.87 ms |
| iPad Pro 13-inch M5 Simulator | 10 | 60.0 | 60.0 submissions | 0.39–1.57 ms | 3.48 ms |
| Apple TV 4K Simulator | 15 | 59.9–60.1 | 59.9–60.1 submissions | 0.39–1.50 ms | 4.48 ms |
| Native Mac, 960×640-point window | 7 | 60.0 | 60.0 submissions | 0.34–0.83 ms | 1.77 ms |
| Series 12 46 mm Watch Simulator, aligned software epoch | 14 | 60.0 | 59.0–60.0 images | 3.68–4.76 ms | 8.76 ms |

Before the software epoch correction, seven Watch gameplay windows showed
39.7–46.0 images/s despite roughly 60 callbacks and simulation updates/s. Each
window had 28–41 zero-step callbacks paired with catch-up callbacks. Afterward
all fourteen windows had zero zero-step callbacks. The two input-associated
gaps above 25 ms still reached 57.71 ms, with bounded catch-up; the remaining
windows published 60 images/s. This demonstrates the phase fix in Simulator,
not a guarantee about physical Watch display/thermal limits. More published
frames also perform more rendering work per second; the software CPU benchmark
above measures per-frame efficiency independently of that cadence correction.

Sampled iPhone windows still contain 21 callbacks above 25 ms (maximum 47.25 ms).
iPad has one at 25.04 ms; TV and native Mac have none in these gameplay windows.
The native UI results therefore establish useful CPU headroom and improved
Watch cadence, not universal zero-jitter presentation. GPU completion, physical
scanout, prolonged thermal load and all later-stage content remain unmeasured.

Final timing tests and 53 actual Session-to-engine Crown checks pass, including
software first-callback, duplicate-callback and resumed-epoch assertions. All
147 haptic policy checks pass. Latest source builds for iOS, watchOS, tvOS and
native macOS. The original UI and renderer remain visually consistent in the
reviewed host captures.

Physical testing was stopped at the user's scope correction. An earlier iPhone
test-runner attempt timed out while enabling automation, and Watch installation
failed to reconnect; neither supplies physical performance evidence. No Apple
TV hardware was queried or woken. Test-only native/Simulator processes, temporary
captures, traces and result bundles are cleaned after recording verification;
reusable application build products remain in standard DerivedData.
