<div align="center">

<img src="assets/banner.svg" alt="Aureon" width="100%" />

# Aureon 0.2.0

**Lyrics, MIDI controllers, oversampling filters, PCM→DSD, transitions, a tag editor and an optional on-device Intelligence layer.**

</div>

> [!WARNING]
> **Known issue.** Closing Now Playing with the chevron (top left of the Now Playing page) can leave part of the window,
> including the sidebar, not reacting to clicks. It is reproduced by an automated test and is **not fixed in 0.2.0**.
> No workaround is known yet. It is the first thing to fix in 0.2.1.

Playback is still bit-perfect from file to DAC by default. Everything that changes the samples (upsampling, EQ, crossfades,
DSD conversion, Intelligence features) is opt-in, and the signal-path view always shows which state you are in.

## At a glance

| | | |
|:--|:--|:--|
| 🎤 **Lyrics**<br/>Time-synced, word-by-word | 🎛 **MIDI**<br/>Learn, 14-bit, presets | 🔊 **Oversampling filters**<br/>Four designs, live switching |
| 🌀 **PCM → DSD**<br/>DSD64 to DSD512 over DoP | 🔀 **Transitions**<br/>Crossfade and smart, albums stay gapless | 🧠 **Intelligence**<br/>One master switch, all on device |
| 🏷 **Tag editor**<br/>FLAC, ALAC/AAC, MP3 | 📁 **Folders**<br/>Browse the disk as it is | 👂 **ABX testing**<br/>Blind trials with a p-value |

## What's new

### 🧠 Intelligence (optional)

- A new **Intelligence** tab with one master switch for every AI feature, a switch per feature, a hardware indicator, a local model loader and optional API settings. Turning the master switch off takes effect immediately: models are unloaded and every feature falls back to its classic behaviour.
- **On by default on Apple Silicon, off by default on Intel Macs**, where switching it on first shows a warning.
- **Natural-language playlists:** describe what you want to hear and get a playlist.
- **Semantic search:** find songs by meaning ("rainy sunday piano") beside the normal results.
- Only text is ever sent to an API, and only if you configure one. Audio never leaves your Mac.
- *Experimental:* the audio enhancer for lossy streams and on-device lyrics generation.

### 🎤 Lyrics

- A **Lyrics** button and a sing-along panel on Now Playing, with time-synced highlighting.
- Lookup order: `.lrc` file next to the song, lyrics in the file's tags, then LRCLIB (only title, artist, album and length are sent; results are cached).
- Optional on-device lyrics generation for songs that have none (Whisper, experimental) and optional write-back to the file's tags.

### 🔊 Sound

| | |
|:--|:--|
| **Oversampling filters** | Settings → Audio → Upsampling: linear phase, minimum phase, apodizing and brickwall, switchable while playing. |
| **PCM → DSD** | For DoP-capable DACs: DSD64, DSD128, DSD256 and DSD512 with 5th and 7th-order noise shapers. **DSD512 is experimental**; it has not been run against a real DAC that accepts it. |
| **Transitions** | Crossfade (1–12 s) and smart transitions (skips silence, respects existing fades, loudness handover). Albums stay gapless. Off by default. |
| **ABX testing** | Sample-aligned, loudness-matched, double-blind trials scored with a p-value. |
| **MIDI controllers** | MIDI Learn, 14-bit and relative controls, soft takeover. Presets for the Pioneer DDJ-400 and Korg nanoKONTROL2, which follow published maps and have **not** been tried on real hardware. |

### 📚 Library

- **Folders tab:** browse your disk as it is, no import needed, with symlink-loop protection.
- **Tag editor** for FLAC, ALAC/AAC (MP4) and MP3 files, with bulk editing. Writes are atomic and never touch a file that is playing.
- **Query search** with a small documented grammar.
- **Credit graph:** pick any person and see every record they worked on, in what role, and who they worked with.
- **Digital booklet viewer** for PDFs next to an album.
- The library stays current through file-system events instead of rescanning at start-up.

### ✨ Interface and performance

- Hardware-style player bar with LED lamps, a waveform scrubber, and a redesigned Now Playing with a cover-colour backdrop.
- Layout options for the DJ console.
- Cover art is cached as thumbnails, albums load in pages, imports are linear, and heavy work runs off the main thread.

## Install

| | |
|:--|:--|
| **Disk image**<br/>`Aureon-0.2.0.dmg` | 1. Open the image and drag **Aureon** onto **Applications**.<br/>2. First launch: right-click (or Control-click) Aureon → **Open**, then confirm. macOS asks because the app is **not notarised**; afterwards it opens normally.<br/>3. When macOS asks for access to your music folders, choose Allow. |
| **Installer**<br/>`Aureon-0.2.0.pkg` | Installs into `/Applications`. It is **unsigned**, so Gatekeeper will warn: right-click the package → Open, or allow it under System Settings → Privacy & Security. |
| **Checksums**<br/>`Aureon-0.2.0.sha256` | `shasum -a 256 -c Aureon-0.2.0.sha256` |

The app is ad-hoc signed (not Developer ID, not notarised).

## Requirements

- **Apple Silicon** (arm64). The 0.2.0 builds do not run on Intel-based Macs. **A build for Intel Macs will be released soon.**
- Extreme sample rates depend on your Mac and DAC; slower hardware may play them at a lower rate.

## Known issues

- **Closing Now Playing can leave part of the window unresponsive** (see the warning at the top). Not fixed in 0.2.0; first fix in 0.2.1.
- DSD512 output, the audio enhancer and on-device lyrics generation are experimental and untested against real hardware or every model.
- The MIDI presets are untested on physical controllers; use Learn or Reverse if a control behaves backwards.
- DoP is never enabled by default: a DAC that does not understand it plays it as loud noise.
- Not included: Tidal, Qobuz and Spotify, MQA, keylock and scratching in DJ mode, MIDI output.

Full feature list: [Docs/FEATURES.md](Docs/FEATURES.md).
