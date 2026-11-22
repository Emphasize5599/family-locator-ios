# Family Locator privacy policy

Effective November 22, 2026.

Family Locator is an independent, open-source iPhone client for the Zood Location network, maintained through [Emphasize5599/family-locator-ios](https://github.com/Emphasize5599/family-locator-ios). It is not affiliated with Tangled Wires, LLC. The account and encrypted-message service is operated by Zood at `api.zood.xyz`; its [mobile-app privacy policy](https://www.zood.xyz/privacy/mobile-apps) also applies to that service.

## Information used

- **Account information:** your username, public account identifier and public encryption key are sent to the Zood service. You may optionally provide an email address at registration. Password-derived encryption protects your private keys; the app does not send your plaintext password to the service.
- **Location and device information:** when you allow location access, the app obtains coordinates, timestamp, accuracy, speed and direction, and may include battery level, charging state, device platform and whether location requests are supported. Location packages are encrypted on your device for the people you choose to share with. The service carries and stores encrypted packages; recipients can decrypt them.
- **Friends and profile photo:** the app stores your friends, sharing settings, received locations and optional profile photo locally. It uploads an encrypted friends-list backup to your account, and sends your selected profile photo to friends you share with. Photo selection uses Apple's system picker; the app does not request access to your entire photo library.
- **Service connections:** the Zood service receives the requests needed to authenticate, find usernames and deliver encrypted data. As with any internet service, it receives connection information such as an IP address. The independent app maintainers do not control Zood's infrastructure or its retention of service logs.
- **Apple services:** the map and address lookup use Apple Maps and Core Location. Those services are subject to Apple's privacy policies.

The app contains no advertising or third-party analytics SDK and does not use advertising identifiers or cross-app tracking. Local diagnostic logs describe connection/location-service events, not raw coordinates, passwords or encryption keys.

## Your choices and consent

You can view friends without sharing your own location. Adding a friend starts sharing your location with that username; the Add Friend screen explains this before you confirm. Turn off a friend's sharing toggle or remove the friend to stop future sharing with them. Other people may retain locations or screenshots they previously received.

Always location access enables background location sharing. Live Requests uses background location activity to remain available for requests and may use additional battery. You can switch it off in the app's Settings, change location permission in iOS Settings, or log out. Logging out removes this app's credentials and local friend data and stops its location activity on this iPhone; it does not delete your server account.

Timed sharing creates a link containing a decryption key. Anyone with that link can view the shared location. Do not post the link publicly unless you intend that access. Stopping the share or letting its timer expire stops future updates; the last transmitted location and copies already received may remain accessible. The app cannot recall screenshots or data retained by recipients.

Incoming sharing requests are held for approval before displaying the sender's location or photo. Approving does not share your location back. Deny dismisses a request; Block also ignores future messages from that account on this iPhone and removes any friendship. Review or unblock accounts in Settings. Blocking applies to this app on this device, not other Zood clients. Locations already delivered to other people cannot be recalled.

## Storage, retention and deletion

Account credentials and private keys are stored in the iOS Keychain. The local friends file uses iOS file protection. Pending requests and blocked-account identifiers are stored per account in this device's Keychain; they survive logout, are not synchronized to other clients, and are removed here after successful account deletion. The app uses its own preferences for settings and upload timing. Server backups and location payloads are encrypted, but encryption does not conceal all account identifiers or connection metadata.

Use **Settings > Delete Account** to permanently delete the authenticated Zood account and its encrypted friends-list backup. This affects the same account in other Zood-compatible clients. After the server confirms deletion, this app signs out, removes local account data, and stops location monitoring. An unsuccessful network request is shown as an error; logging out alone is not represented as deletion. Zood's [account deletion page](https://www.zood.xyz/location/delete-account) is also available.

The app does not promise to erase encrypted packages, provider backups or logs beyond the deletion behavior documented by the service operator. Previously received locations, shared links and copies saved by other people cannot be recalled.

## Contact and changes

For Family Locator support, privacy questions, or abuse reports, email [bens@sanzone.net](mailto:bens@sanzone.net). Report a Problem in the app prepares an email containing the selected username; you choose whether to send it and what to include. No location, photo, password or encryption key is attached automatically. Your email provider handles the message, and the maintainer receives your email address and submitted details to investigate and respond. Do not send passwords, location coordinates, private keys, or timed-sharing links. Reports cannot directly suspend an account on the independently operated Zood service; backend concerns may require contacting its operator. For private account or server-data questions, use [Zood's contact page](https://www.zood.xyz/contact).

Policy changes will be published on this page with an updated effective date. Material changes to data use require updated disclosures and, where applicable, consent.
