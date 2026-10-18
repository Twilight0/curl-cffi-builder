#!/usr/bin/env python3
"""
    Build script to assemble multi-architecture Kodi module addon (script.module.curlcffi)
"""
import os
import re
import shutil
import sys
import zipfile
from pathlib import Path

VERSION = "0.16.4b1"
BASE_DIR = Path(__file__).resolve().parent.parent
TEMPLATE_DIR = BASE_DIR / "kodi_addon_template"
BUILD_DIR = BASE_DIR / "build_kodi" / "script.module.curlcffi"
DIST_DIR = BASE_DIR / "dist"

PLATFORM_MAPPING = {
    "win_amd64": "windows_x64",
    "win32": "windows_x86",
    "manylinux_2_17_x86_64": "linux_x86_64",
    "manylinux_2_17_aarch64": "linux_aarch64",
    "manylinux_2_17_armv7l": "linux_armv7l",
    "manylinux2014_armv7l": "linux_armv7l",
    "linux_armv7l": "linux_armv7l",
    "android_24_arm64_v8a": "android_arm64-v8a",

    "android_arm64_v8a": "android_arm64-v8a",
    "android_21_arm64_v8a": "android_arm64-v8a",
    "android_armeabi_v7a": "android_armeabi-v7a",
    "android_21_armeabi_v7a": "android_armeabi-v7a",
    "android_21_x86_64": "android_x86_64",
    "android_x86_64": "android_x86_64",
    "ios_14_0_arm64_iphoneos": "ios_arm64",
    "iphoneos": "ios_arm64",
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
        whl_path_str = str(whl)
        print(f"Processing wheel: {whl.name} ({whl_path_str})")
        
        target_platform = "unknown"
        for key, target in PLATFORM_MAPPING.items():
            if key in whl_path_str:
                target_platform = target
                break

        if target_platform == "unknown":
            if "arm64-v8a" in whl_path_str or "arm64_v8a" in whl_path_str:
                target_platform = "android_arm64-v8a"
            elif "armeabi-v7a" in whl_path_str or "armeabi_v7a" in whl_path_str:
                target_platform = "android_armeabi-v7a"
            elif "android" in whl_path_str and "x86_64" in whl_path_str:
                target_platform = "android_x86_64"
            elif "macosx" in whl_path_str:
                target_platform = "macos_arm64"
            elif "win" in whl_path_str:
                target_platform = "windows_x64"
            elif "armv7" in whl_path_str or "armhf" in whl_path_str:
                target_platform = "linux_armv7l"
            elif "aarch64" in whl_path_str or "arm64" in whl_path_str:
                target_platform = "linux_aarch64"
            else:
                target_platform = "linux_x86_64"


        # Per-minor wheels (Android/iOS link libpython by versioned SONAME) go
        # into lib/<platform>/<pytag>/ so one addon covers 3.10..3.14 (floor
        # is upstream requires-python >=3.10, so no cp38/cp39). Universal
        # abi3 wheels (desktop) extract flat into lib/<platform>/.
        pytag = _wheel_pytag(whl.name)
        if pytag is None:
            target_lib_dir = BUILD_DIR / "lib" / target_platform
        else:
            target_lib_dir = BUILD_DIR / "lib" / target_platform / pytag
        target_lib_dir.mkdir(parents=True, exist_ok=True)

        with zipfile.ZipFile(whl, 'r') as zip_ref:
            for member in zip_ref.namelist():
                if member.startswith(("curl_cffi/", "curl_cffi-",
                                       "_cffi_backend.", "cffi/")):
                    zip_ref.extract(member, target_lib_dir)

        print(f"Extracted {whl.name} -> lib/{target_lib_dir.relative_to(BUILD_DIR / 'lib')}/")

    # 2b. Vendor the cffi backend next to each curl_cffi copy. Upstream wheels
    # declare Requires-Dist: cffi, fulfilled by pip at build time and never
    # shipped - but Kodi's embedded Python has no cffi, so `import _cffi_backend`
    # (line 52 of curl_cffi/__init__.py) dies everywhere the host cannot
    # provide it. Desktop backends come from PyPI wheels; Android/iOS have no
    # PyPI tags, so those are cross-compiled from sdist with the NDK below.
    _vendor_cffi_backends()


    # 3. Create ZIP archive for Kodi addon
    output_zip = DIST_DIR / f"script.module.curlcffi-{VERSION}.zip"
    print(f"Creating Kodi addon zip archive: {output_zip}")
    
    with zipfile.ZipFile(output_zip, 'w', zipfile.ZIP_DEFLATED) as zip_out:
        for file in BUILD_DIR.rglob('*'):
            arcname = Path("script.module.curlcffi") / file.relative_to(BUILD_DIR)
            zip_out.write(file, arcname)

    print(f"=== Successfully generated Kodi Addon Zip: {output_zip} ===")


def _wheel_pytag(filename):
    """Return e.g. 'cp311' for per-minor wheels, None for universal abi3 ones."""
    parts = filename.split('-')
    for i, part in enumerate(parts):
        if re.fullmatch(r'cp\d+t?', part):
            nxt = parts[i + 1] if i + 1 < len(parts) else ''
            if nxt == 'abi3' or part == 'abi3':
                return None
            return part
    return None


# The cffi version whose backend is vendored. Must satisfy the
# Requires-Dist the curl_cffi wheels declare (cffi>=2.0.0).
CFFI_VERSION = "2.1.1"

# Desktop platforms whose _cffi_backend comes from PyPI wheels (no compiler
# needed): (addon dir, pip platform tag, abi). One entry per CPython minor is
# fetched at assemble time; the .so lands next to that platform's curl_cffi.
CFFI_DESKTOP_PLATFORMS = [
    ("linux_x86_64", "manylinux_2_17_x86_64", "cp"),
    ("linux_aarch64", "manylinux_2_17_aarch64", "cp"),
    ("linux_armv7l", "manylinux_2_17_armv7l", "cp"),
    ("windows_x64", "win_amd64", "cp"),
    ("macos_arm64", "macosx_11_0_arm64", "cp"),
]

CFFI_MINORS = ["cp310", "cp311", "cp312", "cp313", "cp314"]


def _vendor_cffi_backends():
    """Vendor _cffi_backend next to every assembled curl_cffi copy.

    Desktop: download the matching cffi wheel from PyPI per platform per
    CPython minor and extract the backend .so plus the pure-python cffi/
    package. Android/iOS: the backend .so was cross-compiled into the wheel
    by build_android.sh / build_ios.sh, so nothing to do - just verify.
    """
    import subprocess
    import tempfile

    lib_dir = BUILD_DIR / "lib"

    for plat, pip_plat, abi in CFFI_DESKTOP_PLATFORMS:
        for pytag in CFFI_MINORS:
            dest = lib_dir / plat
            if not (dest / "curl_cffi").is_dir():
                continue
            # Desktop layout is flat (no per-minor subdirs), but the backend
            # filename carries the minor (cpython-311-...), so one dir holds
            # all five. Skip only when THIS minor is already present.
            if list(dest.glob("_cffi_backend.*%s*" % pytag)) or (dest / "_cffi_backend.so").is_file():
                continue
            with tempfile.TemporaryDirectory() as tmp:
                try:
                    subprocess.run(
                        [sys.executable, "-m", "pip", "download", "cffi==%s" % CFFI_VERSION,
                         "--no-deps", "--only-binary=:all:",
                         "--platform", pip_plat,
                         "--python-version", pytag[2:],
                         "--abi", pytag,
                         "-d", tmp],
                        check=True, capture_output=True, text=True,
                    )
                except subprocess.CalledProcessError as e:
                    print(f"WARNING: no cffi wheel for {plat}/{pytag}: {e.stderr.strip().splitlines()[-1] if e.stderr else e}")
                    continue
                wheels = list(Path(tmp).glob("cffi-*.whl"))
                if not wheels:
                    print(f"WARNING: no cffi wheel downloaded for {plat}/{pytag}")
                    continue
                with zipfile.ZipFile(wheels[0], 'r') as z:
                    for member in z.namelist():
                        if member.startswith("_cffi_backend.") or member.startswith("cffi/"):
                            z.extract(member, dest)
                print(f"Vendored cffi backend -> lib/{plat}/ ({pytag})")

    for plat in ("android_arm64-v8a", "android_armeabi-v7a", "android_x86_64", "ios_arm64"):
        base = lib_dir / plat
        if not base.is_dir():
            continue
        for pytag in CFFI_MINORS:
            sub = base / pytag
            if not (sub / "curl_cffi").is_dir():
                continue
            if not (sub / "_cffi_backend.so").is_file() and not list(sub.glob("_cffi_backend.*.so")):
                print(f"WARNING: {plat}/{pytag} has no _cffi_backend.so (rebuild the wheel with build_android.sh/build_ios.sh)")
if __name__ == "__main__":
    assemble_kodi_addon()
