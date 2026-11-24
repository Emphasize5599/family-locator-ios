# Amidst for iPhone

An iOS client for the [Zood Location](https://www.zood.xyz) network: end-to-end encrypted location sharing that
works with people using Zood on Android. It talks to the public Zood server (`api.zood.xyz`) and uses the same
accounts, so existing Zood users can sign in with their username and password.

The companion Android build is [Emphasize5599/george](https://github.com/Emphasize5599/george/tree/family-ios-compat)
(branch `family-ios-compat`).

## How it differs from Zood
Zood's server sends push notifications only to the original apps, so this app (and the Android fork) can't
receive them. Instead, **Live Requests** keeps a low-power background connection open so family can tap
**Refresh** to get your current location. Both apps add compatibility metadata to the encrypted location messages they send:

- `platform`: `ios` or `android`
- `live_requests`: whether this phone can currently answer a Refresh
- `nickname`: an optional shared display name; an empty value clears it

Stock Zood ignores these fields. When a phone reports `live_requests: false`, its friends see Refresh grayed out
with an "Unsupported ⓘ" explanation.

A private nickname you choose for a friend takes priority over their shared name. Their immutable `@username` remains available in View Username. Names and private overrides are included in the encrypted account backup; older Zood clients may omit these optional fields when rewriting a backup.

**Add Friend** checks the username as you type. On the next screen, **Share My Location** sends a location offer with the request and **Not Now** sends a request without location. Request-only invitations require the current Amidst client on both ends. Pending requests show the optional photo and whether the sender currently shares. Approving leaves your location sharing off. If either person chooses to share later, their location updates the existing friend card.

To edit a nickname, tap it on the friend card or in Account. Tap an open folder’s title to rename it. The pencil and Rename Folder actions open the same inline fields. Names wrap as you type, and the folder grows up to the screen margins. The Save and Cancel controls sit below the field while the existing header buttons stay visible. Save keeps the draft; Cancel discards it.

See [Docs/PROTOCOL.md](Docs/PROTOCOL.md) for the wire protocol.

## Building
Xcode 27, iOS 15.0+. Links the local `Vendor/Clibsodium` Swift package, containing upstream libsodium 1.0.22 with its official Apple RNG selection backport rebuilt for iOS 15+ and its simulators. Reproduce the binary with `Tools/build-libsodium.sh` (source archive checksum pinned in the script). See [dependency build notes](Vendor/Clibsodium/README.md).

## License
AGPL-3.0, the same as Zood, with an [additional permission](APP_STORE_EXCEPTION.md) (AGPL section 7) to distribute the app through the App Store and similar stores while the source stays available. Zood is a trademark of Tangled Wires, LLC; this project isn't affiliated with them.

## Screenshot tour

Run `python3 Tools/screenshot-tour.py` for a light/dark/large-text gallery of native screens using fictional data. See [UI tour instructions](Docs/UI_TOUR.md) for the viewer, ZIP, and on-demand GitHub workflow.
