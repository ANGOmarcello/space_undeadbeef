# Backend and persistence

The supplied 1.01 executable imports Foundation/UIKit, graphics, audio, C/C++ and Objective-C runtime APIs. Its import inventory contains no networking framework, socket, HTTP, account, purchasing, advertising, analytics, or multiplayer API. No backend service is required for the observed local game implementation.

The restoration adds no network service. The native host replaces the original Documents-directory file wrappers for the one observed filename, `savedata.dat`. Original `SaveData` packing and validation execute in guest code. Each host stores this file atomically under its own Application Support directory. Originals and existing saves are not migrated or overwritten by intake tooling.

## Local state

| State | Storage | Behavior |
| --- | --- | --- |
| Original game progress | Application Support / host bundle identifier / `savedata.dat` | Original 256-byte `PSH0` packing and validation execute in guest code; host writes are atomic. |
| Sound choice | `NSUserDefaults`, `audio.soundEnabled` | Boolean, defaults to ON; the original Options ON/OFF controls persist changes immediately. |
| Silent-mode policy | `NSUserDefaults`, `audio.respectsSilentMode` | Boolean, defaults to ON; exposed inside the original Options screen on iOS/watchOS. |
| iPhone / Watch haptics | `NSUserDefaults`, `feedback.hapticsEnabled` | Boolean, defaults to ON when absent; explicit OFF is preserved. Original Options ON/OFF controls persist immediately, independently of sound. Each host bundle keeps its own choice. Hosts without haptics keep it disabled. |

Modern audio preferences are applied after loading the legacy save. A historical
save's sound byte therefore does not replace an explicit modern choice. Each host
bundle has separate preferences and progress. No historical user save was supplied,
so migration from an original installation remains unverified.

The smoke test sets `SDB_SAVE_DIRECTORY` to its task-owned temporary directory.
UI tests pass unique `~/tmp/...` paths; the engine expands
the tilde inside the application sandbox, rather than using the test runner's
different home. An absent override retains the normal Application Support path.
With this override, audio and haptics preferences use an atomic `audio-preferences.plist` beside the
test save and do not access standard user defaults. `SDB_MUTE_AUDIO` mutes only that
process while retaining the guest audio execution path. Neither override changes
system volume, Silent Mode, another app's preferences, or the production default.

Native and Simulator verification results, including audio-policy limits, are in
[Verification.md](Verification.md).
