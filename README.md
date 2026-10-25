# SPACE UNDEADBEEF

A restoration workbench for the supplied **Space Deadbeef 1.01** iPhoneOS 2.1 game, following [Respring's restoration workflow](https://github.com/DylanMcD8/respring-skill). The original IPA remains unchanged.

The native 64-bit host executes the original ARMv6/Thumb gameplay in a bounded C++ interpreter. It bridges the original fixed-function drawing to a portable rasterizer and OpenAL commands to AVFoundation. Original menus, game updates, enemy scenarios, collision, targeting, scoring, and save packing execute from the original binary. This is interpreted original code, not recovered source or an independently rewritten game. No JIT or obsolete system frameworks are required.

## Open and build

Open `SPACE UNDEADBEEF.xcodeproj` with Xcode 27.2 or newer and select one of the four shared schemes:

- `SPACE UNDEADBEEF iOS` — iPhone/iPad, iOS 18+
- `SPACE UNDEADBEEF macOS` — macOS 15+
- `SPACE UNDEADBEEF tvOS` — tvOS 18+
- `SPACE UNDEADBEEF watchOS` — standalone watch app, watchOS 11+

Set your own signing team for physical devices. macOS local build/run uses `./script/build_and_run.sh`; `--build-only` builds without launching. Build output stays in standard Xcode DerivedData. Each platform has a distinct host bundle identity and its own save directory.

The checked resources are reproducible from the supplied IPA:

```sh
python3 script/prepare_original.py
```

To regenerate the project after adding source files, run `ruby script/generate_project.rb` (requires the `xcodeproj` Ruby gem). The committed project builds without running this generator.

The four targets include platform app-icon catalogs made from the original
57×57 ship artwork. Run `xcrun swift script/prepare_icons.swift` to regenerate
them. Pixel scaling preserves the supplied artwork; these are not recovered
high-resolution originals. TV assets extend the background edges to fit its
rectangular icon and Top Shelf sizes.

## Controls

The game retains its original touch controls: hold and sweep over enemies to lock targets, release to fire, and hold your ship to charge. The ship follows the pointer vertically. All presentation sizes preserve the original playfield, including inverse input mapping.

- iPhone/iPad: touch and drag.
- Mac: mouse and drag, or arrows to position the pointer and Space to hold/release.
- Apple TV: directional remote presses position the pointer; Select taps, Play/Pause toggles holding for a targeting sweep.
- Apple Watch: touch and drag; the Digital Crown also moves the pointer vertically. Accessibility actions provide tap and hold/release.

## Evidence and limits

Native macOS gameplay and iOS, tvOS, and watchOS Simulator interaction were verified on 25 October 2026 with Xcode 27.2. See [Documentation/Verification.md](Documentation/Verification.md) for the devices, exercised flows, evidence identifiers, and remaining limits. These checks do not establish physical-device performance, hardware silent-mode behavior, or audible speaker output.

See [Documentation/Restoration.md](Documentation/Restoration.md) for exact input hashes, entry points, architecture, and headless integration checks. See [Documentation/Backend.md](Documentation/Backend.md) for the service and persistence inventory.

## Audio

Use the original **Options → Sound ON/OFF** controls. Sound defaults to ON, and explicit choices persist immediately. On iOS and watchOS, **Respect Silent Mode** also defaults to ON; turn it OFF in the same original Options screen to use playback audio while the device is in Silent Mode. macOS and tvOS use normal system audio output and omit that hardware-mode option. SAVE-EXIT returns to the title.

The game pauses its host updates and audio while inactive. Diagnostic runs may set the process-only `SDB_MUTE_AUDIO` override; normal launches do not enable that override.

## Original material

The original executable and audiovisual material retain their original ownership. Local preparation does not grant redistribution rights. This repository is a local restoration workbench; it is not published or submitted to App Store Connect.
