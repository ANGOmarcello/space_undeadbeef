#!/usr/bin/env python3
"""Stage an unsigned, recipient-signed Space Deadbeef IPA.

Created by Angelo Cammalleri on 08.11.2026.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True
from audit_release import ROOT, audit_ipa, device_host, metadata, private_member, require


def write_zip(output: Path, root: Path, prefix: str, comment: bytes = b"") -> None:
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED, strict_timestamps=False) as archive:
        for path in sorted(root.rglob("*")):
            require(not path.is_symlink(), f"Unexpected link in release input: {path.relative_to(root)}")
            if path.is_file():
                archive.write(path, prefix + path.relative_to(root).as_posix())
            else:
                require(path.is_dir(), f"Unexpected file type: {path.relative_to(root)}")
        archive.comment = comment


def package(app: Path, output: Path, source: Path) -> dict:
    expected = metadata(source)
    require(app.is_dir() and not app.is_symlink(), "Supply a built iPhoneOS .app directory")
    require(not output.exists(), "Choose a new IPA output path")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="space-ipa-") as temporary:
        scratch = Path(temporary)
        staged = scratch / "Payload" / (expected["product"] + ".app")
        shutil.copytree(app, staged, symlinks=True)
        for path in sorted(staged.rglob("*"), key=lambda item: len(item.parts), reverse=True):
            require(not path.is_symlink(), f"Unexpected link in app: {path.relative_to(staged)}")
            if private_member(PurePosixPath(path.relative_to(staged).as_posix())):
                # This host uses the prepared Original directory. Reject an
                # unexpected embedded IPA instead of dropping game content.
                require(path.suffix.casefold() != ".ipa", "Unexpected nested IPA in app")
                if path.is_dir():
                    shutil.rmtree(path)
                else:
                    path.unlink()
        binary = staged / expected["product"]
        _, signed = device_host(binary.read_bytes())
        if signed:
            subprocess.run(["/usr/bin/codesign", "--remove-signature", str(binary)], check=True)
        notices = staged / "Notices"
        notices.mkdir(exist_ok=True)
        shutil.copyfile(source / "THIRD_PARTY_NOTICES.md", notices / "THIRD_PARTY_NOTICES.md")
        candidate = scratch / output.name
        write_zip(candidate, staged, f"Payload/{staged.name}/")
        receipt = audit_ipa(candidate, source)
        with output.open("xb") as destination, candidate.open("rb") as prepared:
            shutil.copyfileobj(prepared, destination)
    return receipt


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    args = parser.parse_args()
    try:
        receipt = package(args.app, args.output, args.source_root)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        parser.error(str(error))
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
