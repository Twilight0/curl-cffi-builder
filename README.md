# curl-cffi Builder (Mobile Wheels & Kodi Add-on)

Automated GitHub Actions cross-compilation pipeline to build **`curl_cffi`** wheels (`.whl`) for mobile operating systems (**Android** `arm64-v8a` / `x86_64` and **iOS** `arm64`), as well as assembling a multi-platform Kodi module add-on (**`script.module.curlcffi`**).

---

## Features
- 🚀 **Bypasses Cloudflare & TLS Fingerprinting** on mobile and Kodi devices by bundling `curl-impersonate`.
- 📱 **Mobile Wheels Support**: Built for Android (`arm64-v8a`, `x86_64`) and iOS (`arm64`).
- 📺 **Kodi Module Add-on (`script.module.curlcffi`)**: Packages native C binaries into an installable `.zip` with dynamic architecture path injection across Windows, Linux, Android TV, CoreELEC, and macOS.
- ⚡ **Automated CI/CD**: Uses GitHub Actions matrix (`ubuntu-latest` for Android & Linux, `macos-latest` for iOS, `windows-latest` for Windows).

---

## Output Artifacts & Releases

1. **`curl-cffi-android-arm64-v8a.whl`** & **`curl-cffi-android-x86_64.whl`**
2. **`curl-cffi-ios-arm64.whl`**
3. **`script.module.curlcffi-0.6.0.zip`** (Multi-platform Kodi Module Addon)

---

## License
MIT / Apache-2.0
