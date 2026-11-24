# Amidst on the App Store

Not ready to submit. This file is the script for App Store Connect. It is not an Apple approval.

Reviewer usernames and passwords stay in `.review-private/APP_REVIEW_CREDENTIALS.md`. That file is Git-ignored. Do not paste it here, into a release, or into a GitHub issue.

The home-screen name is Amidst. The store name is Amidst: Where Everyone Is.

## What's left to do

Do these before submitting. The form answers and the listing text below are ready to paste.

1. Re-check both demo accounts against the live service. Create one new disposable account, delete it through Settings → Account → Delete Account, and confirm it can no longer sign in. If a reviewer deletes a demo account, replace it and update the private file. Do not reset the sample friend while a review is open.
2. On a physical iPhone, test Always, While Using, denied, and approximate location. Also test background updates, Live Requests, Low Power Mode, force-quit and relaunch, timed-share expiry, log out, and deletion. A simulator pass does not cover this.
3. Archive with the publisher's distribution certificate and upload the build. The GitHub IPAs are sideloads, not App Store builds. `ITSAppUsesNonExemptEncryption` is already `YES`.
4. Create the App Store Connect record for bundle ID `com.bensanzone.amidst`. Paste the answers and the listing from this file. Enter the publisher's own review-contact name, phone, and email. Enter the copyright name. Choose the territories.
5. On the encryption questions, do not answer "HTTPS only." The app uses libsodium public-key encryption, secret-box encryption, and Argon2. The publisher decides which exemption applies and files any required paperwork.
6. Take the screenshots from this build. Use fictional people. Do not show a price, the word "free," the Zood icon, or a live timed-share link.
7. Confirm someone monitors https://github.com/Emphasize5599/family-locator-ios/issues and can escalate service abuse to the Zood operator. Deny and Block in the app are not enough on their own.
8. Keep evidence that Amidst may use `api.zood.xyz`, in case Apple asks under guideline 5.2.2.
9. Read https://www.zood.xyz/privacy/mobile-apps and confirm the privacy answers still match what that service stores.

Do not choose the Kids Category. Do not ask Brazil for a lower Shared Location rating. Do not put "free" or a price in the name, subtitle, screenshots, or previews.

## Answers for the submission form

Apple calculates the age rating from the questionnaire. Do not type a rating in by hand.

### App Information

| Field | Answer |
| --- | --- |
| Name | Amidst: Where Everyone Is |
| Subtitle | Open Source, Always Encrypted |
| Bundle ID | `com.bensanzone.amidst` |
| Primary language | English (U.S.) |
| Primary category | Social Networking |
| Secondary category | Lifestyle |
| Content rights | No licensed third-party catalog. Apple Maps is the system map. Photos and names are user content. |

Age rating, capabilities:

| Question | Answer |
| --- | --- |
| Parental controls | None |
| Age assurance | None |
| Unrestricted web access | None. Privacy, support, and license links open fixed pages. |
| User-generated content | Yes. Usernames, optional photos, and nicknames are shared with chosen friends. |
| Messaging and chat | None. There is no conversation thread. |
| Advertising | None |
| Social media | None. There is no feed and no discovery of strangers. |
| Shared location | Yes |
| Dating and relationships | None |

Age rating, content: None for every frequency question. That includes violence, profanity, sexual content, horror, gambling, alcohol and drugs, medical or wellness topics, contests, and loot boxes.

License agreement: Apple's standard EULA. The AGPL and the App Store exception stay on the source repository. They are linked from Settings. They are not the store EULA.

### Pricing and Availability

Price is free. There are no in-app purchases. Sell it in every territory unless the publisher has a reason to exclude one.

### App Privacy

Privacy Policy URL: https://github.com/Emphasize5599/family-locator-ios/blob/main/Docs/PRIVACY.md?view=policy

Data is collected, linked to the user, and used for app functionality. It is not used for tracking. There is no advertising SDK and no analytics SDK. The Zood service at `api.zood.xyz` receives the account and the encrypted packages, so include that service when the form asks about third parties.

| Data | Collected | Notes |
| --- | --- | --- |
| User ID | Yes | Username and public account identifier. |
| Email address | Yes | Optional, at registration. |
| Precise location | Yes | Encrypted on the device for the people the user chose. |
| Fitness | Yes | Walking, running, cycling, or driving, sent inside the encrypted location package. |
| Contacts | Yes | Only a chosen contact's name and identifier, inside the encrypted backup. The address book is not uploaded. The contact photo stays on the device. |
| Photos | Yes | Optional profile photo, encrypted for friends. |
| Other data | Yes | Battery, platform, accuracy, speed, and direction, inside the encrypted package. The service also sees connection metadata such as IP address. |

Not collected: payment info, health records beyond the motion category above, browsing history, search history, advertising data, or the full contacts database.

### Prepare for Submission

| Field | Answer |
| --- | --- |
| Support URL | https://github.com/Emphasize5599/family-locator-ios/issues |
| Marketing URL | Leave blank |
| Copyright | The publisher's legal name. It is not in this repository. |
| Sign-in required | Yes |
| Demo account | Copy both accounts from the private credentials file. No email code, no two-factor prompt, and no purchase. |
| Review contact | The publisher's name, phone, and email. |
| What's New | First release. |

App Review Information notes:

```
The App Store name is Amidst: Where Everyone Is. The subtitle is Open Source, Always Encrypted. On the home screen the app is Amidst.

Amidst is an independent encrypted location-sharing client compatible with Zood Location. Accounts exist so chosen friends can exchange encrypted location packages. Location packages, friend messages, shared photos, and the account backup are encrypted on the device before upload. The service can still see account identifiers and connection metadata. There are no purchases, ads, or tracking SDKs.

Use the supplied demo credentials. The demo has one sample companion at the Golden Gate Bridge. That pin is static test data, not a live person. The demo does not share the reviewer's location with that companion. To test a live refresh, sign the companion account into a second device, choose Always, and turn on Live Requests. Viewing the saved pin does not require the reviewer's own location permission.

Background location keeps a share updated and answers a refresh from a friend who was already granted access. Live Requests requires iOS 17 or later. On iOS 15 and 16 the app can still share movement-triggered updates and does not advertise Live Requests. Turning Live Requests off, revoking permission, or force-quitting can stop replies. iOS decides whether background time is available.

Timed Sharing is the map-pin button above the friends bar. The link contains the decryption key. Anyone with the link can view the shared locations. The timer stops new updates. Locations already delivered can remain visible. Stop the share with its toggle.

Contact & Support and Report a Problem both open GitHub Issues. Privacy Policy, Open-Source Licenses, and Background App Refresh are in Settings. Blocked Users, Log Out, and Delete Account are in Settings → Account, under the profile tile. Delete Account permanently deletes the shared Zood account and its encrypted backup after the server confirms. A failed request is not treated as deletion.
```

### Export compliance

The build declares non-exempt encryption because the app does more than HTTPS. On the upload questions, describe libsodium encryption used to protect location packages, messages, and backups. The publisher chooses the exemption and completes any annual self-classification or other filing that choice requires.

## Suggested App Store listing

| Field | Text | Characters |
| --- | --- | --- |
| Name | Amidst: Where Everyone Is | 25 |
| Subtitle | Open Source, Always Encrypted | 29 |
| Promotional text | Locations are encrypted on your phone before they are sent. The source is public. Share only with the family and friends you choose. | 132 |

Keywords:

```
map,location,share,family,friend,private,gps,locator,find,track,tracker,tracking,kid,child,phone
```

Description:

```
Amidst is where the people you care about are. Share your location with family and friends you choose, and see the locations they share with you.

Locations, messages, and account backups are encrypted on your phone before they are sent. There is no plaintext sharing mode. The source code is public.

Add friends by username. Choose whether to share with each person, and stop sharing at any time. Organize the map into folders. For a time-limited share, create a link and send it to someone you trust.

With your permission, Amidst can update a share in the background and answer a Live Request from a friend you already share with. You can view friends and send requests without sharing your own location.

Amidst is an independent open-source client for the Zood Location network and works with Amidst on Android. It is not affiliated with Zood's trademark owner. There are no purchases and no ads.
```

Screenshots: follow the current specifications at https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications. Use this build. Sample people must be fictional. The first images should show the map with friends on it.

## For AI agents

Humans can submit from the sections above. This section is the engineering record. Do not treat it as store copy.

### Listing decisions

The name and subtitle are locked. Do not repeat a word between them. Guideline 2.3.7 forbids "free" and prices in the name, subtitle, screenshots, and previews. The description may say there are no purchases and no ads.

Primary Social Networking and secondary Lifestyle are the categories Life360 uses. Social Networking is people sharing with people they know. Navigation would describe a directions app.

The keyword string in the listing section is 96 of 100 characters. Four characters are open, which is one 3-letter word. `mom` or `dad` would fill it. Either one leaves the other parent out, so neither was added.

Apple indexes each word once across the name, subtitle, and keywords, and treats a plural as a repeat of the singular. `friend` is singular for that reason. `kids` and `children` are repeats of `kid` and `child`. `find` is included and `my` is not, so the field does not spell Find My. Nothing in the list repeats Amidst, Where, Everyone, Is, Open, Source, Always, or Encrypted.

`finder` came out so `tracking` would fit. `find` and `friend` still combine. The searches this list is aimed at are family locator, find a friend, share location, private map, GPS, phone tracker, kid tracker, and child tracking. Left out: live, teen, nearby, privacy, realtime, and pet. `private` stays. Also left out, because they name a feature rather than a search: together, places, home, requests, folders, links, and group. Also left out: safety, alert, and history. The app does not track a pet, and it does not offer location history, place alarms, or crash detection.

Kid and child are search words. They are not a reason to choose the Kids Category. Shared Location can display as 16+ in Brazil. This is not a parent-and-child product, so do not ask Brazil for a lower rating on that basis. Apple calculates the age rating from the questionnaire.

"Always Encrypted" means location packages, friend messages, shared photos, and the account backup are encrypted on the device before upload. There is no plaintext sharing mode. The service can still see account identifiers and connection metadata. Do not describe that as the server being unable to see anything. On the encryption questions, do not answer "HTTPS only."

The Play title and short description are in the Android repo at `fastlane/metadata/android/en-US/` and in `Docs/PLAY_REVIEW.md`.

Audited November 22, 2026, with a follow-up on November 24. Signing, App Store Connect validation, and physical-device background behavior are not claimed as done.

### November 24, 2026

- The 1.1.48 candidate (build 50) still deploys to iOS 15 and builds with Xcode and SDK 27.2. Unsigned and ad-hoc IPAs are sideloading artifacts.
- 1.1.49 (build 51) uses bundle ID `com.bensanzone.amidst` and product name Amidst. The friend-link URL name, keychain services, location log, and wake-up geofence use that prefix. It installs beside `com.bensanzone.zood` and does not migrate that app's keychain or monitored region. User-facing Zood mentions stay in Notices & Trademarks, account deletion, the privacy policy, and the store description.
- The privacy manifest includes Contacts because an optional contact name and reference are stored in the encrypted backup. An earlier 1.1.10 note said contact data never left the device. That became stale in 1.1.16.
- A phone symbol indicates an iPhone. The Zood icon was removed. Guideline 4.1(c) forbids another developer's icon without approval. ZOOD is a registered US trademark of Tangled Wires, LLC (Reg. No. 5,886,683, Class 9). "Zood" appears only in descriptive compatibility text.
- Account deletion calls `DELETE /1/users/me` and waits for confirmation before clearing the local account. A historical disposable-account deletion passed. Recheck it before the submission in progress.
- Report a Problem opens the public GitHub Issues page. Filing an issue requires a GitHub account. Nothing is attached. Blocks are enforced by the client after restore. The server cannot read or enforce the block list.

### Resolved engineering

- Settings → Account → Delete Account uses the authenticated delete endpoint. Username entry and a final confirmation explain that deletion is permanent. Logout is not presented as deletion.
- Logout and deletion cancel pending backup work, stop monitoring and streaming, clear cached fixes, and invalidate the background location session. A signed-out screen does not restart location by becoming active.
- Permission changes reapply streaming, including when access is revoked.
- Onboarding and Settings link to the privacy policy and support. Settings also links to open-source notices.
- The privacy manifest declares UserDefaults (`CA92.1`), system boot time (`35F9.1`), no tracking, and the collected-data rows in the form section above. The manifest does not fill out App Store Connect by itself.
- API requests use an ephemeral URLSession with no persistent cache or cookies.
- Timed-share text says expiry stops new uploads and cannot recall a location already delivered.
- libsodium 1.0.22 was rebuilt for iOS 15 with upstream Apple RNG selection commit `f6bd9140861ab6806f4a99923888b65477fc4e33`. The arm64 Release imports `arc4random_buf` and does not import `fstat`. No File Timestamp reason was added.

### Demo accounts

Credentials stay in `.review-private/APP_REVIEW_CREDENTIALS.md`.

Both accounts were verified with the production Crypto, Models, and OscarAPI code. The reviewer account restores an encrypted backup and can decrypt a receiving-only sample at the Golden Gate Bridge. The companion account was verified separately. Neither needs email verification, a one-time code, two-factor authentication, or a purchase.

The sample location is not a continuous background service. With no companion device running, Refresh cannot make that phone answer.

A disposable account was created, given an encrypted backup, deleted through the same API, and then confirmed unable to authenticate. The reviewer and companion accounts were not deleted.

`Tools/ReviewAccountTool.swift` reproduces setup. It contains no credentials. Compile it with `Core/Crypto.swift`, `Core/Models.swift`, and `Core/OscarAPI.swift`, link the macOS slice of Clibsodium, and pass a private output directory. Running it creates real accounts. Reuse the existing private state directory.

### Public URLs

- Privacy: https://github.com/Emphasize5599/family-locator-ios/blob/main/Docs/PRIVACY.md?view=policy
- Support: https://github.com/Emphasize5599/family-locator-ios/issues
- Licenses: https://github.com/Emphasize5599/family-locator-ios/blob/main/Docs/LICENSES.md
- Service policy: https://www.zood.xyz/privacy/mobile-apps

### References

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Provide information for a complete review](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review/)
- [Required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)

### Validation for 1.1.5 (build 7)

- Xcode BuildProject passed with zero errors.
- Unsigned arm64 Release build passed.
- Production API and crypto checks passed after the ephemeral-session change: reviewer and companion authentication, backup restore, and sample-location decryption.
- The privacy manifest parsed. Final bundle inspection belongs to packaging.
- A device-interaction session built, then install and launch stalled on SpringBoard (`NotRun`). The session was closed. Login, Settings, deletion, and logout were not verified through that UI.
- Signing, Organizer validation, and TestFlight were not possible with the account setup at the time.

### Validation for 1.1.6 (build 8)

- Unsigned arm64 Release passed, linking the checked-in Clibsodium package. No `_fstat`. `_arc4random_buf` is present. Minimum iOS is 15.0.
- Keychain checks passed for pending requests, block and unblock, isolation between two temporary accounts, and the existing friends format. Temporary items were removed.
- Simulator UI passed demo login, the saved sample with location denied, the empty Requests state, the friend More menu, Safety Number, support links, and empty Blocked Users. It caught a reversed bottom menu. The action order was corrected. Reviewer friendship state was not modified.
- The shared scheme is checked in. BuildProject passes with the local dependency.
- Unsigned and ad-hoc IPAs are not TestFlight uploads.

### Later UI checks

Safety Number, Add Friend, Pending Requests, and Timed Sharing size their sheets on iOS 16 and later. iOS 15 keeps the full-height sheet. Report a Problem and Contact & Support open GitHub Issues.

The Debug-only screenshot tour uses fictional in-memory fixtures and rejects Zood API calls. See [UI_TOUR.md](UI_TOUR.md). Tour output was a 39-screen matrix. It is not the App Store screenshot set and not a substitute for the reviewer account.

Nickname checks passed for precedence, clearing, legacy decoding, optional backup fields, and @handle lookup. iPhone 11 captures verified nickname saving and View Username. Later keyboard, discard, and Account edits compiled, then simulator connections failed. Only the iOS 27.2 runtime was installed. Physical-device checks on older iOS remain open. Sessions were shut down.

Linked contacts use `CNContactPickerViewController` and do not prompt for Contacts permission. From 1.1.16 the chosen name and identifier also ride in the encrypted backup. From 1.1.17 the contact's name becomes the private nickname and the contact thumbnail is the avatar. The photo stays on the device. Avatars crop. They do not stretch.

Friend folders and bar order are in the encrypted backup from 1.1.17. They do not change who can see a location. Consequential actions ask for confirmation.

Secondary map text uses UIKit `secondaryLabel` so it stays readable on iOS 15–17. Dynamic Type is supported through Accessibility 1.

### What an old article got wrong

A supplied review article is a checklist, not Apple policy. It overstated mandatory 5.5-inch screenshots, a blanket ban on payment links, and a rule that reviewers cannot create accounts. Use the current form and the screenshot specifications linked above.
