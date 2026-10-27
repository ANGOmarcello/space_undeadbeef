# Modern host foundation — version 1.1 (11)

The 27 October 2026 pass preserves the supplied executable, artwork, original
menus, fixed 60 Hz gameplay, collision rules and save packing. Platform behavior
lives in the native host. Foundation verification used native Mac and Simulators,
retaining the user's existing Watch session. Subsequent explicitly requested
device installations are recorded separately in [Verification.md](Verification.md).
Build 11 refines transient iOS scene handling, native audio recovery and iPhone
haptic attachment. It is installed and normally opened on the iPhone 14 Pro;
the user confirmed feeling the Options OFF→ON tick again. Gameplay feedback and
an actual incoming banner remain separate physical verification.

## Native controls and accessibility

Arrow keys move the targeting pointer according to elapsed simulation time,
independently of keyboard repeat. Hold Space to aim/charge and release to fire.
Escape or P invokes the original pause menu. Modifier changes cannot swallow a
tracked key's release. Touch and mouse retain ownership over simultaneous keys
or controller input. Losing focus, an interruption or controller disconnection
cancels owned input without releasing a charged volley.

Extended controllers use the left stick to steer through the original ship
spring, the right stick or D-pad to aim, A or the right trigger to charge/release,
and Menu to pause. Either stick addresses original menu rows. A held controller
button must be released before it can rearm after focus/controller changes.
TV remote Back/Menu pauses gameplay; normal system navigation remains available
in menus. Watch keeps the existing Crown and touch controls. Real controller
feel and physical remote delivery are separate from policy/Simulator checks.

The original live menu records supply semantic buttons and selected values for
assistive technologies. Activation revalidates identity, animation, bounds and
original first-hit rules, then invokes the original menu decision path. These
accessibility children do not draw replacement menus or intercept ordinary
touches. An eligible stopped host exposes an accessibility-only Resume game
action after a media interruption. It restores scheduling and leaves the
original Pause/Resume menu in charge. Continuous gameplay is not claimed to be
fully playable through VoiceOver.

iPhone feedback attaches to the actual app window through a transparent,
noninteractive sentinel, independently of Metal or software rendering. Owner
checks prevent an old view's teardown from removing a replacement attachment.
Invalidated generators rebuild only during an enabled, visible, active update.
The existing iPhone/Watch event policy and cooldowns are unchanged; see
[Haptics.md](Haptics.md) for current delivery and historical device receipts.

## Interruptions and persistence

Scene activity, application focus and audio interruption are independent gates.
A transient inactive iOS scene continues the existing 60 Hz updates and drawing,
while cancelling held input and disabling interaction and haptics. Backgrounding,
focus loss, a real audio interruption and disconnected audio routes enter the
original pause flow. Other platforms also pause for an inactive scene. Stopped
time is not simulated on return.

The native audio gate can keep playback stopped while the original Pause menu
continues updating and drawing. The ordinary Resume action explicitly asks the
OS to activate audio before releasing that gate. It can recover a missing
interruption-ended notification or an ended notification without permission to
resume automatically. A rejected activation remains retryable; it does not
fault the guest or resume gameplay. Successful activation leaves the original
Pause/Resume decision in charge.

A media services reset reconstructs native audio nodes while retaining decoded
PCM, guest state and music identity/cursor intent. One-shot effects interrupted
or requested while gated are discarded rather than replayed later.
Rebuilding the native graph does not itself start playback; explicit recovery
still checks activation, following
[Apple's media reset guidance](https://developer.apple.com/library/archive/qa/qa1749/).
iOS also requests the system-alert interruption preference without changing the
existing Ambient/Playback category policy. A denied preference is diagnostic;
accepted or full-screen calls can still interrupt and follow the same pause flow.

Periodic checkpoints capture the original 256-byte PSH0 pack on the game thread
and perform disk work on a serial worker. The backlog is bounded to one active
write and one latest pending record. Original explicit saves and lifecycle saves
finish before returning and supersede older pending checkpoints. Unchanged
records avoid disk writes. Main-thread error reads do not wait for filesystem IO.

Atomic same-directory replacements retain a bounded recovery sidecar containing
two independently SHA-256-checked original records. A damaged primary can recover
from a verified record. Invalid, oversized, symlink and nonregular files are
rejected. Storage errors are nonfatal and appear through a native alert. See
[the exact original save/menu contracts](SaveAndMenuContracts.md) for recovery
limits, progression validation and original disassembly evidence.

## Optional progress sync without CloudKit deployment

Foundation's NSUbiquitousKeyValueStore shares validated progress using the same
key-value entitlement on all four app identifiers. There is no CloudKit database,
container, schema, server or deployment command. Normal Apple iCloud capability
provisioning and an eligible account are still required for actual delivery.
Local play and local saves remain available if the service is unavailable.
The foundation checks used injected transports. Subsequent device builds use
normal Xcode automatic provisioning; signed cross-device progress delivery remains
unverified.

Only verified checkpoint and score records are exchanged. Furthest progression
wins; high score never decreases. Local sound, game speed and unknown original
bytes are retained. Preferences are not synchronized. A running or paused game
is never replaced by an incoming checkpoint; application occurs at the title
screen. One bounded record per installation prevents an offline writer from
replacing another writer's unseen better progress; records from at most 64
installations are merged, with a 4096-byte bound per record.

KVS availability must not be inferred from iCloud Drive's ubiquity identity token:
Watch and TV can support KVS without Drive. See [Apple's KVS documentation](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore)
and [the platform distinction in QA1935](https://developer.apple.com/library/archive/qa/qa1935/_index.html).
The current SDK declares Watch KVS support beginning with watchOS 9; the older
QA's blanket Watch KVS limitation predates that API availability.

## Efficiency and future compatibility

On the software renderer, an exactly repeated menu command packet reuses its
immutable image. Every fixed update and original guest render call still runs;
moving menus, gameplay, texture edits, resizing and cache trims invalidate reuse.
The paired 416×496 Mac proxy reused 1637/1800 menu images after 300 warmup frames,
with identical guest memory, registers, flags, instruction counts, allocator/RNG,
GL state, pixels, events and final saves. Alternating-order render-only elapsed
mean was 0.358 ms cached versus 3.760 ms uncached; p99 was 5.361/7.508 ms. The
paired process footprint grew 802816 bytes after warmup, below the 32 MiB bound.
These are Mac proxy measurements, not Watch battery, thermal or physical FPS proof.

Backgrounded or audio-gated playback stops its native engine. Memory pressure
trims disposable software scratch and Metal readback/CI caches without freeing visible images, decoded
assets, guest state or GPU resources still in flight. Actual GPU fixtures verify
retained snapshots and pending frames survive trimming byte-for-byte.
Native alerts pause the game and reject held, queued and fresh game input until
acknowledgement, so a controller cannot resume play behind a save-error alert.

Metal shaders are compiled into default.metallib at build time. Application
startup no longer compiles source strings. Device pipeline creation still occurs
normally. All non-Watch bundles must contain their compiled library; Watch uses
the software renderer. GPU fixtures skip only when no Metal device is available;
library or pipeline initialization errors on an available device fail verification.

`script/verify_compatibility.sh` runs isolated correctness checks and serial
unsigned builds for all four platforms, without device discovery or app launch.
`--tests-only`, `--builds-only`, `--require-gpu` and explicit opt-in Simulator UI
checks are supported. The optional UI path requires already booted simulators
and accepts exact UDIDs; it never boots/shuts down somebody else's Simulator.
The checked-in GitHub workflow is configured for future runs, not evidence of
a remote CI run or publication.

Canonical fixtures in `Tests/Fixtures/original-engine-*.txt` were generated from
commit `21c7316` with the unchanged actual-engine-v1 workload and Xcode 27.2 on
Apple silicon. Current/baseline results match for all 600 software images, every
guest-state checkpoint, 300 Metal steps and final original save bytes. Metal
pixel hashes also matched on this Mac during the build 10 foundation pass, but
are intentionally excluded from a global golden assertion because GPUs/drivers
round differently; independent
GPU/CPU fixtures enforce their one-byte tolerance. Changing canonical fixtures
requires reviewing the actual behavior difference, rather than regenerating
expectations merely to pass a test.

The 17 resume fixtures cover every validated original checkpoint entry using
normal Continue and 240 fixed updates, a normal frame and save per entry. They
naturally enter Corporal and Sergeant constructor paths. They do not establish
completion of every stage or boss encounter.
