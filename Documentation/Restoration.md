# SPACE UNDEADBEEF restoration

Static intake performed on 25 October 2026. The supplied IPA is the authoritative
original input. No original source code, original save file, or backend
specification was present in the project folder at intake.

## Original input

| Item | Evidence |
| --- | --- |
| IPA | `MyFirstBundleIdentifier-iOS2.1-(Clutch-2.0.4).ipa`, 11,855,451 bytes |
| IPA SHA-256 | `4000d45e21f69cab6c271c6aa917989674615a51f2bddc295115dc2eab8b36de` |
| Bundle | `Payload/psh.app` |
| Executable | `psh`, 179,136 bytes |
| Executable SHA-256 | `f90a2cdeae9c955520c9358b0f511f92d8327ba69650816b34a7d6f177025d1e` |
| Original identity | `MyFirstBundleIdentifier`, display name `S.deadbeef`, version `1.01` |
| Original system | iPhoneOS SDK 2.1, minimum iOS 2.1, MainWindow nib |
| CPU | One ARMv6, 32-bit Mach-O slice; no ARM64 slice |
| Encryption | `LC_ENCRYPTION_INFO`, cryptoff 4096, cryptsize 69632, cryptid 0 |
| Code | `__text` at `0x2000`, 52,892 bytes; 461 named text symbols, including 457 Thumb symbols |
| Symbols | 3,026 total symbol-table records, 157 undefined imports, retained C++ gameplay names |

The original cannot load directly in current 64-bit operating systems. The current
restoration executes its ARMv6 gameplay through a bounded interpreter, preserving
guest 32-bit memory and object layouts. It does not recover the original C++
source. Static instruction specialization remains a possible future optimization;
it is not the architecture implemented here. Code size alone does not prove
instruction coverage or runtime correctness.

## Engine and compatibility seams

The executable contains gameplay classes including `Player`, `Game`, `Marker`,
`CollisionSystem`, `StageScenario`, `EnemyZako`, `EnemyCorporal`, `EnemySergeant`,
`Snake`, `LockonLaser`, `Menu`, and `SaveData`. Scenario data, enemy paths, and 27
virtual tables remain in the executable. This is a custom engine rather than a
Unity or Mono app.

The original platform wrapper uses UIKit, `EAGLView`, `Texture2D`, OpenGL ES 1,
OpenAL, AudioToolbox, and CoreGraphics. The guest C++ gameplay can be entered below
the UIKit wrapper. Replacing image, audio, and file boundaries avoids building a
general Objective-C compatibility runtime for this specific input.

All addresses below include the Thumb low bit except the two ARM switch helpers.
The guest ABI passes float bit patterns in general registers. Member functions
receive `this` in `r0`; subsequent arguments occupy `r1` to `r3`, then the guest
stack. All pointers are guest addresses rather than native pointers.

| Guest entry | Address | Contract |
| --- | --- | --- |
| TextureManager initialize | `0x421d` | Allocates 62 records of 32 bytes; pointer stored at `0x15744` |
| SoundEffect constructor | `0xe7e9` | `r0` points to 264 bytes; singleton stored at `0x15d6c` |
| GameManager constructor | `0x8dfb` | `r0` points to 24 bytes; singleton stored at `0x15d54` |
| GameManager update | `0x8af3` | `r0=this`, `r1=dt` float bits |
| GameManager render | `0x8b23` | `r0=this` |
| Touch began | `0x8b3d` | `r0=this`, `r1=x`, `r2=y` |
| Touch moved | `0x8b77` | `r0=this`, `r1=currentX`, `r2=currentY`, `r3=previousX`, `[sp]=previousY` |
| Touch ended | `0x8bdb` | `r0=this`, `r1=x`, `r2=y` |
| Touch cancelled | `0x8c15` | `r0=this` |
| Gravity | `0x8c2d` | `r0=this`, `r1=gx`, `r2=gy`, `r3=gz` |
| Pause / forced pause | `0x8c39` / `0x8c71` | Pause receives `r1=bool` |
| Load / save | `0x8c85` / `0x8e13` | `r0=this` |
| ReadFile | `0xa8a1` | `r0=filename`, `r1=sizeOut`; returns guest-allocated buffer or zero |
| WriteFile | `0xa80d` | `r0=filename`, `r1=bytes`, `r2=length`; returns bool |
| FreeFileBuf | `0xa959` | `r0=guest buffer` |
| ARM switch-u8 / switch-32 | `0xee64` / `0xee7c` | Dispatch through inline tables relative to guest `lr` |

Initialization must prepare textures and sound before calling GameManager's
constructor. It constructs Camera (64 bytes), TaskManager (144 bytes), Game (116
bytes), and Menu (44 bytes), starts top menu type 1, then loads a save. Allocation,
list hook/unhook, floating-point helper, math, text formatting, C++ static guard,
and exception-unwind imports need explicit compatibility handling. An unexpected
guest exception or unsupported instruction must fail with diagnostic context.

The original view calls update with the fixed float `1/60`. GameManager updates
the camera, menu, and sound with that dt, while TaskManager uses the game-speed
float at GameManager offset 20. Its normal default is also `1/60`. A modern display
callback must preserve this simulation cadence when presentation refresh differs.

## Graphics and input

The original logical viewport is 320 by 480, centered at zero, with x in
`[-160,160]` and y in `[-240,240]`. Original touch conversion is `x=pointX-160`,
`y=240-pointY`. GameManager applies its own camera inversion during 180-degree
rotation. Host aspect fitting and its inverse input transform must remain paired.

Texture records have the following layout:

| Byte offset | Type | Meaning |
| --- | --- | --- |
| 0 | uint32 | Texture name/handle |
| 4, 8 | float32 | Content width and height |
| 12, 16 | uint32 | Padded pixel width and height |
| 20 | uint32 | Texture pixel format |
| 24, 28 | float32 | maxS and maxT: content dimensions / padded dimensions |

There are 62 slots, with 61 original loaded images; slot 45 is unused. The exact
ID-to-file mapping and dimensions are emitted in `Resources/Original/manifest.json`.
When rendering unpadded native images, account for maxS/maxT in original texture
coordinates rather than cropping the native image incorrectly.

`render_image` at `0x6da1` receives a RenderData pointer in `r0`. Its fields are x,
y, width, height, rotation (floats at 0 through 16), texture ID (uint32 at 20),
additive flag (byte 24), tint flag (byte 25), and tint RGBA (floats 28 through 40).
It translates, rotates about z, and scales static unit vertices by half width and
height. It draws a triangle strip using texture coordinates `(0,maxT)`,
`(maxS,maxT)`, `(0,0)`, `(maxS,0)`. Standard blending uses source alpha and inverse
source alpha; additive blending uses source alpha and one. Other rendering paths
include vertex colors, lines, primitive triangles, and sprite-sheet subregions;
bridging only this sprite helper would miss those paths.

Camera rendering at `0x9027` rotates by camera offset 44, translates by the negative
values at offsets 8 and 20, and scales x/y by the float at offset 32. A renderer
must preserve the matrix stack, primitive order, texture coordinates, and color
state rather than infer sprite placement from class names.

## Assets, audio, and saves

`script/prepare_original.py` validates exact archive and executable hashes,
rejects unsafe ZIP paths/symlinks, copies the guest executable and original WAVs,
and converts Apple CgBI PNGs to standard RGBA PNGs. Conversion reverses PNG row
filters, raw deflate, BGRA order, and premultiplied alpha. Source image bytes and
the IPA remain unchanged; original and prepared hashes are recorded separately.
Prepared game assets under `Resources/Original` are intentional build resources.

The game loads 12 sound IDs, including stage and boss music. The manifest records
filenames and per-asset gains. Original sound methods are stop BGM `0xe86f`, mute
BGM `0xe899`, fade-out `0xe8e1`, update `0xe8f1`, play effect `0xe995`, play BGM with
loop flag `0xea15`, and play looping BGM `0xeaf5`. Audio must preserve enable state,
loop behavior, and pause/fade semantics when replacing OpenAL.

The modern audio policy intentionally changes the original first-launch OFF
default: sound and Respect Silent Mode both default to ON. Explicit choices are
stored immediately in `NSUserDefaults` under `audio.soundEnabled` and
`audio.respectsSilentMode`. The modern preference is applied after legacy save
loading, so a new installation starts with sound enabled while an explicit modern
OFF choice remains OFF. The existing game Sound ON/OFF controls use the same native
preference setter as the host.

On iOS and watchOS, Respect Silent Mode is added inside the original Options menu
by copying its text/button records and reusing its font, colors, animation, and
hit testing. Its label and ON/OFF choices occupy the next existing section spacing;
SAVE-EXIT remains in place. The session uses the ambient category when respecting
silent mode and the playback category when that policy is OFF. macOS retains
normal system audio output; it has no equivalent iPhone hardware silent switch.

When `SDB_SAVE_DIRECTORY` is provided for a test, both preference keys use an
atomic `audio-preferences.plist` in that temporary directory. The test path never
accesses standard user defaults. This verifies preference policy and persistence
without changing real user settings; production uses `NSUserDefaults`.

`SaveData` writes `savedata.dat`, exactly 256 bytes, with magic `0x30485350`
(`PSH0`) and its size at byte 8. The original format includes gameplay checkpoint,
score, game speed, and sound state. Preserve the guest pack/unpack logic and
perform host writes atomically. No user save was supplied, so cross-install
migration has not been verified.

## Current execution architecture

`Sources/Legacy/GuestCPU.cpp` interprets original ARMv6 ARM/Thumb instructions in
32 MiB of bounded guest memory. It has an instruction budget and stops on
unsupported execution. It uses no JIT. Game logic, scenario tables, enemy
behaviors, menus, collision code, and save packing remain in the hash-checked
original executable.

`Sources/Legacy/SDBEngine.mm` loads Mach-O segments, resolves the original import
stubs, and enters the C++ gameplay below UIKit. Native bridges implement memory,
math, list nodes, text formatting, files, and audio. A software OpenGL ES 1
compatibility renderer implements the exercised fixed-function matrix, vertex,
texture, color, and blending paths and produces a CoreGraphics image. It preserves
the original 320 by 480 logical viewport and presents it clockwise in a 480 by 320
landscape frame. Native host views supply aspect fitting and inverse input mapping.

The renderer includes original texture padding, texture environment replacement
versus modulation, additive blending, and rotation axes. Supporting these paths
does not establish complete OpenGL ES or ARM conformance.

## Headless integration verification

On 25 October 2026, `Tests/RuntimeSmoke.mm` compiled and ran against the current
native engine with Foundation, CoreGraphics, ImageIO, and AVFoundation. These are
macOS command-line integration checks; they do not establish app installation or
physical-device support. The harness writes frames and saves only to a caller-owned
temporary directory. It sets `SDB_MUTE_AUDIO=1` and `SDB_SAVE_DIRECTORY` before
constructing the engine, so no real user settings or saves are used.

Verified behavior:

- Original title, Options, and gameplay render with readable, correctly oriented
  assets. A real title tap at landscape `(160,40)` starts the game.
- A 3,600-update active-input run executed 105.3 million guest instructions without
  an instruction or import fault. Ordinary holds, releases, enemy-field scans,
  vertical drags, and Continue taps reached stage 1-10 with one death, high score
  1,065, and current score 90. Captures visibly show a held charge, a released
  expanding shot, enemy explosions, and increasing score. The run produced 368
  guest audio play events through its subsequent resume. No health, score, stage,
  or instruction modifications were used.
- A 1,800-update gameplay run executed 44.7 million guest instructions without an
  instruction or import fault. The guest reached stage 1-03, score 15, one death,
  and its ordinary Continue/Quit menu.
- Drag and cancellation events pass through the original input methods.
- Suspension writes the original 256-byte `PSH0` save format atomically. A fresh
  engine then loads that save; a real Continue tap visibly resumes stage 1-03,
  score 15, and one death. This verifies saves produced by the restored engine,
  not migration from an unavailable historical save.
- Modern first-launch sound and Respect Silent Mode default to ON. The actual
  Options → Sound OFF flow changes the rendered selection and persists immediately,
  surviving engine recreation before SAVE-EXIT and again after SAVE-EXIT. The
  actual ON control persists in both native preferences and the legacy save byte.
  Respect Silent Mode OFF survives sound OFF/ON and engine recreation; changing it
  back to ON also persists. Original audio play events increase during gameplay,
  shots, and resume. Original WAVs decode successfully; listening quality, the
  hardware silent switch, and Apple audio-session behavior were not tested by the
  macOS headless run because playback is muted and macOS uses system output.
- After the modern audio-policy changes, the complete preference/menu/relaunch
  sequence and 2,400 active gameplay updates passed AddressSanitizer and
  UndefinedBehaviorSanitizer with no diagnostics. That active run executed 80.4
  million guest instructions, recorded 316 audio play events, and successfully
  saved and continued the game again. Leak detection was disabled for this native
  framework integration run; this is not a claim of leak-free system frameworks.

Reproduce the headless checks from the project root, with output outside the
repository:

```sh
task_tmp=$(mktemp -d /private/tmp/space-undeadbeef-smoke.XXXXXX)
xcrun clang++ -std=c++17 -O2 -fobjc-arc -I Sources/Legacy \
  Sources/Legacy/GuestCPU.cpp Sources/Legacy/SDBEngine.mm Tests/RuntimeSmoke.mm \
  -framework Foundation -framework CoreGraphics -framework ImageIO \
  -framework AVFoundation -o "$task_tmp/RuntimeSmoke"
SDB_SMOKE_SOUND=1 "$task_tmp/RuntimeSmoke" \
  "$PWD/Resources/Original" "$task_tmp" 160 40 1800
```

`SDB_SMOKE_SOUND=1` exercises the real sound OFF/ON menu and isolated preference
persistence; omitting it preserves the modern ON default or an existing explicit
choice in the caller's temporary directory. Use a fresh `mktemp` directory to test
first-launch defaults. Add `-fsanitize=address,undefined -fno-omit-frame-pointer`
when compiling to enable sanitizer checks.
`SDB_SMOKE_ACTIVE=1` replaces passive gameplay updates with repeated real pointer
holds, releases, target scans, and vertical drags for at least 2,400 updates. It
does not modify guest health, score, scenario, memory, or instructions. Periodic
taps at the ordinary Continue location allow recovery when that menu appears.
Captures identify held and released input phases; their names do not alone prove
a charged shot or lock-on occurred. Visually inspect the produced frames.

## Native host verification

Native macOS and all three Simulator hosts have build and concrete interaction
evidence recorded in [Verification.md](Verification.md). That record separates
original gameplay, host input, audio policy, and the remaining hardware checks
from the headless integration results above.

## Remaining verification boundary

These checks exercise concrete guest paths and generated saves. They do not
establish every enemy, boss, stage, instruction, import, or rendering path, nor an
exact visual/timing match against a running original device. Physical-device
performance, hardware audio and silent-mode behavior, device signing, physical
installation, and distribution require their own evidence. The recorded host
interactions cover specific flows rather than every control or platform behavior.
