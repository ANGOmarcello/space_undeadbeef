# Optional iPhone haptics — 26 October 2026

Haptics default to ON when no preference exists and are controlled through ON/OFF
in the original Options screen. An explicit OFF choice remains OFF. The choice
persists immediately as `feedback.hapticsEnabled` in the
host's UserDefaults, independently of sound and Respect Silent Mode. Tests use
the existing isolated `SDB_SAVE_DIRECTORY` preference file and never real user
settings.

Only the iPhone native host offers or emits feedback. The original menu's font,
colors, animations, button handling and ON/OFF columns are reused. Four sections
share the existing heading-to-SAVE-EXIT span, preserving the original choice
offset and exit anchor. iPad and Watch retain their prior audio Options layout;
Mac retains its original layout.

The host reuses a soft UIKit feedback generator. Each frame consumes one bitset
after all due simulation steps. Damage has priority over laser release, then
target acquisition; a shared 0.25-second cooldown allows at most four pulses per
second. Low intensities are 0.25, 0.15 and 0.10 respectively. There is no deferred
queue or menu feedback. Pause, inactivity, failure and OFF discard events.
OFF/pause cannot reset the cooldown.

Original gameplay is observed without skipping or replacing instructions:

- `SoundEffect::play` entry `0xe994`, before its sound-enabled guard: entry 2 is
  a successful lock-on laser volley, entry 3 a newly acquired target batch.
  Empty releases and unrelated explosions do not generate these events.
- `Player::update` at `0x2796`: the guarded original health-store instruction is
  observed only for the actual player, health offset `0xd8`, and a decreased
  value. Enemy explosions are not interpreted as player damage.

Verification:

- `script/test_haptics_policy.sh`: 83 pure checks cover priority, exact cooldown
  boundaries, sustained 60 Hz event bursts, OFF/toggles, unknown masks, invalid
  timestamps, long uptime and discarded events.
- `script/test_haptics.sh`: 269 public-engine checks pass with address/undefined
  sanitizers. Real Options ON/OFF and immediate persistence survive engine
  recreation. With Sound OFF, 3,000 ordinary gameplay updates produce 12 laser
  releases and 264 target events with zero audio requests. A fresh passive run
  observes one real damage event, followed by ordinary Game Over after 846 steps.
- Guarded Options geometry passes 1,662 sanitizer checks, including 12/15-row
  layouts, wide/tall safe areas, round trips, original metadata/callback
  preservation and invalid/truncated tables.
- iPhone 18 Pro Simulator visually verifies the new default ON in Options with
  fresh isolated preferences. Earlier checks also cover ON/OFF selection,
  immediate persistence across relaunch, SAVE-EXIT and Game Start. The updated
  iOS Simulator and signed device builds pass; prior Mac/Watch builds and
  iOS/Watch Swift 6 host typechecks passed.
- The development-signed 1.1 (1) build was installed and launched successfully
  on the connected physical iPhone 14 Pro running iOS 27.0.1. CoreDevice confirmed
  the installed bundle/version and launched process. Signing validation passed,
  including the iPhone's provisioning membership. No test save/mute environment
  overrides were passed to the physical app. This is installation/launch proof,
  not a tactile or gameplay/performance check.

Simulator and offline checks establish event/persistence behavior, not tactile
quality. The subtle intensities still need a physical iPhone feel check.
No Apple TV device discovery or testing was performed for this step.
