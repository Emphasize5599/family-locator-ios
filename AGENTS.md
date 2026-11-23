# Working style

Work autonomously. Don't stop to ask permission for routine next steps; do them and report afterward.

- Carry work through: fix what you find, build, verify (see Verification resources), commit, merge to `main` and push.
- Don't end a turn with "Should I…?" when the next step is obvious. Pick the sensible default, do it, and say what you chose.
- Still check with the user first for anything outside the repositories or hard to undo: App Store Connect or Play Console submissions, signing with their credentials, messaging testers or other people, paid services, and deleting data.
- Also ask when a request has more than one reasonable product answer and the choice changes what users see.

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
