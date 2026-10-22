# Aureon 0.2.0

Aureon is an open-source, bit-perfect music player for macOS. Playback stays bit-perfect from file to DAC by default; everything that changes the samples (upsampling, EQ, crossfades, DSD conversion, AI) is opt-in, and the signal-path view always shows which state you are in.

This release adds a lot. Please read **Known issues** before installing.

## What's new

### Intelligence (optional)
- A new **Intelligence** tab with one master switch for every AI feature, a switch per feature, a hardware indicator, a local model loader and optional API settings. Turning the master switch off takes effect immediately: models are unloaded and every feature falls back to its classic, non-AI behaviour.
- **On by default on Apple Silicon, off by default on Intel Macs.** On Intel, switching it on first shows a warning.
- **Natural-language playlists**: describe what you want to hear and get a playlist.
- **Semantic search**: find songs by meaning ("rainy sunday piano") next to the normal search results.
- Only text is ever sent to an API (if you configure one). Audio never leaves your Mac.
- Marked experimental in the docs: the AI audio enhancer for lossy streams and on-device lyrics generation.

### Lyrics
- A **Lyrics** button and a lyrics panel on Now Playing, with time-synced highlighting.
- Lyrics are looked up in this order: `.lrc` files next to the song, lyrics embedded in the file's tags, then LRCLIB (only title, artist, album and length are sent; results are cached).
- Optional on-device lyrics generation for songs that have none (uses a Whisper speech model; experimental).
- Optional write-back of lyrics to the file's tags.

### Sound
- **Oversampling filters** (Settings → Audio → Upsampling): linear phase, minimum phase, apodizing and brickwall, with live switching.
- **PCM → DSD output** for DoP-capable DACs: DSD64, DSD128, DSD256 and DSD512, with 5th- and 7th-order noise shapers. **DSD512 is experimental**: it has not been run against a real DAC that accepts it.
- **Transitions**: crossfade (1-12 s) and smart transitions (skips silence, respects existing fades, loudness handover). Albums stay gapless. Off by default.
- **ABX blind testing**: sample-aligned, loudness-matched, double-blind trials scored with a p-value.
- **MIDI controllers**: MIDI Learn, 14-bit and relative controls, soft takeover, presets for the Pioneer DDJ-400 and Korg nanoKONTROL2 (the presets follow published maps and have **not** been tried on real hardware).

### Library
- **Folders tab**: browse your disk as it is, no import needed, with symlink-loop protection.
- **Tag editor** for FLAC, ALAC/AAC (MP4) and MP3 files, with bulk editing. Writes are atomic and never touch a file that is playing.
- **Query search** with a small documented grammar.
- **Credit graph**: pick any person and see every record they worked on, in what role, and who they worked with.
- **Digital booklet viewer** for PDFs next to an album.
- The library stays current through file-system events instead of rescanning at start-up.

### Interface and performance
- Hardware-style player bar with LED lamps, a waveform scrubber, and a redesigned Now Playing with a cover-colour backdrop.
- Layout options for the DJ console.
- Cover art is cached as thumbnails, albums load in pages, imports are linear, and heavy work runs off the main thread.

### Fixes from this review round
- Lyrics lookup fixed, and a Lyrics button added.
- Folder-access prompts are now remembered across updates, because the app is signed with a stable identifier (`org.aureon.player`) rather than a per-build signature.
- Layout fixes on Now Playing (the transport row now adapts to narrow windows) and in DJ mode.
- A round of crash, data-loss and audio fixes found in an internal code review.

## Install

**Disk image (`Aureon-0.2.0.dmg`)**
1. Open the disk image and drag **Aureon** onto **Applications**.
2. The first time, right-click (or Control-click) Aureon and choose **Open**, then confirm. macOS asks because the app is **not notarised**; after that it opens normally.
3. When macOS asks for access to your music folders, choose Allow.

**Installer package (`Aureon-0.2.0.pkg`)** installs into `/Applications`. It is **unsigned**, so Gatekeeper will warn about it: right-click the package and choose Open, or allow it under System Settings → Privacy & Security.

The app is ad-hoc signed (not Developer ID, not notarised). Checksums are in `Aureon-0.2.0.sha256`; check them with `shasum -a 256 -c Aureon-0.2.0.sha256`.

## Requirements
- macOS 15 or later on Apple Silicon. The 0.2.0 builds are **arm64 only**, so they do not run on Intel Macs; building from source on Intel is untested.
- Extreme sample rates depend on your Mac and DAC; slower hardware may play them at a lower rate.

## Known issues
- **Closing Now Playing can leave part of the window unresponsive.** Clicking the chevron that closes Now Playing (top left of the Now Playing page) can leave part of the window, including the sidebar, not reacting to clicks. This is reproduced by an automated test and **is not fixed in 0.2.0**. No workaround is known yet; it is the first thing to fix in 0.2.1.
- DSD512 output, the AI audio enhancer and on-device lyrics generation are experimental and untested against real hardware or every model.
- The MIDI presets are untested on physical controllers; use Learn or Reverse if a control behaves backwards.
- DoP is never enabled by default: a DAC that does not understand it plays it as loud noise.
- Not included: Tidal, Qobuz and Spotify, MQA, keylock and scratching in DJ mode, MIDI output.

Full feature list: `Docs/FEATURES.md`.
