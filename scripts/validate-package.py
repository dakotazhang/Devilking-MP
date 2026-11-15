#!/usr/bin/env python3
"""Validate source privacy settings and the actual device IPA, without dependencies."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = "top.devilkkkkk1.DevilkingMP"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def check_plist(info: dict, built: bool) -> None:
    ats = info.get("NSAppTransportSecurity", {})
    require(ats.get("NSAllowsArbitraryLoads") is False, "Broad ATS HTTP exemption is forbidden")
    require(ats.get("NSAllowsLocalNetworking") is True, "LAN networking declaration is missing")
    require(bool(info.get("NSLocalNetworkUsageDescription")), "Missing LAN privacy description")
    require(bool(info.get("NSFaceIDUsageDescription")), "Missing Face ID privacy description")
    require(not info.get("UIBackgroundModes"), "No background execution modes should be requested")
    require(not info.get("UIFileSharingEnabled", False), "Private configuration must not be exposed through file sharing")
    if built:
        require(info.get("CFBundleIdentifier") == BUNDLE_ID, "Unexpected bundle identifier")
        require(info.get("MinimumOSVersion") == "16.1", "IPA must preserve the iOS 16.1 minimum")
        require(info.get("CFBundlePackageType") == "APPL", "Not an iOS app bundle")


def check_macho(data: bytes) -> dict:
    require(len(data) >= 32, "Device executable is truncated")
    magic, cpu, _, _, commands, command_bytes, _, _ = struct.unpack_from("<8I", data)
    require(magic == 0xFEEDFACF, "Expected a thin 64-bit device Mach-O")
    require(cpu == 0x0100000C, "IPA executable must be arm64")
    require(32 + command_bytes <= len(data), "Malformed Mach-O load commands")
    offset = 32
    platform = None
    minimum = None
    for _ in range(commands):
        require(offset + 8 <= len(data), "Truncated Mach-O command")
        command, size = struct.unpack_from("<II", data, offset)
        require(size >= 8 and offset + size <= len(data), "Invalid Mach-O command size")
        if command == 0x32:
            require(size >= 24, "Invalid LC_BUILD_VERSION")
            platform, packed = struct.unpack_from("<II", data, offset + 8)
            minimum = f"{packed >> 16}.{(packed >> 8) & 255}.{packed & 255}"
        elif command == 0x25:
            packed = struct.unpack_from("<I", data, offset + 8)[0]
            platform = 2
            minimum = f"{packed >> 16}.{(packed >> 8) & 255}.{packed & 255}"
        offset += size
    require(platform == 2, "Executable is not built for an iOS device")
    require(minimum == "16.1.0", "Executable minimum iOS differs from 16.1")
    return {"architecture": "arm64", "platform": "iOS device", "minimum_ios_macho": minimum}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    source_info = plistlib.loads((ROOT / "ios/DevilkingMP/Info.plist").read_bytes())
    check_plist(source_info, built=False)
    project = (ROOT / "ios/project.yml").read_text(encoding="utf-8")
    require(BUNDLE_ID in project and '"16.1"' in project, "Project deployment settings are incomplete")
    require("CODE_SIGN_ENTITLEMENTS" not in project, "Unexpected signing entitlements")
    require((ROOT / "tests/CoreTests.swift").is_file(), "API contract tests are missing")
    require((ROOT / "tests/UITests.swift").is_file(), "Native UI navigation tests are missing")
    swift_sources = list((ROOT / "ios/DevilkingMP").rglob("*.swift"))
    require(any("class AppModel" in p.read_text(encoding="utf-8") for p in swift_sources), "Application core is missing")
    require(any("struct RootView" in p.read_text(encoding="utf-8") for p in swift_sources), "Application views are missing")
    result = {"source_validation": "passed", "package_validation": "not requested"}

    if args.ipa:
        require(args.ipa.is_file(), "IPA was not created")
        with zipfile.ZipFile(args.ipa) as archive:
            names = archive.namelist()
            prefix = "Payload/DevilkingMP.app/"
            require(prefix + "Info.plist" in names, "IPA app Info.plist missing")
            for name in names:
                require(name.startswith("Payload/"), "Unexpected content outside Payload")
                require(".." not in Path(name).parts, "Archive path traversal")
                require(not name.lower().endswith((".p12", ".pem", ".key", ".devilking.json", ".mobileprovision")), "Private signing or configuration material in unsigned IPA")
            info = plistlib.loads(archive.read(prefix + "Info.plist"))
            check_plist(info, built=True)
            executable = info.get("CFBundleExecutable")
            require(executable == "DevilkingMP", "Unexpected device executable")
            macho = check_macho(archive.read(prefix + executable))
        result.update({
            "package_validation": "passed",
            "sha256": hashlib.sha256(args.ipa.read_bytes()).hexdigest(),
            "bytes": args.ipa.stat().st_size,
            "bundle_identifier": info["CFBundleIdentifier"],
            "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"),
            "signed": False,
            "physical_device_verified": False,
            **macho,
        })
    encoded = json.dumps(result, indent=2, ensure_ascii=False)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded + "\n", encoding="utf-8")
    print(encoded)


if __name__ == "__main__":
    main()
