<div align="center">

<img src="https://github.com/retrohog/Aureon/raw/main/assets/banner.svg" alt="Aureon" width="100%" />

# Aureon 0.3.0

**A new design, speaker levelling for several outputs, quick controls, Focus mode and a long list of fixes.**

<img src="https://github.com/retrohog/Aureon/raw/main/Docs/images/now-playing.png" alt="Now Playing in Aureon 0.3.0" width="100%" />

</div>

Aureon still plays bit-perfect from file to DAC by default. Everything that changes the samples is opt-in, and the signal path
always shows which state you are in.

> [!NOTE]
> **Platforms:** Apple Silicon Macs on macOS 15 or later. The new design for Intel Macs and Windows is next.

## What's new

### New design

- **One rail.** Now Playing, Collection, Rooms and Atelier across the top, a line of tabs under each, and a command palette on **⌘K** that reaches every page and main action.
- **Now Playing.** The cover, title, artist and a quality plate: **Hi-Res** with bit depth and rate, **Lossless**, or the codec for lossy files. A gold dot marks a bit-perfect path.
- **Side panels.** Lyrics, Queue, Signal path, Analyser and Booklet open beside the cover. The analyser shows spectrum, spectrogram and levels together.
- **Focus mode.** Press **F** for the cover, names, progress and transport only, with the cover as large as the window allows.
- **Themes.** Six families, each dark and light. **Obsidian** is the default, **Ivory** its light twin.
- **Backdrops.** Flat, Soft, Starlight, or **Album**, with colours taken from the playing cover at Subtle, Rich or Vivid. Text stays readable on all of them.
- **Glass accents** on the player bar, panels, palette and pop-ups. Liquid Glass on macOS 26, a blurred material elsewhere; optional.
- **Light and dark in one tap**, or follow macOS.

### Controls and settings

- **Quick controls (⌥⌘D).** Switch the output device and reach exclusive access, volume, transitions, levelling, upsampling, EQ, shuffle and repeat.
- **Atelier → Sound** in five tabs: Output, Conversion, Levels, Headphones & room, Playback. A strip on top shows whether the path is still bit-perfect.
- **Clearer switches.** Every on/off setting is an **OFF | ON** control.
- **Scroll to change volume** is a choice: Off, ⌥ + scroll (default) or over the handle. One notch moves 1 %, and no scroll moves more than 3 %.
- **Page transitions and launch animation** are settings. Pages change with a short fade, or at once.

### Sound and outputs

- **Speaker levelling.** Several outputs follow the volume in their own decibel steps, with a starting level for each job and a **Level** trim per output and per room.
- **Time alignment.** Aureon reads each output's latency and delays the earlier ones, so a built-in speaker and a Bluetooth one arrive together. **Extra delay** (−50 to +500 ms) trims by ear.
- **Level speakers** in the quick panel and ⌘K opens the speaker set-up in Rooms.
- **Lyrics offset** of ±2 s for files that run a little early or late.

## Fixes

- Closing Now Playing no longer leaves part of the window unresponsive (the known issue in 0.2.0).
- The waveform keeps its contrast on every theme and backdrop, and each seek is marked.
- Lyrics follow the sung line closely; the lag is gone.
- The shuffle menu lists its choices and they can be selected.
- Scrolling over a wide volume bar no longer changes the volume by accident.
- The Ambience speaker keeps the beat: it plays the low notes like the stereo speakers and sits 6 dB behind the music.
- The first-launch password prompt caused by reading saved credentials from the Keychain is gone.
- Page titles and lists stay clear of the top bar when you scroll.
- Lists and the queue keep a fixed height and scroll inside themselves, so nothing else moves when the queue grows.
- Closing the launch animation never quits the app if the main window is slow to open.

## Known issues

- Casting and multi-room streams can crash under heavy load: the live FLAC encoder has an intermittent index error. Not fixed yet.
- The app is ad-hoc signed and not notarised. The first launch needs right-click → **Open**, and macOS may ask again for music-folder access after an update.
- Speaker levelling and alignment have not been checked by ear on every speaker. Bluetooth speakers may need an Extra delay trim.
- Intel Macs and Windows do not have the new design yet.

The README lists what has not been verified on real hardware.

## Install

Open **Aureon-0.3.0.dmg** and drag **Aureon** to **Applications**, or run **Aureon-0.3.0.pkg**. On first launch, right-click the app and choose **Open**. Requires an Apple Silicon Mac with macOS 15 or later.

## Downloads and checksums

```
SHA256 (Aureon-0.3.0.dmg)  2366c8de488daf1aa6d7af13b56e6289d0b3b475f3fc5aaacc61495fa6554f75
SHA256 (Aureon-0.3.0.pkg)  d557e407df326060f5ad5ed636a8adab7d7760e60a2f96be34fd13321c407902
```

Earlier changes are in [RELEASE-NOTES-0.2.0.md](RELEASE-NOTES-0.2.0.md).
