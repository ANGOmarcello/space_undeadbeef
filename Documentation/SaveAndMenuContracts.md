# Save and menu contracts — 27 October 2026

`SDBSaveStore` owns progress files only. It never reads or changes user defaults.
The engine still invokes the original guest packing/unpacking routines. Sound,
Silent Mode and Haptics retain their separate host preferences.

## Verified original save format

The authoritative executable's `SaveData::load` at `0xe788` checks exactly three
conditions: the returned file length is 256 (`0xe79e–0xe7a6`), its first word is
`0x30485350` / `PSH0` (`0xe7b2–0xe7b8`), and its word at offset 8 is the returned
length (`0xe7ba–0xe7be`). It then copies all 256 bytes. It has no checksum. The
new loader's structural validator is tested against actual execution of that
original method for valid, truncated, wrong-magic, wrong-size and changed-reserved
byte fixtures. An old legacy record therefore receives its original structural
validation; arbitrary corruption in its unused bytes cannot be detected until a
new integrity record exists.

`GameManager::save` at `0x8e12` constructs the original zero-filled SaveData,
packs game speed at offset `0x10` and the original sound byte at `0x14`, then calls
`Game::pack` at `0x4f6e` and `SaveData::save` at `0xe770`.

| Save offset | Verified field and executable evidence |
| --- | --- |
| `0x20` | Current score, from `Game + 0x60`; `Game::incScore` at `0x4fa2` updates it. |
| `0x24` | High score, from `Game + 0x64`; `incScore` retains the larger score. |
| `0x28` | Original game counter from `Game + 0x68`; packing is verified. Its use is retained without changing it. |
| `0x2c` | Scenario checkpoint cursor, from `StageScenario + 0x14`. |
| `0x30` | Checkpoint counter, from `StageScenario + 0x18`. |
| `0x34` | Lap counter, from `StageScenario + 0x1c`. |
| `0x38` | Music entry, from `StageScenario + 0x20`. |

`StageScenario::pack/unpack` at `0x8724/0x8736` copy those four scenario fields.
`ss_checkpoint` at `0x840c` increments the checkpoint counter and stores the next
scenario unit index; `ss_lap_inc` at `0x841e` increments lap, resets checkpoint
counter and stores the next index. The hash-checked `stage0_scenario` at `0x13f7c`
contains 87 units of 20 bytes. Portable imports accept only zero or the unit after
one of its checkpoint/lap operations, with a matching checkpoint counter, bounded
nonnegative signed scores/counters and music entry 0 through 12. The host does not
invent scenario instructions, health, progress or score during gameplay.

## Storage and recovery

`savedata.dat` remains exactly the original 256-byte record. The bounded
`savedata.recovery.plist` contains schema 1 and at most two SHA-256-verified records:
the new checkpoint and the previous valid checkpoint. The sidecar is committed
before the primary, so a primary matching either record is accepted after an
interrupted replacement. A truncated or mismatched primary recovers from the
newest valid sidecar record; a damaged newest recovery record can fall back to
the previous one. Repair failures return the valid recovered bytes and expose
the write error. Invalid primary/recovery files are left untouched when no valid
record exists.

Reads reject symlinks, nonregular files and files larger than their 256/4096-byte
limits, and cap the actual read as well as the initial size check. Writes use a
same-directory temporary file, file flush and atomic rename. This is not a claim
of guaranteed survival under every filesystem or power-loss condition.

Repeated saves with identical bytes do not replace either file. A legacy record
without integrity protection is seeded once on its next save. Storage errors are
reported through `lastSaveError`; they do not become fatal CPU/game faults.
`saveProgress` is synchronous and calls the original guest save routine. Lifecycle
suspension also saves before suspending the audio mixer.
Periodic `checkpointProgress` captures the same original guest bytes on the
engine thread, then gives them to the save coordinator's serial worker. The
coordinator retains at most one running write and the latest pending checkpoint;
completed explicit/lifecycle saves supersede stale queued checkpoints. Reading
`lastSaveError` uses the cached result rather than waiting for disk work.

## Portable progress

`progressPortableSnapshot` captures the original pack output without writing a
file. Schema 1 includes the bounded 256-byte data, SHA-256 and derived progression
metadata. Future schemas and checksum/unsafe-field failures are rejected.

`SDBEngine.mergeProgress(_:remote:)` is a pure merge: the farther lap/checkpoint
retains its original scenario block and associated score/counter; high score
always takes the maximum. Local game speed, sound and unknown bytes remain local.
An older remote checkpoint with a higher high score cannot regress local progress.
`importValidatedProgress` permits application only on the original title screen,
with no active touch or suspension. It persists the merged record and invokes
the original `GameManager::load` at `0x8c84`, then reapplies the host's modern sound
choice. Gameplay, Pause and death menus reject application. Cloud transport,
account authorization and conflict scheduling belong to the native host.

## Semantic original menu actions

`menuActions` traverses the original menu's bounded live button list, identifies
verified callbacks and reports their current animated bounds in logical space.
Decorative records are omitted. Sound, Silent Mode, Haptics and speed selection
come from their actual current state. IDs include the menu-generation counter,
guest button and data-record identity; `Menu::start` invalidates earlier IDs.
Actions are unavailable during pending decisions, suspension and gameplay.

Activation rechecks the live ID and follows the original executable's first-hit
test using `MenuButton::isExecutable` / `in`. It then calls original
`Menu::touchBegan` and `Menu::touchEnded` at that exact button center. The original
sound, decided animation and callback run normally. A successful result means the
original decision was accepted, not that an arbitrary state was assigned by the
host. No stale action can dispatch directly into an old callback.

The focused menu integration test exercises title, Options selections,
SAVE-EXIT, Credits/Back, original Game Start, Pause/Resume/Quit, stale IDs,
inactive suppression, save/relaunch, and naturally earned checkpoint import to
a fresh receiver with its own preferences. The store suite covers original
loader equivalence, bounded recovery, checksum/schema failures, unchanged saves,
I/O failure reporting and deterministic merging. Both use temporary state.

## Software menu rendering and inactive memory

The software renderer still executes every original simulation and guest render
call. For menus it records the exact ordered logical triangle/state packet
before rasterization. When that packet, texture generation and raster geometry
are byte-identical to the previous menu frame, it retains the existing immutable
image and pixel buffer. Changed packets replay the original software triangle
path in the original order. Transition animations therefore continue normally;
gameplay never uses this cache. Retained packet metadata is capped at 1 MiB.
Both texture insertion paths increment its generation, and resize, gameplay or
resource trimming invalidate the packet. Invalid blend factors fall back to
immediate rasterization so the original covered-pixel fault boundary is retained.

`trimTransientResources` keeps the visible immutable frame and all guest state.
It releases menu packet metadata and the renderer's transient readback cache;
software pixels and scratch buffers are released only while suspended. The next
render recreates those buffers without advancing the simulation specially.

`script/test_memory_soak.sh` compares cached and test-only uncached engines with
actual original title/Options actions, transitions, resize, gameplay, trim/resume
and completed saves. Its 1,800 post-warm menu samples follow 300 warmup frames.
Every step checks all 32 MiB of guest memory, registers/flags/instruction count,
allocator/RNG state, feedback/counters, final graphics state and exact software
pixels. The 27 October run passed 21,258 checks, reused 1,637 menu images and
observed 802,816 bytes of post-warm footprint growth, below its 32 MiB allowance.
Alternating-order render-only wall-time samples averaged 0.358 ms cached versus
3.760 ms uncached, with p99 5.361/7.508 ms. These are a native Mac process proxy,
not measured Watch battery life, hardware frame rate or isolated CPU-cycle data.
The draw suite separately passes 106 primitive/order/packet/fault checks under
ASan/UBSan.

## Native cancellation of held input

The original `Game::touchCancelled` does not end its aim marker. Explicit native
focus/lifecycle cancellation also invokes the original `Marker::ended` path at
`0x4b3b`, already used by native Crown steering, without releasing a charged
volley. Ordinary touch-ended firing is unchanged. Menu integration verifies that
`cancelHeldInput` clears aiming without a release event and that a fresh charge
can begin afterward. This adapts native cancellation; it changes no guest
movement, health, projectile or scenario rules.

## Checkpoint-entry compatibility smoke

`script/test_scenario_resume.sh` starts from actual original pack output and
creates isolated, validator-approved PSH0 fixtures at all 17 verified checkpoint
cursors listed above (cursor 85 uses lap 1 and reset checkpoint counter). Each
fixture loads through the original loader, round-trips unchanged through its
original pack routine, activates the actual Continue menu action, advances 240
ordinary fixed steps and renders/saves normally. It never writes live guest
state or changes health, speed, physics or scenario instructions. A transparent
test-only hook counts original function entry while preserving the existing
hook result and instruction execution.

The 27 October strict ASan/UBSan run passed all 17 entries without a guest fault;
all remained in gameplay and executed 240 original scenario updates. These short
runs naturally reached one Corporal constructor (cursor 52) and four Sergeant
constructors (cursors 58, 62, 66 and 70). Zako and Snake constructors were not
reached in these bounded intervals. This verifies checkpoint entry and selected
later enemy paths, not complete stages or boss fights.
