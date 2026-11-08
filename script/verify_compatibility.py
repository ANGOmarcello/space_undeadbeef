#!/usr/bin/env python3
"""Local compatibility checks; no physical-device discovery or installation.

Created by Angelo Cammalleri on 27.10.2026.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
PLATFORMS = {
    "iOS": "generic/platform=iOS Simulator",
    "macOS": "platform=macOS",
    "tvOS": "generic/platform=tvOS Simulator",
    "watchOS": "generic/platform=watchOS Simulator",
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--tests-only", action="store_true", help="Run isolated headless correctness suites.")
    mode.add_argument("--builds-only", action="store_true", help="Build unsigned app targets; do not launch apps.")
    parser.add_argument("--platforms", nargs="+", choices=PLATFORMS, default=list(PLATFORMS))
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
    parser.add_argument("--require-gpu", action="store_true", help="Treat skipped actual-GPU checks as failures.")
    parser.add_argument("--ui", nargs="+", choices=["iphone", "ipad", "tvos"],
                        help="Opt in to original UI tests on already-booted simulators only.")
    parser.add_argument("--iphone-simulator", help="Explicit latest regular iPhone Pro Simulator UDID.")
    parser.add_argument("--ipad-simulator", help="Explicit iPad Simulator UDID.")
    parser.add_argument("--tvos-simulator", help="Explicit Apple TV Simulator UDID; physical TVs are never queried.")
    args = parser.parse_args()
    results: list[tuple[str, str]] = []
    products = Path.home() / "Library/Developer/Xcode/DerivedData"

    def record(status: str, label: str, detail: str = "") -> None:
        results.append((status, label))
        print(f"{status} {label}" + (f": {detail}" if detail else ""), flush=True)

    with tempfile.TemporaryDirectory(prefix="space-undeadbeef-compatibility.", dir="/private/tmp") as temporary:
        scratch = Path(temporary)

        def run(label: str, command: list[str], *, gpu_check: bool = False) -> bool:
            log = scratch / (re.sub(r"[^a-zA-Z0-9_-]", "-", label) + ".log")
            with log.open("wb") as output:
                try:
                    completed = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, check=False)
                except OSError as error:
                    record("FAIL", label, str(error))
                    return False
            text = log.read_text(errors="replace")
            skipped = completed.returncode == 77 or (gpu_check and "SKIP" in text)
            if completed.returncode and completed.returncode != 77:
                record("FAIL", label, f"exit {completed.returncode}")
                print("\n".join(text.splitlines()[-45:]), flush=True)
                return False
            if skipped:
                status = "FAIL" if gpu_check and args.require_gpu else "SKIP"
                record(status, label, "; ".join(line for line in text.splitlines() if "SKIP" in line) or "service unavailable")
                return status != "FAIL"
            record("PASS", label)
            # Test summaries carry useful evidence without dumping build output.
            if command[0].endswith(".sh"):
                for line in text.splitlines()[-4:]:
                    print(f"  {line}", flush=True)
            return True

        def verify_resources() -> None:
            try:
                resources = ROOT / "Resources/Original"
                manifest = json.loads((resources / "manifest.json").read_text())
                for item in manifest["assets"]:
                    path = resources / item["name"]
                    if path.parent != resources or hashlib.sha256(path.read_bytes()).hexdigest() != item["preparedSHA256"]:
                        raise ValueError(f"prepared original mismatch: {item['name']}")
                executable = manifest["executable"]
                if hashlib.sha256((resources / executable["name"]).read_bytes()).hexdigest() != executable["sha256"]:
                    raise ValueError("original executable hash mismatch")
                record("PASS", "prepared original hashes", f"{len(manifest['assets'])} assets and guest executable; no IPA needed")
            except (OSError, ValueError, KeyError) as error:
                record("FAIL", "prepared original hashes", str(error))

        verify_resources()
        if not args.builds_only:
            suites = [
                ("runtime", []), ("frame_timing", []), ("haptics_policy", []),
                ("audio", []), ("draw_assembly", []), ("watch_controls", []),
                ("crown_input", []), ("haptics", []), ("rendering", []),
                ("performance_equivalence", ["watch"]), ("performance_equivalence", ["metal"]),
            ]
            # These independently test host lifecycle/controller policy and
            # isolated persistence. Missing expected suites are failures.
            for suite in ["lifecycle_policy", "native_controls_policy", "haptic_attachment", "engine_audio_gate", "save_store", "save_coordinator", "menu_actions",
                          "session_lifecycle", "progress_sync", "folder_progress", "memory_soak", "scenario_resume"]:
                suites.append((suite, []))
            for suite, arguments in suites:
                label = "test " + suite + (" " + " ".join(arguments) if arguments else "")
                run(label, [str(ROOT / f"script/test_{suite}.sh"), *arguments],
                    gpu_check=suite == "rendering" or arguments == ["metal"])

        def build_directory(name: str) -> Path:
            return products / f"SpaceUndeadbeef-Compatibility-{name}"

        def protected_build(label: str, platform: str, command: list[str]) -> bool:
            directory = build_directory(platform)
            directory.mkdir(parents=True, exist_ok=True)
            with (directory / ".compatibility.lock").open("w") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    record("FAIL", label, "this compatibility build directory is already in use")
                    return False
                # Never replace a product from which an app is still running.
                processes = subprocess.run(["/bin/ps", "-axo", "comm="], text=True, capture_output=True, check=False)
                if processes.returncode:
                    record("FAIL", label, "cannot verify that this build product is idle")
                    return False
                if any(line.strip().startswith(str(directory) + "/") for line in processes.stdout.splitlines()):
                    record("FAIL", label, "an app from this build directory is running; it was left untouched")
                    return False
                return run(label, command)

        def build_command(platform: str, destination: str) -> list[str]:
            return ["xcodebuild", "-quiet", "-project", str(ROOT / "SPACE UNDEADBEEF.xcodeproj"),
                    "-scheme", f"SPACE UNDEADBEEF {platform}", "-configuration", args.configuration,
                    "-destination", destination, "-destination-timeout", "20", "-jobs", "2",
                    "-derivedDataPath", str(build_directory(platform)), "CODE_SIGNING_ALLOWED=NO"]

        if not args.tests_only:
            for platform in dict.fromkeys(args.platforms):
                if not protected_build(f"build {platform}", platform, build_command(platform, PLATFORMS[platform]) + ["build"]):
                    continue
                product_name = args.configuration + {"iOS": "-iphonesimulator", "tvOS": "-appletvsimulator",
                                                     "watchOS": "-watchsimulator", "macOS": ""}[platform]
                bundle = build_directory(platform) / "Build/Products" / product_name / "SpaceUndeadbeef.app"
                try:
                    plist = plistlib.loads((bundle / ("Contents/Info.plist" if platform == "macOS" else "Info.plist")).read_bytes())
                    if platform != "watchOS":
                        library = bundle / ("Contents/Resources/default.metallib" if platform == "macOS" else "default.metallib")
                        if not library.is_file() or library.stat().st_size == 0:
                            raise ValueError("compiled default.metallib missing from app bundle")
                    record("PASS", f"bundle {platform}", f"{plist['CFBundleShortVersionString']} ({plist['CFBundleVersion']})")
                except (OSError, ValueError, KeyError) as error:
                    record("FAIL", f"bundle {platform}", str(error))

        if not args.ui:
            record("SKIP", "simulator UI", "opt in with --ui; no simulators or physical devices were launched")
        else:
            try:
                inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"], text=True))
            except (subprocess.SubprocessError, OSError, ValueError) as error:
                record("FAIL", "simulator UI inventory", str(error))
                inventory = {"devices": {}}
            devices = [(runtime, device) for runtime, entries in inventory["devices"].items() for device in entries]
            for kind in dict.fromkeys(args.ui):
                platform = "tvOS" if kind == "tvos" else "iOS"
                pattern = {"iphone": r"iPhone (\d+) Pro", "ipad": r"iPad.*", "tvos": r"Apple TV.*"}[kind]
                matches = [(runtime, device) for runtime, device in devices
                           if f".{platform}-" in runtime and re.fullmatch(pattern, device["name"])]
                def priority(item: tuple[str, dict]) -> tuple:
                    runtime, device = item
                    return tuple(int(n) for n in re.findall(r"\d+", runtime)), tuple(int(n) for n in re.findall(r"\d+", device["name"]))
                matches.sort(key=priority, reverse=True)
                requested = getattr(args, f"{kind}_simulator")
                selected = next((item for item in matches if item[1]["udid"] == requested), None) if requested else (matches[0] if matches else None)
                if not selected or (kind == "iphone" and priority(selected) != priority(matches[0])):
                    record("FAIL", f"UI {kind}", "requested simulator unavailable; iPhone checks require the newest regular Pro")
                    continue
                if selected[1]["state"] != "Booted":
                    record("FAIL", f"UI {kind}", f"{selected[1]['name']} is not booted; no simulator was started or stopped")
                    continue
                identifier = selected[1]["udid"]
                destination = f"platform={platform} Simulator,id={identifier}"
                command = build_command(platform, destination) + ["-parallel-testing-enabled", "NO",
                    "-resultBundlePath", str(scratch / f"{kind}.xcresult"),
                    f"-only-testing:SPACE UNDEADBEEF {platform} UITests/HostUITests/testOriginalGameInteraction"]
                if platform == "iOS":
                    command += [f"-only-testing:SPACE UNDEADBEEF iOS UITests/HostUITests/{test}"
                                for test in ["testAccessibleOriginalMenus", "testSaveFailureRemainsPlayable"]]
                if kind == "iphone":
                    command += [f"-only-testing:SPACE UNDEADBEEF iOS UITests/HostUITests/{test}"
                                for test in ["testHapticHostWithMetal", "testHapticHostWithSoftware"]]
                command += ["test"]
                protected_build(f"UI {kind} {identifier}", platform, command)

    counts = {status: sum(item[0] == status for item in results) for status in ["PASS", "FAIL", "SKIP"]}
    print("Compatibility summary: " + ", ".join(f"{status} {count}" for status, count in counts.items()), flush=True)
    print("Unsigned builds/headless checks are not physical-device performance or distribution proof.", flush=True)
    return 1 if counts["FAIL"] else 0


if __name__ == "__main__":
    sys.exit(main())
