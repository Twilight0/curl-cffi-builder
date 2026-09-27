"""
    script.module.curlcffi
    Dynamic multi-platform loader for curl_cffi native binaries in Kodi
"""
import sys
import os
import platform

def _detect_platform_dir():
    try:
        import xbmc
        is_android = xbmc.getCondVisibility('System.Platform.Android')
    except ImportError:
        is_android = 'android' in platform.platform().lower()

    sys_name = platform.system().lower()
    machine = platform.machine().lower()

    if is_android:
        # NOTE: check x86_64 before the generic '64' substring — 'x86_64'
        # contains '64' but must map to android_x86_64, not arm64.
        if 'x86_64' in machine or 'amd64' in machine:
            return 'android_x86_64'
        if 'aarch64' in machine or 'arm64' in machine or 'armv8' in machine:
            return 'android_arm64-v8a'
        return 'android_armeabi-v7a'
    elif 'darwin' in sys_name or 'mac' in sys_name:
        # NOTE: checked before 'win' — 'darwin' contains the substring 'win'.
        return 'macos_arm64'
    elif 'win' in sys_name:
        return 'windows_x64'
    elif 'linux' in sys_name:
        if 'aarch64' in machine or 'arm64' in machine or 'armv8' in machine:
            return 'linux_aarch64'
        elif 'arm' in machine:  # armv7l, armv6l, armhf
            return 'linux_armv7l'
        return 'linux_x86_64'
    return None


def _pick_tagged_dir(base, tag=None):
    """Pick lib/<platform>/<pytag>/ matching this interpreter, else base.

    Per-minor wheels (Android/iOS link libpython by versioned SONAME) go
    into lib/<platform>/<pytag>/ so one addon covers 3.10..3.14. Universal
    abi3 wheels (desktop) extract flat into lib/<platform>/.
    """
    if tag is None:
        tag = "cp%d%d" % (sys.version_info.major, sys.version_info.minor)
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return base
    for name in names:
        if name.startswith(tag) and os.path.isdir(os.path.join(base, name)):
            return os.path.join(base, name)
    return base

_current_dir = os.path.dirname(os.path.abspath(__file__))
_arch_dir = _detect_platform_dir()

if _arch_dir:
    _target_path = _pick_tagged_dir(os.path.join(_current_dir, _arch_dir))
    if os.path.exists(_target_path) and _target_path not in sys.path:
        sys.path.insert(0, _target_path)
