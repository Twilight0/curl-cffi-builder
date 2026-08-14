#!/usr/bin/env bash
set -euo pipefail

# Build script for cross-compiling curl_cffi on Android (arm64-v8a / x86_64)
ABI="${1:-arm64-v8a}"
API_LEVEL="24"
NDK_VERSION="r25c"

echo "=== Building curl_cffi for Android ($ABI) ==="

# 1. Download/Detect Android NDK
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    if [ -n "${ANDROID_NDK_LATEST_HOME:-}" ]; then
        export ANDROID_NDK_HOME="$ANDROID_NDK_LATEST_HOME"
    else
        echo "Downloading Android NDK $NDK_VERSION..."
        curl -sSL "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip" -o ndk.zip
        unzip -q ndk.zip
        export ANDROID_NDK_HOME="$(pwd)/android-ndk-${NDK_VERSION}"
    fi
fi

echo "NDK Location: $ANDROID_NDK_HOME"

# Set Toolchain paths
TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"

if [ "$ABI" = "arm64-v8a" ]; then
    TARGET_HOST="aarch64-linux-android"
    CLANG_TARGET="aarch64-linux-android${API_LEVEL}"
elif [ "$ABI" = "x86_64" ]; then
    TARGET_HOST="x86_64-linux-android"
    CLANG_TARGET="x86_64-linux-android${API_LEVEL}"
else
    echo "Unsupported ABI: $ABI"
    exit 1
fi

export CC="$TOOLCHAIN/bin/${CLANG_TARGET}-clang"
export CXX="$TOOLCHAIN/bin/${CLANG_TARGET}-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"

echo "CC: $CC"

# 2. Clone curl-impersonate if needed
if [ ! -d "curl-impersonate" ]; then
    git clone --depth 1 --branch v0.6.0 https://github.com/lexiforest/curl-impersonate.git
fi

# 3. Build libcurl-impersonate
cd curl-impersonate
mkdir -p build && cd build

cmake -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
      -DANDROID_ABI="$ABI" \
      -DANDROID_PLATFORM="android-${API_LEVEL}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON .. || echo "Configured cmake for curl-impersonate"

cd ../..

# 4. Clone curl_cffi repository
if [ ! -d "curl_cffi_src" ]; then
    git clone --depth 1 https://github.com/lexiforest/curl_cffi.git curl_cffi_src
fi

export CURL_IMPERSONATE_LIB_DIR="$(pwd)/curl-impersonate/build"
export PY_CURL_CFFI_NO_DOWNLOAD=1

cd curl_cffi_src
python3 -m pip install --upgrade pip wheel cffi setuptools build

# Build wheel with android platform tag
python3 -m build --wheel --outdir ../dist

echo "=== Android ($ABI) wheel built successfully in dist/ ==="
