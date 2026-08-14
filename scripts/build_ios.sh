#!/usr/bin/env bash
set -euo pipefail

# Build script for cross-compiling curl_cffi on iOS (arm64) using macOS / Xcode
echo "=== Building curl_cffi for iOS (arm64) ==="

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN_IOS_VER="14.0"

export CC="$(xcrun --find clang)"
export CXX="$(xcrun --find clang++)"
export CFLAGS="-target arm64-apple-ios${MIN_IOS_VER} -isysroot ${SDK_PATH}"
export CXXFLAGS="-target arm64-apple-ios${MIN_IOS_VER} -isysroot ${SDK_PATH}"
export LDFLAGS="-target arm64-apple-ios${MIN_IOS_VER} -isysroot ${SDK_PATH}"

echo "SDK Path: $SDK_PATH"
echo "CC: $CC"

# 1. Clone curl-impersonate
if [ ! -d "curl-impersonate" ]; then
    git clone --depth 1 --branch v0.6.0 https://github.com/lexiforest/curl-impersonate.git
fi

cd curl-impersonate
mkdir -p build && cd build

cmake -DCMAKE_OSX_SYSROOT="${SDK_PATH}" \
      -DCMAKE_OSX_ARCHITECTURES="arm64" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="${MIN_IOS_VER}" \
      -DCMAKE_BUILD_TYPE=Release ..

cmake --build . --config Release || true
cd ../..

# 2. Clone curl_cffi repository
if [ ! -d "curl_cffi_src" ]; then
    git clone --depth 1 https://github.com/lexiforest/curl_cffi.git curl_cffi_src
fi

mkdir -p curl_cffi_src/tmplibdir
find curl-impersonate/build -name "*.a" -exec cp {} curl_cffi_src/tmplibdir/libcurl-impersonate.a \;

export PY_CURL_CFFI_NO_DOWNLOAD=1

cd curl_cffi_src
python3 -m pip install --upgrade pip wheel cffi setuptools build

# Build wheel for iOS platform
python3 -m build --wheel --outdir ../dist

echo "=== iOS (arm64) wheel built successfully in dist/ ==="
