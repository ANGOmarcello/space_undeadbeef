# Verification record

Recorded on **25 October 2026**, using Xcode 27.2. All four application targets
compiled successfully. Simulator builds and UI tests used ARM64; the native Mac
host ran on Apple silicon with macOS 27.0. These are local development checks.

## Native and Simulator interaction

| Host | Verified flow | Evidence |
| --- | --- | --- |
| iPhone 18 Pro, iOS 27.2 Simulator | Original title and Options; Sound ON; Respect Silent Mode OFF then ON; SAVE-EXIT; Game Start; targeting drag; Home and foreground resume. | `HostUITests.testOriginalGameInteraction`: 1 passed, 0 failed. Settled screenshots accompany the test. |
| Apple TV 4K, 3rd generation, tvOS 27.2 Simulator | Remote directional input and Select start the original game; Play/Pause holds a touch, a rightward sweep moves the pointer, and Play/Pause releases it. | `HostUITests.testOriginalGameInteraction`: 1 passed, 0 failed, with screenshots. |
| Apple Watch Series 12, 46 mm, watchOS 27.2 Simulator | Standalone install and launch; readable title and fitted Options; coordinate taps on the Simulator enter gameplay. A later frame shows stage 1-03 and score 15. | App screenshots and explicit-device tap logs. Digital Crown interaction was not exercised. |
| Native macOS | Original title, Options with Sound ON, SAVE-EXIT, mouse Game Start, Right Arrow and Space, and visible pointer response. Gameplay advanced from stage 1-00 to stage 1-03 with score 15. Window resize from 960×640 to 1000×800 preserved the playfield with black letterboxing; restored to 960×640. | Captures were restricted to the verified application window. No desktop or other-app screenshot was used. |

The Watch originally failed installation with contradictory watch-only and
independent-companion metadata. The final standalone configuration retained
`WKWatchOnly` and installed successfully after removing the contradictory key.

## Audio policy

The original Options screen owns the audio controls. Sound and Respect Silent
Mode default to ON; explicit choices persist in the host's own `NSUserDefaults`.
The headless preference/relaunch and sanitizer checks are detailed in
[Restoration.md](Restoration.md#headless-integration-verification).

On Watch Simulator, runtime diagnostics confirmed the actual audio session changed
from `AVAudioSessionCategoryAmbient` to `AVAudioSessionCategoryPlayback` when
Respect Silent Mode was turned OFF, and back to Ambient when turned ON. The
diagnostics reported no audio-session error. SAVE-EXIT returned to the title and
Game Start entered gameplay after these changes. Playback was muted for that test.

The ordinary Mac test process had no `SDB_MUTE_AUDIO` override. The original Sound
ON selection was visible, the system output was unmuted, the default device was
MacBook Pro Speakers, and CoreAudio playback queues were observed for that exact
process. This establishes configuration and playback-path activity; physical
audibility and listening quality were not verified. No system sound or
accessibility settings were changed.

The passing iOS/tvOS test results retain runtime warnings about synchronous audio
session operations on the main thread. iOS also warns about changing session
configuration while active. The exercised tests passed; they do not establish
that these calls are free from responsiveness risk.

## Evidence identifiers

The inspected final Xcode result bundles were:

- iOS: `test_sim_2026-10-25T19-27-30-047Z_pid29351_9cb19f48.xcresult`
- tvOS: `test_sim_2026-10-25T19-24-25-177Z_pid29351_40685fc8.xcresult`

Watch records were `verification.json` and `audio-verification.json`; Mac records
were `mac-verification.json`, `mac-options.png`, `mac-normal-keyboard.png`,
`mac-normal-resized.png`, and `mac-final-title.png`. These local test artifacts
are outside the source repository. Names identify the inspected evidence rather
than a promise that temporary output will remain available indefinitely.

## Limits

No physical iPhone, Apple TV, or Watch installation, hardware silent-mode switch,
audible output, sustained performance, thermal behavior, or universal instruction
and graphics conformance was established. The Watch Crown remains untested.
Full game parity, every stage and boss, and original-device timing comparison
remain open. No App Store submission or public distribution was performed.

Earlier native Mac instances closed through normal AppKit termination, with no
game crash report found during the checks. The recorded evidence does not
establish the reason for those close/quit actions.
