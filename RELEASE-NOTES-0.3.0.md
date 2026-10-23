<div align="center">

<img src="https://github.com/retrohog/Aureon/raw/main/assets/banner.svg" alt="Aureon" width="100%" />

# Aureon 0.3.0

**A new design for the whole app, speaker levelling for multi-output set-ups, a quick control panel, Focus mode and a long list of fixes.**

</div>

Aureon still plays your music bit-perfect from file to DAC by default. Everything that changes the samples (upsampling, EQ,
crossfades, DSD conversion, levelling) is opt-in, and the signal-path view always shows which state you are in.

> [!NOTE]
> **Platforms.** This release is for **Apple Silicon Macs running macOS 15 or later**. The new design for Intel-based Macs
> and for Windows is coming.

<div align="center">
<img src="https://github.com/retrohog/Aureon/raw/main/Docs/images/now-playing.png" alt="Now Playing in Aureon 0.3.0" width="100%" />
</div>

## New design

Everything is rebuilt around one calm, dark-and-gold look with a light twin, and a navigation that fits on one line.

- **Four places, one rail.** Now Playing, Collection, Rooms and Atelier sit across the top. Each place has a quiet line of
  tabs under it (Collection: Albums, Artists, Songs, Playlists and the rest; Atelier: Sound, Equaliser, DJ, Rip CD, Convert, Cloud,
  Intelligence, ABX Test, Diagnostics). **⌘K** reaches every page, every Sound tab and the main actions by name.
- **Now Playing.** The cover, the title and artist, and a quality plate beside the title: **Hi-Res** with the bit depth and rate,
  **Lossless**, or the codec in plain text for lossy files; a gold dot shows when the path is bit-perfect, and hovering gives
  the source and output in detail. Lyrics, Queue, Signal path, Analyser and Booklet open as a panel beside the cover.
- **Focus mode.** Press **F** (or use the Focus button): only the cover, title and artist, progress and transport stay, and the
  cover grows as large as the window allows. Press F again to bring the panel back.
- **Analyser.** Spectrum, spectrogram and levels are shown together, filling the panel, instead of behind tabs.
- **Themes.** Six colour families, each in dark and light. **Obsidian** (midnight black and ivory with champagne gold) is the
  default and its light twin is **Ivory**. The page behind everything can be Flat, Soft, **Album** (colours taken from the
  cover that is playing, at Subtle, Rich or Vivid) or Starlight, with the text kept readable on all of them.
- **Light and dark in one tap.** A sun and moon switch in the top rail changes the whole window with a soft circular reveal.
  Appearance can also follow macOS.
- **Glass accents** on the player bar, the Now Playing panels, the ⌘K palette and pop-ups (Liquid Glass on macOS 26, a blurred
  material elsewhere). It switches off in Settings and with Reduce Transparency.
- **Quick control panel** (**⌥⌘D**, or the speaker button in the rail and the player bar): switch the output device in one
  click and reach the settings you change most: exclusive access, volume, gapless or crossfade, levelling, upsampling,
  equaliser, shuffle and repeat. Every control is the same setting as its place in Atelier.
- **Launch animation.** The Aureon mark appears, its ring draws itself round the planet and closes, a star leaves it and the
  name follows. A click or any key skips it; it can be switched off in Settings and it never delays start-up.
- **Calm page changes.** Pages and tabs change with a quick fade in place; nothing slides or zooms. **Page transitions: None**
  switches the fade off.
- **Atelier → Sound in five tabs.** Output, Conversion, Levels, Headphones & room and Playback, each with only its own settings,
  and a strip at the top that always says whether the signal path is still bit-perfect.
- **Clearer switches.** Every on/off setting is an **OFF | ON** control, so the state is readable at a glance.

## New features

- **Speaker levelling for several outputs.** With more than one output playing, each speaker's loudness follows the volume in
  its own decibel steps, so one no longer comes in louder than another, and the change is a short, even slide. Each job has a sensible
  starting level (ambience sits behind the music), with a **Level** trim per output and per room in multi-room zones.
  Aureon also reads how late each output plays and delays the earlier ones, so a built-in speaker and a Bluetooth one arrive together.
  **Extra delay** (−50 to +500 ms) trims by ear. **Level speakers** in the quick panel and in ⌘K jumps straight to it in Rooms.
- **Scroll to change volume** is now a choice: Off, **⌥ + scroll** (the default), or only over the handle. A plain scroll over
  the bar scrolls the page, one notch moves 1 %, and no single scroll moves it more than 3 %.
- **Seek feedback.** A short gold marker shows where you clicked on the waveform, every time.
- **Lyrics offset.** Nudge the lyrics ±2 s when a file is a little off.
- **New settings in Appearance:** backdrop intensity, glass accents, page transitions, launch animation and scroll to change volume.

## Bug fixes

- **Closing Now Playing no longer leaves part of the window unresponsive.** The sidebar problem listed as a known issue in 0.2.0 is gone.
- **The waveform can always be read.** The played part keeps at least 4.5:1 contrast against its background and 3:1 against the
  part still to play, on every theme and backdrop, including Album at Vivid and Ivory.
- **Lyrics follow the song closely.** The lag between the sung line and the highlighted line is fixed.
- **The shuffle menu** no longer shows blank rows, and shuffle can actually be chosen.
- **Accidental volume jumps from scrolling** over a wide volume bar are fixed (see above).
- **The Ambience speaker keeps the beat.** It plays the low notes exactly as the stereo speakers do and adds the room above them, and it sits
  6 dB behind the music; before, it played only what differs between the channels, which removed the beat and left a hall-like sound.
- **The first-launch password prompt** caused by reading saved service credentials from the Keychain is fixed.
- **Page titles and lists stay clear of the top bar** when you scroll.
- **The queue panel and lists keep a fixed height** and scroll inside themselves, so nothing else on the page moves when the queue grows.

## Install

1. Open **Aureon-0.3.0.dmg** and drag **Aureon** to **Applications** (or run **Aureon-0.3.0.pkg**).
2. The app is **not notarised yet**, so the first time you open it, right-click it and choose **Open**.

Requires an Apple Silicon Mac with macOS 15 or later.

## Checksums

```
SHA256_PLACEHOLDER
```

Everything else is unchanged from 0.2.0; see [RELEASE-NOTES-0.2.0.md](RELEASE-NOTES-0.2.0.md) for the earlier changes.
