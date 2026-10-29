# Verification record

## Credits row alignment — 1.1 (16), 29 October 2026

At the user's request, the restoration notice is now one `Modernization:` row,
with the website right-aligned in the same 33-column grid and 24×12 font as the
creator credits. It occupies the original email row, with the original row
spacing, a warm-yellow underlined URL and a native link over that URL only.
All seven original creator/thanks rows and EXIT retain their positions.
The actual-engine menu suite passes **97** sanitizer-backed checks with captures;
the iPhone 18 Pro link UI test passes (1 pass, 0 failures), including Safari URL
handoff, return and original EXIT. iOS and Mac builds pass. See
[Credits.md](Credits.md) for wording history and the reported email bounce.

## iPhone delivery — 1.1 (15), 29 October 2026

At the user's request, the Retina-ship source was development-signed and installed
in place on the physical iPhone 14 Pro. Strict signature verification, exact
device provisioning membership, KVS entitlement authorization and packaged hashes
for all 25 full-density ship views pass. CoreDevice independently reports
**1.1 (15)** installed. Normal launch succeeded with no test environment, and a
separate process query confirmed the matching app executable at PID **25616**.
A passive 2556×1179 screenshot shows the live Credits screen and restoration
website credit. No gameplay inputs, uninstall, save reset or performance test
were sent; no Watch, iPad or Apple TV was targeted by this installation request.

## Original ship at Retina density — 1.1 (15), 29 October 2026

All 25 original player-ship views have conservative offline 4× renditions;
Watch loads the matching 2× set to limit decoded storage. Native pixel density
is independent from the unchanged original guest dimensions and UVs. The original
resources and executable remain byte-identical. See [RetinaShip.md](RetinaShip.md)
for the same-frame visual comparison, reproducible exports, provenance and memory
tradeoff.

**205** sanitizer-backed actual texture/guest-metric/coverage/fallback checks
pass. Across 50 silhouettes, maximum area change is 0.0857% and maximum centroid
drift is 0.0098 original pixels. A second export is byte-identical. Baseline and
current engines match every guest/register/draw/audio/save fingerprint over 600
identical fixed steps; image changes are intentional. CPU entrance captures and
all 25 views were inspected, together with Metal screenshots from the iPhone 18
Pro Simulator's passing original-game interaction test (1 pass, 0 failures).
Debug builds pass on all four platforms and report 1.1 (15).

The first baseline command under the restricted shell sandbox could not create
Apple's AVAudioSourceNode component and terminated during audio initialization.
The unchanged baseline and updated checks succeed with normal framework access,
muted audio and temporary saves. No application audio change was necessary.
There was no physical-device discovery, installation, launch or performance test
in this sprite pass. Existing unrelated Xcode project-format edits are preserved.

## Requested device rollout — 1.1 (14), 29 October 2026

The user requested installation on their iPhone, iPad, Series 4, Series 12 and
all Apple TVs. Generic development-signed iOS, watchOS and tvOS builds succeeded
in the existing standard DerivedData folders. Strict signatures, exact device
membership and the shared KVS entitlement authorization passed. The Watch build
contains `arm64` and `arm64_32`, with minimum watchOS 10.0.

| Physical device | Installation and verification |
| --- | --- |
| iPhone 14 Pro | In-place installation succeeded; independent app query reports 1.1 (14). Normal launch succeeded after unlocking, and the matching process was 25544. |
| iPad Air, fourth generation | In-place installation succeeded; independent app query reports 1.1 (14). Normal launch was refused because the iPad was locked. |
| Series 4, watchOS 10.6.2 | CoreDevice acknowledged installation of the signed 1.1 (14) payload. Subsequent version/icon queries failed while establishing the Bluetooth tunnel, including after the user woke the Watch. A separate installed-version readback and classic-icon display remain unverified. |
| Series 12 | Installation has not succeeded: the Watch rejects the Bluetooth developer connection with RemotePairing error 1035. The rejection repeated after the user unlocked the Watch/iPhone and after `manage pair` revalidated the stored developer pairing. The signed payload remains ready; the user was asked to connect the Watch directly to the Mac's Wi-Fi network. |
| Apple TV Office | In-place installation succeeded; independent app query reports 1.1 (14). |
| Apple TV Wintergarten | In-place installation succeeded; independent app query reports 1.1 (14). |
| Apple TV Wohnzimmer | In-place installation succeeded; independent app query reports 1.1 (14). |

The physical Office TV returned its installed icon with placeholders disabled.
Its 1280×768 image was visually checked and contains the new ship/sunset artwork.
The signed compiled catalogs include iOS/Watch precomposed icon images and TV
parallax/Top Shelf resources; see [AppIcon.md](AppIcon.md). No Apple TV app was
launched, no keep-awake assertion was acquired, and no gameplay/performance test,
uninstall, save reset or Watch/iPhone unpairing was performed. Pre-existing Xcode
project-format edits are excluded from this documentation update.

## Icon Composer and restoration credit — 1.1 (14), 29 October 2026

The editable native icon replaces the enlarged 57×57 artwork, with separate
ship/sky layers and light, dark, clear and tinted appearances. The Watch circle
and TV parallax exports retain the same composition. All four platform builds
pass; native full/small previews, generated iPhone/iPad icon dictionaries and
the iPhone 18 Pro Simulator Home Screen were checked. See [AppIcon.md](AppIcon.md)
for source provenance and packaging boundaries.

The obsolete visible email line is replaced by the approved restoration website
credit, preserving original creator rows, font rendering and EXIT. The reported
bounce and historical address are documented in [Credits.md](Credits.md).
That record contains **96** sanitizer-backed menu/layout/save checks, the passing
native-link Simulator UI test, cross-platform builds and the cached-shader
verification limitation. No physical device installation or testing was done.

## Crown input correction — 1.1 (13), 27 October 2026

The Watch host now handles each native scaled Crown binding write directly,
retains an accepted spring destination after idle, and reanchors reversal to
the live ship when it opposes outstanding travel. Focus follows the actual
playable ship state, including after entrance/respawn. Original game code,
spring physics, sensitivity, input range, artwork and layout remain unchanged.
See [WatchControls.md](WatchControls.md) for the input contract.

The focused checks pass: **103** Crown model and actual Session/engine checks,
and **2,549** actual Session lifecycle, input, original-menu and checkpoint
checks. Crown cases cover idle before the first fixed step, successive wrapped
binding values, hard cancellation, ignored samples during touch ownership,
viewport changes, the original Pause/Continue flow, and background/resume.
Each scenario uses normal original Game Start and an empty temporary save;
no health, enemy, position or instruction state is patched. No physical gameplay
inputs or performance workload were sent.

The development-signed generic Watch build succeeds for `arm64` and `arm64_32`,
reports **1.1 (13)** and minimum watchOS 10.0, and passes strict signature,
exact Series 4 profile membership and shared KVS entitlement authorization.
CoreDevice installed build **13** in place on the exact Series 4 and
independently read back **1.1 (13)**. Normal launch, with no test environment or
uninstall/data reset, succeeded; the matching process was **436**. Two passive
368×448 screenshots were black. The user subsequently confirmed that the normal
menu is visible after waking the Series 4. Physical Crown feel during a round
remains unconfirmed. The Series 12 session and Apple TVs were left alone.
Pre-existing Xcode project-format edits are excluded from this correction.

## Series 4 delivery — 1.1 (12), 27 October 2026

The connected Series 4 (`Watch4,2`) reports watchOS 10.6.2 and Developer Mode
enabled. A generic physical-Watch Debug build succeeds with watchOS 10.0 as the
explicit target/generator minimum and the compatible navigation-background API.
Both `arm64` and `arm64_32` slices are present; the latter's Mach-O minimum is
10.0. The development signature, exact Series 4 profile membership and shared
KVS authorization pass. Bundle readback is **1.1 (12)**, minimum OS 10.0.

The exact-device Xcode build initially timed out during destination preparation.
CoreDevice installation then failed before transfer with RSD allocation error
`0xE8000003`; the installed legacy MobileDevice tool could not connect either.
Xcode subsequently showed **Copying OS library symbols from Angelo Series 4**,
also reported by the user. That copy and the following extraction were allowed
to finish without intervention. Xcode then reported the user's existing run
successfully running SpaceUndeadbeef on Angelo Series 4.

Read-only CoreDevice checks independently confirm the installed **1.1 (12)** and
running process **422**. A passive **368×448** screenshot was visually reviewed:
the filled title, original menu, `Ver.1.1` and **Continue 2-04** are visible. No
post-preparation reinstall, relaunch, gameplay input or performance test was
performed. Crown/haptic feel, sustained FPS and the provenance of that checkpoint
remain separate questions; the image does not establish cross-device sync.
No Apple TV was targeted, and the existing Series 12 session was not changed.
Pre-existing Xcode project-format edits are retained separately from the explicit
deployment-minimum change.

Task-owned intermediate caches, failed results, logs and the temporary screenshot
were removed afterward. The signed Watch products remain in standard DerivedData
for matching inspection/debugging. Xcode's newly required Series 4 system-symbol
cache (about 2.1 GiB) remains in its standard `watchOS DeviceSupport` location;
it is needed for future development on this OS and was not treated as disposable.

## Notification recovery and iPhone feedback — 1.1 (11), 27 October 2026

Transient inactive iOS scenes retain ordinary 60 Hz scheduling without entering
Pause; input and feedback wait until active. Backgrounding and real audio
interruptions still enter the original Pause menu. An independent native audio
gate lets that menu finish animating, and its ordinary Resume action can retry
OS activation after a missing interruption-ended notification or a no-resume
recommendation. Audio failure remains nonfatal and does not cause frame-loop
activation retries. See [ModernHosts.md](ModernHosts.md) for the contracts.

iPhone feedback now attaches to the actual window independently of the rendering
surface. Invalidated interactions rebuild on the next eligible update, with
ownership checks for replacement views. No event timing, original artwork,
game instructions or sound/haptic preference defaults changed.

The focused isolated checks pass: **2,549** actual Session/engine lifecycle,
input, original-menu and persistence checks; **55** lifecycle-policy checks;
**33** sanitizer native-audio gate checks; **20** attachment ownership/recovery
checks; **147** unchanged shared haptic cadence checks; **287** sanitizer original
haptic-event checks; **53** Crown/Session checks; and **38** native-input checks.
Session fixtures use normal guest menu animation and injected native audio
availability. They cover noninterruptive inactive time, busy activation, missing
end events, media reset, modal storage failures and held-input cancellation.
No system interruption or real user save is manufactured by these tests.

Both `testHapticHostWithMetal` and `testHapticHostWithSoftware` pass on the
**iPhone 18 Pro, iOS 27.2 Simulator**. They verify real UIKit window attachment,
OFF/ON readiness, Home/foreground recovery and original Start/Pause/Resume.
Exported Options screenshots were visually reviewed in both paths. The result
identifier is `iphone-haptics-verified.xcresult`; temporary results are removed
after recording. Exported app logs contain seven native `selectionChanged`
requests per renderer's isolated process, including the ON preview and menus.
Simulator readiness/API requests do not establish a felt pulse.

The canonical Watch workload retains all 600 software images, guest-state
checkpoints and original 256-byte save exactly. The 300-step Metal workload
retains canonical guest state/save; its existing golden check deliberately
excludes GPU pixel hashes. The original executable and all 96 prepared asset
hashes pass. Canonical expectations were not regenerated.

Unsigned Debug builds pass for iOS, macOS, tvOS and watchOS, with bundle version
**1.1 (11)**. The Mac build reports the existing multiple-destination warning;
TV/Watch compile without warnings. No physical Watch or Apple TV was queried,
launched or tested in this correction. No system or other-app settings changed.

The development-signed iPhone build passes strict signature validation, exact
iPhone provisioning membership and shared KVS entitlement authorization through
the profile's permitted team wildcard. CoreDevice installed it in place on the
iPhone 14 Pro, independently read back **1.1 (11)**, and opened it normally without
test environment, gameplay automation, data reset or preference overrides.
The user subsequently confirmed feeling the Options Haptics OFF→ON tick on this
updated iPhone build. That establishes restored physical feedback for the preview;
gameplay effects and an actual incoming banner remain user verification. The
lifecycle fixture injects the corresponding host events rather than sending a
real notification. No physical performance test was run.

Task-owned intermediate caches, UI test packages/logs, temporary results,
captures and isolated Simulator saves were removed after recording the checks.
The cleanup measured about 191 MiB of additional free space. Latest app products
and matching symbols remain in the standard project DerivedData directories for
local inspection; the installed phone uses its own device-side copy.

## Device installation — 1.1 (10), 27 October 2026

After the foundation verification below, the user explicitly requested installation
on their iPhone and Watch. Xcode's ordinary automatic development provisioning
produced signed device builds for both targets. Strict signatures, exact target
device membership and the shared KVS entitlement/profile match pass for both.
This involved no CloudKit database, container or schema deployment.

The iPhone 14 Pro was updated in place from 1.1 (3) to **1.1 (10)**. CoreDevice
independently read back the installed version and normally launched the updated
bundle. No uninstall, app-data reset, test environment or gameplay input was used.

The Series 12 build is **1.1 (10)**, with `arm64` and `arm64_32` slices. Installation
has not completed: its known connection reports unavailable and CoreDevice
returns usage-assertion error 4016. The user was asked to unlock it and keep it
near the paired iPhone on Wi-Fi. No successful Watch update or cross-device
progress-sync delivery is claimed. No Apple TV was targeted for device operations.

## Modern host foundation — 1.1 (10), 27 October 2026

The controls, interruption handling, recovery saves, optional key-value progress
sync, memory/cache changes and semantic original menus are described in
[ModernHosts.md](ModernHosts.md). The supplied executable and all 96 prepared
original assets retain their recorded hashes. The original menus and fixed
60 Hz gameplay remain authoritative.

`script/verify_compatibility.sh --tests-only --require-gpu` completed with
**21 PASS, 0 FAIL, 1 SKIP**: original-resource verification and all 20 isolated
correctness suites passed. The sole skip was the separately opted-in Simulator
UI path; actual GPU checks ran. Final lifecycle-memory-pressure and modal-input
guards were subsequently checked with 17 lifecycle-policy and 1,886 actual
Session checks, plus 38 native-control checks. These include held controller
input across alert acknowledgement and media-reset recovery without a timer.
The suites include 149 offline audio checks, 41 save-store checks, 28 sanitizer
save-coordinator checks, 76 sanitizer original-menu checks, 46 strict Swift 6
progress-sync checks, 106 sanitizer draw checks, 21,258 paired cache/soak checks
and 189 sanitizer checkpoint-entry checks. Save and sync checks use isolated
state and injected transports; they never access the user's real save or account.
Final GPU reruns passed all eleven parity fixtures, four batching comparisons,
queued-frame/cache-trim checks and the 300-frame canonical Metal workload.
Deliberately missing-library probes failed both GPU fixtures with exit 1 rather
than being classified as an unavailable-device skip.

Canonical baseline/current comparisons retain all 600 software images, original
guest state and final save bytes. GPU fixtures use their documented one-byte
tolerance across drivers. The 17 checkpoint-entry smoke fixtures enter the
original Continue path and run 240 ordinary updates each; these checks do not
establish full-stage or every-boss completion.

### Native and Simulator interaction

- **iPhone 18 Pro, iOS 27.2:** original touch interaction, semantic title/Options,
  Sound OFF/ON, SAVE-EXIT, Credits/Back, Start, Pause/Resume and foreground pause
  passed. The Credits Back semantic frame was checked against its original row.
  A separate real save-I/O failure through the process-only `/dev/null` override
  displayed a dismissible native alert and left the game playable. Original
  title, Credits, pause and the error alert were visually reviewed.
- **13-inch iPad Pro M5 Simulator:** the semantic original-menu interaction test
  passed, including Credits/Back and Pause/Resume. Title and gameplay/pause
  layouts were visually reviewed in portrait.
- **Native Mac on Apple silicon:** semantic Options selection, SAVE-EXIT, Start,
  keyboard movement/charging and P-to-pause worked with isolated state. The
  original Options and Pause screens were visually reviewed. The task's app
  instance quit normally afterward.
- **Watch Series 12, 46 mm Simulator:** title and Options expose the expected
  semantic actions. Original Options, SAVE-EXIT, Start, death Continue and the
  compact corner pause control were exercised. Original Pause/Resume/Quit and
  the bottom HUD were visually reviewed. Crown feel and haptic output were not
  measured in this pass.
- **Apple TV 4K, 3rd generation Simulator:** the functional remote test passed
  with one stable canvas identifier, title Back/Menu exit, foreground reactivation,
  directional Start, gameplay Back-to-pause, original Resume and Play/Pause
  targeting/release. Native accessibility wrappers do not reliably expose the
  focused element through XCTest's `hasFocus`; actual remote interactions are
  the functional assertions. Exported title, gameplay and original Pause
  screenshots were visually reviewed at 3840×2160.

Passing result identifiers include `iphone-semantic-final.xcresult`,
`iphone-save-error.xcresult` and `ipad-final.xcresult`, produced under a task-owned
temporary directory. These names identify inspected results; temporary bundles
and captures are removed after recording the findings.
The passing TV result is `tvos-functional-focus.xcresult`, recorded by
`test_sim_2026-10-27T01-34-29-941Z_pid17188_f762d756.log` (1 test, 0 failures).

All four unsigned application targets pass both Debug and Release builds with
Xcode 27.2, and all bundles read back as **1.1 (10)**. The three Metal bundles
contain their compiled `default.metallib`; Watch builds the software path.
The Mac Release binary contains both `x86_64` and `arm64` slices; native
interaction was exercised on Apple silicon only. These are build checks, not
signed-device installation or distribution checks.

### Verification boundaries

The current physical Watch session was kept. No physical Watch, iPhone or Apple
TV was queried, installed, restarted or used for a performance test in this
pass. Controller policy checks do not establish physical controller feel, and
Mac cache measurements do not establish Watch battery life or sustained hardware
FPS. No system accessibility setting, Coca or Eidetic setting was changed.

Progress sync uses Foundation key-value storage with no CloudKit database,
container, schema or backend deployment. No developer-portal mutation, signed
cross-device sync or live account delivery was performed. Normal Apple KVS
capability provisioning and account availability are still required. The
checked-in compatibility workflow has not been run remotely; no release or
public distribution was performed.

Task-owned caches, intermediate objects, results, logs, captures and isolated
Simulator test saves were removed after verification, reclaiming 1.80 GiB of
actual free space in the final cleanup. The latest unsigned app products and
dSYMs (about 190 MiB total) remain in the standard DerivedData directories
`SpaceUndeadbeef-Compatibility-{iOS,macOS,tvOS,watchOS}/Build/Products` for local
inspection and matching symbols. No disposable output is stored in the repository.

## Second performance pass — 1.1 (9), 26 October 2026

The shared renderer/runtime improvements and software-timer phase correction
are measured in [Performance.md](Performance.md#second-pass--version-11-9).
No artwork, game instructions, physics rate or haptic cadence was changed.
The Watch Simulator now publishes 59–60 images/s in measured gameplay windows,
compared with 40–46 before correcting its epoch. This is Simulator evidence.

The iPhone 18 Pro, 13-inch iPad Pro M5 and Apple TV 4K Simulator each pass
`HostUITests.testPerformanceGameplay`. Native Mac and Watch Simulator gameplay
were visually reviewed with isolated test state. Latest source builds for all
four platform targets. The passing result identifiers are:

- iPhone: `test_sim_2026-10-26T21-34-27-955Z_pid29351_b2342a8e.xcresult`
- iPad: `test_sim_2026-10-26T21-42-22-156Z_pid29351_d7e30209.xcresult`
- TV: `test_sim_2026-10-26T21-49-34-286Z_pid29351_c9456771.xcresult`

99 draw-assembly sanitizer checks, eleven CPU/GPU pixel fixtures, batching and
malformed-input checks, fixed-clock tests, 53 Session/Crown integration checks
and 147 haptic policy checks pass. Baseline/current guest state, all 600 software
images, ten Metal samples across 300 frames, and final saves match exactly.
Details and the CPU comparison table are in the performance record.

The user requested no real-device testing for this pass. Physical attempts were
stopped: iPhone automation timed out at the test-runner stage, and the Watch
installation could not reconnect. No physical performance claim or successful
Watch build-9 delivery is made. Apple TV hardware was not queried or woken.
The final checks use native Mac and Simulators only; original game progress and
preferences are separate from their temporary state. Task-owned test artifacts
are removed after verification, with measurements retained in the documentation.

The subsequent measured 60 Hz performance pass, audio mixer replacement and
its exact verification limits are recorded in [Performance.md](Performance.md).
Optional iPhone and Watch feedback is recorded in [Haptics.md](Haptics.md).

The **1.1 (3)** Watch Crown fixes and **1.1 (4)** pause/HUD layout correction are documented in
[WatchControls.md](WatchControls.md), with separate engine, session, Simulator,
signing and physical-device verification boundaries.
Build **1.1 (4)** was installed in place and launched on the physical Series 12
on 26 October 2026 (PID 958). Its compact corner artwork, original Pause/Continue
flow and centered bottom HUD were visually verified in the Watch Simulator;
hardware Crown feel and the native toolbar's larger invisible hit region remain
separate considerations documented there.

The subsequent **1.1 (5)** update was installed and launched on that Series 12
over Wi-Fi (PID 1023). CoreDevice confirmed the installed build, and a direct
Watch screenshot showed the updated menu with **Continue 1-16** preserved.
See the physical-update section in [WatchControls.md](WatchControls.md).

Build **1.1 (8)** replaces the sparse Watch policy with iPhone's event cadence,
including 250 ms explosion feedback and short Watch clicks for frequent effects.
All 147 shared/Watch policy checks and Watch/iPhone Simulator builds pass. The
signed Watch build passed signature/provisioning checks, was installed in place,
read back as 1.1 (8), and normally launched on Series 12 (PID 1055). The user then
confirmed that smaller explosions and weapon effects feel **much closer** to
iPhone in physical Watch gameplay. Exact strength/pattern parity and a separate
pulse for every effect remain unproven. Details are in [Haptics.md](Haptics.md).

Build **1.1 (6)** enabled the original Watch Haptics Options controls. Its
Simulator UI showed default ON, preserved OFF through SAVE-EXIT/reopening, native
ON-preview requests, and inactive suppression. After the signed update was
installed and normally launched on Series 12 (PID 1050), the user confirmed the
OFF→ON click but reported uniform short pulses. Build 7 differentiates volley
feedback. Its 683 policy checks and Watch/iPhone Simulator builds pass; the signed
Watch build was installed, independently read back as 1.1 (7), and launched normally
(PID 1052). Revised gameplay-pattern feel remains unconfirmed. See
[Haptics.md](Haptics.md) for the final policy and delivery record.

Build **1.1 (2)** corrects menu/weapon/explosion event coverage and native haptics
view association after the user reported no felt feedback. It passed 287 engine
sanitizer checks and 117 policy checks, then was development-signed, installed
and launched on the physical iPhone 14 Pro. Simulator logs verify native menu
feedback requests on the visible game view. The user then confirmed feeling the
Haptics OFF→ON confirmation tick on that phone. Weapon, target, damage, explosion
and other menu feedback remain unconfirmed by feel; see the haptics record for details.

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

At this earlier check, physical iPhone and Apple TV installation remained unverified. Hardware silent-mode
behavior, audible output, sustained performance, thermal behavior, and universal
instruction and graphics conformance were not established. The Watch Crown
remains untested by the agent.

On 26 October 2026 the updated development-signed iOS 1.1 (1) build was installed
and launched on the physical iPhone 14 Pro, iOS 27.0.1. Code-signature validation
and profile membership passed. CoreDevice confirmed the exact installed bundle
and version, and successful process launch without test overrides. The new
haptics default ON was visually verified with fresh isolated preferences in the
iPhone 18 Pro Simulator. Hardware gameplay, tactile quality and sustained
physical-device performance remain separate checks. No Apple TV was queried.
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

On **26 October 2026**, the latest source was built and development-signed as
Watch version **1.1 (2)** and installed in place on the same physical Series 12,
watchOS 27.0.1. The standalone bundle remained
`dev.cammalleri.SpaceUndeadbeef.watch`. Signature validation and provisioning
membership passed. CoreDevice confirmed the installed version/build and
successful foreground launch (PID 895) without test environment overrides.
This establishes the updated physical installation and launch; the earlier
gameplay capture remains version 1.0, and updated hardware performance, audio
and Crown behavior still require a gameplay check. Only the known Watch was
targeted; no Apple TV discovery or testing was performed.


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
The physical Watch gameplay capture in the earlier section remains for version
1.0; the subsequent 1.1 (2) physical installation/launch is recorded above.
Version 1.1's hardware performance and Crown interaction require a gameplay run.


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

## iPhone Duo and iPad adaptation — 26 October 2026

Audited against Apple's Xcode 27.2 app-resizability and SwiftUI guidance,
including current-view geometry, safe areas, orientation, scene lifecycle and
idiom use. The iOS target declares a launch screen, all four iPad orientations
and no full-screen resizing opt-out. The full-bleed GeometryReader bridge
intentionally restores the drawable surface while passing a separate safe UI
rectangle to the original engine. Phone-only haptics is a capability policy,
not a layout decision.

The actual iPhone Duo Simulator preserved the same engine and stage through
folding, unfolding and rotation. The arena filled both displays and actual
corner P taps opened Pause. A persistent side bar exposed overlapping high-score
digits and charge cells. The fix contracts original blank HUD gaps and, below
432 logical safe units, the outer blank margins; original glyphs, sixteen charge
cells and the complete slanted boss gauge keep their sizes. Tested HUD ink fits
down to 349.67 logical safe units; narrower regions are not a layout guarantee.

The separate version label now retains both original coordinates relative to
the unchanged, centered title artwork. This corrects side-bar overlap with the
logo and vertical overlap with its underline on taller viewports.

On the 13-inch iPad Pro M5 Simulator, portrait and landscape gameplay worked.
System status content initially covered the corner P. The iOS host now requests
a hidden status bar through the current SwiftUI API, with an availability-guarded
fallback. Actual P taps reached the original pause menu in both orientations;
rotation retained the game. Final title rendering was reviewed on iPad landscape
and the latest regular iPhone 18 Pro. No artwork or font replacement was needed.

The final iOS Simulator build succeeded. Strict-warning builds with ASan and
UBSan passed 7,423 original-data display checks and 4,712 geometry checks.
Coverage includes asymmetric bars, Duo outer/inner sizes, iPad portrait/landscape
and window dimensions, original glyph/gauge bounds, artwork-relative version
placement, and exact Watch/Duo/original layout restoration.

The existing headless `ViewportSmoke.mm` also passed all seven cases on the Mac
Metal renderer: wide iPhone, Watch-sized surface, portrait iPad, Duo outer/inner,
a 375×700-point iPad window and landscape iPad. Each checks native raster size,
opaque filled gameplay, actual Start, the same live engine across resize and
restoration, Pause/Continue and an isolated 256-byte save. The Watch-sized Metal
fixture is not a watchOS renderer or Crown test. These integration cases do not
depend on Device Hub focus or change real application preferences.

The final visual checks used the game's own Device Hub window after coordinating
with the concurrent Coca chat. The iPad game also rendered correctly in a floating
Stage Manager window (480×395 logical viewport), with working Start and native
Pause, readable HUD and a filled surface. The Simulator's original Windowed Apps
setting was restored and visually confirmed. Continuous dragging through every
possible window size is not established by this check; the narrower window case
above is engine integration proof.

The final Duo build was then checked interactively with the status bar hidden:
title and HUD spacing were clear, the literal corner P opened Pause, and folding,
unfolding and rotation kept stage 1-03, score 15 and one death in the same paused
game. Initial headless captures had returned black on both Duo displays; the
active Device Hub window supplied the final visual proof. Physical Duo/iPad
installation and sustained hardware performance were not tested.
