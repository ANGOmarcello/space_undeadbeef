# Full-screen and Retina modernization

The original-aspect restoration is preserved at commit `92c0cfc`. That build was
verified on native macOS, iPhone/TV/Watch simulators, and a physical Series 12.
This next step changes presentation and arena geometry while keeping the original
game code, 60 Hz simulation, saved progress, audio preferences, and artwork identity.

## Acceptance criteria

- Fill the available iPhone, iPad, and Watch surface without stretching ships,
  cropping menus, or leaving letterbox bars. Support iPad portrait, landscape,
  and resizing, plus desktop window resizing.
- Extend the title background naturally beyond the original composition. Keep
  the original logo, ship, text, and central artwork intact; identify added
  scenery as new material rather than recovered original art.
- Expand the actual gameplay arena and its scrolling background. Update the
  corresponding spawn, culling, player, HUD, and inverse-input bounds together;
  decorative margins alone do not satisfy gameplay width.
- Render at the view's backing-pixel density. Draw original bitmap lettering
  crisply at the final raster size, preserving its shapes. Higher resolution
  does not create missing texture detail or turn bitmap text into a new font.
- Keep UI within local safe areas while allowing scenery to reach the edges.
  Touch, remote, mouse, keyboard, and Crown coordinates must follow the same
  geometry used for rendering.
- Verify original-aspect behavior as a control, wider and taller arenas,
  save/continue and audio settings, then visible iPhone Pro, iPad, Watch, and Mac
  results. Keep source, tests, documentation, and art changes in scoped commits.

## Coordinate spaces

The original landscape frame is 480×320. An adaptive viewport keeps one dimension
at that baseline and expands the other to match the current view aspect ratio.
Logical arena size, native backing pixels, and point-space safe areas remain
separate. The original guest portrait axes remain rotated into the host landscape
axes; input uses the inverse of this presentation mapping.

Retina rendering uses a Metal backend on supported platforms and the native
software renderer on Watch. Original textures remain authoritative. Added title
background material is stored separately from `Resources/Original`.

## Implementation

`DisplayGeometry` derives the logical arena, native raster and inverse input
mapping from the consuming view and its local safe area. It keeps a uniform scale,
limits each raster axis to 8192 pixels and the engine output to 16 million pixels.
The original 480×320 control geometry remains reversible.

`GameDisplayPatch` validates the original loaded literals, tables and three exact
Thumb instruction sites before adapting player bounds, enemy routes, spawn and
culling bounds, scrolling span, HUD, menus, pause and transitions. Repeated resize
starts from immutable original values. Projectile speeds, collision shapes,
simulation steps, original save packing and original input camera inversion are
retained. The taller scrolling background scales uniformly before the original
camera transform, preserving cloud proportions without a repeated sky seam.

The Metal backend preserves triangle order, matrices, UVs, original texture
padding, colour modulation and blending. Native Metal views present its texture
directly; they do not advance the game or read each frame back to the CPU. Watch
uses the software renderer at its native backing resolution. Both reconstruct
original lettering contours at the output pixel density. Baked menu labels keep
their original off-white foreground and soft dark shadow as separate fields,
avoiding the old shadow's pixel fringe being mistaken for the letter outline.
This retains the existing font shapes; it does not recover missing sprite detail.

The iOS host remakes the original folded-corner P control as native vector paths.
It reaches the full screen's top-right corner, provides a minimum 44-point touch
target and invokes the original P-button callback, including its Continue/Quit
menu and audio behavior. The replaced guest drawing and hit target are removed
from that host. Other platforms retain the original control.

## Shared version

All four targets use `Config/App.xcconfig`: `MARKETING_VERSION = 1.1` and
`CURRENT_PROJECT_VERSION = 1`. Each Info.plist expands these values. The original
menu's version string is replaced in loaded guest memory with
`Ver.<CFBundleShortVersionString>`, so it displays `Ver.1.1` from that same config.
Headless tools with no app bundle use `Ver.dev`; the release version is never
copied into the runtime as a second constant.

## Regression commands

- `script/test_runtime.sh`: CPU instruction regressions, geometry/inverse mappings,
  guarded original-data patches, bitmap contour derivation, and isolated runtime
  Options/audio/save/Continue checks under AddressSanitizer and UBSan.
- `script/test_rendering.sh`: original label foreground/shadow reconstruction and
  software/GPU pixel comparisons on solid, curved and reverse-winding fixtures.
  It explicitly reports GPU checks skipped when Metal is unavailable.
- `Tests/ViewportSmoke.mm`: native-sized wide iPhone, tall Watch and portrait iPad
  frames; actual Game Start; full backgrounds; live resize; Pause/Continue; isolated
  256-byte saves. Compile with the engine/renderer and Apple frameworks, then pass
  the original resource directory and a task-owned temporary output directory.
- The shared iOS/tvOS UI scheme tests use an isolated save directory, observe
  original menu transitions and capture the displayed result. The iOS test also
  verifies the native pause control's physical edge placement and original
  Pause/Continue round trip.
