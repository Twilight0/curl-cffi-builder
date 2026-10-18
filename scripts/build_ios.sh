#!/usr/bin/env bash
set -euo pipefail

# Build script for cross-compiling curl_cffi for iOS (arm64) using macOS / Xcode SDK
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN_IOS_VER="14.0"
CURL_CFFI_VERSION="v0.16.4b1"
IMPERSONATE_VERSION="v2.2.3"

export CC="$(xcrun --find clang)"
export CXX="$(xcrun --find clang++)"
export AR="$(xcrun --find ar)"
export RANLIB="$(xcrun --find ranlib)"
export CFLAGS="-target arm64-apple-ios${MIN_IOS_VER} -isysroot ${SDK_PATH} -O3"
export CXXFLAGS="-target arm64-apple-ios${MIN_IOS_VER} -isysroot ${SDK_PATH} -O3"
export LDFLAGS="-target arm64-apple-ios${MIN_IOS_VER} -isysroot ${SDK_PATH}"

echo "SDK Path: $SDK_PATH"
echo "CC: $CC"

mkdir -p dist/ios-pkg

# 1. Clone curl_cffi repository (pinned to latest 0.16.x)
if [ ! -d "curl_cffi_src" ]; then
    git clone --depth 1 --branch "$CURL_CFFI_VERSION" https://github.com/lexiforest/curl_cffi.git curl_cffi_src
else
    git -C curl_cffi_src fetch --depth 1 origin tag "$CURL_CFFI_VERSION" 2>/dev/null || true
    git -C curl_cffi_src checkout -f "$CURL_CFFI_VERSION" 2>/dev/null || echo "WARNING: using existing checkout $(git -C curl_cffi_src rev-parse --short HEAD)"
fi

# 2. Clone curl-impersonate (pinned to version required by curl_cffi 0.16.4b1)
if [ ! -d "curl-impersonate" ]; then
    git clone --depth 1 --branch "$IMPERSONATE_VERSION" https://github.com/lexiforest/curl-impersonate.git
else
    git -C curl-impersonate fetch --depth 1 origin tag "$IMPERSONATE_VERSION" 2>/dev/null || true
    git -C curl-impersonate checkout -f "$IMPERSONATE_VERSION" 2>/dev/null || echo "WARNING: using existing checkout $(git -C curl-impersonate rev-parse --short HEAD)"
fi

# 3. Create iOS Package with static library and Python wrapper
mkdir -p dist/ios-pkg/include dist/ios-pkg/lib dist/ios-pkg/python

# Compile CFFI shim for iOS ARM64
cd curl_cffi_src
$CC $CFLAGS -Iinclude -Iffi -c ffi/shim.c -o ../dist/ios-pkg/lib/shim.o || true
cd ..

# 3b. Compile _cffi_backend for iOS ARM64, one per CPython minor. Same reason
# as Android (no PyPI iOS wheels, no cffi in Kodi's Python); _cffi_backend.c
# ships pre-generated in the sdist. One backend per minor because the SONAME
# is versioned; the per-minor wheel filenames below select the right one.
CFFI_VERSION="2.1.1"
if [ ! -f "cffi-${CFFI_VERSION}.tar.gz" ]; then
    curl -sSL "https://files.pythonhosted.org/packages/source/c/cffi/cffi-${CFFI_VERSION}.tar.gz" -o "cffi-${CFFI_VERSION}.tar.gz"
fi
rm -rf "cffi-${CFFI_VERSION}" && tar xzf "cffi-${CFFI_VERSION}.tar.gz"
for PYMINOR in 310 311 312 313 314; do
    PYVER="3.${PYMINOR:1}"
    case "$PYMINOR" in
        310) CPY=3.10.19 ;; 311) CPY=3.11.14 ;; 312) CPY=3.12.12 ;;
        313) CPY=3.13.9 ;; 314) CPY=3.14.0 ;;
    esac
    if [ ! -d "cpython-${CPY}" ]; then
        curl -sSL "https://github.com/python/cpython/archive/refs/tags/v${CPY}.tar.gz" -o "cpython-${CPY}.tgz"
        mkdir -p "cpython-${CPY}" && tar xzf "cpython-${CPY}.tgz" -C "cpython-${CPY}" --strip-components=1
    fi
    mkdir -p "dist/ios-pkg/backend-cp${PYMINOR}"
    # -bundle with undefined dynamic_lookup: iOS extension modules resolve
    # their Python symbols from the host interpreter at load time (same as
    # desktop macOS extensions); a plain link would fail on undefined symbols.
    # libffi is built from source with the Xcode clang: Homebrew's is macOS-
    # only and the SDK ships no headers. Built once, reused for all minors.
    # Brew is only a fallback if the source build is unavailable.
    if [ ! -f "libffi-ios/lib/libffi.a" ]; then
        if [ ! -d "libffi-src" ]; then
            git clone --depth 1 --branch v3.4.8 https://github.com/libffi/libffi.git libffi-src
        fi
        (cd libffi-src && autoreconf -fi >/dev/null 2>&1 || true)
        rm -rf build-libffi-ios && mkdir -p build-libffi-ios
        (cd build-libffi-ios && ../libffi-src/configure --host=aarch64-apple-darwin \
            --prefix="$(pwd)/../libffi-ios" \
            CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" \
            CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" >/dev/null 2>&1)
        make -C build-libffi-ios -j"$(sysctl -n hw.ncpu)" >/dev/null 2>&1
        make -C build-libffi-ios install >/dev/null 2>&1
    fi
    FFI_PREFIX="libffi-ios"
    if [ ! -f "$FFI_PREFIX/include/ffi.h" ] && brew --prefix libffi >/dev/null 2>&1; then
        FFI_PREFIX="$(brew --prefix libffi)"
    fi
    $CC $CFLAGS -bundle -undefined dynamic_lookup -I"cpython-${CPY}/Include" \
        -I"$FFI_PREFIX/include" -L"$FFI_PREFIX/lib" \
        "cffi-${CFFI_VERSION}/src/c/_cffi_backend.c" \
        -o "dist/ios-pkg/backend-cp${PYMINOR}/_cffi_backend.so" -lffi
done

# Copy Python modules & headers
cp -r curl_cffi_src/curl_cffi dist/ios-pkg/python/
cp -r curl_cffi_src/include/* dist/ios-pkg/include/ || true

# Package iOS Zip & Wheel Artifacts matching pypi.flet.dev naming
# Per-minor tags: iOS links libpython by versioned SONAME like Android,
# so emit one filename per supported CPython minor (payload is the same
# static package; the tag selects lib/ios_arm64/<pytag>/ in the addon).
# Each per-minor wheel also carries its own _cffi_backend.so (compiled above),
# because Kodi's Python has no cffi and PyPI ships no iOS wheels.
cd dist/ios-pkg
zip -r ../curl-cffi-ios-arm64-static.zip .
for PYMINOR in 310 311 312 313 314; do
    cp ../curl-cffi-ios-arm64-static.zip ../curl_cffi-0.16.4b1-cp${PYMINOR}-cp${PYMINOR}-ios_14_0_arm64_iphoneos.whl
    (cd backend-cp${PYMINOR} && zip -gj ../../curl_cffi-0.16.4b1-cp${PYMINOR}-cp${PYMINOR}-ios_14_0_arm64_iphoneos.whl _cffi_backend.so)
done
cd ../..

echo "=== iOS (arm64) static package and wheel built successfully in dist/ ==="
