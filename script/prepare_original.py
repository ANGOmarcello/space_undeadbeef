#!/usr/bin/env python3
"""Prepare the verified original game payload for the modern restoration.

Created by Angelo Cammalleri.
Only Python's standard library is required. The IPA is never modified or run.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import stat
import struct
import zlib
import zipfile


ARCHIVE_NAME = "MyFirstBundleIdentifier-iOS2.1-(Clutch-2.0.4).ipa"
ARCHIVE_SHA256 = "4000d45e21f69cab6c271c6aa917989674615a51f2bddc295115dc2eab8b36de"
EXECUTABLE_SHA256 = "f90a2cdeae9c955520c9358b0f511f92d8327ba69650816b34a7d6f177025d1e"
APP_PREFIX = "Payload/psh.app/"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

# IDs are recovered from -[pshAppDelegate applicationDidFinishLaunching:].
TEXTURES = [
    "font.png", "font_s.png", "title.png", "game_start.png", "credits.png",
    "continue.png", "continue_left.png", "quit.png", "options.png", "warning.png",
    "game_clear.png", "p.png",
    *[f"playerShip_{index:02}.png" for index in range(1, 26)],
    "bg01_00.png", "bg01_01.png", "bg01_02.png", "bg01_03.png",
    "bg01_10.png", "bg01_11.png", "bg01_12.png", "bg01_13.png",
    None, "ThrustMiddle.png", "lockmark.png", "laser.png", "missile.png",
    "Explosion.png", "exp01.png", "exp02.png", "splinter.png", "gray_ball.png",
    "ball.png", "zako01.png", "zako02.png", "sergeant.png", "snake_dou.png",
    "snake_head.png", "snake_tail.png",
]
SOUNDS = [
    ("Beep004_16St.wav", 1.0), ("Beep003_16St.wav", 1.0),
    ("BurnerA_11.wav", 0.5), ("TypewriterA_08.wav", 1.0),
    ("ShotA_11.wav", 1.0), ("ExplosionF-11.wav", 0.5),
    ("Beep019_16.wav", 1.0), ("MDoorA_16.wav", 1.0),
    ("gameover.wav", 1.0), ("gameclear.wav", 1.0),
    ("stage1_bgm.wav", 1.0), ("boss01_bgm.wav", 1.0),
]
ENTRY_POINTS = {
    "textureManagerInitialize": 0x421D,
    "textureManagerGet": 0x420D,
    "gameManagerConstructor": 0x8DFB,
    "gameManagerGet": 0x8A85,
    "gameManagerUpdate": 0x8AF3,
    "gameManagerRender": 0x8B23,
    "touchBegan": 0x8B3D,
    "touchMoved": 0x8B77,
    "touchEnded": 0x8BDB,
    "touchCancelled": 0x8C15,
    "setGravity": 0x8C2D,
    "setPause": 0x8C39,
    "forcePause": 0x8C71,
    "load": 0x8C85,
    "save": 0x8E13,
    "readFile": 0xA8A1,
    "writeFile": 0xA80D,
    "freeFileBuffer": 0xA959,
    "soundConstructor": 0xE7E9,
    "soundGet": 0xE7DD,
    "soundStopBgm": 0xE86F,
    "soundMuteBgm": 0xE899,
    "soundFadeOutBgm": 0xE8E1,
    "soundUpdate": 0xE8F1,
    "soundPlay": 0xE995,
    "soundPlayBgmWithLoop": 0xEA15,
    "soundPlayBgm": 0xEAF5,
    "soundInitialize": 0xEB01,
    "renderImage": 0x6DA1,
    "cameraRender": 0x9027,
    "switchU8Arm": 0xEE64,
    "switch32Arm": 0xEE7C,
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def png_chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def png_chunks(data: bytes) -> list[tuple[bytes, bytes]]:
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("Input is not a PNG")
    result = []
    offset = len(PNG_SIGNATURE)
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError("Truncated PNG chunk")
        size = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        end = offset + size + 12
        if end > len(data):
            raise ValueError("Truncated PNG chunk payload")
        payload = data[offset + 8:end - 4]
        expected = struct.unpack_from(">I", data, end - 4)[0]
        if zlib.crc32(kind + payload) != expected:
            raise ValueError("Invalid PNG CRC")
        result.append((kind, payload))
        offset = end
        if kind == b"IEND":
            if offset != len(data):
                raise ValueError("Unexpected bytes after PNG end")
            return result
    raise ValueError("PNG has no IEND chunk")


def paeth(left: int, above: int, upper_left: int) -> int:
    predictor = left + above - upper_left
    distances = [abs(predictor - left), abs(predictor - above), abs(predictor - upper_left)]
    return [left, above, upper_left][distances.index(min(distances))]


def decode_cgbi(data: bytes) -> tuple[bytes, int, int, bool]:
    """Convert Apple's premultiplied BGRA/raw-deflate PNG variant to RGBA PNG."""
    chunks = png_chunks(data)
    header = next(payload for kind, payload in chunks if kind == b"IHDR")
    width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", header)
    if not any(kind == b"CgBI" for kind, _ in chunks):
        return data, width, height, False
    if (depth, color, compression, filtering, interlace) != (8, 6, 0, 0, 0):
        raise ValueError("Unsupported CgBI pixel format")
    if not 0 < width <= 8192 or not 0 < height <= 8192:
        raise ValueError("Unexpected PNG dimensions")
    stream = b"".join(payload for kind, payload in chunks if kind == b"IDAT")
    decoder = zlib.decompressobj(-15)
    expected_size = height * (1 + width * 4)
    raw = decoder.decompress(stream, expected_size + 1)
    if len(raw) != expected_size or not decoder.eof:
        raise ValueError("Unexpected CgBI decompressed length")
    stride = width * 4
    previous = bytearray(stride)
    output = bytearray()
    offset = 0
    for _ in range(height):
        filter_type = raw[offset]
        row = bytearray(raw[offset + 1:offset + 1 + stride])
        offset += stride + 1
        if filter_type not in range(5):
            raise ValueError("Unsupported PNG row filter")
        for index in range(stride):
            left = row[index - 4] if index >= 4 else 0
            above = previous[index]
            upper_left = previous[index - 4] if index >= 4 else 0
            prediction = [0, left, above, (left + above) // 2, paeth(left, above, upper_left)][filter_type]
            row[index] = (row[index] + prediction) & 255
        previous = row
        rgba = bytearray(stride)
        for index in range(0, stride, 4):
            blue, green, red, alpha = row[index:index + 4]
            if alpha:
                red = min(255, (red * 255 + alpha // 2) // alpha)
                green = min(255, (green * 255 + alpha // 2) // alpha)
                blue = min(255, (blue * 255 + alpha // 2) // alpha)
            else:
                red = green = blue = 0
            rgba[index:index + 4] = bytes((red, green, blue, alpha))
        output.append(0)
        output.extend(rgba)
    # Use a standard sRGB profile; retain no CgBI-specific or incompatible color chunks.
    png = PNG_SIGNATURE + png_chunk(b"IHDR", header) + png_chunk(b"sRGB", b"\0")
    png += png_chunk(b"IDAT", zlib.compress(output, 9)) + png_chunk(b"IEND", b"")
    return png, width, height, True


def inspect_macho(data: bytes) -> dict:
    magic, cpu_type, cpu_subtype, file_type, count, command_bytes, flags = struct.unpack_from("<7I", data)
    if (magic, cpu_type, cpu_subtype, file_type) != (0xFEEDFACE, 12, 6, 2):
        raise ValueError("Expected the original ARMv6 Mach-O executable")
    offset = 28
    encryption = []
    segments = []
    dependencies = []
    symbols = None
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > 28 + command_bytes:
            raise ValueError("Invalid Mach-O load command")
        if command == 0x21:
            crypt_offset, crypt_size, crypt_id = struct.unpack_from("<III", data, offset + 8)
            encryption.append({"offset": crypt_offset, "size": crypt_size, "id": crypt_id})
        elif command == 0x1:
            name, address, vm_size, file_offset, file_size = struct.unpack_from("<16sIIII", data, offset + 8)
            segments.append({"name": name.split(b"\0")[0].decode(), "address": address,
                             "size": vm_size, "fileOffset": file_offset, "fileSize": file_size})
        elif command == 0x2:
            _, symbol_count, _, _ = struct.unpack_from("<IIII", data, offset + 8)
            symbols = symbol_count
        elif command == 0xC:
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            name = data[offset + name_offset:offset + size].split(b"\0")[0].decode()
            dependencies.append(name)
        offset += size
    if not encryption or any(entry["id"] != 0 for entry in encryption):
        raise ValueError("Original executable is encrypted or encryption state is missing")
    return {"architecture": "armv6", "format": "Mach-O 32-bit executable", "symbols": symbols,
            "encryption": encryption, "segments": segments, "dependencies": dependencies,
            "flags": flags}


def write_if_changed(path: Path, data: bytes) -> None:
    if path.exists() and path.read_bytes() == data:
        return
    path.write_bytes(data)


def prepare(archive: Path, destination: Path) -> dict:
    archive_data = archive.read_bytes()
    if sha256(archive_data) != ARCHIVE_SHA256:
        raise ValueError("Unsupported IPA SHA-256; re-derive addresses and mappings before accepting another input")
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if len({entry.filename for entry in entries}) != len(entries):
            raise ValueError("Duplicate ZIP entries")
        if len(entries) > 1000 or sum(entry.file_size for entry in entries) > 500_000_000:
            raise ValueError("Archive exceeds intake bounds")
        for entry in entries:
            path = PurePosixPath(entry.filename)
            if path.is_absolute() or ".." in path.parts or "\\" in entry.filename:
                raise ValueError("Unsafe ZIP path")
            if stat.S_ISLNK(entry.external_attr >> 16):
                raise ValueError("ZIP symlinks are not accepted")
            if entry.file_size > 100_000_000:
                raise ValueError("Oversized ZIP entry")
        binary = source.read(APP_PREFIX + "psh")
        if sha256(binary) != EXECUTABLE_SHA256:
            raise ValueError("Unsupported executable hash")
        info = plistlib.loads(source.read(APP_PREFIX + "Info.plist"))
        macho = inspect_macho(binary)
        assets = []
        payloads = {"psh": binary}
        for entry in sorted(entries, key=lambda entry: entry.filename):
            path = PurePosixPath(entry.filename)
            if not entry.filename.startswith(APP_PREFIX) or len(path.parts) != 3:
                continue
            if path.suffix.lower() not in {".png", ".wav"}:
                continue
            original = source.read(entry)
            record = {"name": path.name, "originalSHA256": sha256(original)}
            if path.suffix.lower() == ".png":
                prepared, width, height, converted = decode_cgbi(original)
                record.update({"width": width, "height": height, "convertedCgBI": converted})
            else:
                prepared = original
            record["preparedSHA256"] = sha256(prepared)
            record["bytes"] = len(prepared)
            payloads[path.name] = prepared
            assets.append(record)
    dimensions = {item["name"]: item for item in assets if "width" in item}
    textures = []
    for index, name in enumerate(TEXTURES):
        if name is None:
            continue
        width, height = dimensions[name]["width"], dimensions[name]["height"]
        padded_width = 1 << (width - 1).bit_length()
        padded_height = 1 << (height - 1).bit_length()
        textures.append({"entry": index, "name": name, "handle": index + 1,
                         "width": width, "height": height, "pixelsWide": padded_width,
                         "pixelsHigh": padded_height, "maxS": width / padded_width,
                         "maxT": height / padded_height})
    manifest = {
        "schemaVersion": 1,
        "archive": {"name": archive.name, "sha256": ARCHIVE_SHA256},
        "executable": {"name": "psh", "sha256": EXECUTABLE_SHA256, "bytes": len(binary), **macho},
        "originalApp": {key: info[key] for key in ["CFBundleIdentifier", "CFBundleDisplayName",
                                                  "CFBundleVersion", "MinimumOSVersion", "DTSDKName"]},
        "logicalViewport": {"width": 320, "height": 480, "origin": "center", "positiveY": "up"},
        "entryPoints": ENTRY_POINTS,
        "globals": {"taskManager": 0x15740, "textures": 0x15744, "game": 0x15A4C,
                    "gameManager": 0x15D54, "camera": 0x15D58, "sound": 0x15D6C},
        "textureRecordBytes": 32,
        "textureCapacity": 62,
        "textures": textures,
        "sounds": [{"entry": index, "name": name, "volume": gain, "gain": gain}
                   for index, (name, gain) in enumerate(SOUNDS)],
        "assets": assets,
        "preparation": {"cgbi": "Unfilter BGRA, unpremultiply alpha, swap to RGBA, encode standard PNG",
                        "runtimeEvidence": "Static inspection only; manifest is not gameplay verification"},
    }
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in payloads.items():
        write_if_changed(destination / name, data)
    write_if_changed(destination / "manifest.json", (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode())
    return manifest


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, default=root / ARCHIVE_NAME)
    parser.add_argument("--destination", type=Path, default=root / "Resources" / "Original")
    args = parser.parse_args()
    manifest = prepare(args.archive, args.destination)
    converted = sum(asset.get("convertedCgBI", False) for asset in manifest["assets"])
    print(f"Prepared {len(manifest['assets'])} original assets ({converted} CgBI PNGs converted), executable, and manifest in {args.destination}")


if __name__ == "__main__":
    main()
