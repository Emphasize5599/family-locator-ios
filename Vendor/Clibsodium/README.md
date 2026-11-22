# Clibsodium for Family Locator

Upstream libsodium **1.0.22** with the official Apple RNG selection backport, release commit `77e1ce5d6dee871c49ef211222ba18ef0c486bda`.
Source archive: https://github.com/jedisct1/libsodium/releases/download/1.0.22-RELEASE/libsodium-1.0.22.tar.gz
SHA-256: `adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349`.

Run `Tools/build-libsodium.sh` from any directory with Xcode's command-line tools selected. The script verifies the archive checksum, configures the full library without shared libraries, and produces iOS arm64, iOS Simulator arm64/x86_64, and macOS arm64 slices. The macOS slice supports the private-account verification tool; this project ships only an iPhone app.

The previously used swift-sodium 0.11.0 binary already contained libsodium 1.0.22, but was built with an iOS 9 deployment target. That selects a compatibility fallback reading `/dev/random`/`/dev/urandom` and calling `fstat`. The safe Apple path was added after the release in upstream commit [`f6bd9140861ab6806f4a99923888b65477fc4e33`](https://github.com/jedisct1/libsodium/commit/f6bd9140861ab6806f4a99923888b65477fc4e33), September 6, 2026. `apple-arc4random.patch` backports that conditional to the release, preserving its WASI branch. This build matches our iOS 15 minimum and selects upstream's supported Apple `arc4random` / `arc4random_buf` implementation. Cryptographic primitives and algorithms are unchanged; no custom RNG is introduced. The unused Swift Sodium wrapper has been removed.

Verify the final Release executable for required-reason API imports after changing dependencies. Compile and run `Tools/ReviewAccountTool.swift` with production Crypto/Models/OscarAPI against a private state directory to check protocol/crypto compatibility. This creates/resets real fixture accounts; do not run against fixtures during an active Apple review.

License: ISC; see [LICENSE](LICENSE). Rebuilt binaries are checked into source so ordinary Xcode builds need no script phase or dependency download. Build paths/toolchain metadata can make byte-for-byte outputs vary; the script makes the inputs and deployment targets reproducible.
