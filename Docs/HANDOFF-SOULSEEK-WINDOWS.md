# Soulseek client: notes for the Windows port

The Soulseek client is the Swift package target `SlskCore` (`Sources/SlskCore`). It imports no user-interface code and never touches the audio engine, so it can be built on its own and moved.

## What is in the package

| File | Job |
| --- | --- |
| `SlskWire.swift` | Frames (`uint32 length | uint32 code | payload`, little endian, strings as `uint32 length + bytes`), the messages we send, decoders for what we receive, zlib helpers. Pure functions. |
| `SlskTransport.swift` | `SlskLoop`: one `poll()` thread that owns every socket (server, peers, file links, listener); `SlskLink` handles. |
| `SlskClient.swift` | The server session (login, backoff, ping), peer links raced from both sides, search, downloads (resume, retry, atomic rename), uploads (round-robin, slots, speed cap), share-list answers, rooms and messages, playback protection, 4 Hz snapshots. |
| `SlskShares.swift` | Share index: only ticked folders, names like `Share\Album\01 Track.flac`, compressed list. |
| `SlskStore.swift` | Own SQLite file: queue, history, bans, notes, friends, wishlist. Never the music library. |
| `SlskModelTypes.swift` | Plain values published to the interface, the protocol log ring. |

The macOS interface lives in `Sources/Aureon/GUI/Soulseek` (`SoulseekModel`, `SoulseekPage`, `DownloadsControl`). Windows needs its own interface; it should read `SlskSnapshot` a few times a second and call the methods of `SlskClient`.

## Things that are macOS-only today

1. **Sockets**: `SlskTransport.swift` uses BSD sockets and `poll()` from `Darwin`. Winsock has `WSAPoll` with the same shape; replace `socket`, `connect`, `read`, `write`, `close`, `fcntl(O_NONBLOCK)` with `ioctlsocket(FIONBIO)`, `recv`, `send`, `closesocket`, and replace the wake pipe with a loopback socket pair or `WSAEventSelect`. `SO_NOSIGPIPE` does not exist on Windows (use `MSG_NOSIGNAL` equivalents or ignore).
2. **zlib**: `SlskZlib` wraps Apple's `Compression` framework (raw deflate) in the two-byte zlib header and an Adler-32 trailer by hand. On Windows use zlib itself (`compress2`, `uncompress`) and delete the wrapper.
3. **MD5**: login sends `md5(username + password)` through `CryptoKit.Insecure.MD5`. Use any MD5.
4. **SQLite**: `SlskStore` links the system `sqlite3`. Bundle SQLite on Windows.
5. **File writes**: `SlskFileWriter` uses `open/write/fsync` and `F_NOCACHE`. On Windows use `CreateFile` with `FILE_FLAG_NO_BUFFERING` only if writes are sector-aligned (they are not), so plain buffered writes with `FlushFileBuffers` on finish is fine. Atomic rename: `MoveFileEx(MOVEFILE_REPLACE_EXISTING)` after the size check.
6. **Keychain**: the macOS app keeps the password in the keychain (`SlskKeychain`). Use Windows Credential Manager.
7. **Paths**: peers send backslash paths already; local paths use `/` on macOS. `SlskShares.build` splits on `/`; feed it forward-slash paths or adjust.

## Protocol facts the client relies on

- Server `server.slsknet.org:2242`. Login (code 1): username, password, version 160, `md5(username+password)`, minor version 1. After a success: SetListenPort (2), SetStatus (28), SharedFoldersFiles (35), HaveNoParent (71). Ping (32) about every five minutes. Reconnect backoff 2, 4, 8 … 60 s.
- Peer links: type `P` (messages), `F` (file), `D` (distributed). Peer-init messages use a one-byte code (0 PierceFirewall, 1 PeerInit). We race a direct connect (address from GetPeerAddress, code 3) with a reverse request (ConnectToPeer, code 18) and give up after 10 s.
- Download: `QueueUpload` (43) → `PlaceInQueue` (44) → the peer sends `TransferRequest` (40, direction 1, token, path, size) → we answer `TransferResponse` (41, allowed) → the peer opens an `F` link to us and sends the 4-byte transfer token → we answer with the 8-byte start offset (size of the `.part` file) → the peer sends the bytes. Denials: `UploadDenied` (50), `UploadFailed` (46).
- Search results (code 9, zlib) arrive on links that peers open to us, not through the server.

## Rules the port must keep

- **Never connect to the real network from tests.** `SlskClient.testing` (set by the `selftest` argument or `AUREON_TESTING`) makes the client refuse any host that is not loopback.
- Sharing is off by default and needs ticked folders. Paths on the wire never contain local folders or the user's name.
- Unfinished files live in a hidden `.incomplete` folder outside the library. A file appears in the downloads folder only after its size matches, in one rename.
- Nothing in the package may run on, or call into, the audio render path. Playback protection (`pauseTransfers`, `setPlaybackGuard`) is driven from the player side.

## Tests

`Sources/Aureon/SelfTest/SoulseekTests.swift` runs a fake server and fake peers on the loopback interface: login, wrong password, reconnect, search results, download, resume from an offset, abort and retry, short files, denial, unreachable peers, three downloads at a time, uploads and share lists, blocked users, playback pause, row building for 20 000 files. Port these first; they define the behaviour.
