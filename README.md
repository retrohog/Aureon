# Aureon

An open-source, audiophile-grade music player for macOS. Aureon keeps your music **bit-perfect** from file to DAC by default,
and lets you opt in to processing — upsampling, ReplayGain, EQ, crossfeed, room correction, plugins — only when you want it. The
signal-path panel always tells you which it is.

> Status: early (0.2). The engine and every service are covered by 236 automated tests; what could not be verified without special
> hardware, accounts or signing is listed under [Limitations](#limitations) — read it before relying on those parts.

## Features

| | |
|---|---|
| **Lossless playback** | FLAC, ALAC, WAV, AIFF decoded at the file's own rate and depth into 32-bit integers. Gapless across same-format tracks; the device clock follows each track. |
| **Dual-path architecture** | Processing off: ring buffer → DAC callback, nothing in between. DSP on: the callback pulls from an `AVAudioEngine` in manual-rendering mode. |
| **DSD** | DSF/DFF. **DoP** keeps the DSD bits untouched with a marker that continues across tracks; or convert to PCM. |
| **Upsampling** | Native polyphase sinc resampler, any rational ratio, linear or minimum phase. No dependencies. |
| **Memory playback** | Whole tracks decoded into RAM before playing; the next two are prefetched. Zero disk reads during playback is asserted by a test. |
| **ReplayGain** | Reads tags (Vorbis, ID3, iTunes); measures EBU R128 loudness for untagged files; peak-aware clipping protection. |
| **Live queue** | Remove, reorder, insert and append while playing; the audible track is never disturbed. |
| **Headphones** | Bauer **BS2B crossfeed**; **AutoEQ** profiles fetched on demand from the open AutoEQ database (any number of filters, safety pre-amp). |
| **Room correction** | **Partitioned FFT convolution** (Accelerate) of Room EQ Wizard–style impulse responses (WAV int/float, mono/stereo, any rate), resampled to the stream. 8 s of stereo IR runs ~57× faster than real time. |
| **DJ mode** | A two-deck console on one mixer clock: waveform with hot cues and loop region, tempo (BPM) and musical key (Camelot) detection with a cached analysis, pitch fader (±8 / ±16 %) with pitch bend, SYNC and beat-aligned BEAT sync, quantize, 4 hot cues per track (remembered), IN/OUT and 1/2/4/8-beat loops with halve/double, per-channel trim, 3-band EQ with kill, sweep filter and an effect rack (echo, reverb, flanger, gate), channel faders, crossfader (smooth / blend / cut), master EQ, level and a brick-wall limiter, headphone cue (PFL) on a second device or outputs 3–4, a WAV mix recorder and a library browser with BPM / key / energy columns. **Auto DJ** picks the next track, matches tempo, and blends with a bass swap, using a ~200-weight on-device network that learns from your thumbs-up / thumbs-down (no cloud, not a language model). |
| **Volume safety** | The volume controls never invent a reading (an unreadable device volume is shown as unavailable), move only when you grab the knob (a click elsewhere nudges a few per cent) and obey an optional ceiling in Settings. |
| **Home & Settings** | A Home page with what you were playing, Radio and Podcasts doors and album rails; a Settings page holds General, Connect and System. |
| **Internet radio** | Free stations worldwide from the radio-browser.info directory: Local radios, High Quality (including lossless FLAC streams), By genre, By location, By language, favourites and your own stream URLs. MP3, AAC/HE-AAC and FLAC over HTTP or HTTPS, live "now playing" titles (ICY metadata), automatic reconnection. Streams are **upscaled automatically** with the sinc resampler to the DAC's best rate (switchable). |
| **Podcasts** | Top shows, categories and languages from Apple's public podcast directory; episodes from the show's own RSS feed, downloaded before playing so seeking and the whole signal path work as for any file. |
| **Artists** | Round portraits (Deezer, then Wikipedia) with an offline fallback that builds a mosaic of the artist's own album covers; sorting, quality filters, A–Z grouping, grid or list, cover-size slider. Songs and albums sort and filter the same way. |
| **Navigation** | Back / Forward (⌘[ ⌘]) retrace pages, albums, genres and shows. |
| **Apple Music-style layout** | Grouped sidebar (Library, Classical, Sound, Discover, Devices) with search; albums as a cover grid with HD marks, album pages with Play / Shuffle / Add to Queue; a floating player bar on every page with transport, progress, format badge, volume and the queue (opened from the bar, no permanent column). |
| **Playlists & likes** | Liked Songs and Playlists in the sidebar; a heart on every song (list, player bar, Now Playing); "Add to Playlist" in every song menu. Click anywhere on a row to play it, with a flash and bounce. |
| **Shuffle & repeat** | Shuffle off / normal / **Smart Shuffle** (no back-to-back artists, favours liked songs, uses tempo and key when known), repeat off / all / one (gapless). |
| **Duplicates** | After adding music Aureon offers to review songs and albums you have twice, recommends the best copy (lossless, resolution, size), shows what would go and why, and moves the rest to the Trash only after you confirm. "feat." artists are folded into their host artist. |
| **DSP profiles** | EQ and plug-in settings are saved into named profiles; unsaved changes prompt when you leave the page or quit. Plug-in windows resize and scroll. |
| **AI Remixer** | In the DJ console: a small on-device network picks filter sweeps, echo-outs, loop rolls, drops, risers and stutters on the bar line and learns from thumbs. It performs the deck's own controls; it does not separate stems. |
| **Themes & sliders** | Seven themes (Aureon, Evergreen, Nord, Catppuccin, Dracula, Gruvbox, Synthwave), each with a dark and a light version (sun/moon button in the sidebar, or Settings → Appearance). Every slider, knob and fader also responds to the scroll wheel / trackpad; the volume slider moves relative to where you drag and can never jump. |
| **Immersive player** | Large cover over a drifting mesh gradient in the cover's own colours, serif title hierarchy (title, artist, album · year · genre, composer), hardware-style format badges (Hi-Res mark, FLAC, 24-BIT \| 96 kHz), a fluid scrubber and volume slider, animated tab transitions. |
| **Signal path** | A node graph from file → decoder → stages → buffer → DAC with pulses flowing along the line; green while the signal is untouched, orange from the first stage that changes samples. Hover a station for details. |
| **Tags & artwork** | Own FLAC (Vorbis + PICTURE blocks, base64 pictures, leading ID3v2), ALAC (`covr`), AIFF/WAV (`ID3 ` chunk) and ID3v2.2–2.4 parsers; AVFoundation fills gaps. Missing covers are fetched from the iTunes Search API, then MusicBrainz + Cover Art Archive, with strict album/artist matching and an on-disk cache. |
| **Spectrum, spectrogram, VU** | 60 fps Canvas views fed by a lock-free tap; the audio thread only copies samples. Analog VU needles with 300 ms ballistics, peak hold, clip light. |
| **DSP & plugins** | 10-band parametric EQ with auto headroom; hosts third-party Audio Unit effects. |
| **Library & classical tags** | Core Data library; multi-valued artists/composers/conductors/ensembles/soloists, work, movement, opus; FLAC Vorbis and ALAC/MP4 parsers. Browse Composer → Work → Recordings → Movements. |
| **Deep Dive** | Identify untagged files (AcoustID/Chromaprint), then MusicBrainz credits (session musicians, producers, composers), artist biographies (Wikipedia), cover art, releases. |
| **Discord & scrobbling** | Rich Presence with quality (“FLAC · 24-bit / 192 kHz”) over Discord's IPC socket; Last.fm and ListenBrainz with an offline retry queue. Secrets live in the Keychain. |
| **Headless daemon & remote** | `Aureon daemon` (or a switch in the app): JSON-RPC over WebSocket with Bonjour, challenge-response pairing, and delta sync for a companion app. |
| **System optimisation** | Time-constraint scheduling for the decode thread, IO cycle usage, and an optional privileged helper that pauses Spotlight/Time Machine while you listen — with fail-safe resume. |
| **Hardware diagnostics** | `Aureon hwdebug`: hog-mode acquire / contention / release, integer-format negotiation, rate switching, silent callback-health test. |

## Install

```bash
git clone <this repo> && cd Aureon
./Packaging/build_app.sh                 # builds and installs ~/Desktop/Aureon.app
./Packaging/build_app.sh --with-helper   # also embeds the quiet-mode helper (needs a signing identity, see Docs/SYSTEM-OPTIMIZATION.md)
```

Requirements: macOS 15+, Swift 6 toolchain (the Command Line Tools are enough — no Xcode needed). The app is ad-hoc signed by default;
on first launch use right-click → Open.

## Use

Double-click the app, or from a terminal:

```bash
Aureon play --ram --replaygain track *.flac
Aureon play --upsample max --phase minimum album/*.flac
Aureon play --crossfeed --headphone-eq "HD 650 ParametricEQ.txt" --convolve room.wav song.flac
Aureon play --dsd dop --hog track.dsf                  # only with a DoP-capable DAC!
Aureon daemon --music ~/Music --name "Study"           # headless; prints the pairing token
Aureon hwdebug --all --json report.json                # test your USB DAC
Aureon radiocheck https://example.com/stream.mp3     # decode a live stream for a few seconds and report (plays nothing)
Aureon inspect song.flac | Aureon verify a.flac b.wav | Aureon devices | Aureon selftest [filter]
```

Keys: <kbd>Space</kbd> pause · <kbd>←</kbd>/<kbd>→</kbd> ±10 s · <kbd>⌘←</kbd>/<kbd>⌘→</kbd> previous/next.

**DoP safety:** a DAC that does not understand DoP plays it as loud noise. Aureon never enables it by default and asks for confirmation.

## Testing

```bash
swift build -c release && .build/release/Aureon selftest        # 236 tests, ~1 min, no audio hardware needed
.build/release/Aureon selftest queue                             # a subset, by name
```

The Command Line Tools ship neither XCTest nor Swift Testing's macro plugin, so the tests are compiled into the binary behind a small
runner (CI and contributors use the same command). End-to-end tests play real files through the real `Player` into a `RecordingSink`
that consumes the ring exactly like a DAC, then check the *delivered samples*: bit-exact gapless and FLAC decoding, no dropped frames
across seeks, pauses and live queue edits, DoP marker continuity, resampler error floor below −100 dB, EBU loudness reference, EQ and
crossfeed design properties, convolution against brute force, a lock-free stress test, Discord against a fake IPC server on a real Unix
socket, Last.fm signatures checked against an independent MD5, a real WebSocket server/client with a 1 200-track sync, a spawned daemon
process, and the helper's suspend/resume logic against real stand-in processes and an XPC round trip.

## Architecture & docs

* [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) — pipeline, real-time rules, RCU, queue reconciliation, DSD, resampler, visualisers
* [Docs/LIBRARY.md](Docs/LIBRARY.md) — schema, tag mapping, classical ontology
* [Docs/REMOTE-PROTOCOL.md](Docs/REMOTE-PROTOCOL.md) — the daemon and the companion-app protocol
* [Docs/SYSTEM-OPTIMIZATION.md](Docs/SYSTEM-OPTIMIZATION.md) — scheduling and the privileged helper
* [Docs/RESEARCH.md](Docs/RESEARCH.md) — clean-room notes on how commercial players are built

## Limitations

Honest list of what is **not** verified or **not** built:

- **Integer mode and DoP are untested against a real USB DAC.** The built-in headphone output offers float formats only; `hwdebug` tells you what your hardware accepts.
- **The privileged helper has never been registered or run as root** (it needs a signed build and your approval). Its logic is tested against stand-in processes; do the supervised first run described in its doc.
- **No iOS app is included.** The protocol, a Foundation-only client library and a library-sync mirror are, and are tested over real sockets. The remote channel is not encrypted.
- **Discord, Last.fm, ListenBrainz, AcoustID and MusicBrainz are tested against fakes/canned responses**, not live accounts: you supply your own keys. Fingerprinting needs `fpcalc` (Chromaprint); a native port is not attempted because AcoustID accepts only exact Chromaprint fingerprints.
- **Resampler is native, not SoX.** `FrameSource` stages make libsoxr a drop-in later. DST-compressed DSD is not supported.
- Convolution adds one block (≈ 11 ms) of latency and its tail is cut at the end of the last track.
- Real-time safety: our callback code is lock-free and allocation-free; Swift reference counting and Apple's `AVAudioEngine` render block are used as documented but outside our control.
- **Artwork lookup is tested against canned responses**, not the live iTunes / MusicBrainz services. Only artist and album names are sent; it can be switched off in Audio → Artwork. DSF/DFF tags (stored at the end of the file) are not read yet.
- **Radio is lossy** (except the FLAC stations). Upscaling replaces the system mixer's resampling with one long-filter step; it cannot restore detail the broadcaster removed. HLS (`.m3u8`) and Ogg/Opus stations are not offered. Verified against real MP3, HE-AAC and FLAC stations with `radiocheck`; the directory itself is a community service and some stations are offline.
- **Podcast playback downloads the whole episode first** (progress is shown); there is no streaming start, queue of episodes or resume position yet.
- **Artist portraits** come from Deezer's public search by exact name and Wikipedia; a common name can still match the wrong artist, in which case the album mosaic is a safer look.
- **DJ mode limits.** No keylock (changing pitch changes key), no scratching / jog wheel, no MIDI controllers. The headphone cue routes to a second device or outputs 3–4; it has been tested with simulated devices only, not with real hardware. Beat sync is only as accurate as the position readout (about a few tens of milliseconds). Tempo and key are estimated and can be wrong on tracks without a clear beat or tonal centre (half/double time is common). Auto DJ needs analysed tracks (use “Analyse all”); its choices are a heuristic plus a tiny network, so expect the occasional poor pick — rate mixes to teach it. The mix runs through a limiter at −0.3 dBFS.
- **No TagLib:** the parsers are Aureon's own (a C++ dependency adds build complexity for no benefit here); unusual tag layouts may still need AVFoundation's fallback.
- The interface is dark-only. Hover, drag and animation behaviour was reviewed from rendered snapshots and code, not by clicking through the live app.
- Not built: streaming services, UPnP/Chromecast renderers, MQA.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Most valuable: a USB-DAC `hwdebug --json` report, libsoxr as an alternative resampler, TLS for the remote channel, an iOS companion app.

## License

MIT — see [LICENSE](LICENSE).
