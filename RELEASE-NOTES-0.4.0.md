<div align="center">

<img src="https://github.com/retrohog/Aureon/raw/main/assets/banner.svg" alt="Aureon" width="100%" />

# Aureon 0.4.0

**A new design: thirteen colours in dark and light, a true-black AMOLED, six Now Playing layouts, a mini player and menu bar player, and an app that remembers where you were.**

<img src="https://github.com/retrohog/Aureon/raw/main/Docs/images/pulse/now-playing-stage.png" alt="Now Playing in Aureon 0.4.0" width="100%" />

</div>

Aureon still plays bit-perfect from file to DAC by default. Everything that changes the samples is opt-in, and the signal path
always shows which state you are in.

> [!NOTE]
> **Platforms:** Apple Silicon and Intel Macs on macOS 15 or later. The Windows version follows separately.

## What's new

### A new design

- **A new shell.** A search bar, the output chip, the mini player button and Settings across the top, a rail of six places (Library, Playlists, Radio, Podcasts, Rooms, Sound), rounded panels, and a player bar with the cover, title, tags, transport and volume. **Podcasts** has its own place under Radio.
- **Thirteen colours, each in dark and light.** A true-black **AMOLED** (dark only) and twelve colours: Graphite, Midnight, Ocean, Forest, Mint, Plum, Violet, Rose, Ember, Cocoa, Dune and Slate. Choose **Dark**, **Light** or **Auto**, which follows macOS as it changes. A **Pure black** switch puts any dark side on a true black window.
- **One brightness slider** lightens or darkens the surfaces of every colour, dark and light; the text and the accent do not move and stay readable. AMOLED keeps its black window.
- **Accent colour.** Pick any colour; text in it is kept readable on every surface.
- **Pop-ups stay inside the window.** The output list, Add to playlist and the other pop-ups are placed by their button and kept wholly in view, scrolling when the window is small.
- **Starlight.** A slow field of fine stars behind the pages on dark themes, with intensity, motion, shooting stars and twinkle under your control. Flat, Soft and Album backdrops are still there.
- **Figtree.** The interface is set in Figtree, bundled with its licence (SIL Open Font License), in Regular by default. Light and Medium are a choice, and so is the text size.
- **Density.** Compact is the default and Comfortable gives lists and covers more room. It lives in Settings → Appearance.
- **Home follows the time of day.** A greeting for the hour, quick picks, and shelves such as Back in rotation, Hi-Res you haven't heard and a mood for the part of the day, all chosen on your Mac from what you play. **Why these?** explains each pick and **Refresh mix** draws a new one.
- **Folders** lists every library folder with its song count and status, and **Remove** takes one out of the library after asking. Your files are never touched.

### Now Playing

- **Six layouts**, chosen in Settings → Now Playing with a preview of each: **Stage**, **Classic**, **Full-bleed**, **Carousel**, **Lumen** and **Chillax**. Each is drawn for a large window and scales down to a small one.
- **The controls are always there.** Shuffle, previous, play or pause, next and repeat; the seek bar with both times; the queue, the mini player, the volume and the output chip stay in view in every layout, down to the smallest window. Lyrics and Up next give way first.
- **Lyrics** stay large and follow the sung line. Their size and timing are in Settings → Now Playing, so nothing floats over the words.
- **The controls stay in view.** The top bar and the controls no longer fade away; Settings → Now Playing has a switch to let them rest after a few seconds.
- **Seek bar choice.** Settings → Now Playing → Seek bar (the layout's own, a waveform or a line) now applies to the player bar, the mini player and every layout.
- **Add to playlist** from the song on screen: a card with a search, **New playlist**, and a tick beside each playlist that holds the song.
- **Credits** under the artist (written by, produced by, conductor, ensemble, instruments), the format tags and the signal path, each switchable.
- **Up next** pictures load ahead of time, so the covers are there when the list opens.

### Mini player and menu bar

- **A mini player** in five forms: a compact bar, a thin strip, a card, a card with lyrics, and a menu bar popover. Drag it from the cover, the names or any empty space; it stays wholly on a screen and remembers its place for each display. Opening it puts the main window away and bringing the main window back puts the mini player away, as in other music apps.
- It can stay above other windows, follow you to every desktop, and remember its place. Its background is solid, a gradient from the cover or a blur, and its opacity is yours to set.
- **A menu bar player** shows the logo, the logo and title, or the title. The popover opens on a click or on hover and closes by itself after a time you choose.

### Remembers where you were

- Aureon reopens with the queue, the song and its place in it, the page you were on and how far you had scrolled, the window's size and position on each display, the output device, your theme and layout, and the mini player.
- Choose what happens to playback: **Paused** (the default), **Playing**, **Ask me**, or **Start fresh**. The volume is never restored; it belongs to the device.

### Queue

- The queue panel has three tabs: **Queue**, **History** (what you have played since Aureon opened; click a song to play it again) and **Output** (the device, its rate and every step from the file to the speaker).

## Fixes

- The app no longer quits when you switch to the mini player.
- Settings no longer jump back to the top when you change something.
- The output list opens inside the window, on every page, and no longer closes the moment it opens on Now Playing.
- The seek bar choice in Settings is applied everywhere.
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
SHA256 (Aureon-0.4.0.dmg)            ff93ad8caa36fb69d64611504658d12c91f75e3c0071a7a0e326f0827452435e   23,761,700 bytes
SHA256 (Aureon-0.4.0.pkg)            be351efcd38fd52611fbb2e522398ec98fe20d51e165f8bb8d0234bc5515dbd9   20,424,443 bytes
SHA256 (Aureon-0.4.0-universal.dmg)  08dda272f11d2cd5080891d3e535cf45e10554683b0e246c617dc9b8c5bede6c   36,638,528 bytes
SHA256 (Aureon-0.4.0-universal.pkg)  413189f631ed93578fc57e061141e25e66a3b28fd0ebdf786345ff188778e522   31,814,334 bytes
```

Earlier changes are in [RELEASE-NOTES-0.3.0.md](RELEASE-NOTES-0.3.0.md) and [RELEASE-NOTES-0.2.0.md](RELEASE-NOTES-0.2.0.md).
