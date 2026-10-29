# Credits and restoration contact

On 29 October 2026, Angelo Cammalleri reported that he had written to the original
credits address, `space_deadbeef@yahoo.com`, and the message bounced. This reported
bounce is the reason for replacing that address in the visible Credits screen.
The historical address is retained here as part of the restoration record.

The approved replacement wording is:

> Restoration & modernization by cammalleri.dev

The website opens `https://cammalleri.dev` on platforms that support opening web
links. The original creator, graphics, effects, sound and special-thanks credits
remain unchanged. The restoration credit describes the modern port and does not
replace the original game's authorship.

## Implementation

The visible wording wraps after “modernization” into two short lines in the
former contact band. It is drawn through the original font helper using the
original gray and animation. The seven creator/thanks rows and the original
EXIT remain in place. The guard checks the exact historical contact string,
font metrics and nonexecutable row before changing its rendering. Prepared
original files and the supplied executable are unchanged.

The native host supplies the link's accessible label and hit target. Its frame
tracks the live original menu row as the layout or animation moves. It appears
only in ready Credits and is separate from EXIT. iOS, macOS and watchOS use a
native SwiftUI Link to the fixed HTTPS destination; tvOS displays the address
without an external-browser control. No email is sent by the app.

## Verification — 29 October 2026

- **96** sanitizer-backed menu/layout/save checks pass with optional captures
  enabled (**93** without the three capture-write assertions). The real engine
  renders the two-line notice, preserves EXIT, restores the title and original
  save behavior, and keeps link bounds separate through Watch-sized, portrait
  iPad and original-size layouts. Captures were visually reviewed.
- **One iPhone 18 Pro, iOS 27.2 Simulator UI test passes**, with zero failures or
  skips. It opens Credits, checks the exact accessible wording and separate
  EXIT bounds, taps the native link, verifies Safari receives `cammalleri.dev`,
  returns to Credits and exits through the original control. Its test save and
  muted audio are isolated. No system accessibility setting was changed.
- Unsigned Debug builds pass for iOS, macOS, watchOS and tvOS as **1.1 (14)**.
  This is compile and Simulator evidence; physical Watch/Mac link interaction
  was not exercised. The UI run reports the existing synchronous audio-session
  diagnostics; audio code was not changed by this work.

The standalone menu-test script's Metal preparation step could not run because
`xcrun metal` reported a missing Metal Toolchain component. The identical menu
harness was compiled directly with ASan/UBSan and the CPU renderer, referencing
the current Mac app's existing, unchanged `default.metallib`. These checks are
not evidence of a fresh shader compilation. No toolchain download was started.
