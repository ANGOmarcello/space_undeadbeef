# Verification record

The subsequent measured 60 Hz performance pass, audio mixer replacement and
its exact verification limits are recorded in [Performance.md](Performance.md).
The following optional iPhone feedback step is recorded in [Haptics.md](Haptics.md).

Recorded on **25 October 2026**, using Xcode 27.2. All four application targets
compiled successfully. Simulator builds and UI tests used ARM64; the native Mac
host ran on Apple silicon with macOS 27.0. These are local development checks.

## Native and Simulator interaction

| Host | Verified flow | Evidence |
| --- | --- | --- |
| iPhone 18 Pro, iOS 27.2 Simulator | Original title and Options; Sound ON; Respect Silent Mode OFF then ON; SAVE-EXIT; Game Start; targeting drag; Home and foreground resume. | `HostUITests.testOriginalGameInteraction`: 1 passed, 0 failed. Settled screenshots accompany the test. |
| Apple TV 4K, 3rd generation, tvOS 27.2 Simulator | Remote directional input and Select start the original game; Play/Pause holds a touch, a rightward sweep moves the pointer, and Play/Pause releases it. | `HostUITests.testOriginalGameInteraction`: 1 passed, 0 failed, with screenshots. |
| Apple Watch Series 12, 46 mm, watchOS 27.2 Simulator | Standalone install and launch; readable title and fitted Options; coordinate taps on the Simulator enter gameplay. A later frame shows stage 1-03 and score 15. | App screenshots and explicit-device tap logs. Digital Crown interaction was not exercised. |
| Physical Apple Watch Series 12, watchOS 27.0.1 | The user built and ran the app after completing Developer Mode and Mac pairing. Device Hub's live screen showed original gameplay at stage 1-11, score/high score 1,950, and zero deaths. | CoreDevice reported installed `dev.cammalleri.SpaceUndeadbeef.watch` version 1.0 (1), its running `SpaceUndeadbeef.app` process (PID 521), and a compatible physical Watch destination. No agent reinstall, restart, or game input was performed. |
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

Physical iPhone and Apple TV installation remain unverified. Hardware silent-mode
behavior, audible output, sustained performance, thermal behavior, and universal
instruction and graphics conformance were not established. The Watch Crown
remains untested by the agent.
Full game parity, every stage and boss, and original-device timing comparison
remain open. No App Store submission or public distribution was performed.

Earlier native Mac instances closed through normal AppKit termination, with no
game crash report found during the checks. The recorded evidence does not
establish the reason for those close/quit actions.

## App icons

The four targets now compile platform icon catalogs derived from the original
57×57 ship image. iOS and Watch use opaque 1024-pixel input; macOS includes the
standard raster sizes and an emitted `AppIcon.icns`; TV includes its layered icon
and wide Top Shelf assets. Pixel scaling preserves the original proportions and
extends background edges for TV rectangles. The TV foreground layer is empty so
the supplied flat artwork retains its appearance.

After installation, the ship icon was visually verified on iPhone Home, Watch's
circular app carousel, and the focused and unfocused TV launcher with Top Shelf.
AppKit's resolved Mac application icon also displayed the ship with the system
mask. All four icon builds passed. The final TV/iOS builds had no warnings; Mac
and Watch emitted the routine skipped-App-Intents metadata notice. No physical
device launcher icon was verified in these checks.

## Physical Watch build and run

Automatic signing is configured for Angelo Cammalleri's existing development
team. A Debug build for `generic/platform=watchOS` succeeded with both `arm64`
and `arm64_32` slices, a development provisioning profile, and a valid code
signature (`codesign --verify --strict`). The deployment minimum remains watchOS
11. This first check established a signed device build separately from installation.

During destination diagnosis, the iOS scheme listed physical iPhones, while both
this project's Watch scheme and CocaWatch listed no physical Watch. The user
enabled Developer Mode, completed its restart confirmation, and then paired the
Series 12 directly with this Mac through Device Hub. These were separate steps;
no Simulator-only project restriction was found. Xcode 27's network-pairing
workflow is documented in
[Apple's Device Hub guide](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub).

After pairing, CoreDevice identified the connected physical Series 12 (`Watch8,4`)
and Xcode listed it as a compatible `watchOS, arm64` destination. The user reported
that the game ran successfully. A read-only app query confirmed version 1.0 (1)
installed under the intended Watch bundle ID, and the process query confirmed the
game running. Device Hub's live mirror then visibly showed stage 1-11 and score
1,950. The agent did not replace the user's build or send gameplay input. The
temporary screen-sharing stream was stopped after verification; the game was left
running. This establishes physical installation and gameplay, while the hardware
audio, Crown, and sustained-performance limits above remain separate.


## Version 1.1 display modernization

The pre-modernization build above is preserved by
`baseline/original-aspect-v1` at `92c0cfc`. Version 1.1 uses the shared
`Config/App.xcconfig` for every platform and reads that bundle version for the
original menu's `Ver.1.1` label.

The adaptive display checks passed 252 CPU instruction checks, 4712 geometry and
inverse-mapping checks, 1559 guarded original-data patch checks, and 10472 bitmap
contour checks under sanitizers. The original Options/audio preference, save,
resume and Continue integration smoke passed with isolated test state.

`script/test_rendering.sh` passed on the actual Mac GPU. Software and Metal
outputs differ by at most one byte for straight edges, reverse winding, pure
shadow, original font_s and original GAMESTART foreground/shadow fixtures.
Six original baked labels split and recombine within 0.88 alpha byte and 0.47
premultiplied RGB byte before sharpening. This is controlled renderer proof;
it does not imply new detail in the original bitmap sprites.

Native-size viewport smoke checks passed at 2622×1206 (wide iPhone), 416×496
(Watch software path), and 2064×2752 (portrait iPad Metal). They verify actual
Game Start, opaque full frames, full scrolling backgrounds, live resize with the
same game object, Pause/Continue and an isolated 256-byte lifecycle save. Later
frames reached stage 1-03 with enemies using the expanded arena. Source sprite
proportions are retained. A repeating sky seam on tall viewports was replaced
with uniform background cover scaling before the original camera transform.

The iPhone 18 Pro UI test verifies the original Options, Start, targeting drag,
background/resume, native corner P-button position and the original Pause/Continue
menu round trip. The iPad 13-inch Pro ran the same flow successfully. One iPad
run spent five additional minutes inside XCTest's pending-crash-log wait after
all interactions; its Xcode log ultimately records one passed test and zero
failures. A second run with a two-minute execution allowance timed out in that
same XCTest crash-log wait after the interactions and cleanup; it is not counted
as another passing run. No application crash report was found for either run.
The development-signed Watch 1.1 build also succeeded for device architectures,
and `codesign --verify --strict` passed with normal Keychain trust access.

Visual review covers the latest iPhone Pro, portrait iPad, Watch Simulator and
native macOS. The title extension was simplified to the original muted peach sky
and one continuing cloud after user review. Original texture-border normalization
and padding extrusion remove the marked right-edge and bottom sampling lines.
The native Mac window was zoomed and restored while preserving a filled surface.
The physical Watch gameplay proof in the earlier section remains for version 1.0;
version 1.1's hardware performance and Crown interaction require a device run.


The final tvOS remote test also completed successfully: one passed test, zero
failures, with an observed original-menu transition into gameplay. XCTest again
waited five minutes for pending crash-log collection after all interactions.
The MCP call reached its 300-second timeout first; the final Xcode log independently
records `TEST EXECUTE SUCCEEDED`. This distinction is retained rather than treating
the connector timeout as an application-test failure.

Final display/source verification completed on 26 October 2026. Latest application
products and device dSYMs are retained in their standard DerivedData locations;
task-owned temporary captures, test results and compilation intermediates are
removed after recording these results.

## Original lettering correction — 26 October 2026

Direct source-asset inspection confirms the main-menu label shadows already
reach the PNG edge and are cropped there in the original. Dynamic Credits and
Options lettering has white atlas pixels and a single glyph draw, with no
separate black-shadow pass. The earlier whole-atlas distance-field treatment
distorted these tightly packed letters and exaggerated their uneven edges.

Dynamic lettering now keeps original alpha, uses the larger original font atlas
for the identical small-font grid, and clamps each glyph's sampling to its own
cell's texel centers. Glyph positions, UVs, dimensions and advances are retained.
This improves the supplied bitmap rendering without claiming vector-font detail.

`script/test_rendering.sh` passed all ten software/actual-Mac-GPU comparisons
within one byte. New coverage includes original small/large font alpha with the
same normalized glyph cell, fractional linear sampling, and a synthetic atlas
that visibly bleeds without isolation but has an exact background-colored
perimeter with isolation. The isolated GPU draw starts at vertex 7, verifying
triangle bounds relative to an arbitrary draw offset.

iOS, native macOS and Watch Simulator builds succeeded. Credits and Options were
visually reviewed in the iPhone 18 Pro Simulator and native Mac app, including
the large Mac view where neighboring-cell hairlines were visible before the fix.
The Watch result here is build proof; no new physical-device run is claimed.
