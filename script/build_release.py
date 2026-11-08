#!/usr/bin/env python3
"""Build a local Respring-style release from a committed source snapshot.

Created by Angelo Cammalleri on 08.11.2026.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from audit_release import ROOT, extract_source, metadata, require, sha256
from package_ipa import package, write_zip


def build(ref: str, output: Path) -> dict:
    require(not output.exists(), "Choose a new release directory; existing releases are retained")
    revision = subprocess.check_output(
        ["git", "-C", str(ROOT), "rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], text=True,
    ).strip()
    print(f"Building committed source {revision}", flush=True)
    derived_root = Path.home() / "Library/Developer/Xcode/DerivedData"
    derived_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="space-release-") as temporary, \
         tempfile.TemporaryDirectory(prefix="SpaceDeadbeef-Release-", dir=derived_root) as derived:
        scratch = Path(temporary)
        snapshot = scratch / "git-source.zip"
        subprocess.run(["git", "-C", str(ROOT), "archive", "--format=zip", "--prefix=SpaceDeadbeef/",
                        "--output", str(snapshot), revision], check=True)
        source = extract_source(snapshot, scratch / "source")
        expected = metadata(source)
        expected["source_revision"] = revision
        (source / "distribution.json").write_text(json.dumps(expected, indent=2) + "\n")
        (source / "Documentation/Verification.md").write_text(
            "# Release source verification\n\n"
            f"Source revision: `{revision}`.\n\n"
            "This source archive supplies the inputs for the matching unsigned iPhone/iPad IPA. "
            "It contains the prepared, hash-checked original game resources and the native host. "
            "See [BUILDING.md](../BUILDING.md) for the package audit and sideloading checks.\n"
        )
        staged = scratch / "release"
        staged.mkdir()
        stem = expected["asset_stem"]
        source_zip = staged / f"{stem}-source.zip"
        write_zip(source_zip, source, "SpaceDeadbeef/", revision.encode("ascii"))
        # Build the same exported source tree we ship. No local Xcode edits,
        # user files, or sibling checkout can silently enter the source ZIP.
        log = scratch / "xcodebuild.log"
        with log.open("w") as capture:
            completed = subprocess.run([
                "xcodebuild", "-project", "SPACE UNDEADBEEF.xcodeproj", "-scheme", "SPACE UNDEADBEEF iOS",
                "-configuration", "Release", "-destination", "generic/platform=iOS", "-derivedDataPath", derived,
                "-xcconfig", "Config/Sideload.xcconfig", "-jobs", "2", "ARCHS=arm64",
                f"SDB_RELEASE_SOURCE_COMMIT={revision}", "build",
            ], cwd=source, stdout=capture, stderr=subprocess.STDOUT)
        if completed.returncode:
            print("\n".join(log.read_text(errors="replace").splitlines()[-60:]), file=sys.stderr)
            raise ValueError("The unsigned iPhoneOS Release build failed")
        app = Path(derived) / "Build/Products/Release-iphoneos" / (expected["product"] + ".app")
        ipa = staged / f"{stem}.ipa"
        receipt = package(app, ipa, source)
        (staged / "SHA256SUMS").write_text(
            "".join(f"{sha256(artifact)}  {artifact.name}\n" for artifact in (ipa, source_zip))
        )
        output.parent.mkdir(parents=True, exist_ok=True)
        # Publish to the local destination only after both artifacts pass.
        with tempfile.TemporaryDirectory(prefix=".space-release-", dir=output.parent) as delivery:
            ready = Path(delivery) / "ready"
            shutil.copytree(staged, ready)
            require(not output.exists(), "The release destination appeared while building")
            ready.rename(output)
    return receipt | {"output": str(output)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default="HEAD", help="Committed source to package (default: HEAD)")
    parser.add_argument("--output", type=Path, required=True, help="New directory for the three release assets")
    args = parser.parse_args()
    try:
        print(json.dumps(build(args.ref, args.output.expanduser().resolve()), indent=2))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
