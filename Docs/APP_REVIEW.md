# iOS App Review preparation

Audited November 22, 2026. This is an engineering review, not an Apple approval or a guarantee of acceptance. Signing, App Store Connect validation and device-only behavior remain outside the completed checks.

## Status: not ready to submit yet

The app now has an in-app deletion flow, published privacy/support/license links, a privacy manifest for first-party UserDefaults use, and verified review accounts. Resolve the items below before claiming submission readiness.

| Item | Evidence / next action |
| --- | --- |
| SDK required-reason API | The linked Release executable imports `_fstat`. The bundled libsodium `randombytes_sysrandom` object uses it to verify `/dev/random` or `/dev/urandom` device type. Apple's File Timestamp category includes `fstat`; the documented app-container reason does not accurately describe that system-device access. No misleading reason was added. Obtain an upstream Apple-platform binary using its supported `arc4random` path without the fallback, or a supported/approved declaration, then inspect the final executable and run App Store Connect validation. Do not merely add `C617.1` to hide the warning. |
| User-generated content / abuse handling | Users exchange profile photos and usernames. Removing a friend stops future outgoing sharing, but is not a durable block against unsolicited incoming messages. There is no report/moderation workflow. Evaluate guideline 1.2 with the service operator; provide appropriate blocking/reporting and a real response process before public distribution. A public GitHub issue is not a private channel for sensitive location or abuse reports. |
| Rights and operator responsibilities | The project is AGPL-3.0 and interoperates with a third-party service. Source/license links and an independence disclaimer are included. Confirm rights for the existing icon/branding, App Store distribution obligations, and continued use of the backend; this audit does not establish those rights or third-party retention guarantees. |
| Submission metadata | Enter the publisher's real review-contact name, phone and email, support details, age-rating answers, screenshots, description, privacy-policy URL and App Privacy answers. No live App Store Connect record was available to inspect. Do not select Kids Category without the additional requirements for that category. |
| Encryption | The previous unverified `ITSAppUsesNonExemptEncryption = NO` assertion was removed. Answer Apple's encryption questions based on the actual libsodium/crypto_box/secretbox/Argon2 implementation and obtain any required determination. |
| Physical-device validation | Test Always/While Using/denied/approximate location, background updates, Live Requests, Low Power Mode, force-quit/relaunch, timed-share expiry, logout and deletion on supported iPhones. Simulator/API checks do not establish background reliability. |

## Changes made

- Settings > Delete Account uses the real authenticated `DELETE /1/users/me` endpoint. Username entry and a final destructive confirmation explain permanent deletion. A failed request remains an error; local logout is not presented as deletion.
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

Privacy Policy, Support, Open-Source Licenses, Background App Refresh status and Delete Account are accessible in Settings. Delete Account permanently deletes the shared Zood account and encrypted backup; it is not a deactivate-only flow. The username and final confirmation are intentional safeguards.

## Public URLs

- Privacy: https://github.com/Emphasize5599/family-locator-ios/blob/main/Docs/PRIVACY.md
- Support: https://github.com/Emphasize5599/family-locator-ios/issues
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
