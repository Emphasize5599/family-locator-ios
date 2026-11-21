# Family Locator for iPhone

An iOS client for the [Zood Location](https://www.zood.xyz) network: end-to-end encrypted location sharing that
works with people using Zood on Android. It talks to the public Zood server (`api.zood.xyz`) and uses the same
accounts, so existing Zood users can sign in with their username and password.

The companion Android build is [Emphasize5599/george](https://github.com/Emphasize5599/george/tree/family-ios-compat)
(branch `family-ios-compat`).

## How it differs from Zood
Zood's server sends push notifications only to the original apps, so this app (and the Android fork) can't
receive them. Instead, **Live Requests** keeps a low-power background connection open so family can tap
**Refresh** to get your current location. Both apps add two fields to the location messages they send:

- `platform`: `ios` or `android`
- `live_requests`: whether this phone can currently answer a Refresh

Stock Zood ignores these fields. When a phone reports `live_requests: false`, its friends see Refresh grayed out
with an "Unsupported ⓘ" explanation.

See [Docs/PROTOCOL.md](Docs/PROTOCOL.md) for the wire protocol.

## Building
Xcode 27, iOS 15.0+. Depends on [swift-sodium](https://github.com/jedisct1/swift-sodium) (`Clibsodium` product)
via Swift Package Manager.

## License
AGPL-3.0, the same as Zood. Zood is a trademark of Tangled Wires, LLC; this project isn't affiliated with them.
