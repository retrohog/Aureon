<div align="center">

<img src="assets/banner.svg" alt="Aureon" width="100%" />

# Aureon 0.2.0

**Lyrics, MIDI controllers, oversampling filters, PCM→DSD, transitions, a tag editor and an optional on-device Intelligence layer.**

</div>

Aureon plays your music bit-perfect from file to DAC by default. Everything that changes the samples (upsampling, EQ,
crossfades, DSD conversion, Intelligence features) is opt-in, and the signal-path view always shows which state you are in.

> [!WARNING]
> **Known issue:** closing Now Playing with the chevron (top left of the page) can leave part of the window, including the
> sidebar, not reacting to clicks. No workaround yet. It is the first thing we will fix in 0.2.1.

## Highlights

| | | |
|:--|:--|:--|
| **Lyrics**<br/>Time-synced, word by word | **MIDI controllers**<br/>Learn, 14-bit, presets | **Oversampling filters**<br/>Four designs, switch live |
| **PCM → DSD**<br/>DSD64 to DSD512 over DoP | **Transitions**<br/>Crossfade and smart, albums stay gapless | **Intelligence**<br/>One master switch, all on device |
| **Tag editor**<br/>FLAC, ALAC/AAC, MP3 | **Folders**<br/>Browse the disk as it is | **ABX testing**<br/>Blind trials with a p-value |

## What's new

### Lyrics

- A **Lyrics** button and a sing-along panel on Now Playing, with time-synced highlighting.
- Lyrics are found in this order: an `.lrc` file next to the song, the lyrics in the file's tags, then LRCLIB. Only the title, artist, album and length are sent, and results are cached.
- Optional on-device lyrics generation for songs that have none (experimental), and optional write-back to the file's tags.

### Sound

| | |
|:--|:--|
| **Oversampling filters** | Linear phase, minimum phase, apodizing and brickwall, in Settings → Audio → Upsampling. Switch while a song plays. |
| **PCM → DSD** | For DoP-capable DACs: DSD64, DSD128, DSD256 and DSD512 with 5th and 7th-order noise shapers. DSD512 is experimental. |
| **Transitions** | Crossfade (1–12 s) or smart transitions that skip silence, keep existing fades and match loudness. Albums stay gapless. Off by default. |
| **ABX testing** | Sample-aligned, loudness-matched, double-blind trials scored with a p-value. |
| **MIDI controllers** | MIDI Learn, 14-bit and relative controls, soft takeover. Presets for the Pioneer DDJ-400 and Korg nanoKONTROL2, built from the published maps and not yet tried on the real devices. |

### Intelligence (optional)

- One **Intelligence** tab: a master switch for every smart feature, a switch per feature, a hardware indicator, a local model loader and optional API settings. Switching the master off unloads the models at once and every feature falls back to its classic behaviour.
- **On by default on Apple Silicon, off by default on Intel Macs**, where turning it on first shows a warning.
- **Natural-language playlists:** describe what you want to hear and get a playlist.
- **Semantic search:** find songs by meaning ("rainy sunday piano") next to the normal results.
- Only text is ever sent to an API, and only if you set one up. Audio never leaves your Mac.
- Experimental: the audio enhancer for lossy streams and on-device lyrics generation.

### Library

- **Folders tab:** browse your disk as it is, no import needed.
- **Tag editor** for FLAC, ALAC/AAC and MP3 with bulk editing. Writes are atomic and never touch a file that is playing.
- **Query search** with a small documented grammar.
- **Credit graph:** pick any person and see every record they worked on, in what role, and with whom.
- **Digital booklets:** PDFs next to an album open in a booklet viewer.
- The library stays current through file-system events instead of rescanning at start-up.

### Interface and performance

- A hardware-style player bar with LED lamps and a waveform scrubber.
- A redesigned Now Playing page with a backdrop taken from the cover.
- Layout options for the DJ console.
- Faster browsing: cover art is cached, albums load in pages, imports run in linear time and heavy work stays off the main thread.
- Folder-access prompts are remembered across updates.

## Requirements

- **Apple Silicon Macs.** The 0.2.0 builds do not run on Intel-based Macs; **a build for Intel Macs will be released soon.**
- The app is not notarised yet, so the first launch needs right-click → **Open**.
- Extreme sample rates depend on your Mac and DAC; slower hardware may play them at a lower rate.

## Known issues

- **Closing Now Playing can leave part of the window unresponsive** (see the warning above). First fix in 0.2.1.
- DSD512 output, the audio enhancer and on-device lyrics generation are experimental and untested on real hardware.
- The MIDI presets are untested on physical controllers; use Learn or Reverse if a control behaves backwards.
- DoP is never enabled by default: a DAC that does not understand it plays it as loud noise.

Full feature list: [Docs/FEATURES.md](Docs/FEATURES.md).
