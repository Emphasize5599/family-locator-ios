# Zood client protocol (as implemented by george / oscar)

Server: `https://api.zood.xyz/1/` · JSON keys are snake_case · `byte[]` fields are standard base64 (no wrapping, padded).
Auth header: `X-Oscar-Access-Token: <token>`. Errors: `{"error_code": Int, "error_message": String}`.

## Crypto (libsodium)
| Use | Primitive |
|---|---|
| Identity keypair | `crypto_box_keypair` (X25519, 32-byte keys) |
| Messages / drop-box packages | `crypto_box_easy(msg, nonce, receiverPub, senderSec)` → `{cipher_text, nonce}` |
| Wrapping secret key, symmetric key, backups | `crypto_secretbox_easy` |
| Password stretch | `crypto_pwhash`, 32-byte output. Signup uses `argon2id13`, ops 30, mem 64 MiB, 16-byte salt. Login must honour whatever alg/ops/mem the server returns (`argon2i13` = sodium alg id 1, `argon2id13` = 2). |

## Sign up — `POST users`
Body: `username, email?, public_key, password_salt, password_hash_algorithm, password_hash_operations_limit, password_hash_memory_limit, wrapped_secret_key(+_nonce), wrapped_symmetric_key(+_nonce)` (both wrapped with the password hash). Response `{id}` (16 bytes). Then log in normally.

## Log in
1. `POST sessions/{username}/challenge` → `{user:{public_key, wrapped_secret_key(+_nonce), password_salt, password_hash_*}, challenge, creation_date}`
2. Stretch password, `secretbox_open` the secret key (failure = wrong password).
3. `GET public-key` → `{public_key}` (server).
4. `POST sessions/{username}/challenge-response` with `{challenge: box(challenge), creation_date: box(creation_date)}` (to server pubkey, from our secret key) → `{id, access_token, wrapped_symmetric_key(+_nonce)}`.
5. `GET users/me/backup` → EncryptedData (secretbox with symmetric key) of Snapshot JSON; error 20 = no backup.

## Snapshot (backup) — `PUT users/me/backup`
`{friends:[{user_id, sending_box_id, receiving_box_id, nickname?, shared_nickname?, avatar_thumbnail?}], nickname?, users:[{user_id, public_key, username}], avatar?, blocked?, invites?:[{token, used_by?}], schema_version: 1, timestamp(ms)}`. Never write `schema_version > 1` or Android refuses to restore (OutdatedClient). `avatar_thumbnail` is optional base64 image data for a friend’s shared profile photo. The edge is at most 128 pixels, with 12 KiB per image and 128 KiB of raw thumbnails per backup. Private linked contact photos stay on-device. Older clients ignore the field and may omit it when rewriting a backup.

## Messages (user → user, crypto_box)
- Send: `POST users/{hexUserId}/messages` `{cipher_text, nonce, urgent, transient}`
- Fetch: `GET messages` → `[{id, sender_id, cipher_text, nonce, sent_date}]`; delete after processing `DELETE messages/{id}`.
- Look up a sender: `GET users/{hexId}` → `{username, public_key}`; search: `GET users?username=` → `{id, username, public_key}`.

## UserComm JSON (plaintext inside messages and packages)
`type` ∈ avatar_request, avatar_update(avatar), location_sharing_grant(drop_box 16B), location_sharing_revocation, location_info(latitude, longitude, time ms, accuracy?, speed?, bearing?, movement?, battery_level?, battery_charging?), location_update_request, location_update_request_received(location_update_request_action: starting|too_soon|finished), device_info (self only!), browse_devices/scream/scream_began (self only).
Android drops unknown `type`s, ignores unknown fields. Registration availability uses the unauthenticated authentication-challenge endpoint without completing the challenge. Account lookup in Add Friend uses the authenticated username search. Both checks are debounced and submission remains authoritative.

`friend_request` is a durable, encrypted request-only message with optional `nickname` and `avatar`. It carries no drop box, return box, or location. Recipients can approve the friend record with both boxes empty, or deny or block without a notification to the sender. A later location grant from either participant updates that friendship in place. The receiving client records that the friendship was established without a grant and never enables its own outgoing sharing when handling the grant. The optional `established_without_location` field preserves that decision in backup format version 1. Other grants still need approval unless they match an existing share or reply to an active invitation. Only updated Amidst clients recognize this message. Pending requests can display profile photos sent with the request or delivered as a subsequent encrypted avatar update.

A one-time invite sends one durable encrypted message carrying `invite_token` (16 bytes, standard base64). It uses `friend_request` when the recipient keeps sharing off or `location_sharing_grant` when the recipient explicitly chooses to share. The inviter creates the token when sharing the link (`#t=` in the web URL fragment, base64url without padding), and stores it in the optional backup list `invites`. The first eligible redemption consumes the token (`used_by` is the sender). It creates a friendship with no outgoing share on the inviter side and only fills the receiving box if the recipient chose to share. Unknown tokens and replays are ignored. Both sides need an updated Amidst client for automatic acceptance. Older clients use the ordinary request flow for message types they recognize. Redemption happens when the inviter's client processes the message. The encrypted backup carries token state between installs, and the server does not arbitrate simultaneous redemption against separate copies of the backup.

Blocked IDs live in the end-to-end encrypted `blocked` backup field. The server stores the ciphertext and the clients enforce the block list.

### Fork extension (this project)
`location_info` (and `location_update_request_received`) carry extra fields:
- `platform`: `"ios"` | `"android"`
- `live_requests`: Bool — device currently holds a socket and can answer `location_update_request`.
Stock Zood ignores them. Absent fields leave the sender’s capabilities unknown and Refresh available.

Fork-only message types (sent only to friends who have reported `platform`/`live_requests`, so stock Zood never
receives them):
- `device_status_request` (no fields), sent transient + urgent: "can you answer location requests right now?"
  Sent before showing Unsupported for a friend whose cached `live_requests` is `false`, at most once a minute.
- `device_status` (`platform`, `live_requests`), the transient + urgent reply. Only sent to friends we share with.
  A phone that isn't listening never receives the transient request. On iOS a timed-out probe leaves manual Refresh available. An explicit negative reply is shown as temporary for 30 seconds.

## Location sharing
- Grant: generate random 16-byte box id = our *sending* box, send `location_sharing_grant{drop_box}` message. Receiver stores it as its *receiving* box for us.
- Upload: `POST drop-boxes/send` multipart; each part name = hex box id, part body = JSON EncryptedData (crypto_box to that friend).
- Read: `GET drop-boxes/{hexBoxId}` → raw JSON EncryptedData; decrypt with friend pubkey.

## Socket — `wss://api.zood.xyz/1/sockets`
Auth: `Sec-Websocket-Protocol: <token>` header **or** `?ticket=` from `POST sessions/expiring-tickets` → `{ticket}` (valid 60 s). iOS uses ticket (server doesn't echo the subprotocol).
Client → server binary: `[0x01] + boxId` watch, `[0x02] + boxId` ignore, `[0x00]` nop.
Server → client binary: `[0x01] + boxId(16) + EncryptedData JSON` package; `[0x02] + JSON{id, cipher_text, nonce, sender_id, sent_date, type}` message.

## Push
Server APNs topic is hardcoded `xyz.zood.michael` and FCM uses the upstream Firebase project → forks get no push. Do **not** register APNs/FCM tokens from forks.

## Nicknames (Family Locator clients)

Usernames and encryption keys remain the account identity. `nickname` is optional display metadata carried inside encrypted user communications and location packages. Missing means an older client; an empty string explicitly clears a previous shared name. `nickname_update` pushes a profile change without requiring movement or a photo. Profile requests also return this message when no avatar exists. Older Zood clients ignore the field and discard the unknown message type.

Display priority is the account owner's private friend nickname, then the friend's advertised nickname, then `@username`. Receiving a profile change updates only the advertised value. Removing the private override reveals the latest advertised value. Both clients normalize empty/control-only values and bound name length.

The encrypted Snapshot adds optional top-level `nickname` (own shared name), and `nickname` (private override) / `shared_nickname` on friends. Schema remains 1: older clients ignore these optional fields, but saving a backup from an older client can omit them. Android stores local names in account-scoped preferences to avoid changing the SQLite schema; iOS keeps them with local friend records. Private overrides must never be included in messages to friends.
