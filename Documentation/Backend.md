# Backend and persistence

The supplied 1.01 executable imports Foundation/UIKit, graphics, audio, C/C++ and Objective-C runtime APIs. Its import inventory contains no networking framework, socket, HTTP, account, purchasing, advertising, analytics, or multiplayer API. No backend service is required for the observed local game implementation.

The native host replaces the original Documents-directory file wrappers for the
one observed filename, `savedata.dat`. Original `SaveData` packing and validation
execute in guest code. iPhone/iPad, Mac and Watch store this file atomically under their own
Application Support directory, with bounded checksummed recovery records.
Starting with 1.1 (21), tvOS stores the original bytes and two checksummed
recovery records in one bounded local UserDefaults transaction (under 4 KiB),
because its Application Support directory is not writable. No cloud account is
required for this local save. Readable older TV files are validated and imported
without deleting or repairing their originals. Intake
tooling does not migrate or overwrite originals or existing saves.

Version 1.1 (10) adds optional Foundation key-value progress sync. It requires no
CloudKit database or schema deployment and introduces no application backend.
Apple's normal KVS entitlement/provisioning and account availability are still
required. Local saves operate independently; signed cross-device delivery has
not been verified. See [ModernHosts.md](ModernHosts.md) for the sync, lifecycle,
controls and compatibility contracts.

## Local state

| State | Storage | Behavior |
| --- | --- | --- |
| Original game progress | iOS/Mac/Watch: Application Support / host bundle identifier / `savedata.dat`; tvOS: `progress.tvOS.v1` UserDefaults data | Original 256-byte `PSH0` packing and validation execute in guest code; file replacement is atomic, while tvOS preferences durability is managed by the OS. |
| Sound choice | `NSUserDefaults`, `audio.soundEnabled` | Boolean, defaults to ON; the original Options ON/OFF controls persist changes immediately. |
| Silent-mode policy | `NSUserDefaults`, `audio.respectsSilentMode` | Boolean, defaults to ON; exposed inside the original Options screen on iOS/watchOS. |
| iPhone / Watch haptics | `NSUserDefaults`, `feedback.hapticsEnabled` | Boolean, defaults to ON when absent; explicit OFF is preserved. Original Options ON/OFF controls persist immediately, independently of sound. Each host bundle keeps its own choice. Hosts without haptics keep it disabled. |

Modern audio preferences are applied after loading the legacy save. A historical
save's sound byte therefore does not replace an explicit modern choice. Each host
bundle has separate preferences and local progress; validated progression may be
merged through the shared KVS identifier. No historical user save was supplied,
so migration from an original installation remains unverified.

The smoke test sets `SDB_SAVE_DIRECTORY` to its task-owned temporary directory.
UI tests pass unique `~/tmp/...` paths; the engine expands
the tilde inside the application sandbox, rather than using the test runner's
different home. An absent override retains the platform's production storage.
With this override, audio and haptics preferences use an atomic `audio-preferences.plist` beside the
test save and do not access standard user defaults. `SDB_MUTE_AUDIO` mutes only that
process while retaining the guest audio execution path. Neither override changes
system volume, Silent Mode, another app's preferences, or the production default.

Native and Simulator verification results, including audio-policy limits, are in
[Verification.md](Verification.md).

TV UI tests opt into that same preferences backend with a uniquely prefixed
`SDB_TV_SAVE_SUITE`, while their audio state and sync remain isolated by the
existing temporary-directory override. A final scoped cleanup launch removes
that suite; ordinary tests retain the filesystem backend.
