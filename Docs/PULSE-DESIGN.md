# The Pulse design

The look and behaviour of Aureon's window, written down so that every version (Apple Silicon and Intel Macs, and the native Windows app) builds the same
interface from the same numbers. On the Mac the values live in `Sources/Aureon/GUI` (`Theme.swift`, `DesignTokens.swift`, `Typography.swift`,
`Pulse/`). Anything marked *Mac only* needs something the other platforms do not have and is shown switched off there, with the reason.

## Shell

| Part | Size / behaviour |
|---|---|
| Top bar | 56 pt. Window buttons, the mark, Back and Forward, **Home**, an always-visible search pill (460 wide, 38 high, ⌘K / Ctrl+K), the output chip (device and rate; opens the quick controls), Settings. |
| Rail | 72 wide, five items: Library, Playlists, Radio, Rooms, Sound. A symbol over a 11 pt label; the selected item sits on a raised plate (radius 12). Home and Settings are not on the rail. |
| Main panel | Rounded (16), on the window colour; the pages of a destination are pill chips along its top (Library: Albums, Artists, Songs, Composers, Works, Conductors, Ensembles, Folders, Deep Dive). |
| Queue | A rounded panel (340 wide) beside the main panel with three tabs (a pill switch under the title): **Queue** (add, clear, drag to reorder, ⌫ removes), **History** (songs played since the app opened, newest first, 200 at most, a click plays one again, a trash button clears it) and **Output** (the device and its rate, then the steps Source → Player → Output from the signal path, and a link to the output settings). |
| Player bar | 96 pt, three columns: cover 68 (radius 10), title 16 medium with the heart and add-to-playlist beside it, artist 14, format tags; transport (shuffle, previous, a 46 pt accent play circle, next, repeat) with a 5 pt slider; lyrics, queue, output, volume (96 wide). |
| Now Playing | The whole window. The bar rests after 3.5 s without the pointer. Six layouts (below). |

Corners: panel 16, card 14, control 10, tag 6, pills fully round. Spacing on an 8 pt grid. Hairlines: the ink at 14 % (18 % on light themes).

## Colours

Five **families**, each with a **dark** half and a **light** half. A family is chosen once; the **mode** (Dark, Light or Auto) picks the half; a **Pure black**
switch puts any dark half on a black window. Every theme is five colours: window / panel / raised surface / ink / accent (hex).

| Family | Dark: window | panel | raised | ink | accent | Light: window | panel | raised | ink | accent |
|---|---|---|---|---|---|---|---|---|---|---|
| Graphite (default) | 0C0C0E | 161619 | 222227 | F6F3EC | F2B84B | C0BEB6 | CBC9C1 | B5B3AA | 201D18 | 6A4300 |
| Midnight | 080B14 | 0F1424 | 1A2036 | EEF2FF | 7FA6FF | B4BDCB | C2CAD6 | A6B0C0 | 121827 | 2F4F9E |
| Forest | 0A110D | 111B15 | 1B2A21 | EEF4EA | 9ED38A | B9C0B2 | C5CCBE | ABB3A3 | 181D16 | 2B5436 |
| Plum | 100A12 | 1A1220 | 28192F | F7EEF6 | F09AD0 | C4BBC9 | D0C8D5 | B6ACBC | 1E1424 | 7A2E6E |
| Cocoa | 120D0A | 1D1511 | 2B201A | F6EEE6 | F0A36B | CAC0AC | D4CBB8 | BDB39E | 1E1913 | 7E3418 |

Theme ids are the family name for the dark half (`graphite`), the name with `.light` for the light half (`graphite.light`) and the name with `.black` for the dark
half on pure black (`graphite.black`). The light halves are named in the interface only as "the light side of Graphite" and so on.

- **Mode.** *Dark* always shows the dark half, *Light* the light half, *Auto* follows the system's appearance and changes live when it changes (no restart). The
  order in Settings is Dark, Light, Auto. The command "Switch between light and dark" (⌘K) goes to the other half of the same family, with a soft circular reveal.
- **Pure black** (a switch, off by default, shown above the colour tiles; it affects only the dark half, in Dark and in Auto at night). The window is `000000`; the
  panel is the dark panel colour mixed 55 % towards black; the raised surface is the dark raised colour mixed 32 % towards black; ink and accent are unchanged, so the
  family's tint stays. Resulting panel / raised: Graphite 0A0A0B / 17171B, Midnight 070910 / 121625, Forest 080C09 / 121D16, Plum 0C080E / 1B1120, Cocoa 0D0908 / 1D1612.
- **Light brightness**: a slider from 0 to 1, 0.35 by default (the table). Above it the light surfaces are mixed towards white by `(b − 0.35) × 0.55`, below it
  towards black by `(0.35 − b) × 0.2`. It is shown whenever the mode is Light or Auto. The light halves are muted on purpose: no light panel is brighter than a soft grey.
- **Accent**: a free colour picker; each theme's own accent is used until one is chosen. Text in the accent is nudged until it reads at 4.5:1 on every surface
  (towards white on dark themes, towards black on light ones); the label on a solid accent is black or white, whichever reads better. The second end of an
  accent gradient is the same hue turned 4 % and 14 % darker.
- **Secondary and tertiary text** are the ink at the lowest opacity that still gives 7:1 and 4.5:1 on every surface.
- **Contrast is checked for every family in every mode**: dark, light at brightness 0, 0.35 and 1, and pure black, with the designed accent and with eight picked
  hues. Ink must reach 6.5:1 on every surface, tertiary text and accent text 4.5:1, a solid accent's label 4.5:1, a designed accent 3:1 on its surfaces.
- **Backdrop** per half of a family (the dark half and pure black share one): Flat, Soft (a quiet two-tone wash), Album (the cover, blurred) or Starlight. Dark
  halves open on Starlight, light halves on Soft. A cover-coloured veil on Full-bleed follows the theme's panel colour.
- **A fresh install** opens in Graphite, Dark, with the designed accent.
- **Settings page** (Settings → Appearance), top to bottom: Mode (Dark / Light / Auto), the Pure black switch, the colour tiles, Light brightness (when Light or Auto),
  Accent, Density, Font and Text size, Backdrop, Page transitions, Scroll to change volume, Launch. Each colour tile is split down the middle: the dark half on the
  left, the light half on the right, each a miniature of the shell (rail, panel, title, tag and player bar); the chosen family has an accent outline and a tick.
- **Carried over from earlier builds** (the nine-theme model, applied once when no new choice is saved): Graphite → Graphite, Dark; AMOLED → Graphite, Dark with
  Pure black; Midnight, Forest, Plum and Cocoa → the same family, Dark; Stone → Graphite, Light; Sage → Forest, Light; Paper → Cocoa, Light. If the old appearance was
  Auto the mode stays Auto and the family is that of the old dark choice.

## Type

Figtree (SIL Open Font License, bundled with its licence) in Regular by default; Light and Medium are a setting; nothing heavier than Medium, ever.
Titles are set one step heavier than running text. Technical readouts use a monospaced face with tabular figures. Where Figtree is not available the
platform's geometric sans stands in (Avenir Next on the Mac).

Sizes: 10 · 11 · 12 · 13 · 14.5 · 16 · 18 · 20 · 22 · 24 · 28 · 34 · 44 · 56. Page title 44 (tracking −0.5), shelf title 22, row title 14–16, body 13–14.5,
captions 11–13. Tags 24 high, 12 / 500. A text-size setting scales all of it between 85 % and 130 %.

## Controls

Pill buttons 36 high (small 28, mini 24); the primary one is the accent. Round icon buttons 36–44. The play button is an accent circle. Sliders: a 5 pt
rounded track, a 13 pt thumb that appears on hover. Toggles 44 × 26. Segmented choices are pills on a raised track, the chosen one filled with the ink.
Chips are pills 32 high.

## Density

**Compact** (the default) and **Comfortable**, set only in Settings → Appearance. Compact scales covers and grid cells to 82 %, rows to 44 pt (Comfortable
54 pt), and the rhythm of lists to 88 %.

## Home

A greeting for the part of the day (late 0–5, morning 5–11, afternoon 11–17, evening 17–22, night 22–24), a line saying why, the chips All / Focus /
Wind down / New to me / Hi-res, eight quick picks (4 × 2, 56 high) and shelves (Back in rotation, Hi-Res you haven't heard, New in your library,
Because you play…, and the mood of the hour). The mix is a pure function of the albums with their play counts and last-played times, the clock and a seed
that changes at every launch and on Refresh mix. Moods by part of the day:

late: Still up (electronic, piano, ambient) · Low light (ambient, piano) — morning: Morning light (folk, jazz, soul) · Slow start (piano, classical) —
afternoon: Focus (ambient, electronic, piano) · Steady work (electronic, folk) — evening: Warm room (jazz, soul, classical) · Dinner music (folk, jazz,
indie) — night: After dark (ambient, electronic) · Late piano (piano, classical).

A genre's weight is the mood's weight times how much the listener plays it (0.3 to 3); albums last played in the same part of the day count 1.35 times;
liked albums 1.15 times; every score is jittered by 0.6 to 1.6 from the seed. Nothing leaves the computer.

## Library

Header "Library" with `N albums · N songs · N folders`; an accent **Add folder**, the filter, sort and quality pills, a grid/list toggle. The Folders page
lists each library folder (status: watching, scanning, not connected; song count; Rescan, Remove) with an Add music panel. Removing a folder asks first and
leaves the files alone.

## Now Playing

Six layouts, chosen in Settings → Now Playing (a grid of previews, with lyrics on and off) and remembered. Each is drawn for a 1440 × 900 window and scaled by
`min(width / 1440, height / 900)` limited to 0.62 … 1.25; the window never has to be larger than 860 × 540 for anything to be reachable.

**The frame every layout shares.** Top to bottom: the top bar's space (56); the **body**, given exactly the room that is left and clipped to it; and the **dock**,
which is never inside the body and always has its natural height. The dock is: the seek bar with the played and remaining times above one row of controls — on
the left the song's heart / Add to playlist / More and the output chip (or the song itself), in the middle shuffle · previous · a 64 pt accent play circle · next ·
repeat, on the right the **cluster**: output chip, queue, mini player, volume. The cluster gives way in this order when the window is narrow: the output chip
leaves (it is then on the left), the volume slider shrinks to 60 %, then goes; the three buttons stay. The body sizes its covers from the room it has (never more
than the layout's design size) and what does not fit — lyrics, Up next, credits — shrinks or scrolls inside the body. The rule that must hold at every size and with
lyrics on or off: the dock is inside the window and uncovered, and nothing in the body touches the dock, the tag row or the heart / playlist / More buttons.

**Margins**: `max(28, 64 × scale)` left and right; the dock sits 14 × scale above the bottom edge. The bar of controls fades after 3.5 s without the pointer and
returns on movement; the controls stay clickable while visible.

- **Stage** (default): tabs **Lyrics / Up next / Credits / Signal path** across the top, 46 pt centred lyrics in the middle, the waveform seek bar, the song
  (cover 120, title 30) at the foot of the dock's left side. Lyrics off: credits at the left, a 420 cover with its names in the middle, up next at the right.
- **Classic**: a 500 cover on the left; title 54, credits, tags, the tabs and 38 pt lyrics on the right. Lyrics off: a 580 cover, title 60, tags, credits, up next.
- **Full-bleed**: the cover is the whole window under a veil in the panel colour (35 % at the top to 78 % at the bottom); title 58 (108 with lyrics off) low on
  the left, up next at the top right.
- **Carousel**: the cover among its neighbours (200 centre, 140 and 100 beside); the neighbours play on a click; the title and an "Add to" line below.
- **Lumen**: a 420 cover with a radius of 38 on the left, title and credits and the heart / playlist / More under it; the words in the middle; up next on the right
  (only when the body is wider than 980); a rounded dock (radius 32, the raised colour) holding the times, a slim seek bar, the transport and the cluster in one row.
  Credits under the artist are dropped when the body is shorter than 500.
- **Chillax**: a 540 cover; a 76 pt title with the heart / playlist / More beside it, the format tags, the signal path; the queue as a shelf of five cards under the
  cover (dropped when the body is shorter than 470); the dock has a slim seek bar, the output chip on the left and the cluster without it.

On every layout: heart, **Add to playlist** (a card with a search, New playlist, and a tick on each playlist that holds the song), **More** (Analyser, Booklet,
Show lyrics, the lyrics actions — look again, write by listening, save to tags, save as .lrc — and the layout), credits under the artist (written by, produced by,
engineered by, conductor, ensemble, then one line per instrument), the format tags, the signal path, the output chip, queue, mini player and volume. Popovers opened
from Now Playing (the output list, the Add to playlist card) stay open until dismissed; each output chip has its own anchor (the top bar's, the player bar's and Now
Playing's) so two chips never share one popover. Pictures of the next ten songs are read ahead on a background queue (three at a time); a cover that is not there yet
shows the placeholder and fades in.

**Lyrics** carry no controls of their own: no timing pill and no menu over the words. Size is Medium 0.85, Large 1 (default) or Huge 1.2; the timing offset (−2 to +2 s
in steps of 0.1, Reset) and the lookup choices are in Settings → Now Playing → Lyrics, and the actions are in More. Lyrics stay large and projected; the active line is
sharp and the others fade.

## Mini player and menu bar

Five layouts: Compact bar 520 × 96, Thin strip 520 × 48, Card 380 × 620, Card with lyrics 260 × 620, Menu bar popover 340 × 236. It is dragged by its body (the title strip is not needed). **Opening the mini player puts the main window away** (a setting, on by default; the window's size and place are remembered) and **closing the mini player — its expand button, a click on the Dock icon, the menu — brings the main window back exactly where it was**, so only one of the two is on screen, as in other music apps. A floating window stays above
others (an option), can follow to every desktop, remembers its place, and its opacity is a setting (40–100 %). Backgrounds: Solid, Gradient (from the cover's colour),
Blur and glow; a strength slider. Live preview only while that settings page is open. The menu bar item shows the logo, the logo and title, or the title; the popover
opens on click or on hover, closes on a click elsewhere, closes by itself after Never / 3 / 5 / 10 / 30 s (5 by default) and waits while the pointer is over it.
*Mac only*: the menu bar item; on Windows the same popover belongs to the notification area.

## Memory

Remembered between launches: the queue and the song with its place; the page, what is open on it and how far it is scrolled; the window's size and place **for each
display**; the output device; the theme and look; the Now Playing layout; the mini player and its place; the library's filters and sorting. Resume modes: Paused
(default, the song waits where it was left), Playing, Ask me (a card offers to continue), Start fresh. The volume is never restored: it belongs to the device.

## What differs on other platforms

- **Intel Macs**: the same code and the same screens. Features that need Apple Silicon (the on-device language model and audio enhancer) are shown switched off with the reason.
- **Windows**: a native application with the same tokens, layouts and behaviours; the web interface is not the design. Window glass and the menu bar item map to
  the platform's equivalents (acrylic, the notification area).

## Settings pages

Settings has a search field and nine pages: General, **Appearance** (colours, accent, density, type, backdrop, motion, volume scrolling, launch), **Now Playing**
(layout previews, lyrics: show, size, timing, lookup choices; what else shows: Add to playlist button, credits, signal path and tags, seek bar style), **Mini player**
(form, background, strength, opacity, always on top, every desktop, remember place, keep floating, hide the Aureon window; menu bar item and popover timing),
**Startup & memory** (resume mode and what is remembered), Pages (which pages are on the rail), Connect, MIDI and System.

## Not in this version

Designed but not built: a colour theme of its own for the mini player and the menu bar player (they follow the app's), and the Now Playing layouts Vinyl, Hi-Fi,
Orbit, Timeline and Poster. A native build should treat the six layouts above as the complete set.
