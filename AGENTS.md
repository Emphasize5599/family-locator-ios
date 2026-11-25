# Working style

Work autonomously. Don't stop to ask permission for routine next steps; do them and report afterward.

- Carry work through: fix what you find, build, verify (see Verification resources), commit, merge to `main` and push.
- Every push gets a GitHub release (see Releases).
- Don't end a turn with "Should I…?" when the next step is obvious. Pick the sensible default, do it, and say what you chose.
- A request to push a new build authorizes signing with the project's existing credentials and uploading to the requested or established build destination. A repository-only update does not authorize credential use or a store upload.
- Ask before submitting a build for App Review or production release, changing signing credentials, using existing signing credentials outside an authorized build push, messaging testers or other people, using paid services, or deleting data.
- Also ask when a request has more than one reasonable product answer and the choice changes what users see.

# Releases

Publish a GitHub release whenever you push to `main`, so testers can install what's on GitHub.

- Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` when the last release already used them.
- Build an arm64 Release with `CODE_SIGNING_ALLOWED=NO` and package two IPAs: `Amidst-<version>-unsigned.ipa` (AltStore/Sideloadly re-sign it) and `Amidst-<version>-fakesigned.ipa` (ad-hoc `codesign -s -` with the placeholder entitlements, for AppSync). Check the version, build, minimum iOS and privacy manifest, and that Debug tour fixtures are absent.
- Tag `v<version>-review`, mark it a pre-release, target the pushed commit, and write notes covering what changed, what was verified and what wasn't. These are not TestFlight/App Store builds; real distribution signing is still required.
- If the same push changed the Android app, also release it from the Android repo (`v<version>-family`, signed GitHub-flavor APK; confirm its certificate matches the previous release).

# Screenshot tours in Xcode

When the user asks you to run a screenshot tour from the Xcode assistant, make it visible in Xcode's device-interaction side panel, not only as PNG files or an HTML gallery.

- Follow the `device-interaction` skill and create a clearly named session such as **Family Locator Screenshot Tour**.
- Use the dedicated tour simulator and Debug fixtures described in `Docs/UI_TOUR.md`; never use real family data for tour captures.
- Publish scene captures through `DeviceInteractionSynthesize` so they appear in that named session. The standalone runner's file-based scene requests can drive the same installed Debug app.
- Keep the HTML gallery/ZIP as a portable companion. CLI and GitHub runs alone cannot populate Xcode's device-interaction panel.
- Report the actual side-panel coverage if tools prevent publishing the full tour. Close the session after capture to release resources.

# Verification resources

- This Mac has 8 GB of RAM. Run only one simulator or emulator at a time, including across iOS and Android. Shut down the current one before starting another.
- Cold boots are not required; reusing an already-booted simulator or an Android Quick Boot snapshot is fine.
- Finish memory-heavy release optimization and stop its build service before simulator verification on this 8 GB Mac.
