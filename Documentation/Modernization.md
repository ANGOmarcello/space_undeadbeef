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
