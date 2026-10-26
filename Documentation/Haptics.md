# Optional iPhone haptics — 26 October 2026

Haptics default to ON when no preference exists. The original Options ON/OFF
controls persist `feedback.hapticsEnabled` immediately, independently of sound
and Respect Silent Mode. An explicit OFF remains OFF. Tests use isolated
`SDB_SAVE_DIRECTORY` preferences and never real user settings. Only iPhone
hosts offer or emit feedback; the existing menu layout is retained.

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
