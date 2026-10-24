<div align="center">

<img src="https://github.com/retrohog/Aureon/raw/main/assets/banner.svg" alt="Aureon" width="100%" />

# Aureon 0.4.0

**A new design: five colours in dark and light, six Now Playing layouts, a mini player and menu bar player, and an app that remembers where you were.**

<img src="https://github.com/retrohog/Aureon/raw/main/Docs/images/pulse/now-playing-stage.png" alt="Now Playing in Aureon 0.4.0" width="100%" />

</div>

Aureon still plays bit-perfect from file to DAC by default. Everything that changes the samples is opt-in, and the signal path
always shows which state you are in.

> [!NOTE]
> **Platforms:** Apple Silicon and Intel Macs on macOS 15 or later. The Windows version follows separately.

## What's new

### A new design

- **A new shell.** A search bar and the output chip across the top, a rail of five places (Library, Playlists, Radio, Rooms, Sound), rounded panels, and a player bar with the cover, title, tags, transport and volume.
- **Five colours, each in dark and light.** Graphite, Midnight, Forest, Plum and Cocoa. Every colour has a dark side and a soft light side; choose **Dark**, **Light** or **Auto**, which follows macOS as it changes. A **Pure black** switch puts any dark side on a true black window for OLED screens.
- **Accent colour.** Pick any colour; text in it is kept readable on every surface. The light sides have a brightness control.
- **Starlight.** A slow field of fine stars behind the pages on dark themes, with intensity, motion, shooting stars and twinkle under your control. Flat, Soft and Album backdrops are still there.
- **Figtree.** The interface is set in Figtree, bundled with its licence (SIL Open Font License), in Regular by default. Light and Medium are a choice, and so is the text size.
- **Density.** Compact is the default and Comfortable gives lists and covers more room. It lives in Settings → Appearance.
- **Home follows the time of day.** A greeting for the hour, quick picks, and shelves such as Back in rotation, Hi-Res you haven't heard and a mood for the part of the day, all chosen on your Mac from what you play. **Why these?** explains each pick and **Refresh mix** draws a new one.
- **Folders** lists every library folder with its song count and status, and **Remove** takes one out of the library after asking. Your files are never touched.

### Now Playing

- **Six layouts**, chosen in Settings → Now Playing with a preview of each: **Stage**, **Classic**, **Full-bleed**, **Carousel**, **Lumen** and **Chillax**. Each is drawn for a large window and scales down to a small one.
- **The controls are always there.** Shuffle, previous, play or pause, next and repeat; the seek bar with both times; the queue, the mini player, the volume and the output chip stay in view in every layout, down to the smallest window. Lyrics and Up next give way first.
- **Lyrics** stay large and follow the sung line. Their size and timing are in Settings → Now Playing, so nothing floats over the words.
- **Add to playlist** from the song on screen: a card with a search, **New playlist**, and a tick beside each playlist that holds the song.
- **Credits** under the artist (written by, produced by, conductor, ensemble, instruments), the format tags and the signal path, each switchable.
- **Up next** pictures load ahead of time, so the covers are there when the list opens.

### Mini player and menu bar

- **A mini player** in five forms: a compact bar, a thin strip, a card, a card with lyrics, and a menu bar popover. Drag it by its body. Opening it puts the main window away and bringing the main window back puts the mini player away, as in other music apps.
- It can stay above other windows, follow you to every desktop, and remember its place. Its background is solid, a gradient from the cover or a blur, and its opacity is yours to set.
- **A menu bar player** shows the logo, the logo and title, or the title. The popover opens on a click or on hover and closes by itself after a time you choose.

### Remembers where you were

- Aureon reopens with the queue, the song and its place in it, the page you were on and how far you had scrolled, the window's size and position on each display, the output device, your theme and layout, and the mini player.
- Choose what happens to playback: **Paused** (the default), **Playing**, **Ask me**, or **Start fresh**. The volume is never restored; it belongs to the device.

### Queue

- The queue panel has three tabs: **Queue**, **History** (what you have played since Aureon opened; click a song to play it again) and **Output** (the device, its rate and every step from the file to the speaker).

## Fixes

- The output list on Now Playing no longer closes the moment it opens.
- Lyrics controls no longer overlap the format tags or the buttons beside the title, in any layout.
- Every Now Playing layout keeps its bottom controls at small window sizes.
- Shuffle and repeat show clearly when they are on.
- A fresh install opens in Graphite, dark.
- Settings made in earlier builds carry over to the new colours.

## Known issues

- **Windows is not included.** The Windows version follows separately, built from the same design.
- **Casting and multi-room streams can crash under heavy load.** The live FLAC encoder has an intermittent index error. Not fixed yet.
- **The app is ad-hoc signed and not notarised.** The first launch needs right-click → **Open**, and macOS may ask again for music-folder access after an update.
- **The Intel build has not been tested on real Intel hardware.** It has been run natively on Apple Silicon and under Rosetta only.
- **On Intel Macs the on-device language model and the audio enhancer are unavailable**; features that use them take an API key instead.
- **The mini player and the menu bar player use the app's colours.** They do not have a theme of their own yet.
- **History starts empty each time Aureon opens.**

The README lists what has not been verified on real hardware.

## Roadmap

- A theme of its own for the mini player.
- More Now Playing layouts: Vinyl, Hi-Fi, Orbit, Timeline and Poster.
- A Windows version.
- A signed and notarised app.

## Install

Open the disk image and drag **Aureon** to **Applications**, or run the matching `.pkg`. On first launch, right-click the app and choose **Open**. Requires macOS 15 or later.

## Downloads and checksums

**Apple Silicon Macs:** `Aureon-0.4.0.dmg` or `.pkg`. **Intel Macs:** `Aureon-0.4.0-universal.dmg` or `.pkg` (also runs on Apple Silicon).

```
__CHECKSUMS__
```

Earlier changes are in [RELEASE-NOTES-0.3.0.md](RELEASE-NOTES-0.3.0.md) and [RELEASE-NOTES-0.2.0.md](RELEASE-NOTES-0.2.0.md).
