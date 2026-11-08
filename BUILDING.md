# Build and package Space Deadbeef

Use Xcode 27.2 or newer on a Mac with the Metal toolchain, plus Python 3.9 or
newer. The source archive includes the prepared game resources. You do not need
the original IPA to compile it; the IPA is only needed to regenerate those
resources, as documented in [Restoration.md](Documentation/Restoration.md).

Open `SPACE UNDEADBEEF.xcodeproj` and choose the shared scheme for iOS, macOS,
tvOS or watchOS. Personal device builds use your own Apple development team and
available bundle identifier. The provisioned progress option requires an
authorized iCloud key-value entitlement. See [iCloud progress](Documentation/ICLOUD.md).

## Package a release

From the Git checkout, commit the intended source and run:

```sh
python3 script/build_release.py --ref HEAD --output Releases/SpaceDeadbeef-1.1-build23
```

The command exports that revision, builds the exported iOS Release source, and
audits the resulting unsigned ARM64 **iPhoneOS** app. It excludes private device
receipts and leaves local uncommitted edits out of the archive. Temporary
products are isolated under standard Xcode DerivedData and cleaned afterward.
Only the three finished assets go in the output directory:

| Release asset | Purpose |
| --- | --- |
| `SpaceDeadbeef.ipa` | Unsigned iPhone/iPad device package, for recipient signing |
| `SpaceDeadbeef-source.zip` | Matching Xcode source, prepared inputs, scripts and notices |
| `SHA256SUMS` | SHA-256 hashes of both downloads |

Attach these assets to the GitHub Release for the same source revision. This is
the structure used by [Chuzzle](https://github.com/DylanMcD8/respring-chuzzle/releases/tag/revision-1)
and [Peggle](https://github.com/DylanMcD8/respring-peggle/releases/tag/revision-2).
Our interpreter is included in the matching source ZIP; there is no separate
bundled third-party runtime source archive. See [third-party notices](THIRD_PARTY_NOTICES.md).

The manual **Package unsigned iOS release** workflow prepares an Actions
artifact on the same Xcode runner as compatibility CI. Publication to GitHub
Releases is a separate step. No developer credentials or profiles are needed to
build the package.

## Check or rebuild a download

In the download directory, check both files with `shasum -a 256 -c SHA256SUMS`.
From the extracted source archive, verify that the IPA matches its build
revision and prepared assets:

```sh
python3 script/audit_release.py /path/to/SpaceDeadbeef.ipa
```

To compile the extracted source directly, use the iOS scheme with
`-configuration Release -destination 'generic/platform=iOS'` and
`-xcconfig Config/Sideload.xcconfig`. Supply the archive's `source_revision`
from `distribution.json` as `SDB_RELEASE_SOURCE_COMMIT=<revision>` when packaging
that build with `script/package_ipa.py`. The packaging script stages a copy and
does not modify the built app. A simulator `.app` is never a release input.

The IPA needs signing before installation. Its optional iCloud Drive workflow
uses Files access, so the signing account need not provision a developer-owned
iCloud container. To check an installed build, launch it, start a run, return to
the title, and verify Continue after relaunch. For cloud delivery, link the same
dedicated folder on two devices and verify that a later checkpoint from one
appears on the other. Package checks and local folder tests do not prove that
Apple delivered a file to a second device.
