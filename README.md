# curl-cffi Mobile Wheels (Android & iOS)

Automated GitHub Actions cross-compilation pipeline to build **`curl_cffi`** wheels (`.whl`) for mobile operating systems (**Android** `arm64-v8a` / `x86_64` and **iOS** `arm64`).

---

## Features
- 🚀 **Bypasses Cloudflare & TLS Fingerprinting** on mobile devices by bundling `curl-impersonate`.
- 📱 **Android Support**: Built for `arm64-v8a` and `x86_64` using Android NDK r25c.
- 🍏 **iOS Support**: Built for `arm64` using Xcode SDK (`iphoneos`).
- ⚡ **Automated CI/CD**: Uses GitHub Actions matrix (`ubuntu-latest` for Android, `macos-latest` for iOS).

---

## How It Works

1. **Android CI Job** (`ubuntu-latest`):
   - Sets up Android NDK `r25c`.
   - Cross-compiles `libcurl-impersonate` (with `BoringSSL` and `nghttp2`) targeting `aarch64-linux-android24-clang`.
   - Compiles Python `cffi` extension and produces Android wheel packages.

2. **iOS CI Job** (`macos-latest`):
   - Sets up Apple Xcode SDK (`iphoneos`).
   - Cross-compiles `libcurl-impersonate` targeting `arm64-apple-ios14.0`.
   - Compiles Python `cffi` extension and produces iOS wheel packages.

---

## Triggering a Build
The GitHub Actions workflow triggers automatically on:
- Every push to `main`
- Manual trigger via **Actions -> Run workflow** (`workflow_dispatch`)
- Creating a git version tag (`git tag v0.1.0 && git push origin v0.1.0`)

---

## License
MIT / Apache-2.0
