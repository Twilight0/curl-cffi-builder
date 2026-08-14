#!/usr/bin/env python3
"""
    Build script to assemble multi-architecture Kodi module addon (script.module.curlcffi)
"""
import os
import shutil
import zipfile
from pathlib import Path

VERSION = "0.6.0"
BASE_DIR = Path(__file__).resolve().parent.parent
TEMPLATE_DIR = BASE_DIR / "kodi_addon_template"
BUILD_DIR = BASE_DIR / "build_kodi" / "script.module.curlcffi"
DIST_DIR = BASE_DIR / "dist"

PLATFORM_MAPPING = {
    "win_amd64": "windows_x64",
    "win32": "windows_x86",
    "manylinux_2_17_x86_64": "linux_x86_64",
    "manylinux2014_x86_64": "linux_x86_64",
    "manylinux_2_17_aarch64": "linux_aarch64",
    "android_24_arm64_v8a": "android_arm64-v8a",
    "android_arm64_v8a": "android_arm64-v8a",
    "android_armeabi_v7a": "android_armeabi-v7a",
    "macosx_11_0_arm64": "macos_arm64",
    "macosx_10_9_universal2": "macos_arm64",
}

def assemble_kodi_addon():
    print("=== Assembling Kodi Binary Module Addon: script.module.curlcffi ===")
    
    if BUILD_DIR.exists():
        shutil.rmtree(BUILD_DIR)
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    DIST_DIR.mkdir(parents=True, exist_ok=True)

    # 1. Copy template files
    shutil.copytree(TEMPLATE_DIR / "lib", BUILD_DIR / "lib", dirs_exist_ok=True)
    shutil.copy(TEMPLATE_DIR / "addon.xml", BUILD_DIR / "addon.xml")

    # 2. Extract wheel packages into respective platform directories
    wheel_files = list(BASE_DIR.glob("**/*.whl"))
    print(f"Found {len(wheel_files)} wheels to process...")

    for whl in wheel_files:
        whl_name = whl.name
        print(f"Processing wheel: {whl_name}")
        
        target_platform = "unknown"
        for key, target in PLATFORM_MAPPING.items():
            if key in whl_name:
                target_platform = target
                break

        if target_platform == "unknown":
            if "android" in whl_name:
                target_platform = "android_arm64-v8a"
            elif "macosx" in whl_name:
                target_platform = "macos_arm64"
            elif "win" in whl_name:
                target_platform = "windows_x64"
            else:
                target_platform = "linux_x86_64"

        target_lib_dir = BUILD_DIR / "lib" / target_platform
        target_lib_dir.mkdir(parents=True, exist_ok=True)

        with zipfile.ZipFile(whl, 'r') as zip_ref:
            for member in zip_ref.namelist():
                if member.startswith(("curl_cffi/", "curl_cffi-")):
                    zip_ref.extract(member, target_lib_dir)

        print(f"Extracted {whl_name} -> lib/{target_platform}/")

    # 3. Create ZIP archive for Kodi addon
    output_zip = DIST_DIR / f"script.module.curlcffi-{VERSION}.zip"
    print(f"Creating Kodi addon zip archive: {output_zip}")
    
    with zipfile.ZipFile(output_zip, 'w', zipfile.ZIP_DEFLATED) as zip_out:
        for file in BUILD_DIR.rglob('*'):
            arcname = Path("script.module.curlcffi") / file.relative_to(BUILD_DIR)
            zip_out.write(file, arcname)

    print(f"=== Successfully generated Kodi Addon Zip: {output_zip} ===")

if __name__ == "__main__":
    assemble_kodi_addon()
