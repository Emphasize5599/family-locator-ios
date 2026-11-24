# Open-source licenses and attribution

Amidst is licensed under the [GNU Affero General Public License, version 3](../LICENSE), with an [additional permission](../APP_STORE_EXCEPTION.md) under section 7 for distribution through the App Store and similar stores. It implements the open Zood protocol and is compatible with the [Zood Location Android client](https://github.com/zood/george). Zood is a trademark of Tangled Wires, LLC; Amidst is an independent project.

The full corresponding source, changes and build instructions are available in [this repository](https://github.com/Emphasize5599/family-locator-ios). For source corresponding to an installed release, select its matching release tag. Apple Maps content remains subject to Apple's terms and attribution shown by the map.

## Trademarks and artwork

Apple, iPhone and Apple Maps are trademarks of Apple Inc., registered in the U.S. and other countries and regions.

Android is a trademark of Google LLC. The Android logo is shown only to indicate that a friend uses an Android device. Where the Android robot appears, it is reproduced or modified from work created and shared by Google and used according to terms described in the [Creative Commons 3.0 Attribution License](https://creativecommons.org/licenses/by/3.0/). Until the official artwork is added to the asset catalog as `AndroidLogo`, the app shows an original robot-style placeholder.

The same notices appear in the app under Settings › About › Notices & Trademarks.

## swift-sodium and libsodium

Cryptographic primitives are supplied by upstream [libsodium](https://github.com/jedisct1/libsodium) 1.0.22 with the official Apple RNG selection backport, maintained by Frank Denis and contributors, rebuilt for this app's supported deployment targets. The former swift-sodium wrapper dependency is no longer linked. Source archive, checksum and reproducible build instructions are in [Vendor/Clibsodium](../Vendor/Clibsodium/README.md).

ISC License

Copyright (c) 2013-2026, Frank Denis <j at pureftpd dot org>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
