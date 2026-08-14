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
        if '64' in machine or 'aarch64' in machine:
            return 'android_arm64-v8a'
        return 'android_armeabi-v7a'
    elif 'win' in sys_name:
        return 'windows_x64'
    elif 'linux' in sys_name:
        if 'aarch64' in machine or 'arm64' in machine or 'arm' in machine:
            return 'linux_aarch64'
        return 'linux_x86_64'
    elif 'darwin' in sys_name or 'mac' in sys_name:
        return 'macos_arm64'
    return None

_current_dir = os.path.dirname(os.path.abspath(__file__))
_arch_dir = _detect_platform_dir()

if _arch_dir:
    _target_path = os.path.join(_current_dir, _arch_dir)
    if os.path.exists(_target_path) and _target_path not in sys.path:
        sys.path.insert(0, _target_path)
