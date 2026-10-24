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
| Queue | A rounded panel (340 wide) beside the main panel. |
| Player bar | 96 pt, three columns: cover 68 (radius 10), title 16 medium with the heart and add-to-playlist beside it, artist 14, format tags; transport (shuffle, previous, a 46 pt accent play circle, next, repeat) with a 5 pt slider; lyrics, queue, output, volume (96 wide). |
| Now Playing | The whole window. The bar rests after 3.5 s without the pointer. Six layouts (below). |

Corners: panel 16, card 14, control 10, tag 6, pills fully round. Spacing on an 8 pt grid. Hairlines: the ink at 14 % (18 % on light themes).

## Themes

Nine, each as window / panel / raised surface / ink / accent (hex):

| Theme | Window | Panel | Raised | Ink | Accent |
|---|---|---|---|---|---|
| Graphite (default) | 0C0C0E | 161619 | 222227 | F6F3EC | F2B84B |
| AMOLED | 000000 | 0A0A0A | 171717 | F4F1EA | F2B84B |
| Midnight | 080B14 | 0F1424 | 1A2036 | EEF2FF | 7FA6FF |
| Forest | 0A110D | 111B15 | 1B2A21 | EEF4EA | 9ED38A |
| Plum | 100A12 | 1A1220 | 28192F | F7EEF6 | F09AD0 |
| Cocoa | 120D0A | 1D1511 | 2B201A | F6EEE6 | F0A36B |
| Stone (light) | C0BEB6 | CBC9C1 | B5B3AA | 201D18 | 6A4300 |
| Sage (light) | B9C0B2 | C5CCBE | ABB3A3 | 181D16 | 2B5436 |
| Paper (light) | CAC0AC | D4CBB8 | BDB39E | 1E1913 | 7E3418 |

- **Light brightness**: a slider from 0 to 1, 0.35 by default (the table). Above it the surfaces are mixed towards white by `(b − 0.35) × 0.55`, below it towards
  black by `(0.35 − b) × 0.2`.
- **Accent**: a free colour picker; each theme's own accent is used until one is chosen. Text in the accent is nudged until it reads at 4.5:1 on every
  surface (towards white on dark themes, towards black on light ones); the label on a solid accent is black or white, whichever reads better. The
  second end of an accent gradient is the same hue turned 4 % and 14 % darker.
- **Secondary and tertiary text** are the ink at the lowest opacity that still gives 7:1 and 4.5:1 on every surface.
- Dark and light: with Auto the dark choice is used at night and the light choice by day, following the system. Picking a theme sets the choice for its kind.
- **Backdrop** per theme: Flat, Soft (a quiet two-tone wash), Album (the cover, blurred) or Starlight. Night themes open on Starlight, day themes on Soft.

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

Six layouts, chosen in Settings → Now Playing and remembered; each is drawn for 1440 × 900 and scaled (0.62 to 1.25) to the window. Lyrics on or off changes
what the middle shows; the lyrics stay large and projected.

- **Stage** (default): Lyrics / Up next / Credits / Signal path tabs, 46 pt centred lyrics, waveform, the song (cover 120, title 30) at the foot. Lyrics off:
  credits, a 420 cover with its names, up next.
- **Classic**: a 500 cover on the left; title 54, tabs, 38 pt lyrics on the right. Lyrics off: a 580 cover, title 60, tags, credits, up next.
- **Full-bleed**: the cover is the whole screen under a veil; title 58 (108 with the lyrics off).
- **Carousel**: the cover among its neighbours (200 centre, 140 and 100 beside); the neighbours play on a click.
- **Lumen**: a 420 cover with a radius of 38, the words in the middle, up next on the right, a rounded dock (radius 32) with seek, transport and volume.
- **Chillax**: a 540 cover, a 76 pt title with the heart / playlist / more beside it, the queue as a shelf of five cards. (Set in Figtree.)

On every layout: heart, **Add to playlist** (a card with a search, New playlist, and a tick on each playlist that holds the song), More (analyser, booklet,
lyrics switch, layout), credits under the artist (written by, produced by, engineered by, conductor, ensemble, then one line per instrument), the format tags, the
signal path, the output chip, queue, mini player, volume. Lyrics size: Medium 0.85, Large 1 (default), Huge 1.2.

## Mini player and menu bar

Five layouts: Compact bar 520 × 96, Thin strip 520 × 48, Card 380 × 620, Card with lyrics 260 × 620, Menu bar popover 340 × 236. A floating window stays above
others (an option), can follow to every desktop, remembers its place, and its opacity is a setting (40–100 %). Backgrounds: Solid, Gradient (from the cover's colour),
Blur and glow; a strength slider. Live preview only while that settings page is open. The menu bar item shows the logo, the logo and title, or the title; the popover
opens on click or on hover, closes on a click elsewhere, closes by itself after Never / 3 / 5 / 10 / 30 s (5 by default) and waits while the pointer is over it.
*Mac only*: the menu bar item; on Windows the same popover belongs to the notification area.

## Memory

Remembered between launches: the queue and the song with its place; the page, what is open on it and how far it is scrolled; the window's size and place **for each
display**; the output device; the theme and look; the Now Playing layout; the mini player and its place; the library's filters and sorting. Resume modes: Paused
(default, the song waits where it was left), Playing, Ask me (a card offers to continue), Start fresh. The volume is never restored: it belongs to the device.

## What differs on other platforms

- **Intel Macs**: the same code and the same screens. Features that need Apple Silicon (the on-device smart features) are shown switched off with the reason.
- **Windows**: a native application with the same tokens, layouts and behaviours; the web interface is not the design. Window glass and the menu bar item map to
  the platform's equivalents (acrylic, the notification area).
