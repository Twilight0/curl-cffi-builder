#!/usr/bin/env bash
set -euo pipefail

# Build script for cross-compiling curl_cffi on Android (arm64-v8a / armeabi-v7a / x86_64)
ABI="${1:-armeabi-v7a}"
API_LEVEL="${API_LEVEL:-21}"
NDK_VERSION="r26d"
# One wheel per CPython minor: Android links libpython by versioned SONAME, so
# abi3 tags are invalid here (see upstream setup.py bdist_wheel_abi3).
export PYTAG="${PYTAG:-cp310-cp310}"
PYMINOR="$(echo "$PYTAG" | sed -E 's/^cp([0-9])([0-9]+)t?-.*/\1.\2/')"

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

# 2. Clone curl-impersonate (pinned to v2.2.3, required by curl_cffi 0.16.4b1)
IMPERSONATE_VERSION="v2.2.3"
if [ ! -d "curl-impersonate" ]; then
    git clone --depth 1 --branch "$IMPERSONATE_VERSION" https://github.com/lexiforest/curl-impersonate.git
else
    git -C curl-impersonate fetch --depth 1 origin tag "$IMPERSONATE_VERSION" 2>/dev/null || true
    git -C curl-impersonate checkout -f "$IMPERSONATE_VERSION" 2>/dev/null || echo "WARNING: could not checkout $IMPERSONATE_VERSION, using $(git -C curl-impersonate rev-parse --short HEAD)"
fi

# Patch curl-impersonate CMakeLists.txt to pass -L${DEPS_INSTALL_DIR}/lib to linker flags if not present
if ! grep -q "CMAKE_EXE_LINKER_FLAGS=-L\${DEPS_INSTALL_DIR}/lib" curl-impersonate/CMakeLists.txt; then
    sed -i '/"-DCMAKE_CXX_FLAGS=${_curl_cxx_flags}"/a \    "-DCMAKE_EXE_LINKER_FLAGS=-L${DEPS_INSTALL_DIR}/lib"\n    "-DCMAKE_SHARED_LINKER_FLAGS=-L${DEPS_INSTALL_DIR}/lib"' curl-impersonate/CMakeLists.txt
fi

# 3. Build libcurl-impersonate from source with CMake
BUILD_DIR="build_android_${ABI}"
INSTALL_DIR="$(pwd)/installed_android_${ABI}"

CMAKE_EXTRA_ARGS=()
if [ "$ABI" = "armeabi-v7a" ]; then
    CMAKE_EXTRA_ARGS+=("-DCMAKE_ANDROID_ARM_MODE=ON")
fi

cmake -S curl-impersonate -B "$BUILD_DIR" -GNinja \
  -DCMAKE_SYSTEM_NAME=Android \
  -DCMAKE_ANDROID_NDK="$ANDROID_NDK_HOME" \
  -DCMAKE_ANDROID_ARCH_ABI="$ABI" \
  -DCMAKE_SYSTEM_VERSION="$API_LEVEL" \
  "${CMAKE_EXTRA_ARGS[@]}"

cmake --build "$BUILD_DIR" --parallel "$(nproc)"
cmake --install "$BUILD_DIR" --prefix "$INSTALL_DIR"

# 4. Clone curl_cffi repository (pinned to latest 0.16.x)
CURL_CFFI_VERSION="v0.16.4b1"
if [ ! -d "curl_cffi_src" ]; then
    git clone --depth 1 --branch "$CURL_CFFI_VERSION" https://github.com/lexiforest/curl_cffi.git curl_cffi_src
else
    git -C curl_cffi_src fetch --depth 1 origin tag "$CURL_CFFI_VERSION" 2>/dev/null || true
    git -C curl_cffi_src checkout -f "$CURL_CFFI_VERSION" 2>/dev/null || echo "WARNING: could not checkout $CURL_CFFI_VERSION, using $(git -C curl_cffi_src rev-parse --short HEAD)"
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

# Create a minimal libpython3.so stub for cross-linking the Limited API (abi3)
STUB_DIR="/tmp/pystub_${ABI}"
mkdir -p "$STUB_DIR"
cat << 'EOF' > "$STUB_DIR/pystub.c"
void PyImport_ImportModule() {}
void PyLong_FromVoidPtr() {}
void PyObject_CallMethod() {}
void _Py_Dealloc() {}
void PyArg_UnpackTuple() {}
void PyObject_Malloc() {}
void PyErr_Occurred() {}
void PyEval_SaveThread() {}
void PyEval_RestoreThread() {}
void PyLong_FromLong() {}
void PyObject_Free() {}
void* _Py_NoneStruct = 0;
EOF
$CC -shared -fPIC "$STUB_DIR/pystub.c" -Wl,-soname,libpython${PYMINOR}.so -o "$STUB_DIR/libpython3.so"

# Collect all static archives (curl-impersonate, BoringSSL, nghttp2, nghttp3, ngtcp2, brotli, zstd, zlib)
STATIC_ARCHIVES=()
for a in "$INSTALL_DIR"/lib/*.a "$BUILD_DIR"/deps/install/lib/*.a; do
    if [ -f "$a" ]; then
        STATIC_ARCHIVES+=("$a")
    fi
done
echo "Linking static archives: ${STATIC_ARCHIVES[*]}"

# Compile _wrapper.abi3.so
$CC -fPIC -shared -O3 $ARCH_FLAGS \
  -DPy_LIMITED_API=0x030A0000 \
  -I"$PY_INCLUDE_DIR" \
  -Icurl_cffi_src/include \
  -Icurl_cffi_src/ffi \
  -I"$INSTALL_DIR/include" \
  curl_cffi_src/curl_cffi/_wrapper.c \
  curl_cffi_src/ffi/shim.c \
  -lc -ldl -lm -llog \
  -L"$STUB_DIR" -lpython3 \
  -L"$INSTALL_DIR/lib" \
  -L"$BUILD_DIR/deps/install/lib" \
  -Wl,--whole-archive "${STATIC_ARCHIVES[@]}" -Wl,--no-whole-archive \
  -Wl,-Bstatic -lc++_static -lc++abi -Wl,-Bdynamic \
  -Wl,-rpath,'$ORIGIN:$ORIGIN/../../..' \
  -o curl_cffi_src/curl_cffi/_wrapper.abi3.so

$STRIP --strip-unneeded curl_cffi_src/curl_cffi/_wrapper.abi3.so
rm -rf "$STUB_DIR"
rm -f curl_cffi_src/curl_cffi/libpython3.so

# 4b. Build libffi for this ABI (shared): _cffi_backend links it, and the NDK
# sysroot ships none. Once per ABI, reused for all minors; the .so ships in
# the wheel next to the backend (see §5), found via $ORIGIN rpath.
if [ ! -f "libffi-${ABI}/lib/libffi.so" ]; then
    # Release tarball (not git): it ships a pre-generated configure, so no
    # autotools or autoconf-archive are needed on the runner.
    if [ ! -d "libffi-3.4.8" ]; then
        curl -sSL "https://github.com/libffi/libffi/releases/download/v3.4.8/libffi-3.4.8.tar.gz" -o "libffi-3.4.8.tar.gz"
        tar xzf "libffi-3.4.8.tar.gz"
    fi
    rm -rf "build-libffi-${ABI}" && mkdir -p "build-libffi-${ABI}"
    (cd "build-libffi-${ABI}" && ../libffi-3.4.8/configure --host="$TARGET_HOST" \
        --prefix="$(pwd)/../libffi-${ABI}" CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" >/dev/null 2>&1)
    make -C "build-libffi-${ABI}" -j"$(nproc)" >/dev/null 2>&1
    make -C "build-libffi-${ABI}" install >/dev/null 2>&1
fi

# 4c. Compile _cffi_backend for this ABI + Python minor from the cffi sdist.
# Kodi's embedded Python has no cffi, and PyPI ships no Android wheels, so the
# backend is cross-compiled here with the same NDK clang. _cffi_backend.c ships
# pre-generated in the sdist (src/c/): only the C compile targets Android, and
# pycparser (host-side codegen) is not needed. Python.h comes from the host
# headers with the ABI's size macros patched (same trick as §4's PY_INCLUDE_DIR
# — LP64 holds for aarch64/x86_64; armeabi-v7a gets the 32-bit treatment).
# Output goes straight into the package dir: placed next to curl_cffi it
# imports as top-level `_cffi_backend`, exactly what `import _cffi_backend`
# in curl_cffi/__init__.py asks for. libffi.so rides along beside it.
CFFI_VERSION="2.1.1"
if [ ! -f "cffi-${CFFI_VERSION}.tar.gz" ]; then
    curl -sSL "https://files.pythonhosted.org/packages/source/c/cffi/cffi-${CFFI_VERSION}.tar.gz" -o "cffi-${CFFI_VERSION}.tar.gz"
fi
rm -rf "cffi-${CFFI_VERSION}" && tar xzf "cffi-${CFFI_VERSION}.tar.gz"
FFI_INC="libffi-${ABI}/include"
"$CC" -shared -fPIC -O2 $ARCH_FLAGS \
  -I"$PY_INCLUDE_DIR" \
  -I"$FFI_INC" \
  "cffi-${CFFI_VERSION}/src/c/_cffi_backend.c" \
  -o curl_cffi_src/curl_cffi/_cffi_backend.so \
  -L"libffi-${ABI}/lib" -lffi -lc -ldl -lm -llog \
  -Wl,-rpath,'$ORIGIN'
"$STRIP" --strip-unneeded curl_cffi_src/curl_cffi/_cffi_backend.so
cp "libffi-${ABI}/lib/libffi.so" curl_cffi_src/curl_cffi/

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

VERSION = '0.16.4b1'
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
# Backend beside the package: top-level `_cffi_backend` is what
# `import _cffi_backend` in curl_cffi/__init__.py asks for.
shutil.copy('curl_cffi_src/curl_cffi/_cffi_backend.so', pkg_dir / '_cffi_backend.so')
shutil.copy('curl_cffi_src/curl_cffi/libffi.so', pkg_dir / 'libffi.so')
# Clean generated C source and link-time stub from wheel (stub must never ship:
# its \$ORIGIN rpath would shadow the real libpython on device)
if (pkg_dir / 'curl_cffi' / '_wrapper.c').exists():
    (pkg_dir / 'curl_cffi' / '_wrapper.c').unlink()
for junk in (pkg_dir / 'curl_cffi').glob('libpython3*.so*'):
    junk.unlink()

dist_info = pkg_dir / f'curl_cffi-{VERSION}.dist-info'
dist_info.mkdir(parents=True, exist_ok=True)

(dist_info / 'top_level.txt').write_text('curl_cffi\n')

PYTAG = os.environ['PYTAG']
wheel_tag = f'{PYTAG}-android_{API_LEVEL}_{TAG_ABI}'
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
Requires-Python: >=3.10
Requires-Dist: cffi>=2.0.0
Requires-Dist: certifi>=2024.2.2
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
