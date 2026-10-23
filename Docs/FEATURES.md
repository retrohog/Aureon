# Aureon features

Aureon is an open-source, audiophile-grade music player for macOS. It keeps your music **bit-perfect from file to DAC by default**. Everything that changes the samples (upsampling, EQ, crossfades, DSD conversion, smart features) is opt-in, and the signal-path view always tells you which state you are in.

This page lists what the code in this repository does today, grouped by area. For how it is built, see [ARCHITECTURE.md](ARCHITECTURE.md); for the commands, see the [README](../README.md).

**Status labels**

| Label | Meaning |
|---|---|
| ✅ | Built and working. |
| 🧪 | **Experimental.** Works end to end, but has not been checked against the real hardware or models it is meant for, or it is off by default for a reason. Read the note before relying on it. |
| 🎛 | Verified against simulated devices or published specifications only. No real device was available. |

Requirements: Swift 6 toolchain (the Command Line Tools are enough). Some visual effects use macOS 26's Liquid Glass and fall back to standard materials on older systems.

---

## Contents

1. [Bit-perfect engine and DSP](#1-bit-perfect-engine-and-dsp)
2. [Transitions](#2-transitions)
3. [Oversampling filters, DSD and PCM→DSD](#3-oversampling-filters-dsd-and-pcmdsd)
4. [Intelligence (smart features)](#4-intelligence-smart-features)
5. [Library and folders](#5-library-and-folders)
6. [Tag editing](#6-tag-editing)
7. [Search](#7-search)
8. [Credits](#8-credits)
9. [Lyrics](#9-lyrics)
10. [ABX blind testing](#10-abx-blind-testing)
11. [MIDI controllers](#11-midi-controllers)
12. [DJ mode](#12-dj-mode)
13. [User interface](#13-user-interface)
14. [Performance](#14-performance)
15. [Sources, outputs and tools](#15-sources-outputs-and-tools)
16. [Not included](#16-not-included)

---

## 1. Bit-perfect engine and DSP

### Playback
- ✅ **Lossless playback** of FLAC, ALAC, WAV and AIFF, decoded at the file's own sample rate and bit depth into 32-bit integers. Gapless between tracks of the same format; the device clock follows each track.
- ✅ **Dual-path architecture.** With processing off, the path is *decoder → lock-free ring buffer → DAC callback* and nothing else touches the samples. With DSP on, the callback renders through a manual-rendering `AVAudioEngine`. The signal-path panel shows which one is active.
- ✅ **Exclusive (hog) mode** and **automatic sample-rate switching** to match each file.
- ✅ **Memory playback.** Whole tracks are decoded into RAM before playing and the next two are prefetched. No disk reads happen during playback.
- ✅ **Live queue.** Remove, reorder, insert and append while playing without disturbing the audible track.
- ✅ **Multichannel.** 5.1 and 7.1 files play at their own channel count when the device has the outputs (speaker labels are matched, not guessed); otherwise an ITU-R BS.775 downmix is used.
- ✅ **Shuffle and repeat.** Shuffle off / normal / Smart Shuffle (no back-to-back artists, favours liked songs, uses tempo and key when known); repeat off / all / one, gapless.
- 🎛 **Integer-format output and DoP** are implemented and exercised against recording sinks, but not against a physical USB DAC. `Aureon hwdebug` tells you what your hardware accepts.

### Real-time safety
The audio render callback contains no memory allocation, no locks and no Swift or Objective-C messaging. Everything the interface changes reaches it through atomics and RCU-published snapshots. Heavy work (decoding, resampling, analysis, model inference) runs on producer or background threads, ahead of a roughly five-second ring buffer.

### Loudness and gain
- ✅ **ReplayGain** read from Vorbis, ID3 and iTunes tags, with R128 measurement for untagged files and peak-aware clipping protection.
- ✅ **EBU R128 / ITU-R BS.1770-4** integrated loudness, loudness range, 4× true peak and DR, measured with Accelerate and cached in the library.

### DSP (all off by default)
- ✅ **10-band parametric EQ** with automatic headroom, saved as named profiles.
- ✅ **Audio Unit plug-in hosting** for third-party effects.
- ✅ **Room correction.** Partitioned FFT convolution of Room EQ Wizard–style impulse responses (WAV int/float, mono/stereo, any rate), resampled to the stream. About 57× real time for 8 s of stereo.
- ✅ **Headphone correction.** AutoEQ profiles fetched on demand from the open AutoEQ database, with a safety pre-amp.
- ✅ **BS2B crossfeed.**
- ✅ **Dither.** TPDF, high-pass TPDF and noise-shaped TPDF to 16, 20 or 24 bits, in integer arithmetic last in the render path.
- ✅ **Signal path view.** A node graph from file to DAC with pulses along the line: green while the signal is untouched, orange from the first stage that changes samples. Hover a station for details.
- ✅ **Setting conflict checks.** Combinations that would corrupt a stream (for example EQ on DoP) are flagged before they take effect.

---

## 2. Transitions

Gapless is the default and is bit-exact. Transitions are opt-in.

- ✅ **Crossfade** from 1 to 12 seconds with an equal-power, linear or S-curve gain law.
- ✅ **Smart transitions.** Each pair of songs is looked at first:
  - digital silence at the end of one song and the start of the next is skipped;
  - a song that already fades out keeps its own fade, the next one comes in underneath, and the overlap never runs longer than that fade;
  - a **loudness handover** measures each song's first and last seconds (EBU R128) and eases the next song in from the level the current one ends at, lowering it by up to a set amount (default 6 dB) and raising it by up to half that.
- ✅ **Albums stay gapless.** Songs from the same album (folder) are never crossfaded, so live albums and records that run on from track to track are left alone.
- ✅ **Mixed before the ring buffer**, on the engine thread. The audio callback does not know a transition is happening, and outside an overlap the delivered stream is bit-for-bit the gapless one.
- ✅ A **MIX lamp** on the player bar shows when a transition is active.
- **Limits.** Transitions are never applied to DoP, radio, or across a sample-rate change; those stay gapless. While two songs overlap, the output is not bit-perfect.

---

## 3. Oversampling filters, DSD and PCM→DSD

See [DSD-OUTPUT.md](DSD-OUTPUT.md) for the full design and measurements.

### Oversampling filters
- ✅ **Native polyphase sinc resampler** for any rational ratio, with no external dependencies. Designs are built off the audio thread and cached.
- ✅ **Four filters**, in Settings → Audio → Upsampling:

  | Filter | Character |
  |---|---|
  | **Linear phase** | Constant delay, symmetric ringing. Adjustable pass-band (0.90–0.99 of Nyquist) and stop-band (96 / 120 / 144 dB). |
  | **Minimum phase** | No pre-ringing; delay varies with frequency. |
  | **Apodizing** | Flat to 0.86 of Nyquist, 130 dB stop-band closed at the source's Nyquist, removing the energy and ringing the recording's own filter left near Nyquist. |
  | **Brickwall** | Flat to 0.99 of Nyquist, 144 dB stop-band, about six times the taps of the standard filter. |

- ✅ **Live filter switching.** The new design is built on a background queue and swapped in between two reads with a 20 ms crossfade. The render thread is never involved.
- ✅ **Cost guard.** A filter that costs more than this Mac can spare at that rate is declined, and the player says so.

### Native DSD
- ✅ **DSF and DFF playback** with **DoP**, keeping the DSD bits untouched with a marker that continues across tracks, or conversion to PCM. A DAC that does not understand DoP plays it as loud noise, so DoP is never enabled by default and asks for confirmation.
- ✅ **Fast decimation** (byte-lookup FIR plus half-band stages), so even DSD1024 converts faster than real time.
- ✅ **Rate planner.** A start-up benchmark times the resampler and decimator and the player picks what this Mac can sustain with headroom, so an older Intel Mac plays at a lower rate instead of stuttering.
- **Limits.** DST-compressed DSD is not supported, and DSD files cannot be streamed from a bucket or server.

### PCM → DSD (off by default)
Any music as DSD64, DSD128, DSD256 or DSD512 for a DoP-capable DAC: the chosen filter, Kaiser half-band interpolation, then a 5th- or 7th-order one-bit noise-shaping modulator, packed into DoP words.

- ✅ DSD64, DSD128 and DSD256, **5th and 7th order**. Modulator coefficients are generated by a documented design script (`Tools/modulator`) and cross-checked by a C reference loop. In-band SNR measured in the design tools is 110 dB (5th order) or 121 dB (7th order) at DSD64, and 142–150 dB or more at DSD128 and above.
- 🧪 **DSD512** (1.4112 MHz DoP rate). The modulator and planner support it, but it needs a DAC that accepts DSD512 over DoP and a Mac that can sustain the modulator at that rate, and it has not been run against such a DAC. The planner picks the highest rate the DAC offers and the Mac can make with 2× headroom.
- **Limits.** Stereo only. EQ, room correction, crossfeed, headphone correction and dither are not applied to a DSD stream (they would destroy the bits), so the settings screen asks before you combine them. Transitions fall back to gapless.

```bash
Aureon play --dsd-out 512 --modulator 7 --filter apodizing track.flac
```

---

## 4. Intelligence (smart features)

Every learned model in Aureon lives behind one gate and one settings page, the **Intelligence** tab.

### Master switch and defaults
- ✅ **Enable Intelligence Features** is a global master switch. Switching it off takes effect immediately: the Smart DJ model process quits, the Smart Remixer stops, the semantic index is dropped from memory, Smart Shuffle falls back to plain rules and the audio enhancer's gate closes. Every feature then uses its classic path.
- ✅ **On by default on Apple Silicon, off by default on Intel Macs.** The hardware is read from the kernel, not from how the binary was built, so an x86_64 copy running under Rosetta on Apple Silicon is still recognised (and told it is translated).
- ✅ **Intel warning.** Switching the master switch on in an Intel Mac first shows a warning sheet. It only takes effect once the warning is accepted, and the acceptance can be withdrawn.
- ✅ **One switch per feature**, plus an indicator of what this Mac can run (Apple Silicon with Neural Engine, Intel, translated).
- ✅ **Render-thread safe.** The gate is a single atomic load of a 32-bit mask, so even code on the audio path can ask it without locking or allocating.

### Features behind the gate

| Feature | What it does | Runs |
|---|---|---|
| **Smart DJ** | Builds a set from a sentence ("10 upbeat electronic tracks for a workout"). Plain code reads the request, narrows the library to about 60 candidates, a language model picks from them with **grammar-constrained** JSON output, and a ranking checks and completes the result so it is always valid. | On device (MLX helper process) or via API |
| **Natural-language playlists** | "A 2-hour mix of late-night, low-energy acoustic tracks with high dynamic range." The request is parsed for length, count, genre, tempo, energy, decade, DR and mood; the whole library is scored using Aureon's own measurements (tempo, key, energy, loudness, DR) plus tags and semantic similarity; the model fills in what the words leave open; the result is fitted to the length and ordered along an energy arc. Works without a model, by ranking alone. | On device or via API |
| **Semantic Search** | Finds songs by meaning ("rainy sunday piano"). Every song gets a short description that is turned into a vector; a query finds the nearest ones. The index is built in the background, cached per model and freed when the feature is off. | Apple's on-device sentence embeddings (any Mac, Intel included) or an API |
| **Smart Shuffle** | A small transition network orders a queue so each song flows into the next. | On device |
| **Smart Remixer** | A small on-device network picks filter sweeps, echo-outs, loop rolls, drops, risers and stutters on the bar line of the DJ console and learns from thumbs. It performs the decks' own controls; it does not separate stems. | On device |
| 🧪 **Real-time audio enhancer** (neural upscaler) | Bandwidth extension for lossy sources (radio, podcasts, MP3/AAC files). See the note below. | Strictly on device |
| 🧪 **Lyrics generation** | Writes time-synced lyrics for a song that has none, using a Whisper speech model. See [Lyrics](#9-lyrics). | Strictly on device |

The model for Smart DJ runs in a **helper process** that starts when the feature is switched on and quits when it is switched off, so its memory goes back to the system.

### Local models and API providers
- ✅ **Local models under one billion parameters.** You may load your own model, but it is checked before anything is loaded: at most 1 B parameters and 1.5 GiB of weights. Parameter counts are read straight from safetensors and GGUF headers in milliseconds; CoreML sizes are estimated from the weight file. A model over the cap is refused. MLX folders run on native Apple Silicon; the Whisper family (39 M to 244 M parameters) is well under the cap.
- ✅ **Bring your own API key** for OpenAI, DeepSeek or any OpenAI-compatible endpoint. Keys are stored in the **macOS Keychain** only, never in preferences or logs. Addresses must be HTTPS, except a server on this Mac. Replies are requested as JSON schema, stepping down to JSON mode or plain text if a server refuses. A "Check connection" button validates the address and key without spending tokens.
- ✅ **Privacy by construction.** Only text goes to an API (the request and short song descriptions). **Audio never leaves your Mac**, and the audio enhancer and lyrics generation are never routed to an API.

### 🧪 Note on the real-time audio enhancer
The engine is complete: a C++ overlap-add and watchdog core (`AureonNeuralCore`), a CoreML worker on the Neural Engine, and a `FrameSource` on the decode thread, so inference never touches the audio thread. It is **off by default** because it changes the samples. If inference falls behind real time (the watchdog trips at a real-time factor of 0.8) or a model fails, playback continues unchanged through the classic sinc resampler. It needs a CoreML model you supply; the converter script is in `Tools/upscaler`. No model is bundled, and the converter has not been run against a real trained model. Switching it off is heard after the buffered audio drains, up to five seconds.

---

## 5. Library and folders

### Library
- ✅ **Core Data library** with multi-valued artists, composers, conductors, ensembles and soloists; work, movement, opus and catalog number. Browse **Composer → Work → Recordings → Movements** for classical music. See [LIBRARY.md](LIBRARY.md).
- ✅ **Albums, Artists, Songs** pages with sorting, quality filters, A–Z grouping, grid or list, and a cover-size slider. Hi-res marks on album art.
- ✅ **Always current without rescanning.** An FSEvents watcher notices changes, including those made while Aureon was closed (it replays the history since the last event it handled), and compares only the files that changed. A full sweep still runs every 14 days. A folder that suddenly lists empty (an unplugged drive) is never wiped.
- ✅ **Liked Songs and playlists**, a heart on every song, and "Add to Playlist" in every song menu.
- ✅ **Duplicate finder.** Reviews songs and albums you have twice, recommends the best copy (lossless, resolution, size), shows what would go and why, and moves the rest to the Trash only after you confirm. "feat." artists are folded into their host artist.
- ✅ **Deep Dive.** Identify untagged files with AcoustID/Chromaprint (needs `fpcalc`), then fetch MusicBrainz credits, Wikipedia biographies, cover art and releases.
- ✅ **Artwork.** Missing covers are fetched from the iTunes Search API, then MusicBrainz and the Cover Art Archive, with strict album/artist matching and an on-disk cache. It can be switched off. Artist portraits come from Deezer and Wikipedia, with an offline mosaic of the artist's own covers as a fallback.

### Folders tab
- ✅ **Browse the disk as it is**, with no import and no tags. Add any number of root folders; each listing is one prefetched directory read, so a folder of 50,000 files appears in a fraction of a second on a background queue.
- ✅ **Safe with links.** Symbolic links are shown as what they point at and checked for loops; recursive "play this folder tree" follows linked folders once each by device and inode.
- ✅ Shows playable audio, MP3 (listed and taggable), images and PDFs, with a filter box and a tree view that keeps its expansion state across refreshes.
- ✅ **Digital booklets.** PDFs next to an album (including in `Scans`, `Artwork`, `Booklet`, `Extras` folders) open in a booklet reader. Pages for each track are found from the PDF's own outline first, then from the page text, so a track lands on its own lyrics or notes page.

---

## 6. Tag editing

- ✅ **Edit tags in the files themselves**: FLAC (Vorbis comments), ALAC and AAC in MP4 (iTunes atoms) and MP3 (ID3v2.4).
- ✅ Fields: title, artist, album, album artist, composer, year, genre, track and total, disc, and the four ReplayGain fields. Artist, album artist, composer and genre are multi-valued (separated by `;`).
- ✅ **Surgical writes.** Only edited fields change; every other comment, atom or frame is copied as it was, pictures included, and the audio is streamed across byte for byte, never decoded.
- ✅ **Atomic.** The new file is built beside the old one, flushed, and swapped in with one rename that keeps permissions. A failure at any point leaves the original untouched.
- ✅ **Never replaces a file in use.** A file the engine has open, or that is playing or buffered, is refused with a "busy" result and retried when it is free; the check is repeated immediately before the swap.
- ✅ **Bulk editing** of a selection from the Folders tab or the library.
- ✅ Own parsers for FLAC, MP4, AIFF/WAV `ID3 ` chunks and ID3v2.2–2.4, with AVFoundation filling gaps. Library imports of changed files pick up the edits.

---

## 7. Search

- ✅ **Query language.** A small, documented grammar that compiles to one Core Data predicate (run by SQLite, never by loading the library into memory):

  ```
  Genre: Jazz AND Year: 1955..1965 NOT Artist: "Miles Davis"
  composer:beethoven (tag:Classical/Symphonies OR work:sonata) -live rate:>=96k
  ```

  - Boolean operators `AND`, `OR`, `NOT` (also `&&`, `||`, `!`, `-`), recognised in capitals only, so "rock and roll" stays three words; juxtaposition means AND; parentheses group.
  - **Fields:** any, title, artist, album artist, album, composer, conductor, ensemble, performer, person, genre, tag, year, work, catalog, codec, rate, bits, channels, liked, plays, loudness (LUFS), DR, duration, path, hi-res. Many aliases (`by:`, `orchestra:`, `format:`, `khz:` …).
  - **Values:** quoted exact text, contains with `*` and `?` wildcards, ranges `a..b`, comparisons `>`, `>=`, `<`, `<=`, `=`, and hierarchical tags such as `tag:"Classical/Symphonies"`.
  - Case- and accent-insensitive. Errors point at the character where the query went wrong.
- ✅ **Plain search** across songs, albums, artists and works on the Search page.
- ✅ **Semantic Search** ("matches by meaning") appears under the ordinary results while the Intelligence feature is on. See [Intelligence](#4-intelligence-smart-features).

---

## 8. Credits

- ✅ **Credit graph.** Pick any person, from a track's credits or the search results, and see every record they worked on and in what capacity, plus the people they worked with. Roles are grouped as **Artist, Session musician, Producer, Engineer, Writer & arranger, Conductor & ensemble and Remixer**.
- ✅ **Fast.** One prefetching query per person (tracks, credits, parties and releases together), run off the main thread, so a prolific session player costs one round trip rather than one per record.
- ✅ **Shared credits** between two people, and a focus page for navigation.
- ✅ Credits come from file tags and from Deep Dive's MusicBrainz lookups, and are exposed to remote clients (`library.people`, `library.credits`, `library.sharedCredits`).

---

## 9. Lyrics

Lyrics are found in this order, and a time-synced result always beats a plain one:

1. ✅ **A sidecar file** next to the song (`.lrc` or `.txt`).
2. ✅ **The file's own tags**: embedded USLT/SYLT frames and lyrics tags.
3. ✅ **LRCLIB** (lrclib.net), a free open database of synced lyrics. Only the title, artist, album and length are sent, and results are cached on your Mac so a song is asked about once.
4. 🧪 **Generated on your Mac** with Whisper (tiny, base or small; base by default) for songs that have none. See the note below.

Features:
- ✅ **Sing-along view** on Now Playing: the current line is sharp and glowing, the lines around it softly blurred, and the page follows the song. Instrumental passages are marked as breaks. Scrolling is the system's own; the view waits a few seconds after you scroll and a pill brings you back.
- ✅ **Word-level highlighting** when the source carries word times (enhanced LRC, or lyrics Aureon generated), animated at the display's refresh rate.
- ✅ **Reduce Motion** is respected: lines then change brightness only.
- ✅ **Optional write-back** of lyrics to the file's tags (LRC text when timed).
- ✅ Read and written with Aureon's own LRC reader/writer, with tolerant parsing.

🧪 **Whisper generation** is an Intelligence feature: off with the master switch, never sent to an API, and only run after you agree for that song. The model runs in a separate helper process (`Packages/WhisperHelper`) so its memory returns to the system when it is unloaded and a failure cannot take the player down. The surrounding code (audio preparation to 16 kHz mono, filtering Whisper's known inventions on silence, splitting long passages into lines, marking instrumental stretches) is implemented; the helper depends on a speech-model package that has not yet been built and run end to end on a real model, so treat this one as experimental.

---

## 10. ABX blind testing

A listening-test bench for comparing two files (different masterings, a rip and its source, a lossless file and its lossy encode) honestly.

- ✅ **Sample-aligned.** Both files are decoded and carried through one four-channel ring, frame by frame, so they can never drift apart. Switching only changes which half of each frame is heard. An alignment search finds and removes any offset between the files.
- ✅ **Loudness-matched** with EBU R128 measurements, so a louder file does not win by being louder.
- ✅ **Click-free switching** with a 10 ms raised-cosine crossfade, and a loop region with short fades.
- ✅ **Double-blind trials.** X is randomly A or B; you answer each trial and the result is scored with a **p-value and a confidence interval**.
- ✅ **Real-time safe.** The audio thread only applies gains from atomics; nothing is allocated, locked or messaged there. Both files are resampled to a common rate and shown with the conversion that was applied.
- **Limits.** DSD files must be converted to PCM first. Starting ABX stops the main player; "Resume Player" restarts it.

---

## 11. MIDI controllers

- ✅ **CoreMIDI input** (UMP 1.0). The receive block packs messages into a **lock-free ring**; the main thread drains it. The audio render thread never sees MIDI.
- ✅ **Smart event handling.** Fader and knob moves are coalesced (at least 8 ms apart); notes, buttons and encoders never are.
- ✅ **MIDI Learn** and a mapping editor in Settings → MIDI, with 7-bit, **14-bit** (MSB/LSB pairs) and relative encoder modes, reverse, and **soft takeover** (pickup) so a fader does not jump the value when it is far from the on-screen position. `player.volume` always uses pickup.
- ✅ **Targets** for both DJ decks (play, cue, sync, loops, hot cues, pitch, trim, 3-band EQ, EQ kills, filter, headphone cue, effects, jog), the mixer (crossfader, master level), headphones (level, mix), each band of the parametric EQ and the player (volume, transport). Target ids are stable and saved in `~/Library/Application Support/Aureon/midi.json`.
- ✅ **Presets:** Pioneer DDJ-400 (deck 1/2, mixer, 8 hot-cue pads per deck, loops, jog and tempo, mapped from the controller's published MIDI map) and Korg nanoKONTROL2 (a DJ-mixer layout and a parametric-EQ layout). A preset is suggested when a matching device is plugged in.
- 🎛 **The presets have not been tried on physical hardware.** They follow published maps and have been exercised through a live virtual CoreMIDI source; where a control's direction is wrong, use Learn or Reverse.
- **Not included:** MIDI output / LED feedback and motorised faders.

---

## 12. DJ mode

A two-deck console on one mixer clock.

- ✅ **Waveform decks** with hot cues and a loop region; **BPM and musical key (Camelot) detection** with a cached analysis.
- ✅ **Pitch fader** (±8 / ±16 %) with pitch bend, **SYNC** and beat-aligned **BEAT sync**, and quantize.
- ✅ **Four hot cues per track** (remembered), IN/OUT and 1/2/4/8-beat loops with halve and double, beat jump and loop roll.
- ✅ **Channel strips:** trim, 3-band EQ with kill switches, sweep filter, channel faders and meters, crossfader assign.
- ✅ **Effects rack:** echo, reverb, flanger and gate. **Crossfader** in smooth, blend or cut curves.
- ✅ **Master section:** master EQ, level and a brick-wall limiter at −0.3 dBFS.
- ✅ **Headphone cue (PFL)** on a second device or outputs 3–4 (🎛 run with simulated devices only), and a **WAV mix recorder**.
- ✅ **Library browser** with BPM, key and energy columns, and "Analyse all".
- ✅ **Customizable layout.** The console's decks, mixer channels, bottom bar and page can each show, hide and reorder their sections from the Layout button; the choice is saved.
- ✅ **Auto DJ** and **Smart Remixer** (see [Intelligence](#4-intelligence-smart-features)), and **Smart DJ** set building.
- **Limits.** No keylock (changing pitch changes key), no scratching. Tempo and key are estimates and can be wrong on tracks without a clear beat (half and double time is common). The mix runs through a limiter.

---

## 13. User interface

- ✅ **One rail.** Now Playing, Collection, Rooms and Atelier across the top, a quiet line of tabs under each, Back / Forward (⌘[ ⌘]), and a command palette (**⌘K**) that reaches every page, every Sound tab and the main actions.
- ✅ **Now Playing.** The cover, the title and artist, and a quality plate beside the title (Hi-Res with bit depth and rate, Lossless, or the codec for lossy files, with a gold dot when the path is bit-perfect and the source and output in a hover pop-up). Lyrics, Queue, Signal path, Analyser and Booklet open as a panel beside the cover.
- ✅ **Focus mode (F).** Only the cover, the names, progress and transport remain, with the cover as large as the window allows. A second press restores the panel; the choice is remembered.
- ✅ **Player bar.** Cover, title, progress, volume with mute, and the lyrics and queue buttons, on a floating plate of glass; the quality plate shortens first in a narrow window.
- ✅ **Themes.** Six families (Obsidian with its light twin Ivory, Bespoke, Graphite, Evergreen, Nord, Gruvbox), each in dark and light, with a one-tap light/dark switch in the rail (a soft circular reveal) or Auto to follow macOS. Text contrast follows WCAG ratios on every theme and backdrop.
- ✅ **Backdrops.** Flat, Soft, **Album** (colours from the cover that is playing, at Subtle, Rich or Vivid, rendered once off the main thread and cross-faded on a track change) and Starlight.
- ✅ **Glass accents** on the player bar, the Now Playing panels, the palette and pop-ups: Liquid Glass on macOS 26, a blurred material elsewhere; off in Settings and with Reduce Transparency.
- ✅ **Quick control panel (⌥⌘D).** Output device list with one-click switching, and exclusive access, volume, gapless / crossfade, levelling, upsampling, equaliser, shuffle and repeat, plus Level speakers and More sound settings.
- ✅ **Atelier → Sound** in five tabs (Output, Conversion, Levels, Headphones & room, Playback), with a bit-perfect strip on top and OFF | ON switches.
- ✅ **Launch animation** (planet, a ring that draws itself closed, a star, the name); skipped by a click or key, optional in Settings, never delays start-up.
- ✅ **Page transitions.** A quick fade in place (or none); nothing slides or zooms.
- ✅ **Waveform scrubber.** The scrubber shows the track's waveform, computed once, cached on disk, and borrowed from the DJ analysis when it exists. The played part keeps at least 4.5:1 contrast against its background (3:1 against the unplayed part) on every theme and backdrop, and a short gold marker shows every seek.
- ✅ **Scroll-wheel on sliders.** Sliders respond to the scroll wheel and trackpad, and custom controls pass scrolling on to the page when they cannot use it. The volume slider changes with **⌥ + scroll** by default (a plain scroll over the bar scrolls the page), in steps of 1 % with no single event above 3 %; Settings can turn it off or limit it to the handle.
- ✅ **Volume safety.** The volume controls never invent a reading (an unreadable device volume is shown as unavailable), move only when you grab the knob, and obey an optional ceiling.
- ✅ **Visualizers.** Spectrum, spectrogram and analog VU needles (300 ms ballistics, peak hold, clip light), fed by a lock-free tap, shown together in the Analyser panel.
- ✅ **Intelligence page** with the master switch, hardware badge, per-feature switches, local model loader and API settings.
- ✅ **Home page** with what you were playing, radio and podcast doors and album rails.
- ✅ **Accessibility.** Reduce Motion is honoured in the animated views.

---

## 14. Performance

- ✅ **120 fps interface.** Heavy work (Core Data fetches, model inference, disk reads, cross-correlation, waveform and colour analysis) runs off the main thread. Scrolling, transitions and the playhead run at the display's refresh rate.
- ✅ **Meters, spectrum and spectrogram are capped at 60 fps** to leave headroom, fed by a lock-free tap that only copies samples on the audio thread.
- ✅ **Artwork cache.** Cover art is extracted once and cached as a 384-px thumbnail, a 1200-px large picture and a stored colour palette in `~/Library/Caches/Aureon/Artwork`, content-addressed so identical covers are shared. Later launches never re-parse audio files for art. A "no cover" answer is remembered for 12 hours.
- ✅ **Paged albums.** The album grid loads 48-row pages from SQL and keeps at most five resident, so a library of thousands of albums scrolls smoothly.
- ✅ **Denormalised sort and count columns** on releases, refreshed in the same commit as the data, so sorting and paging do not touch every track.
- ✅ **Fast, linear imports** using one bulk lookup of known files instead of a fetch per file.
- ✅ **Delta library updates** (FSEvents) instead of a startup rescan.
- ✅ **Start-up benchmark** that sizes buffers and picks what this Mac can sustain in real time for extreme rates and PCM→DSD, so slower machines degrade gracefully.
- ✅ **System optimisation.** Time-constraint scheduling for the decode thread and an optional privileged helper that pauses Spotlight and Time Machine while you listen, with fail-safe resume (see [SYSTEM-OPTIMIZATION.md](SYSTEM-OPTIMIZATION.md)). 🎛 The helper has not been run as root; its logic has only been run against stand-in processes.
- ✅ **Models stay out of the way.** The language model and semantic index load when needed, unload after a period of idleness, and free their memory when the master switch is turned off.

---

## 15. Sources, outputs and tools

- ✅ **Internet radio** (radio-browser.info): local, high-quality (including lossless FLAC streams), by genre, location and language, favourites and your own stream URLs. MP3, AAC/HE-AAC and FLAC over HTTP(S), live "now playing" titles and automatic reconnection. Streams are upscaled with the sinc resampler to the DAC's best rate (switchable).
- ✅ **Podcasts** from Apple's public directory and each show's RSS feed, downloaded before playing so seeking and the full signal path work as for any file.
- ✅ **Cloud and servers.** Your own Backblaze B2, Amazon S3, Cloudflare R2, Wasabi or MinIO bucket (SigV4, keys in the Keychain), Navidrome / Subsonic servers and Lyrion Music Server, streamed through a chunked reader with read-ahead, retries and next-track warming so playback stays gapless. 🎛 Run against in-memory servers that verify every signature, not live accounts.
- 🎛 **Speaker set-up.** Play through several outputs at once, each with a job: stereo, left, right, centre, ambience or bass. Each output has a distance, a level trim and an extra delay (−50 to +500 ms). Levels follow the volume in each device's own decibel steps, with a starting level per job (ambience sits 6 dB behind the music), and outputs are time-aligned from their reported latency. Ambience keeps the low notes exactly as the stereo speakers play them. Run against simulated devices; not measured on real speakers.
- ✅ **Cast, multi-room and AirPlay.** The processed output is encoded to lossless FLAC on the fly and sent to Chromecast / Google Home / Nest. Multi-room zones feed Sonos, DLNA/UPnP and Chromecast with sample-exact per-room delay and an "Align rooms" step. AirPlay uses the system route picker. 🎛 Verified against software speakers, not physical ones.
- ✅ **Rip CD.** Native IOKit drive access with C2 error pointers, secure re-reads with voting, offset correction, **AccurateRip** v1/v2 verification, MusicBrainz tags and covers, FLAC / Apple Lossless / WAV, CUE sheet and log; BIN/CUE images too. 🎛 Run against a simulated drive.
- ✅ **Convert.** Multithreaded batch transcoding to AAC, Apple Lossless or FLAC with optional R128 levelling that never lets a true peak pass the ceiling, tags and cover art carried over, and the folder structure mirrored. Also available from the terminal.
- ✅ **Scrobbling and presence.** Last.fm and ListenBrainz with an offline retry queue, and Discord Rich Presence showing the stream quality. Secrets live in the Keychain.
- ✅ **Headless daemon and remote protocol.** `Aureon daemon` serves JSON-RPC over WebSocket with Bonjour discovery, challenge-response pairing and delta sync, and a Wi-Fi bridge syncs a library to a companion app over TLS-PSK. See [REMOTE-PROTOCOL.md](REMOTE-PROTOCOL.md).
- ✅ **Command line.** `play`, `convert`, `inspect`, `verify`, `devices`, `radiocheck`, `hwdebug` and `daemon`.
- ✅ **Hardware diagnostics.** `Aureon hwdebug` tests hog-mode acquisition, integer-format negotiation, rate switching and callback health on your DAC and can write a JSON report.

---

## 16. Not included

Listed so nothing here is a surprise:

- **Tidal, Qobuz and Spotify.** They hand lossless streams only to their own apps and partners. Aureon does not circumvent that.
- **MQA** and **UPnP renderer** output.
- **An iOS companion app.** The protocol, a Foundation-only client library and a library-sync mirror are included; the app is not.
- **Beat-matched transitions** between queued songs. The DJ console beat-matches; queue playback does not.
- **Keylock and scratching** in DJ mode, and **MIDI output / LED feedback**.
- **Encryption on the daemon's remote channel** (the Wi-Fi bridge uses TLS-PSK, which has no forward secrecy and is meant for a trusted home network).
