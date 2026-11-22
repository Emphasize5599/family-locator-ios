# Screenshot tours in Xcode

When the user asks you to run a screenshot tour from the Xcode assistant, make it visible in Xcode's device-interaction side panel, not only as PNG files or an HTML gallery.

- Follow the `device-interaction` skill and create a clearly named session such as **Family Locator Screenshot Tour**.
- Use the dedicated tour simulator and Debug fixtures described in `Docs/UI_TOUR.md`; never use real family data for tour captures.
- Publish scene captures through `DeviceInteractionSynthesize` so they appear in that named session. The standalone runner's file-based scene requests can drive the same installed Debug app.
- Keep the HTML gallery/ZIP as a portable companion. CLI and GitHub runs alone cannot populate Xcode's device-interaction panel.
- Report the actual side-panel coverage if tools prevent publishing the full tour. Close the session after capture to release resources.
