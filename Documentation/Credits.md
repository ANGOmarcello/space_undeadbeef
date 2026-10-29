# Credits and restoration contact

On 29 October 2026, Angelo Cammalleri reported that he had written to the original
credits address, `space_deadbeef@yahoo.com`, and the message bounced. This reported
bounce is the reason for replacing that address in the visible Credits screen.
The historical address is retained here as part of the restoration record.

The current approved replacement wording is:

> Modernization:     cammalleri.dev

The website is warm yellow and underlined. This single-row wording supersedes
the initially approved two-line “Restoration & modernization by cammalleri.dev”
notice, at the user's request on 29 October 2026.

The website opens `https://cammalleri.dev` on platforms that support opening web
links. The original creator, graphics, effects, sound and special-thanks credits
remain unchanged. The restoration credit describes the modern port and does not
replace the original game's authorship.

## Implementation

The label and website occupy the former email row, at its original 30-unit
distance from Special Thanks. Both use the adjacent credits' original 24×12
font and 33-column alignment: label left, website right. The label retains the
original gray; the website uses the original highlighted-choice yellow and a
one-unit underline at the normal font size. All parts follow the live original
animation. The seven creator/thanks rows and the original EXIT remain in place.
The guard checks the exact historical contact string,
font metrics and nonexecutable row before changing its rendering. Prepared
original files and the supplied executable are unchanged.

The native host supplies the link's accessible label and hit target. Its frame
tracks the live original menu row as the layout or animation moves. It appears
only in ready Credits and is separate from EXIT. iOS, macOS and watchOS use a
native SwiftUI Link to the fixed HTTPS destination; tvOS displays the address
without an external-browser control. No email is sent by the app.

## Verification — 29 October 2026

- **97** sanitizer-backed menu/layout/save checks pass with optional captures
  enabled (**94** without the three capture-write assertions). The real engine
  renders the single-row notice at the original glyph size, preserves EXIT, restores the title and original
  save behavior, and keeps link bounds separate through Watch-sized, portrait
  iPad and original-size layouts. Captures were visually reviewed.
- **One iPhone 18 Pro, iOS 27.2 Simulator UI test passes**, with zero failures or
  skips. It opens Credits, checks the exact accessible wording and separate
  EXIT bounds, taps the native link, verifies Safari receives `cammalleri.dev`,
  returns to Credits and exits through the original control. Its test save and
  muted audio are isolated. No system accessibility setting was changed.
- The initial credit passed unsigned Debug builds for all four platforms as
  **1.1 (14)**. The revised row is version **1.1 (16)**.
  This is compile and Simulator evidence; physical Watch/Mac link interaction
  was not exercised. The UI run reports the existing synchronous audio-session
  diagnostics; audio code was not changed by this work.

The standalone menu-test script's Metal preparation step could not run because
`xcrun metal` reported a missing Metal Toolchain component. The identical menu
harness was compiled directly with ASan/UBSan and the CPU renderer, referencing
the current Mac app's existing, unchanged `default.metallib`. These checks are
not evidence of a fresh shader compilation. No toolchain download was started.
