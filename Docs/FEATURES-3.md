# Phase 5

## Dither (Audio → Dither)
TPDF, high-pass TPDF and noise-shaped TPDF (NTF `(1 − z⁻¹)²`), rounding to 16, 20 or 24 bits. Integer arithmetic on the engine's left-justified Int32, last in the render path, preallocated, no locks. Off by default. `Processing/Dither.swift`.

## Multi-room zones (Audio → Multi-room zone)
One processed stream, one FLAC feed per room, a sample-exact delay line in front of each encoder (`Zone/Zone.swift`).
- **Sonos**: the first ticked player coordinates; the others are joined to it with `x-rincon:` and Sonos keeps the group in sync itself.
- **DLNA / UPnP** (SSDP discovery, SOAP AVTransport): each room gets its own stream. "Align rooms" reads each room's play position, finds the second boundaries (±20–40 ms), and sets delays so that delay + latency is equal everywhere; the sliders trim by ear in 1 ms steps.
- **Chromecast**: same feed, started through the Cast channel.
- **AirPlay 2** is not a zone member: macOS only lets its own output route drive AirPlay receivers, and third-party senders cannot join its private sync. Use the AirPlay button.
- Honest limits: nothing here has run against real speakers. Sub-millisecond sync across protocols is not possible without a shared clock; devices' clocks drift, so re-align in long sessions.

## Lyrion Music Server (Cloud page)
UDP discovery on port 3483, JSON-RPC library import (`songs`, paged, `serverstatus`), and the original file from `/music/<id>/download` through the same chunked RAM reader as buckets and Subsonic servers (`Streaming/LMS.swift`). Basic auth; password in the Keychain.

## Phone and tablet sync (Cloud page)
`Bridge/Bridge.swift`: Network.framework listener (`_aureonsync._tcp`), TLS with a pre-shared key (TLS_PSK_WITH_AES_128_GCM_SHA256), a separate short-lived pairing listener (`_aureonpair._tcp`) protected by a one-time 128-bit code, per-device revocable tokens (only a hash is stored), library deltas from the change log (`changes(afterSeq:)`), playlists and likes, resumable checksummed file transfer at low priority. The client half (`BridgeClient`, `BridgeBrowser`) is in the same file for the iOS companion to reuse; the companion app itself is not part of this repository. PSK suites have no forward secrecy; this is meant for a trusted home network.

## Add to playlist
A button next to the heart in the player and the bar adds the playing song to any playlist (or a new one).
