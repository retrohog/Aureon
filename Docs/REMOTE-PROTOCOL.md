# Aureon remote protocol (v1)

JSON-RPC 2.0 over WebSocket text frames. Served by the app (Connect → Remote control) or headless with `Aureon daemon`.
`Sources/Aureon/Remote/RemoteProtocol.swift` and `RemoteClient.swift` depend only on Foundation and CryptoKit: copy them into an
iOS/iPadOS app unchanged (`URLSessionWebSocketTask` is the transport).

## Connecting

1. Discover the server with Bonjour (`_aureon._tcp`) or enter `ws://host:port/`.
2. The server immediately sends a notification `hello` with `{nonce, protocol, server}`.
3. The client answers within 5 s with `auth {hmac}` where `hmac = HMAC-SHA256(key: pairingToken, message: nonce)` as lowercase hex.
   The pairing token is shown in Connect → Remote control (or printed by the daemon) and never travels over the network.
4. Any other first message, a wrong `hmac`, or silence is answered with error 401 and the socket is closed.

> The channel is **not encrypted**. Use it on a trusted network, or tunnel it (VPN, SSH, Tailscale). Anyone who can read the
> traffic can read the library and *hijack the session after authentication*. TLS is a planned addition.

## Methods

Requests: `{"jsonrpc":"2.0","id":1,"method":"queue.add","params":{…}}`. Errors: `{"error":{"code":…,"message":…}}`
with codes −32601 (unknown method), −32602 (invalid params), 401, 403 (path outside the music folders), 404, −32603.

| Method | Params | Result |
|---|---|---|
| `ping` | | `"pong"` |
| `status.get` | | `RemoteStatus` (state, title, artist, album, position, duration, codec, bitDepth, sampleRate, bitPerfect, pipeline, deviceName, errors, serverTime) |
| `player.play` | `entryID?`, `seconds?` | status. No `entryID`: starts the queue, or resumes |
| `player.pause` / `resume` / `toggle` / `stop` | | status |
| `player.next` / `previous` | | `true` |
| `player.seek` / `player.seekBy` | `seconds` | `true` |
| `volume.set` | `volume` 0…1 | `true` (when the host exposes a device volume) |
| `queue.get` | | `{revision, currentID, entries:[QueueEntryDTO]}` |
| `queue.add` | `trackIDs?` (library ids) / `paths?`, `at?`, `play?` | the added entries |
| `queue.remove` | `ids` (queue entry ids) | queue snapshot |
| `queue.move` | `from` (indices), `to` | queue snapshot (SwiftUI `onMove` semantics) |
| `queue.clear` | | queue snapshot |
| `settings.get` / `settings.set` | `settings` (full `PlaybackSettings`) | the settings now in force |
| `devices.list` | | `[{id,name,rates}]` |
| `library.stats` | | counts and the current revision |
| `library.parties` | `role` (composer, artist, conductor, ensemble, soloist, …), `search?`, `limit?` | `[PartyDTO]` |
| `library.works` | `composerID?`, `search?` | `[WorkDTO]` |
| `library.releases` | `search?`, `partyID?` | `[ReleaseDTO]` |
| `library.tracks` | `releaseID?`, `workID?`, `partyID?`, `role?` | `[TrackDTO]` |
| `library.recordings` | `workID` | `[RecordingGroupDTO]` (a work's tracks per release, with conductor / ensemble / soloists) |
| `library.search` | `q` | `SearchResults` |
| `library.people` | `search?`, `limit?` | `[PartyDTO]` (everyone with a credit, any role) |
| `library.credits` | `partyID` | `CreditGraphDTO`: every record the person is credited on, by capacity, and who they worked with |
| `library.sharedCredits` | `partyID`, `otherID` | `SharedCreditsDTO`: the records both worked on |
| `library.changes` | `cursor`, `limit?` | `{revision, cursor, changes, more}` — see below |
| `library.import` | `path` (inside the music folders) | counts |
| `art.get` | `trackID` or `entryID`, `size?` (32…1024) | `{mime:"image/jpeg", base64}` or `null` |

## Notifications (server → client)

| Method | When | Params |
|---|---|---|
| `status` | on every state/track change, and every 0.5 s while playing (2 s idle) | `RemoteStatus` |
| `queue.changed` | the queue changed (from any client or locally) | queue snapshot |
| `settings.changed` | settings changed | `PlaybackSettings` |
| `library.changed` | the library has a new revision | `{revision}` |

Clients can interpolate the position between `status` messages using `serverTime`.

## Keeping a library in sync

* **Queue**: server-authoritative. Every mutation produces a `queue.changed` snapshot with a higher `revision`; apply the newest.
* **Library**: the server keeps an append-only change log. Each row has a unique, gap-free `seq`. A client stores a `cursor`
  (initially 0), calls `library.changes {cursor}` and applies each change by uid:
  `upsert` replaces the object it carries, `delete` removes it. While `more` is true, call again with the returned `cursor`.
  On `library.changed`, sync again. `LibraryMirror` / `RemoteClient.syncLibrary` implement exactly this.
* Objects never reference each other by Core Data identity; ids are stable UUID strings, safe to use as primary keys in a
  local SwiftData/Core Data cache on the phone.
* Paging by revision would be wrong (one import batch shares a revision), which is why the cursor is a per-row sequence number.

## Security notes

Remote clients may only add files below the configured music folders (`--music` for the daemon, the library folders in the app);
`..` tricks and symlinks are resolved before the check. Settings that name a file (the convolution impulse response) are subject to
the same rule.
