# How Amidst for iPhone is put together

A one-page map for new contributors. Read this first, then the doc comments in the files it points to.

## The idea in one paragraph

Amidst shows where your family and friends are. It talks to the existing Zood servers and works with the Zood and Amidst Android apps. Everything personal is **end-to-end encrypted on the phone** before it leaves, so the server only stores and forwards data it can't read. That one rule explains most of the code: every location, request and profile change is encrypted for one specific friend, and the account backup is encrypted with a key only the user's password can unlock.

## Where things live

| Folder / file | What it's for |
| --- | --- |
| `MyApp.swift`, `ContentView.swift` | App entry point. Creates the single `AppModel` and switches between onboarding and the map. |
| `Core/AppModel.swift` | The heart of the app. Owns the signed-in account, friends, requests and blocks, and coordinates everything else. Screens read from it and call its methods. |
| `Core/Crypto.swift` | The only place that encrypts or decrypts (libsodium). |
| `Core/OscarAPI.swift` | REST calls to the Zood server (`api.zood.xyz`). |
| `Core/OscarSocket.swift` | The live connection that delivers friends' locations and requests instantly. |
| `Core/LocationService.swift` | Gets the phone's location while respecting battery and the user's permissions. |
| `Core/MotionActivity.swift` | Walking / cycling / driving, from Motion & Fitness. |
| `Core/Storage.swift` | What's saved on the phone: credentials and safety state in the Keychain, everything else in one JSON file. |
| `Core/Models.swift` | The message format shared with the Android apps. Change it only with matching Android changes. |
| `Core/DeviceSession.swift` | One active phone per account: signing in elsewhere signs this phone out. |
| `Core/FriendFolders.swift`, `Core/TimedShare.swift` | Friend-bar folders, and temporary links for people without the app. |
| `Views/` | SwiftUI screens. `MainView` is the map, `FriendPanel` the friend card, `SettingsView` settings. |
| `Core/ScreenshotTour.swift` | Debug only: fictional data for screenshots. Compiled out of release builds. |

## How a location gets from my phone to yours

1. `LocationService` gets a new location and hands it to `AppModel.upload(location:)`.
2. For **each** friend I share with, `Crypto.box` encrypts the location so only that friend can open it.
3. `OscarAPI.dropPackages` puts each copy in that friend's private *drop box* on the server.
4. On your phone, `OscarSocket` hears that the box changed. `AppModel` decrypts the package and updates your map.

Requests, approvals, names and photos travel the same way, through each user's encrypted inbox (`OscarAPI.sendMessage`).

## Rules worth knowing before changing things

- **Privacy first.** Never send anything about a friend to the server unencrypted, and never log locations.
- **Blocks win.** A block is saved before any network call, and data from blocked people is dropped on arrival.
- **Stay compatible.** The Android apps read the same messages and backup. New fields must be optional, and old clients must keep working when they're missing.
- **Ask before sharing.** Nothing from a stranger appears until the user approves it in Requests.
- **Battery matters.** Background work exists only for location sharing and live requests (App Review guideline 2.5.4).
