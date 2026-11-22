#!/bin/bash
set -euo pipefail
# Build upstream 1.0.22 with its pinned Apple RNG backport for this app's supported deployment targets.
# iOS >=10 selects upstream's Apple arc4random implementation rather than /dev/random + fstat.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="${ZOOD_SODIUM_BUILD_DIR:-$(mktemp -d /private/tmp/zood-sodium.XXXXXX)}"
archive="$work_dir/libsodium-1.0.22.tar.gz"
mkdir -p "$work_dir"
if [[ -n "${ZOOD_SODIUM_ARCHIVE:-}" ]]; then
    cp "$ZOOD_SODIUM_ARCHIVE" "$archive"
else
    curl --http1.1 --fail --location --retry 3 https://github.com/jedisct1/libsodium/releases/download/1.0.22-RELEASE/libsodium-1.0.22.tar.gz -o "$archive"
fi
# The release archive's checksum is recorded alongside this reproducible build script.
expected="adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349"
actual="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
[[ "$actual" == "$expected" ]] || { echo "Unexpected libsodium source checksum" >&2; exit 1; }
tar -xzf "$archive" -C "$work_dir"
cd "$work_dir/libsodium-1.0.22"
# Backport upstream f6bd9140861ab6806f4a99923888b65477fc4e33 (Apple RNG selection only).
patch -p1 < "$repo_root/Vendor/Clibsodium/apple-arc4random.patch"
for variant in ios-arm64 sim-arm64 sim-x86_64 mac-arm64; do
    case "$variant" in
        ios-arm64) sdk=iphoneos; target=arm64-apple-ios15.0; host=aarch64-apple-darwin ;;
        sim-arm64) sdk=iphonesimulator; target=arm64-apple-ios15.0-simulator; host=aarch64-apple-darwin ;;
        sim-x86_64) sdk=iphonesimulator; target=x86_64-apple-ios15.0-simulator; host=x86_64-apple-darwin ;;
        mac-arm64) sdk=macosx; target=arm64-apple-macos12.0; host=aarch64-apple-darwin ;;
    esac
    make distclean >/dev/null 2>&1 || true
    export CC="$(xcrun --sdk "$sdk" --find clang)"
    export CFLAGS="-O3 -target $target -isysroot $(xcrun --sdk "$sdk" --show-sdk-path)"
    export LDFLAGS="$CFLAGS"
    ./configure --host="$host" --prefix="$work_dir/$variant" --disable-shared
    make -j8 install
    mkdir -p "$work_dir/$variant/include/Clibsodium"
    mv "$work_dir/$variant/include/sodium" "$work_dir/$variant/include/sodium.h" "$work_dir/$variant/include/Clibsodium/"
    printf 'module Clibsodium { header "sodium.h" export * }\n' > "$work_dir/$variant/include/Clibsodium/module.modulemap"
done
mkdir -p "$work_dir/simulator"
xcrun lipo -create "$work_dir/sim-arm64/lib/libsodium.a" "$work_dir/sim-x86_64/lib/libsodium.a" -output "$work_dir/simulator/libsodium.a"
# Do not overwrite an existing artifact until all compilation succeeds.
xcodebuild -create-xcframework \
    -library "$work_dir/ios-arm64/lib/libsodium.a" -headers "$work_dir/ios-arm64/include" \
    -library "$work_dir/simulator/libsodium.a" -headers "$work_dir/sim-arm64/include" \
    -library "$work_dir/mac-arm64/lib/libsodium.a" -headers "$work_dir/mac-arm64/include" \
    -output "$work_dir/Clibsodium.xcframework"
cp "$work_dir/libsodium-1.0.22/LICENSE" "$repo_root/Vendor/Clibsodium/LICENSE"
rm -rf "$repo_root/Vendor/Clibsodium/Clibsodium.xcframework"
cp -R "$work_dir/Clibsodium.xcframework" "$repo_root/Vendor/Clibsodium/"
