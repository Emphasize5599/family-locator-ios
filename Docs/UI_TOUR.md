# UI screenshot tour

An on-demand tour of the native iPhone app, modeled after [Gasket's screenshot tour](https://github.com/Emphasize5599/gasket/blob/HEAD/docs/UI_TOUR.md). Uses fictional demo accounts and the public Golden Gate Bridge landmark; no real login is required.

## Run locally

Requires macOS, Xcode 27+, an installed iOS simulator runtime, and Python 3. Select Xcode's tools with `xcode-select` if necessary.

```sh
python3 Tools/screenshot-tour.py /private/tmp/zood-ui-tour
```

The runner creates or reuses **Family Locator Screenshot Tour**, a dedicated simulator. It builds/installs Debug, captures light/dark/large-text variants, and writes:

- `index.html`: searchable screenshot gallery.
- `viewer.html`: one screen at a time; Previous/Next and left/right arrow keys.
- `light/`, `dark/`, `large-text/`: PNG screenshots.
- `manifest.json`: captured states, simulator UUID and any failures.
- `family-locator-ui-tour.zip`: portable gallery with screenshots and manifest.
- `build.log`: local build diagnostics, excluded from the ZIP.

Open `index.html` in a browser or unzip the archive anywhere. A failed capture is recorded and makes the command exit nonzero; successful captures are retained.

Useful options:

```sh
python3 Tools/screenshot-tour.py /private/tmp/zood-ui-tour --scenes safety-number,requests --variants light,large-text
python3 Tools/screenshot-tour.py /private/tmp/zood-ui-tour --no-build --derived-data /private/tmp/zood-tour-derived
```

`--device UUID` selects another simulator. Prefer the dedicated simulator: the script changes appearance/status bar temporarily and installs the Debug bundle. It does not erase the simulator. To limit memory use, it shuts down other simulators, boots the selected simulator (reusing it if it's already running), and shuts it down after capture. Run Android emulator checks separately. Relaunch without tour flags to return to normal behavior. Output files are overwritten by matching scene names; the gallery/ZIP only include the current run's captures unless `--append` is passed to retain and update a previous gallery.

## GitHub

Actions → **UI screenshot tour** → Run workflow. Download the `family-locator-ui-tour` artifact. Optionally pass a comma-separated scene list. The hosted runner must have Xcode 27+ and an iOS runtime; the workflow checks the toolchain explicitly and fails clearly if the runner image is older. Local execution is the verified route; the hosted workflow has not been exercised from this workspace.

## Coverage and isolation

Scenes: onboarding, map (one friend / enough friends to scroll the friend bar / a friend folder closed and open), friend panel (normal/long nickname/just refreshed/Refresh unsupported), friend and profile nickname editors, Account, both steps of Add Friend, pending requests (photo and no location / empty), Safety Number, Timed Sharing, Settings (top/support), blocked users (populated/empty), Delete Account. Each is captured in light, dark, and the largest text size the app supports (it caps Dynamic Type at Accessibility 1; see `maxTextSize` in `MyApp.swift`). Set `ZOOD_LEGACY_STYLE=1` to see the pre-iOS 26 look (blur material, bordered buttons) on a newer simulator. These are viewport captures; long screens scroll normally in the app. This is an explicit scene tour, not automatic discovery of every alert, system picker or menu.

Debug-only `ZOOD_SCREENSHOT_TOUR` supplies an in-memory model before loading Keychain/local accounts and skips session/location startup. Backend API calls are rejected in tour mode, controls are read-only by default, and each file-based scene request receives a unique readiness marker after presentation. This prevents screenshots of a normal login session if an incompatible build is installed. Map tiles and address lookup still use Apple services and may vary with network availability. No family data, passwords, live sharing links, or real account keys belong in the screenshots. Fixtures cannot log in or upload locations. `ZOOD_TOUR_INTERACTIVE=1` enables local UI interactions for manual verification; local friend/safety writes and backup uploads remain disabled.

Release builds ignore tour flags and contain no fixture account/view implementation. The runner requires a Debug build, even when using `--no-build`; a Release build will fail readiness rather than capture personal screens.

Add new scenes to `ScreenshotTourView` and `SCENES` in the runner as features grow. Behavioral tests and real-device background testing remain separate from screenshot review.

## Xcode side panel

When the Xcode assistant runs a tour, it also creates a named **Family Locator Screenshot Tour** device-interaction session and captures scenes through Xcode's runtime tools. This is the same side-panel presentation used by **Verify Compact Safety UI**. The assistant follows `AGENTS.md` to provide these captures; the HTML/ZIP is a portable companion.

The Python CLI and GitHub Actions do not themselves have access to Xcode's assistant-only side-panel tools. To publish an already installed tour there, start a device-interaction session on the tour simulator, launch Debug with `ZOOD_SCREENSHOT_TOUR=map`, write `{scene, token, largeText}` to the app's `Documents/tour-request.json`, wait for `tour-ready.txt` to match the unique token, then capture with `DeviceInteractionSynthesize`. Use the device-interaction skill and close the session afterward. Capture coverage in the panel must be reported accurately if a runtime tool fails.
