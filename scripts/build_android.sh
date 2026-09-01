#!/usr/bin/env bash
set -euo pipefail

# Build script for cross-compiling curl_cffi on Android (arm64-v8a / armeabi-v7a / x86_64)
ABI="${1:-armeabi-v7a}"
API_LEVEL="${API_LEVEL:-21}"
NDK_VERSION="r26d"

echo "=== Building curl_cffi for Android ($ABI) ==="

# 1. Download/Detect Android NDK
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    if [ -n "${ANDROID_NDK_LATEST_HOME:-}" ]; then
        export ANDROID_NDK_HOME="$ANDROID_NDK_LATEST_HOME"
    elif [ -d "/home/twilight/Android/Sdk/ndk/27.0.12077973" ]; then
        export ANDROID_NDK_HOME="/home/twilight/Android/Sdk/ndk/27.0.12077973"
    elif [ -d "/home/twilight/Android/Sdk/ndk/28.2.13676358" ]; then
        export ANDROID_NDK_HOME="/home/twilight/Android/Sdk/ndk/28.2.13676358"
    else
        echo "Downloading Android NDK $NDK_VERSION..."
        curl -sSL "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip" -o ndk.zip
        unzip -q ndk.zip
        export ANDROID_NDK_HOME="$(pwd)/android-ndk-${NDK_VERSION}"
    fi
fi

echo "NDK Location: $ANDROID_NDK_HOME"

TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"

if [ "$ABI" = "arm64-v8a" ]; then
    TARGET_HOST="aarch64-linux-android"
    CLANG_TARGET="aarch64-linux-android${API_LEVEL}"
    ARCH="arm64"
    ARCH_FLAGS=""
elif [ "$ABI" = "armeabi-v7a" ]; then
    TARGET_HOST="armv7a-linux-androideabi"
    CLANG_TARGET="armv7a-linux-androideabi${API_LEVEL}"
    ARCH="arm"
    ARCH_FLAGS="-march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16"
elif [ "$ABI" = "x86_64" ]; then
    TARGET_HOST="x86_64-linux-android"
    CLANG_TARGET="x86_64-linux-android${API_LEVEL}"
    ARCH="x86_64"
    ARCH_FLAGS=""
else
    echo "Unsupported ABI: $ABI"
    exit 1
fi

export CC="$TOOLCHAIN/bin/${CLANG_TARGET}-clang"
export CXX="$TOOLCHAIN/bin/${CLANG_TARGET}-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export CFLAGS="-fPIC $ARCH_FLAGS"
export CXXFLAGS="-fPIC $ARCH_FLAGS"

echo "CC: $CC"

# 2. Clone curl-impersonate if needed
if [ ! -d "curl-impersonate" ]; then
    git clone --depth 1 https://github.com/lexiforest/curl-impersonate.git
fi

# Patch curl-impersonate CMakeLists.txt to pass -L${DEPS_INSTALL_DIR}/lib to linker flags if not present
if ! grep -q "CMAKE_EXE_LINKER_FLAGS=-L\${DEPS_INSTALL_DIR}/lib" curl-impersonate/CMakeLists.txt; then
    sed -i '/"-DCMAKE_CXX_FLAGS=${_curl_cxx_flags}"/a \    "-DCMAKE_EXE_LINKER_FLAGS=-L${DEPS_INSTALL_DIR}/lib"\n    "-DCMAKE_SHARED_LINKER_FLAGS=-L${DEPS_INSTALL_DIR}/lib"' curl-impersonate/CMakeLists.txt
fi

# 3. Build libcurl-impersonate from source with CMake
BUILD_DIR="build_android_${ABI}"
INSTALL_DIR="$(pwd)/installed_android_${ABI}"

cmake -S curl-impersonate -B "$BUILD_DIR" \
  -DCMAKE_SYSTEM_NAME=Android \
  -DCMAKE_ANDROID_NDK="$ANDROID_NDK_HOME" \
  -DCMAKE_ANDROID_ARCH_ABI="$ABI" \
  -DCMAKE_SYSTEM_VERSION="$API_LEVEL" \
  -DCMAKE_ANDROID_ARM_MODE=ON

cmake --build "$BUILD_DIR" --parallel "$(nproc)"
cmake --install "$BUILD_DIR" --prefix "$INSTALL_DIR"

# 4. Clone curl_cffi repository
if [ ! -d "curl_cffi_src" ]; then
    git clone --depth 1 https://github.com/lexiforest/curl_cffi.git curl_cffi_src
fi

# Generate CFFI wrapper C file
python3 -c "
import sys
from pathlib import Path
from cffi import FFI

ffibuilder = FFI()
root_dir = Path('curl_cffi_src')
with open(root_dir / 'ffi/cdef.c') as f:
    cdef_content = f.read()
ffibuilder.cdef(cdef_content)
ffibuilder.set_source(
    'curl_cffi._wrapper',
    '#include \"shim.h\"',
    source_extension='.c'
)
ffibuilder.emit_c_code('curl_cffi_src/curl_cffi/_wrapper.c')
"

# Prepare Python include headers (ensure 32-bit config for armeabi-v7a)
PY_INCLUDE_DIR="/tmp/pyinclude_${ABI}"
rm -rf "$PY_INCLUDE_DIR"
mkdir -p "$PY_INCLUDE_DIR"

# Detect host python header directory
HOST_PY_INC="$(python3 -c 'import sysconfig; print(sysconfig.get_path("include"))')"
cp -r "$HOST_PY_INC"/* "$PY_INCLUDE_DIR/"

if [ "$ABI" = "armeabi-v7a" ]; then
    sed -i 's/#define SIZEOF_LONG 8/#define SIZEOF_LONG 4/g' "$PY_INCLUDE_DIR/pyconfig.h" 2>/dev/null || true
    sed -i 's/#define SIZEOF_VOID_P 8/#define SIZEOF_VOID_P 4/g' "$PY_INCLUDE_DIR/pyconfig.h" 2>/dev/null || true
    sed -i 's/#define SIZEOF_SIZE_T 8/#define SIZEOF_SIZE_T 4/g' "$PY_INCLUDE_DIR/pyconfig.h" 2>/dev/null || true
    sed -i 's/#define SIZEOF_PTHREAD_T 8/#define SIZEOF_PTHREAD_T 4/g' "$PY_INCLUDE_DIR/pyconfig.h" 2>/dev/null || true
    sed -i 's/#define SIZEOF_UINTPTR_T 8/#define SIZEOF_UINTPTR_T 4/g' "$PY_INCLUDE_DIR/pyconfig.h" 2>/dev/null || true
    sed -i 's/#define SIZEOF_INTPTR_T 8/#define SIZEOF_INTPTR_T 4/g' "$PY_INCLUDE_DIR/pyconfig.h" 2>/dev/null || true
    sed -i 's/#define SIZEOF_TIME_T 8/#define SIZEOF_TIME_T 4/g' "$PY_INCLUDE_DIR/pyconfig.h" 2>/dev/null || true
    sed -i 's/#define ALIGNOF_SIZE_T 8/#define ALIGNOF_SIZE_T 4/g' "$PY_INCLUDE_DIR/pyconfig.h" 2>/dev/null || true
    sed -i 's/#define ALIGNOF_MAX_ALIGN_T 16/#define ALIGNOF_MAX_ALIGN_T 8/g' "$PY_INCLUDE_DIR/pyconfig.h" 2>/dev/null || true
fi

# Compile _wrapper.abi3.so
$CC -fPIC -shared -O3 $ARCH_FLAGS \
  -DPy_LIMITED_API=0x03080000 \
  -I"$PY_INCLUDE_DIR" \
  -Icurl_cffi_src/include \
  -Icurl_cffi_src/ffi \
  -I"$INSTALL_DIR/include" \
  curl_cffi_src/curl_cffi/_wrapper.c \
  curl_cffi_src/ffi/shim.c \
  -L"$INSTALL_DIR/lib" \
  -Wl,--whole-archive "$INSTALL_DIR/lib/libcurl-impersonate.a" -Wl,--no-whole-archive \
  -lz -llog -lc++ -lm \
  -o curl_cffi_src/curl_cffi/_wrapper.abi3.so

$STRIP --strip-unneeded curl_cffi_src/curl_cffi/_wrapper.abi3.so

# 5. Assemble Wheel
DIST_DIR="$(pwd)/dist"
mkdir -p "$DIST_DIR"

python3 -c "
import os
import hashlib
import base64
import zipfile
import shutil
from pathlib import Path

VERSION = '0.6.0'
ABI = '$ABI'
API_LEVEL = '$API_LEVEL'
TAG_ABI = ABI.replace('-', '_')

SRC_DIR = Path('curl_cffi_src')
SO_FILE = SRC_DIR / 'curl_cffi' / '_wrapper.abi3.so'
OUT_DIR = Path('$DIST_DIR')

pkg_dir = OUT_DIR / f'pkg_{ABI}'
if pkg_dir.exists():
    shutil.rmtree(pkg_dir)
pkg_dir.mkdir(parents=True, exist_ok=True)

shutil.copytree(SRC_DIR / 'curl_cffi', pkg_dir / 'curl_cffi')
shutil.copy(SO_FILE, pkg_dir / 'curl_cffi' / '_wrapper.abi3.so')
# Clean generated C source from wheel
if (pkg_dir / 'curl_cffi' / '_wrapper.c').exists():
    (pkg_dir / 'curl_cffi' / '_wrapper.c').unlink()

dist_info = pkg_dir / f'curl_cffi-{VERSION}.dist-info'
dist_info.mkdir(parents=True, exist_ok=True)

(dist_info / 'top_level.txt').write_text('curl_cffi\n')

wheel_tag = f'cp38-abi3-android_{API_LEVEL}_{TAG_ABI}'
wheel_content = f'''Wheel-Version: 1.0
Generator: curl-cffi-builder (1.0)
Root-Is-Purelib: false
Tag: {wheel_tag}
'''
(dist_info / 'WHEEL').write_text(wheel_content)

metadata_content = f'''Metadata-Version: 2.1
Name: curl_cffi
Version: {VERSION}
Summary: Python binding for curl-impersonate via cffi for Android.
Author: Lexi Forest
Classifier: Programming Language :: Python :: 3
'''
(dist_info / 'METADATA').write_text(metadata_content)

records = []
wheel_name = f'curl_cffi-{VERSION}-{wheel_tag}.whl'
wheel_path = OUT_DIR / wheel_name

with zipfile.ZipFile(wheel_path, 'w', zipfile.ZIP_DEFLATED) as zf:
    for file in sorted(pkg_dir.rglob('*')):
        if file.is_file():
            rel_path = file.relative_to(pkg_dir)
            zf.write(file, rel_path)
            content = file.read_bytes()
            digest = hashlib.sha256(content).digest()
            b64_hash = 'sha256=' + base64.urlsafe_b64encode(digest).decode('ascii').rstrip('=')
            records.append(f'{rel_path},{b64_hash},{len(content)}')
    
    rec_rel_path = f'curl_cffi-{VERSION}.dist-info/RECORD'
    rec_content = '\n'.join(records) + f'\n{rec_rel_path},,\n'
    zf.writestr(rec_rel_path, rec_content)

shutil.rmtree(pkg_dir)
print(f'=== Android ({ABI}) wheel built successfully: {wheel_path} ===')
"
