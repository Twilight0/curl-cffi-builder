#!/usr/bin/env bash
set -euo pipefail

echo "=== Cross-compiling curl_cffi for Linux ARM 32-bit (armv7l / armhf) ==="

sudo apt-get update && sudo apt-get install -y gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf ninja-build cmake python3-pip

export CC="arm-linux-gnueabihf-gcc"
export CXX="arm-linux-gnueabihf-g++"
export AR="arm-linux-gnueabihf-ar"
export RANLIB="arm-linux-gnueabihf-ranlib"
export STRIP="arm-linux-gnueabihf-strip"
export CFLAGS="-fPIC -march=armv7-a -mfpu=neon -mfloat-abi=hard"
export CXXFLAGS="-fPIC -march=armv7-a -mfpu=neon -mfloat-abi=hard"

IMPERSONATE_VERSION="v2.2.3"
if [ ! -d "curl-impersonate" ]; then
    git clone --depth 1 --branch "$IMPERSONATE_VERSION" https://github.com/lexiforest/curl-impersonate.git
fi

# Patch curl-impersonate CMakeLists.txt to pass -L${DEPS_INSTALL_DIR}/lib to linker flags if not present
if ! grep -q "CMAKE_EXE_LINKER_FLAGS=-L\${DEPS_INSTALL_DIR}/lib" curl-impersonate/CMakeLists.txt; then
    sed -i '/"-DCMAKE_CXX_FLAGS=${_curl_cxx_flags}"/a \    "-DCMAKE_EXE_LINKER_FLAGS=-L${DEPS_INSTALL_DIR}/lib"\n    "-DCMAKE_SHARED_LINKER_FLAGS=-L${DEPS_INSTALL_DIR}/lib"' curl-impersonate/CMakeLists.txt
fi

BUILD_DIR="build_linux_armv7l"
INSTALL_DIR="$(pwd)/installed_linux_armv7l"
rm -rf "$BUILD_DIR" "$INSTALL_DIR"
mkdir -p "$BUILD_DIR" "$INSTALL_DIR"

cmake -S curl-impersonate -B "$BUILD_DIR" -GNinja \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=armv7l \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
  -DUSE_LIBIDN2=OFF

cmake --build "$BUILD_DIR" --parallel "$(nproc)"
cmake --install "$BUILD_DIR"

CURL_CFFI_VERSION="v0.16.4b1"
if [ ! -d "curl_cffi_src" ]; then
    git clone --depth 1 --branch "$CURL_CFFI_VERSION" https://github.com/lexiforest/curl_cffi.git curl_cffi_src
fi

python3 -c "
from cffi import FFI
from pathlib import Path
ffibuilder = FFI()
with open('curl_cffi_src/ffi/cdef.c') as f:
    ffibuilder.cdef(f.read())
ffibuilder.set_source('curl_cffi._wrapper', '#include \"shim.h\"', source_extension='.c')
ffibuilder.emit_c_code('curl_cffi_src/curl_cffi/_wrapper.c')
"

PY_INCLUDE_DIR="/tmp/pyinclude_armv7l"
rm -rf "$PY_INCLUDE_DIR"
mkdir -p "$PY_INCLUDE_DIR"
HOST_PY_INC="$(python3 -c 'import sysconfig; print(sysconfig.get_path("include"))')"
cp -r "$HOST_PY_INC"/* "$PY_INCLUDE_DIR/"
sed -i 's/#define SIZEOF_LONG 8/#define SIZEOF_LONG 4/g' "$PY_INCLUDE_DIR/pyconfig.h" 2>/dev/null || true
sed -i 's/#define SIZEOF_VOID_P 8/#define SIZEOF_VOID_P 4/g' "$PY_INCLUDE_DIR/pyconfig.h" 2>/dev/null || true
sed -i 's/#define SIZEOF_SIZE_T 8/#define SIZEOF_SIZE_T 4/g' "$PY_INCLUDE_DIR/pyconfig.h" 2>/dev/null || true

STATIC_ARCHIVES=()
for a in "$INSTALL_DIR"/lib/*.a "$BUILD_DIR"/deps/install/lib/*.a; do
    if [ -f "$a" ]; then
        STATIC_ARCHIVES+=("$a")
    fi
done

$CC -fPIC -shared -O3 $CFLAGS \
  -DPy_LIMITED_API=0x030A0000 \
  -I"$PY_INCLUDE_DIR" \
  -Icurl_cffi_src/include \
  -Icurl_cffi_src/ffi \
  -I"$INSTALL_DIR/include" \
  curl_cffi_src/curl_cffi/_wrapper.c \
  curl_cffi_src/ffi/shim.c \
  -L"$INSTALL_DIR/lib" \
  -Wl,--whole-archive "${STATIC_ARCHIVES[@]}" -Wl,--no-whole-archive \
  -lc -ldl -lm -lrt -lpthread \
  -Wl,-rpath,'$ORIGIN' \
  -o curl_cffi_src/curl_cffi/_wrapper.abi3.so

$STRIP --strip-unneeded curl_cffi_src/curl_cffi/_wrapper.abi3.so

# Build libffi for armv7l (shared): _cffi_backend links it and the cross
# sysroot has none. Once, reused for all minors; the .so ships in each wheel
# next to the backend (see below), found via $ORIGIN rpath.
if [ ! -f "libffi-armv7l/lib/libffi.so" ]; then
    # Release tarball (not git): it ships a pre-generated configure, so no
    # autotools or autoconf-archive are needed on the runner.
    if [ ! -d "libffi-3.4.8" ]; then
        curl -sSL "https://github.com/libffi/libffi/releases/download/v3.4.8/libffi-3.4.8.tar.gz" -o "libffi-3.4.8.tar.gz"
        tar xzf "libffi-3.4.8.tar.gz"
    fi
    rm -rf build-libffi-armv7l && mkdir -p build-libffi-armv7l
    (cd build-libffi-armv7l && ../libffi-3.4.8/configure --host=arm-linux-gnueabihf \
        --prefix="$(pwd)/../libffi-armv7l" CC="$CC" >/dev/null 2>&1)
    make -C build-libffi-armv7l -j"$(nproc)" >/dev/null 2>&1
    make -C build-libffi-armv7l install >/dev/null 2>&1
fi

# Compile _cffi_backend for armv7l, one per CPython minor. No PyPI
# manylinux_armv7l cffi wheel exists, so this is built from the sdist with the
# same cross toolchain (_cffi_backend.c ships pre-generated in src/c/).
# One backend per minor because the filename carries the interpreter tag.
CFFI_VERSION="2.1.1"
if [ ! -f "cffi-${CFFI_VERSION}.tar.gz" ]; then
    curl -sSL "https://files.pythonhosted.org/packages/source/c/cffi/cffi-${CFFI_VERSION}.tar.gz" -o "cffi-${CFFI_VERSION}.tar.gz"
fi
rm -rf "cffi-${CFFI_VERSION}" && tar xzf "cffi-${CFFI_VERSION}.tar.gz"
# Each minor compiles against its OWN headers (genuine pyconfig.h): the CI
# installs 3.10..3.14, resolved from the toolcache. No fallback across minors.
py_include() {
    local minor="$1" cand inc
    for cand in /opt/hostedtoolcache/Python/3.${minor}*/x64/bin/python3.${minor} \
                 python3.${minor}; do
        if command -v "$cand" >/dev/null 2>&1; then
            inc="$("$cand" -c 'import sysconfig; print(sysconfig.get_path("include"))' 2>/dev/null)"
            if [ -n "$inc" ] && [ -f "$inc/pyconfig.h" ]; then
                echo "$inc"
                return 0
            fi
        fi
    done
    echo "ERROR: no Python 3.${minor} headers (need 3.10..3.14 installed)" >&2
    return 1
}
for PYMINOR in 310 311 312 313 314; do
    MINOR="${PYMINOR:1}"
    PY_INC="$(py_include "$MINOR")"
    # 32-bit target, 64-bit headers: same LONG_BIT guard as Android armeabi.
    PY_INC32="/tmp/pyinclude_backend_armv7l_cp${PYMINOR}"
    rm -rf "$PY_INC32" && mkdir -p "$PY_INC32"
    cp -r "$PY_INC"/* "$PY_INC32/"
    for macro in SIZEOF_LONG SIZEOF_VOID_P SIZEOF_SIZE_T SIZEOF_PTHREAD_T \
                 SIZEOF_UINTPTR_T SIZEOF_INTPTR_T SIZEOF_TIME_T ALIGNOF_SIZE_T; do
        sed -i "s/#define $macro 8/#define $macro 4/g" "$PY_INC32/pyconfig.h" 2>/dev/null || true
    done
    sed -i 's/#define ALIGNOF_MAX_ALIGN_T 16/#define ALIGNOF_MAX_ALIGN_T 8/g' "$PY_INC32/pyconfig.h" 2>/dev/null || true
    mkdir -p "backend-cp${PYMINOR}"
    $CC -fPIC -shared -O3 $CFLAGS \
        -I"$PY_INC32" \
        -I"libffi-armv7l/include" \
        "cffi-${CFFI_VERSION}/src/c/_cffi_backend.c" \
        -o "backend-cp${PYMINOR}/_cffi_backend.so" \
        -L"libffi-armv7l/lib" -lffi -lc -ldl -lm -lrt -lpthread \
        -Wl,-rpath,'$ORIGIN'
    $STRIP --strip-unneeded "backend-cp${PYMINOR}/_cffi_backend.so"
    cp "libffi-armv7l/lib/libffi.so" "backend-cp${PYMINOR}/"
done

DIST_DIR="$(pwd)/dist"
mkdir -p "$DIST_DIR"

# One wheel per CPython minor (like Android/iOS): each carries its own
# _cffi_backend, and the per-minor tag selects lib/linux_armv7l/<pytag>/ in
# the addon. A single abi3 wheel could not carry five backends.
for PYMINOR in 310 311 312 313 314; do
python3 -c "
import zipfile, hashlib, base64, shutil
from pathlib import Path

VERSION = '0.16.4b1'
PYMINOR = '$PYMINOR'
TAG = f'cp{PYMINOR}-cp{PYMINOR}-manylinux_2_17_armv7l.manylinux2014_armv7l'
OUT_DIR = Path('$DIST_DIR')

pkg_dir = OUT_DIR / 'pkg_armv7l'
shutil.rmtree(pkg_dir, ignore_errors=True)
pkg_dir.mkdir(parents=True, exist_ok=True)

shutil.copytree('curl_cffi_src/curl_cffi', pkg_dir / 'curl_cffi')
shutil.copy('curl_cffi_src/curl_cffi/_wrapper.abi3.so', pkg_dir / 'curl_cffi/_wrapper.abi3.so')
shutil.copy(f'backend-cp{PYMINOR}/_cffi_backend.so', pkg_dir / '_cffi_backend.so')
shutil.copy(f'backend-cp{PYMINOR}/libffi.so', pkg_dir / 'libffi.so')
(pkg_dir / 'curl_cffi' / '_wrapper.c').unlink(missing_ok=True)

dist_info = pkg_dir / f'curl_cffi-{VERSION}.dist-info'
dist_info.mkdir(parents=True, exist_ok=True)
(dist_info / 'top_level.txt').write_text('curl_cffi\n')
(dist_info / 'WHEEL').write_text(f'''Wheel-Version: 1.0\nGenerator: curl-cffi-builder\nRoot-Is-Purelib: false\nTag: {TAG}\n''')
(dist_info / 'METADATA').write_text(f'''Metadata-Version: 2.1\nName: curl_cffi\nVersion: {VERSION}\nRequires-Python: >=3.10\nRequires-Dist: cffi>=2.0.0\n''')

records = []
whl_path = OUT_DIR / f'curl_cffi-{VERSION}-{TAG}.whl'
with zipfile.ZipFile(whl_path, 'w', zipfile.ZIP_DEFLATED) as zf:
    for f in sorted(pkg_dir.rglob('*')):
        if f.is_file():
            rel = f.relative_to(pkg_dir)
            zf.write(f, rel)
            dig = hashlib.sha256(f.read_bytes()).digest()
            h = 'sha256=' + base64.urlsafe_b64encode(dig).decode('ascii').rstrip('=')
            records.append(f'{rel},{h},{f.stat().st_size}')
    rec_rel = f'curl_cffi-{VERSION}.dist-info/RECORD'
    zf.writestr(rec_rel, '\n'.join(records) + f'\n{rec_rel},,\n')

shutil.rmtree(pkg_dir)
print(f'=== Linux ARM 32-bit wheel built successfully: {whl_path} ===')
"
done
