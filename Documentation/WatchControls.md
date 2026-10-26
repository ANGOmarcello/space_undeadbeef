# Watch controls and HUD

Version **1.1 (3)** replaces the Watch's Crown-controlled virtual pointer with
relative vertical ship steering. Each new Crown gesture starts at the actual
ship position. The target stays within the original radius-inset arena bounds;
the original spring, damping, integration and clamps still move the ship.

The host calls the original `DynamicReal::springForce` at `0x562d` with the
original stiffness from `0x291c`, then runs the normal fixed simulation step.
It does not write ship positions or start a targeting touch. Crown input ends
when rotation becomes idle, a touch begins, a menu appears, the viewport changes,
or the app pauses or becomes inactive. Touch targeting owns input until release.
The next Crown gesture anchors to the ship again, avoiding a jump after dragging.

The original `Game::touchCancelled` does not release its marker. If a canceled
touch left that marker held, accepted Crown input calls the original
`Marker::ended` at `0x4b3b`; it does not call the touch-release volley routine.
The white virtual pointer and its obsolete Watch accessibility actions are gone.
The Crown uses a finite continuous range with wrap-aware deltas. An explicit
infinite range caused `CALayerInvalidGeometry` in the Watch Simulator's Crown
indicator during verification; the final range avoids that failure and the
system Crown accessory is hidden. Rotation during the original automatic ship
entrance or death is discarded rather than queued for the next playable state.

The Watch uses the native folded-paper Pause control. **1.1 (4)** anchors it to
the physical top-left corner rather than adding the Watch's top safe-area gap.
The shallower angled fold is **26 points tall**, compared with about 49 points
on the 46 mm Watch before this correction. Its original P stays upright and
uniformly proportioned, with the artwork ending above the clock's text baseline.
A Watch-only navigation container supplies the native leading toolbar button
alongside the clock. The bar background is hidden; the paper decoration fills
the physical corner. The native button keeps a larger invisible tap area for
reliable activation, including below the visible fold. This is a visual size
reduction, not a guarantee of touch pass-through in the system toolbar region.
The guest pause sprite and hit target are removed from the Watch surface; the
native button still invokes the original pause routine. Resume restores Crown
focus. The container fixes physical left placement regardless of layout direction.

Watch HUD placement is explicit, independent of aspect ratio. The original
score, high score, stage/deaths, charge cells and boss gauge form the same two
rows near the full screen's bottom edge. **1.1 (4)** removes the extra Watch
bottom safe-area gap: the original left inset plus one original glyph row
supplies 46 logical units of clearance above the rounded lower edge, about
20 points on the 46 mm Watch. Original glyph metrics remain unchanged. The
complete HUD, including the slanted full boss gauge, is horizontally centered
as one group within the horizontal safe bounds. Narrower safe widths compress
the original gaps between columns. Ship travel, gameplay sprites, and other
platforms' HUD placement stay unchanged.

## Verification

The **1.1 (3)** steering checks on 26 October 2026 passed:

- `script/test_watch_controls.sh`: **35 ASan/UBSan engine checks**. The actual
  normalized ship position moved `0.5 → 0.213242 → 0.726602`, with no held aim.
  Raw positions remained within the original radius clamps. Four software frames
  were inspected for actual movement, HUD placement and the original Pause menu.
- `script/test_crown_input.sh`: **50 model/session checks**, compiling the real
  Swift session against the original engine. These cover both continuous-range
  seams, original ship movement, ignored entrance input, touch handoff, viewport
  changes, Pause/Continue and background/resume without stale targets or aim.
- `Tests/GameDisplayPatchTests.cpp`: **1,992 strict-compiler and ASan/UBSan
  checks**, including HUD bounds, narrow safe widths, atomic rejection, unchanged
  original glyph/charge metrics, unchanged arena data, and exact restoration of
  non-Watch and original layouts.
- The Series 12 46 mm watchOS 27.2 Simulator built and ran. Visible gameplay
  showed the bottom HUD and top-left P without the white pointer. Tapping the
  visible native P reached original `menuType 3`, and Continue resumed gameplay.
  Subsequent runs stayed open after the finite Crown-range correction.
- The shared iOS host compiled for the iPhone 18 Pro Simulator. This was a
  compile-only regression check; no iPhone interface or installation was changed.
- The watchOS device build is development-signed **1.1 (3)**. Strict signature
  verification passed, and its provisioning profile includes the Series 12.

The **1.1 (4)** layout correction additionally passed:

- **2,091 strict-compiler and ASan/UBSan checks** of the original-data display
  patch. These cover full-surface bottom placement, group centering including
  the full boss gauge, narrow and asymmetric safe bounds, preserved original
  glyph/charge metrics, atomic rejection and exact non-Watch restoration.
- The Series 12 46 mm Simulator visibly showed the compact corner fold above
  the clock baseline and the centered bottom HUD. Tapping the visible P opened
  the original Pause menu; Continue resumed gameplay. Native toolbar taps can
  activate Pause below the visible paper, as noted above.
- The shared iOS host compiled for iPhone 18 Pro Simulator without warnings.
  This was a compile-only regression check.
- The watchOS device build passed strict signature verification and Series 12
  provisioning membership. CoreDevice installed **1.1 (4)** in place on the
  physical Series 12, confirmed its bundle/version, and launched it without test
  overrides (PID **958**). No uninstall or physical game-data reset was performed.

These checks prove the original steering and host input bridge, layout and
physical installation/launch. Automated Simulator wheel attempts do not
establish physical Crown delivery or feel. Updated hardware gameplay remains a
separate check. Earlier physical-build history is in [Verification.md](Verification.md).

## Physical update to 1.1 (5) — 26 October 2026

After the Series 12 joined the Mac's Wi-Fi network, its existing paired
CoreDevice connection succeeded over the local network, with Developer Mode
enabled. The current source, including `d968435`'s artwork-relative menu-version
alignment, was built for that exact physical Watch destination. The shared build
number advanced to 5; the marketing version remains 1.1. Watch HUD and Crown
behavior retain the earlier corrections above.

The device build succeeded, strict signature verification passed, and the
embedded development profile includes the Series 12. CoreDevice installed the
standalone app in place, then independently reported version **1.1 (5)** under
`dev.cammalleri.SpaceUndeadbeef.watch`. Normal launch succeeded (PID **1023**),
without test-save or audio overrides, uninstalling, or resetting app data.

A direct physical-device screenshot confirmed the filled main menu, its
`Ver.1.1` label and retained **Continue 1-16** progress. No gameplay input was
sent, so this update establishes installation, launch and title rendering;
it does not add a new physical Crown or sustained frame-rate measurement.
Only the known Series 12 was targeted; no Apple TV discovery was performed.

## Optional Watch haptics — 26 October 2026

Build 1.1 (6) adds the original Haptics ON/OFF Options section on Watch. The user
confirmed feeling its OFF→ON preview on the physical Series 12 after an in-place
installation and normal launch (PID 1050). The game uses WatchKit presets rather
than a SwiftUI feedback counter. Crown ticks remain disabled; steering and
corner Pause/HUD geometry are unchanged.

Build 7 differentiates targeted rocket/laser volleys from short menu/ordinary-fire
clicks, with a conservative quiet interval. Pattern mappings, persistence,
rate limits, system-controlled audibility and exact verification boundaries are
recorded in [Haptics.md](Haptics.md#watch-adaptation-builds-11-67).

The final development-signed **1.1 (7)** passed strict signature/profile checks,
was installed in place on the same Series 12, read back as build 7, and launched
normally (PID 1052). No test save/audio overrides or uninstall were used. Physical
feel of the revised volley pattern remains a user check.

## Watch cadence update to 1.1 (8)

After the user reported sparse impact/explosion feedback, build 8 removes the
extra Watch-only quiet windows and uses the same event policy as iPhone. Volleys
return to short clicks for rapid effects; damage retains Direction down. Crown,
Pause and HUD behavior are unchanged. The signed app was installed in place,
independently read back as **1.1 (8)**, and normally launched on Series 12
(PID **1055**), retaining saves and preferences. See
[Haptics.md](Haptics.md#watch-cadence-parity-build-11-8) for the shared cadence,
147 policy checks and platform limits. The user subsequently confirmed that
smaller explosions and weapon effects feel **much closer** to iPhone during
physical Watch gameplay. This is confirmation of improved feedback frequency;
it does not establish exact pattern/strength parity for every effect.
