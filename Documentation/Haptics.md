# Optional iPhone and Watch haptics — 26 October 2026

Haptics default to ON when no preference exists. The original Options ON/OFF
controls persist `feedback.hapticsEnabled` immediately, independently of sound
and Respect Silent Mode. An explicit OFF remains OFF. Tests use isolated
`SDB_SAVE_DIRECTORY` preferences and never real user settings. iPhone and Watch
hosts offer native feedback through the same original Options controls. Each
host bundle stores its own choice; the iPhone implementation is unchanged.
Current Watch build **1.1 (8)** shares the iPhone event policy; the earlier
Watch-specific quiet windows described under builds 6–7 are historical.

## Feedback delivery correction, build 1.1 (2)

The user reported no felt feedback in the first installed build. Source review
confirmed menu feedback was filtered out, ordinary Bluster shots and explosions
were unobserved, and a shared cooldown could suppress a weapon event after a
lock tick. The original soft impacts also used very low intensities.

The native host now retains selection, light-impact and medium-impact generators
associated with its visible Metal game view. It attaches them once per view,
removes their interactions on teardown and suppresses offscreen/inactive feedback.
This follows [Apple's view-association guidance](https://developer.apple.com/documentation/applepencil/playing-haptic-feedback-in-your-app)
and [the UIKit view initializer](https://developer.apple.com/documentation/uikit/uiimpactfeedbackgenerator/init(style:view:)).
The API correction does not alone prove why the earlier build felt silent.
Audio-session settings and input hit testing are unchanged.

Accepted menu selections now produce a selection tick, including native Pause
and an immediate Haptics ON preview. OFF clears pending feedback immediately.
Weapon, target, damage and explosion events use stronger light/medium impacts.
The host coalesces each frame's events and discards throttled events without a
backlog. Separate bounded cooldowns prevent weaker events from starving weapons:

| Event | Native feedback | Cooldown |
| --- | --- | --- |
| Accepted menu action / ON preview | Selection tick | 120 ms |
| Targeted volley | Medium impact, intensity 0.85 | 250 ms; can preempt a recent ordinary shot |
| Primary Bluster/Bullet shot | Light impact, intensity 0.70 | 500 ms after any weapon |
| Player damage | Medium impact, intensity 1.0 | 350 ms; preempts weaker feedback |
| Explosion | Medium impact, intensity 0.65 | 250 ms and a quiet gameplay interval |
| New target | Light impact, intensity 0.35 | 1 second and a quiet gameplay interval |

Original instructions and gameplay remain unchanged. SoundEffect entry `0xe994`
is observed before its sound-enabled guard: entry 0 means an accepted executable
menu action, 2 a targeted volley, 3 a target acquisition, 4 an actual Bluster
construction and 5 an actual Explosion construction. Guarded `Player::update`
boundaries observe decreased player health (`0x2796`) and a successful Bullet
append (`0x286e`). The original pause callback at `0x9b0e` covers the native P
button. Dormant Bullet code is guarded but not claimed as exercised; the ordinary
weapon test uses the game's actual Bluster path. Empty-space taps emit no menu
event. Gameplay events are filtered in menus while accepted selections survive
menu transitions.

## Verification

- `script/test_haptics_policy.sh`: 117 pure checks pass, including separate
  budgets, priority preemption, exact boundaries, OFF, no queued replay and
  sustained 60 Hz bursts.
- `script/test_haptics.sh`: 287 address/undefined-sanitizer checks pass. With
  Sound OFF, 3,000 ordinary updates yield 12 targeted volleys, 19 Bluster shots,
  264 target acquisitions and 108 explosions before host throttling, with zero
  audio requests. A passive run observes actual damage and ordinary Game Over.
  Accepted title/Options/ON-preview/SAVE-EXIT/Start/Pause/Continue selections work;
  empty-space taps and OFF suppress events. Preference/recreation checks pass.
- iPhone 18 Pro Simulator shows the existing Options with default ON. Opt-in
  `SDB_HAPTICS_LOG=1` confirms `enabled=1 attached=1 inWindow=1`, native
  `selectionChanged` calls for menu actions/ON preview, and disabled state after
  OFF. Simulator hardware capability is correctly reported as false; these logs
  establish API requests, not a physical pulse.
- Final signed-device and Simulator builds pass. iOS/watchOS Swift 6 host
  typechecks pass. The signed profile includes the target iPhone and its code
  signature validates. Build 1.1 (2) was installed and launched on the physical
  iPhone 14 Pro, iOS 27.0.1, without test preference/audio overrides. CoreDevice
  confirms the installed version/build. The user then confirmed feeling the
  Haptics OFF→ON confirmation tick in the original Options screen. This establishes
  physical feedback for that interaction only. Weapon, target, damage, explosion
  and other menu feedback remain unconfirmed by feel; the earlier report of no
  felt feedback is retained above.

No system haptic, audio, accessibility or other-app settings were changed.
No Apple TV device discovery or testing was performed for this correction.

## Watch adaptation, builds 1.1 (6–7)

WatchKit plays preset patterns while the app is active. The Watch now offers the
existing Haptics ON/OFF section, defaults ON when absent, preserves an explicit
OFF, and previews ON with a click. OFF immediately clears pending events. The
host coalesces each frame and discards throttled events without a replay queue.

| Event | Watch pattern | Per-kind interval |
| --- | --- | --- |
| Accepted menu action / ON preview | Click | 250 ms after any feedback |
| Targeted rocket/laser volley | Start | 750 ms |
| Ordinary Bluster/Bullet shot | Click | 1 second |
| Player damage | Direction down | 750 ms |
| Explosion | Click | 1.5 seconds |
| New target | Click | 2 seconds |

Gameplay events also wait at least 500 ms after any feedback. Volleys and damage
reserve 750 ms before **any** subsequent pattern, including menu ticks. These are
conservative app limits, not documented pattern durations or a guarantee about
when the hardware finishes. Cooldown timestamps survive OFF, pause and inactive
transitions. Crown rotation keeps its existing disabled system ticks.

The distinct Start pattern marks the weapon action beginning; Direction down
marks health decreasing. WatchKit has no per-call intensity/duration control, so
this does not reproduce iPhone's variable-strength impacts. Apple's
[play guidance](https://developer.apple.com/documentation/watchkit/wkinterfacedevice/play(_:))
warns that rapid requests interrupt the current pattern. No repeated-pulse
sequence or delayed playback was added.

Watch patterns can include an audible system tone. The game Sound option controls
original game audio; watchOS Silent Mode and system haptics settings govern these
native patterns. WatchKit exposes no per-call mute option. See Apple's
[haptics guidance](https://developer.apple.com/design/human-interface-guidelines/playing-haptics).
No system audio or haptic settings are changed.

### Watch verification

- The Series 12 46 mm Simulator visibly showed the original Options layout and
  default Haptics ON. OFF survived SAVE-EXIT and reopening Options. Native request
  logs stopped while OFF; switching ON immediately requested `play.click` with
  `enabled=1 active=1`. Returning Home produced `state=inactive`, with no further
  feedback requests. All Simulator preferences were isolated from real app data.
- `script/test_haptics.sh` again passed 287 ASan/UBSan checks of original event
  observation, Sound OFF, persistence, default ON, explicit OFF and no queued
  replay. No physical haptic was invoked by those tests.
- Build 1.1 (6) passed Watch Simulator and signed-device builds, strict signature
  verification and Series 12 provisioning membership. CoreDevice installed it in
  place, read back 1.1 (6), and launched normally (PID 1050) with no test save or
  audio overrides. The user confirmed feeling the Watch OFF→ON click, but reported
  that feedback felt uniformly like one short pulse. Build 7 consequently gives
  targeted volleys their own Start pattern and a protected quiet interval.

- Final build 1.1 (7) passed 683 Swift 6 warnings-as-errors policy checks: the
  original 117 iPhone checks plus 566 Watch checks, including the protected
  volley interval, exact boundaries and sustained mixed 60 Hz event bursts.
  Watch Simulator, physical-device and iPhone 18 Pro Simulator regression builds
  passed. The iPhone check was compile-only; its feedback implementation is unchanged.
- Strict signature verification and exact Series 12 provisioning membership
  passed for build 7. CoreDevice installed it in place, independently read back
  version 1.1 (7), and launched normally (PID 1052), preserving existing app data.
  Physical menu feedback was confirmed on build 6; build 7's distinct volley and
  other gameplay-pattern feel have not yet been confirmed by the user.

No Apple TV was queried or activated for this Watch adaptation. The task's
Simulator game process was stopped after verification; other apps, system
settings and pre-existing Simulator boot state were left alone.

## Watch cadence parity, build 1.1 (8)

The user reported sparse Watch feedback compared with iPhone, especially for
small impacts and explosions. Builds 6–7 deliberately imposed a 500 ms shared
quiet window, 750 ms protection after volleys/damage, and a 1.5 second explosion
interval. These app-imposed restrictions caused additional Watch-only dropouts;
they were not watchOS rate limits.

Watch now aliases the existing `GameHapticPolicy`, using exactly the iPhone's
event selection, priorities, cooldowns and no-replay behavior. Explosions can
return after 250 ms and the same gameplay quiet interval as iPhone, volleys use
250 ms, primary fire 500 ms, damage 350 ms, targets 1 second and menu actions
120 ms. The table in the iPhone section above defines the shared rules. The iPhone
policy and native feedback implementation did not change.

Frequent Watch events all request the short Click preset. The longer Start volley
pattern was removed so it does not compete with rapid impacts. Player damage
retains Direction down. Active-app, explicit OFF and no-queue guards remain.

This matches detected-event coverage and requested timing, not physical texture.
`CHHapticEngine` is explicitly unavailable on watchOS in the installed iPhone SDK,
and WatchKit supplies presets without per-call intensity. Apple's
[play documentation](https://developer.apple.com/documentation/watchkit/wkinterfacedevice/play(_:))
says a request can interrupt an engaged engine and delay the next pattern by at
least 100 ms; it does not specify a maximum playback rate. Distinct felt pulses
for every overlapping effect cannot be guaranteed. The original engine coalesces
same-kind events per frame, and each host chooses one event per update. Generic
projectile contact without an Explosion or player-health decrease has no separate
hook on either platform.

Verification:

- **147** Swift 6 warnings-as-errors policy checks pass: the original **117**
  iPhone checks plus **30** Watch cadence regressions. Explicit expected events
  cover repeated 250 ms explosions, volley/primary preemption, damage, matching
  iPhone decisions, OFF and no replay. The obsolete sparse-Watch assertions were
  removed because that policy was intentionally replaced.
- Watch Simulator, signed Watch-device and iPhone 18 Pro Simulator builds pass.
  These were compile-only regression checks; no Simulator interaction, app
  preferences, boot state or system settings were changed for build 8. Original
  event-observation integration checks remain recorded above; no engine hook changed.
- Strict signature verification and exact Series 12 provisioning membership pass.
  CoreDevice installed **1.1 (8)** in place, independently read back that version,
  and launched normally (PID **1055**) with no test-save or audio overrides. Existing
  progress and Options preferences were retained. The user then confirmed that
  build 8's smaller explosions and weapon effects feel **much closer** to iPhone
  during physical Watch gameplay. This confirms the reported improvement in
  frequency, not exact pattern/strength parity or a separate pulse for every effect.

Only the known Series 12 was targeted. No Apple TV discovery or activation occurred.
