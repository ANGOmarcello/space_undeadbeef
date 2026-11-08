#!/usr/bin/env python3
"""Validate the unsigned iPhone/iPad IPA against its matching source.

Created by Angelo Cammalleri on 08.11.2026.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import struct
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent
PRIVATE_NAMES = {
    "_codesignature", "embedded.mobileprovision", "embedded.provisionprofile",
    "sc_info", "itunesmetadata.plist", "itunesartwork", ".ds_store", "__macosx",
}
PRIVATE_SUFFIXES = {".ipa", ".mobileprovision", ".provisionprofile", ".p12", ".pfx", ".xcent"}
MACHO_MAGICS = {bytes.fromhex(x) for x in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
)}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def metadata(root: Path) -> dict:
    result = json.loads((root / "distribution.json").read_text())
    config = (root / "Config/App.xcconfig").read_text()
    for field, key in (("wrapper_version", "MARKETING_VERSION"), ("build", "CURRENT_PROJECT_VERSION")):
        values = re.findall(rf"^{key}\s*=\s*([0-9]+(?:\.[0-9]+)*)\s*$", config, re.MULTILINE)
        require(len(values) == 1, f"Missing unambiguous {key} in App.xcconfig")
        require(field not in result or result[field] == values[0], f"Distribution {field} disagrees with App.xcconfig")
        result[field] = values[0]
    return result


def private_member(path: PurePosixPath) -> bool:
    return (any(part.casefold() in PRIVATE_NAMES or part.startswith("._") for part in path.parts)
            or path.suffix.casefold() in PRIVATE_SUFFIXES)


def checked_members(archive: zipfile.ZipFile) -> dict[str, zipfile.ZipInfo]:
    """Reject unsafe paths, duplicate names, link entries and account sidecars."""
    files: dict[str, zipfile.ZipInfo] = {}
    seen: set[str] = set()
    for info in archive.infolist():
        name = info.filename.rstrip("/")
        path = PurePosixPath(name)
        require(bool(name) and not path.is_absolute() and "\\" not in name and
                all(part not in ("", ".", "..") for part in name.split("/")), f"Unsafe ZIP path: {name}")
        folded = name.casefold()
        require(folded not in seen, f"Duplicate ZIP path: {name}")
        seen.add(folded)
        mode = stat.S_IFMT(info.external_attr >> 16)
        require(mode in (0, stat.S_IFDIR if info.is_dir() else stat.S_IFREG), f"Nonregular ZIP entry: {name}")
        require(not private_member(path), f"Signing or account metadata in ZIP: {name}")
        if not info.is_dir():
            files[name] = info
    require(archive.testzip() is None, "ZIP integrity check failed")
    return files


def extract_source(archive_path: Path, destination: Path) -> Path:
    with zipfile.ZipFile(archive_path) as archive:
        files = checked_members(archive)
        roots = {PurePosixPath(name).parts[0] for name in files}
        require(len(roots) == 1 and all(len(PurePosixPath(name).parts) > 1 for name in files),
                "Source ZIP needs one project directory")
        archive.extractall(destination)
        for name, info in files.items():
            (destination / name).chmod(0o755 if (info.external_attr >> 16) & 0o111 else 0o644)
    root = destination / next(iter(roots))
    require((root / "SPACE UNDEADBEEF.xcodeproj/project.pbxproj").is_file(), "Xcode project missing in source archive")
    return root


def device_host(binary: bytes) -> tuple[str, bool]:
    """A simulator can also be ARM64; LC_BUILD_VERSION identifies the SDK platform."""
    require(len(binary) >= 32, "Truncated Mach-O header")
    magic, cpu, _, kind, commands, size, _, _ = struct.unpack_from("<8I", binary)
    require(magic == 0xFEEDFACF and cpu == 0x0100000C and kind == 2, "Expected a thin ARM64 Mach-O executable")
    end = 32 + size
    require(end <= len(binary) and commands <= size // 8, "Invalid Mach-O load command table")
    offset = 32
    minimum = None
    signed = False
    for _ in range(commands):
        require(offset + 8 <= end, "Truncated Mach-O load command")
        command, length = struct.unpack_from("<II", binary, offset)
        require(length >= 8 and offset + length <= end, "Invalid Mach-O load command length")
        if command == 0x32:  # LC_BUILD_VERSION; PLATFORM_IOS is 2, simulator is 7.
            require(length >= 24 and minimum is None, "Invalid Mach-O build version")
            platform, version = struct.unpack_from("<II", binary, offset + 8)
            require(platform == 2, "Expected iPhoneOS device code, not a simulator or other platform")
            minimum = f"{version >> 16}.{(version >> 8) & 255}"
            if version & 255:
                minimum += f".{version & 255}"
        if command == 0x1D:  # LC_CODE_SIGNATURE
            signed = True
        if command in (0x21, 0x2C):  # LC_ENCRYPTION_INFO / LC_ENCRYPTION_INFO_64
            require(length >= 20 and struct.unpack_from("<I", binary, offset + 16)[0] == 0, "Encrypted host binary")
        offset += length
    require(offset == end and minimum is not None, "Missing or malformed iPhoneOS build version")
    return minimum, signed


def audit_ipa(ipa: Path, source: Path) -> dict:
    expected = metadata(source)
    app = f"Payload/{expected['product']}.app/"
    with zipfile.ZipFile(ipa) as archive:
        entries = checked_members(archive)
        require(all(name.startswith(app) for name in entries), "The IPA must contain only one Payload app")
        require(not any(PurePosixPath(name).suffix.casefold() in {".zip", ".tar", ".gz"} for name in entries),
                "Unexpected nested archive in app")
        info = plistlib.loads(archive.read(app + "Info.plist"))
        for key, value in {
            "CFBundleIdentifier": expected["bundle_identifier"],
            "CFBundleExecutable": expected["product"],
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "UIDeviceFamily": [1, 2],
            "MinimumOSVersion": expected["minimum_ios"],
            "CFBundleShortVersionString": expected["wrapper_version"],
            "CFBundleVersion": expected["build"],
            "SDBProgressSyncMode": "folder",
        }.items():
            require(info.get(key) == value, f"Unexpected {key} in built app: {info.get(key)!r}")
        revision = info.get("SDBReleaseSourceCommit", "")
        require(bool(re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", revision)), "Missing build source revision")
        if "source_revision" in expected:
            require(revision == expected["source_revision"], "IPA and source archive revisions differ")
        executable = app + expected["product"]
        minimum, signed = device_host(archive.read(executable))
        require(minimum == expected["minimum_ios"] and not signed, "Host has an unexpected deployment target or signature")
        require(bool(entries[executable].external_attr >> 16 & 0o111), "Host executable mode was not preserved")
        for name in ("default.metallib", "Assets.car", "Notices/THIRD_PARTY_NOTICES.md"):
            require(app + name in entries and entries[app + name].file_size > 0, f"Missing app resource: {name}")
        require(info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName") == expected["product"],
                "Missing compiled app icon metadata")

        original = source / "Resources/Original"
        manifest = json.loads((original / "manifest.json").read_text())
        inputs = {item["name"]: item["preparedSHA256"] for item in manifest["assets"]}
        guest = manifest["executable"]
        require(expected["guest_executable"] == "Original/" + guest["name"], "Unexpected original executable identity")
        inputs[guest["name"]] = guest["sha256"]
        inputs["manifest.json"] = sha256(original / "manifest.json")
        require(set(name.removeprefix(app + "Original/") for name in entries if name.startswith(app + "Original/"))
                == set(inputs), "Original payload inventory differs from its manifest")
        for name, digest in inputs.items():
            require(hashlib.sha256(archive.read(app + "Original/" + name)).hexdigest() == digest,
                    f"Original asset hash mismatch: {name}")

        for path in (source / "Resources/Modern").rglob("*"):
            if path.is_file():
                member = app + path.relative_to(source / "Resources").as_posix()
                require(member in entries and hashlib.sha256(archive.read(member)).hexdigest() == sha256(path),
                        f"Modern asset mismatch: {member}")
        for name in entries.keys() - {executable, app + expected["guest_executable"]}:
            with archive.open(name) as file:
                require(file.read(4) not in MACHO_MAGICS, f"Unexpected bundled Mach-O: {name}")
    return {
        "name": expected["name"], "version": expected["wrapper_version"], "build": expected["build"],
        "source_revision": revision, "minimum_ios": minimum, "platform": "iPhoneOS arm64", "unsigned": True,
        "progress_sync": "Files / iCloud Drive", "original_files_verified": len(inputs), "sha256": sha256(ipa),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    sources = parser.add_mutually_exclusive_group()
    sources.add_argument("--source-root", type=Path, default=ROOT)
    sources.add_argument("--source-zip", type=Path)
    args = parser.parse_args()
    try:
        if args.source_zip:
            with tempfile.TemporaryDirectory(prefix="space-audit-") as temporary:
                receipt = audit_ipa(args.ipa, extract_source(args.source_zip, Path(temporary)))
        else:
            receipt = audit_ipa(args.ipa, args.source_root)
    except (OSError, ValueError, TypeError, KeyError, zipfile.BadZipFile) as error:
        parser.error(str(error))
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
