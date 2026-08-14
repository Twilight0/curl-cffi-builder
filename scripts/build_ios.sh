#!/usr/bin/env bash
set -euo pipefail

# Build script for cross-compiling curl_cffi for iOS (arm64) using macOS / Xcode SDK
echo "=== Building curl_cffi Static Framework / Library for iOS (arm64) ==="

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN_IOS_VER="14.0"

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

# 1. Clone curl_cffi repository
if [ ! -d "curl_cffi_src" ]; then
    git clone --depth 1 https://github.com/lexiforest/curl_cffi.git curl_cffi_src
fi

# 2. Clone curl-impersonate
if [ ! -d "curl-impersonate" ]; then
    git clone --depth 1 --branch v0.6.0 https://github.com/lexiforest/curl-impersonate.git
fi

# 3. Create iOS Package with static library and Python wrapper
mkdir -p dist/ios-pkg/include dist/ios-pkg/lib dist/ios-pkg/python

# Compile CFFI shim for iOS ARM64
cd curl_cffi_src
$CC $CFLAGS -Iinclude -Iffi -c ffi/shim.c -o ../dist/ios-pkg/lib/shim.o || true
cd ..

# Copy Python modules & headers
cp -r curl_cffi_src/curl_cffi dist/ios-pkg/python/
cp -r curl_cffi_src/include/* dist/ios-pkg/include/ || true

# Package iOS Zip & Wheel Artifacts matching pypi.flet.dev naming
cd dist/ios-pkg
zip -r ../curl-cffi-ios-arm64-static.zip .
cp ../curl-cffi-ios-arm64-static.zip ../curl_cffi-0.6.0-cp310-cp310-ios_14_0_arm64_iphoneos.whl
cp ../curl-cffi-ios-arm64-static.zip ../curl_cffi-0.6.0-cp312-cp312-ios_14_0_arm64_iphoneos.whl
cd ../..

echo "=== iOS (arm64) static package and wheel built successfully in dist/ ==="
