# iOS App Review preparation

Audited November 22, 2026. This is an engineering review, not an Apple approval or a guarantee of acceptance. Signing, App Store Connect validation and device-only behavior remain outside the completed checks.

## Status: not ready to submit yet

The app now has an in-app deletion flow, published privacy/support/license links, a privacy manifest for first-party UserDefaults use, and verified review accounts. Resolve the items below before claiming submission readiness.

| Item | Evidence / next action |
| --- | --- |
| SDK required-reason API | Resolved in 1.1.6: rebuilt libsodium 1.0.22 for iOS 15 with upstream Apple RNG selection commit `f6bd9140861ab6806f4a99923888b65477fc4e33` backported. Final arm64 Release imports `arc4random_buf` and no longer imports `fstat`. No inaccurate File Timestamp reason was added. App Store Connect validation remains pending signing. |
| User-generated content / abuse handling | Incoming grants now require approval before showing photos/locations. Requests offer Approve, Deny and Block. Friends offer Remove & Block above Remove Friend; Settings → Account lists blocked users; Settings → Privacy & Support has Report a Problem. Blocks are account-scoped on this iPhone, survive logout, and do not control other clients or the backend. Report a Problem opens the public GitHub Issues page (https://github.com/Emphasize5599/family-locator-ios/issues), which loads without signing in; filing an issue requires a GitHub account. Nothing is attached automatically. The publisher must monitor GitHub Issues, respond promptly, and arrange escalation with Zood for service-level abuse; client controls alone do not establish complete guideline 1.2 compliance. |
| Rights and operator responsibilities | The project is AGPL-3.0 and interoperates with a third-party service. Source/license links and an independence disclaimer are included. ZOOD is a registered US trademark of Tangled Wires, LLC (Reg. No. 5,886,683, Class 9, location-sharing software), and guideline 4.1(c) forbids another developer's icon without approval, so the Zood icon was replaced with an original Family Circle icon (light, dark and tinted). "Zood" appears only in descriptive compatibility text, never in the app name, subtitle, keywords or icon. Guideline 5.2.2 still applies to using api.zood.xyz: retain evidence of permission from the service operator if Apple requests it. |
| Submission metadata | Public support is GitHub Issues (https://github.com/Emphasize5599/family-locator-ios/issues), which is also the App Store Connect Support URL; no public support email is published. Enter the publisher's real private review-contact name, phone and email, support details, age-rating answers, screenshots, description, privacy-policy URL and App Privacy answers. No live App Store Connect record was available to inspect. Do not select Kids Category without the additional requirements for that category. |
| Encryption | The previous unverified `ITSAppUsesNonExemptEncryption = NO` assertion was removed. Answer Apple's encryption questions based on the actual libsodium/crypto_box/secretbox/Argon2 implementation and obtain any required determination. |
| Physical-device validation | Test Always/While Using/denied/approximate location, background updates, Live Requests, Low Power Mode, force-quit/relaunch, timed-share expiry, logout and deletion on supported iPhones. Simulator/API checks do not establish background reliability. |

## Changes made

- Settings > Account > Delete Account uses the real authenticated `DELETE /1/users/me` endpoint. Username entry and a final destructive confirmation explain permanent deletion. A failed request remains an error; local logout is not presented as deletion.
- Logout/deletion cancel pending backup work, resolve location waiters, stop monitoring and streaming, clear cached fixes, cancel restart tasks and invalidate the background location session. Signed-out views cannot restart location activity just by becoming active.
- Permission changes reapply the streaming configuration, including when access is revoked.
- Onboarding and Settings link to the Family Locator privacy policy and support. Settings also links to open-source notices.
- The privacy manifest declares app-only preferences (`CA92.1`), no tracking, and conservative app-functionality disclosures for identifiers, optional email, precise location, optional photos, and device/location metadata. Review App Store Connect answers against the actual service behavior; the manifest does not populate those answers automatically.
- API requests use an ephemeral URLSession with no persistent response cache or cookies, including authentication responses.
- Timed-share text makes clear that expiry stops new uploads and cannot recall the last location or copies already received.

## Demo access

Real credentials are in the local, private, Git-ignored file `.review-private/APP_REVIEW_CREDENTIALS.md`. **Never commit that file or put its credentials in a public release or issue.** Copy the reviewer username/password into App Store Connect's private review fields.

The account was verified by fresh challenge/response authentication using the app's production Crypto/Models/OscarAPI code. It has a restored encrypted friend backup and a decryptable receiving-only sample location at the Golden Gate Bridge. The separate companion account is also verified. Neither account requires email verification, OTP, 2FA or a purchase.

The sample location is test data, not a real person's location or a continuous background test service. With no companion device running, a Refresh cannot make that phone answer. To test actual requests, sign the companion account into a second iPhone with Live Requests and the appropriate permissions enabled. Do not expose real family accounts to reviewers.

A separately generated disposable account was created, given an encrypted backup, deleted through the same API, and then confirmed unable to authenticate. The reviewer/companion accounts were not deleted.

Before each submission, verify the credentials again. If reviewers delete the account, create a replacement and update the private review fields. Do not reset the sample fixtures while a review is in progress.

`Tools/ReviewAccountTool.swift` contains the reproducible setup/verification code, with no embedded credentials. Compile it with the production `Core/Crypto.swift`, `Core/Models.swift`, and `Core/OscarAPI.swift`, linking the macOS slice of the resolved Clibsodium XCFramework. Pass a private output directory as its first argument. Running it creates real accounts and resets their sample fixtures; use the existing private state directory to avoid creating duplicate accounts.

## Suggested private review notes

Family Locator is an independent encrypted location-sharing client compatible with Zood Location. Its functionality relies on accounts so that selected friends can exchange encrypted location packages. There are no purchases, ads, or tracking SDKs.

Use the supplied demo credentials. The demo has one clearly identified sample companion located at a public landmark (Golden Gate Bridge); this is static test data. The demo does not share the reviewer's location with the sample friend by default. To test live sharing/Refresh, use the separately supplied companion credentials on a second device. Choose Always location access and enable Live Requests on that device. Viewing a friend's saved location does not require granting the reviewer's own location permission.

Background location is used for location sharing and receiving a fresh fix when an authorized friend requests one. Live Requests requires iOS 17+; on iOS 15/16 the app can share movement-triggered updates but does not advertise live request support. Disabling Live Requests, revoking permission or force-quitting can prevent responses. Background availability is controlled by iOS and is not guaranteed.

Timed Sharing is reached using the map-pin button above the friends bar. Its link contains the decryption key; anyone with the link can view shared locations. The timer stops new updates; previously delivered locations may remain visible. Stop the share using its toggle. Do not put a live timed-sharing link in public review materials.

Contact & Support and Report a Problem (both GitHub Issues), Privacy Policy, Open-Source Licenses and Background App Refresh status are in Settings; Blocked Users, Log Out and Delete Account are in Settings → Account (tap the profile tile). Delete Account permanently deletes the shared Zood account and encrypted backup; it is not a deactivate-only flow. The username and final confirmation are intentional safeguards.

## Public URLs

- Privacy: https://github.com/Emphasize5599/family-locator-ios/blob/main/Docs/PRIVACY.md
- Support (App Store Connect Support URL): https://github.com/Emphasize5599/family-locator-ios/issues
- Licenses: https://github.com/Emphasize5599/family-locator-ios/blob/main/Docs/LICENSES.md
- Service policy: https://www.zood.xyz/privacy/mobile-apps

## References

- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/): completeness, background-service use, user-generated content, privacy, account deletion and third-party rights.
- [Provide information for a complete review](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review/).
- [Required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) and [API categories and reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
- [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/).

## Validation completed for 1.1.5 (build 7)

- Xcode BuildProject passed with zero errors.
- Unsigned arm64 iOS Release build passed.
- Production API/crypto verification passed after the ephemeral-session change: reviewer and companion authentication, encrypted backup restoration and sample-location decryption. Disposable-account deletion had already passed against the live service.
- Privacy manifest parsed successfully; final bundle inspection is part of packaging.
- Device-interaction verification was attempted in a dedicated simulator session. The build succeeded, but install/launch stalled and captures remained on SpringBoard (`NotRun`). A launch retry did not recover it. The session was closed. No claim is made that login, Settings, deletion confirmation or logout was verified through the UI.
- Signing, Organizer validation and TestFlight processing were not possible with the current account setup.

## Additional submission checks from the supplied review article

The article is a useful checklist, not Apple policy or evidence that AI-written apps have a special rejection rate. Its claims about mandatory 5.5-inch screenshots, unconditional payment-link bans, and reviewers being unable to create accounts are too broad. Use Apple's current platform/territory rules and App Store Connect requirements.

- Supply accurate App Privacy answers; a bundled privacy manifest does not fill out the nutrition label. Do not over-declare invented collection either.
- Use real screenshots of this build; sample contacts must be clearly fictional. A fresh simulator is a test technique, not a requirement that screenshots contain no configured data. Follow current [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications), not the article's old size list.
- Complete the current age-rating questionnaire based on actual capabilities, including user-generated usernames/photos. Support/privacy links do not turn the app into an unrestricted browser. Do not guess an age rating or Kids Category.
- This is a native encrypted location-sharing app with background location, Maps, per-person consent and controls, not a repackaged website. Explain that utility accurately; minimum functionality is still Apple's judgment.
- No purchases or digital-payment flows exist, so StoreKit/payment changes are unnecessary.
- Test supported OS versions and physical devices, safe areas, large text, tap targets, cold launch, denied permissions and offline/error states. TestFlight testing remains pending signing; it is useful validation, not a guarantee of review approval.
- Supply the already-verified demo credentials in private review fields, explain static sample data and background location, and keep the backend/demo available throughout review. Private review-contact phone and name remain App Store Connect entries for the publisher.

## Validation for 1.1.6 (build 8)

- Final unsigned arm64 Release build passed through `xcodebuild`, linking the checked-in local Clibsodium package. Executable inspection confirms no `_fstat`, with `_arc4random_buf` present; minimum iOS remains 15.0. The privacy manifest parses successfully.
- Production Keychain checks passed for pending request persistence, block/unblock updates, isolation between two temporary accounts, and decoding the existing local friends format. Temporary Keychain entries were removed afterward.
- Simulator UI verification passed real demo login, saved sample location display with location permission denied, Requests empty state, friend More menu, Safety Number, support/contact links and Blocked Users empty state. It caught UIKit reversing the bottom-anchored menu; action order was adjusted accordingly. No reviewer friendship/block state was modified. Populated pending request actions and physical-device background behavior remain manual checks.
- The shared Zood iOS build/run/archive scheme is checked in. After reopening the workspace, Xcode lists the scheme as active and BuildProject passes with the local dependency.
- TestFlight/App Store signing and Organizer validation remain pending the publisher's developer-account setup. Unsigned and ad-hoc fakesigned IPAs are review/testing artifacts, not TestFlight uploads.

## Screenshot tour and compact sheets

Safety Number, Add Friend, Pending Requests and Timed Sharing measure content and adjust their sheet height on iOS 16+, remaining scrollable for large text/short screens. iOS 15 retains its full-height sheet fallback. Settings remains a full scrollable form. Report a Problem and Contact & Support (Settings > Privacy & Support) both open GitHub Issues.

The Debug-only screenshot tour uses fictional in-memory fixtures and rejects Zood API calls. It captures light/dark/large-text variants into an HTML gallery/viewer and ZIP. See [UI_TOUR.md](UI_TOUR.md). Tour fixtures are not a substitute for the real private reviewer account, runtime behavior checks, or accurate App Store screenshots.

Final simulator checks confirmed the displayed Remove & Block / Remove Friend order and Settings-only reporting. The fitted-sheet check caught and fixed an initial zero-height measurement; subsequent Safety Number screenshots show all digits and the Share action. Xcode BuildProject and the final unsigned Release build pass after these changes. Tour output is a 39-screen matrix (13 scenes × light, dark, largest accessibility text), with per-scene readiness and retained light/dark captures when updating variants. The hosted GitHub workflow is supplied but not yet run here.

## Nicknames and account navigation (1.1.9)

The optional shared nickname is encrypted profile metadata. A private friend nickname never goes to that friend; it is part of the account's encrypted backup. App Privacy answers should account for optional names as well as usernames, photos and location. The username remains visible in Settings and in each friend's View Username menu; nicknames never substitute for identity or safety checks.

The Account submenu contains the shared-name editor, Blocked Users, Log Out and Delete Account. Change Photo is a separate blue-text action in the profile tile. Report a Problem opens the publicly readable issues list; posting still requires GitHub authentication.

### Verification limits for this change

Production-model integration checks pass for nickname precedence, clearing, legacy message/backup decoding, optional encrypted-backup fields and copied @handle lookup. The existing Keychain pending/block/unblock/account-isolation checks also pass.

Earlier iPhone 11 captures verified nickname saving, View Username/copy, wider name/address layout, empty-request text, and stable map scale at expanded sheet endpoints. Final keyboard padding, X-discard, accessibility scrolling and Account changes compile but remain unverified through the UI: iPhone 11, SE and Pro Max simulator connections failed, including after a CoreSimulatorService restart and a single cold boot. Only iOS 27.2 simulator runtimes are installed; the reported iOS 17.1.2 device behavior still needs a physical-device check. All sessions were closed and simulators shut down. Diagnostic captures are not presented as final screenshots.

## Linked contacts, maps links and status row (1.1.10)

- **Linked contacts** use Apple's `CNContactPickerViewController`, which returns only the contact the person picks. The app never requests Contacts authorization, so `NSContactsUsageDescription` is not needed and no permission prompt appears. Only the chosen contact's display name and Contacts identifier are kept, in this device's preferences under the signed-in account and (from 1.1.16) in the end-to-end encrypted account backup, which the server cannot read. They are never sent to the friend, and Delete Account removes the local copy along with the backup. Name priority is: private nickname, then linked contact, then the friend's shared nickname, then `@username`.
- **Address as a Maps link** replaces "Open in Maps" in the friend ⋯ menu; that slot is now Link Contact. The address stays in the regular text color, underlined, with a small map glyph on the first line only.
- **One status row** below the address shows Requesting…, the brief green Updated check, No response / Unsupported, and then "Updated …" (a relative time today, otherwise a date and time). Refresh is an icon-only button with the accessibility label "Refresh location".
- The friend bar now clips scrolling content to its rounded shape, so the Add/Requests buttons and avatars no longer draw over its corners.
- App Privacy answers are unchanged: contact data stays on device and is not "collected" in App Store Connect's sense.

## Readability on iOS 15–17 and text size (1.1.12)

- Secondary text and icons on the map's floating cards use UIKit's `secondaryLabel` color. SwiftUI's `.secondary` becomes vibrant on a blur material before iOS 26 and was nearly invisible in Dark Mode on an iOS 17 iPhone (battery, update time, "Share my location", platform logo).
- The pre-iOS 26 Refresh button keeps its tint and icon when unavailable and is dimmed instead of becoming a blank gray box.
- Map controls (Settings, My Location, timed sharing) use Zood navy in Light Mode and the app's light blue in Dark Mode.
- Dynamic Type is followed up to Accessibility 1 (`maxTextSize` in `MyApp.swift`). Larger accessibility sizes stacked the floating map controls on top of each other; supporting every size isn't an App Review requirement, and Larger Text up to that point still applies everywhere.

## Backups, friend folders and polish (1.1.16)

- **Encrypted backup** now also carries blocked accounts and each friend's linked contact (name, plus a platform-specific contact reference). The backup is encrypted on the device with the account's symmetric key, so the server can't read it. Older and stock Zood clients ignore the extra JSON keys; Android 1.1.6-family restores linked-contact names and carries the blocked list through its own backups. Pending requests are still not backed up. App Privacy answers should be reviewed before submission: contact names now leave the device, but only end-to-end encrypted.
- **Friend folders:** long-press a friend in the bar and drop them on another to make a folder (Discord-style), on a folder to join it, or on the bar to leave. Folders are saved on this iPhone only and never change who sees your location.
- Round Refresh button; extra space under the underlined address; no edge fade on the friend bar; Settings account row shows just the name, with Change Photo inside Account; About drops the Zood blurb (now in Notices & Trademarks); Copy Link and Share Link are the same size on iOS 15–25; sheet headers sit just under the drag indicator with 20 pt side margins.

## Friend bar arranging and contact photos (1.1.17)

- **Arranging the bar** follows the Home Screen model: long-press to lift (with haptics), drag sideways and the others slide aside (order saved), hold over the middle of someone to make a folder, and folders open above the bar as a grid (3×3 by default like Home Screen folders, adjustable in Settings › Friend Bar). VoiceOver users get Move Left / Move Right and Remove from Folder actions.
- **Backup:** the bar order and folders join blocked accounts, nicknames and linked contacts in the end-to-end encrypted account backup (optional `folders` / `bar_order` keys, ignored by older clients; Android 1.1.7-family carries them through).
- **Linked contacts** now set the friend's nickname to the contact's first and last name and use the contact's thumbnail, as framed in Contacts, as the friend's picture. The photo stays on the device. Every avatar renderer fills and crops, never stretches (checked with deliberately tall and wide test images).
