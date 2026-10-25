# The Pulse design

The look and behaviour of Aureon's window, written down so that every version (Apple Silicon and Intel Macs, and the native Windows app) builds the same
interface from the same numbers. On the Mac the values live in `Sources/Aureon/GUI` (`Theme.swift`, `DesignTokens.swift`, `Typography.swift`,
`Pulse/`). Anything marked *Mac only* needs something the other platforms do not have and is shown switched off there, with the reason.

## Shell

| Part | Size / behaviour |
|---|---|
| Top bar | 56 pt. Window buttons, the mark, Back and Forward, **Home**, an always-visible search pill (460 wide, 38 high, ⌘K / Ctrl+K), the output chip (device and rate; opens the quick controls), the **Mini player** button (⌥⌘M) and Settings. On Now Playing it stays in view unless the listener turns on "Hide the controls when the pointer rests" (then it fades after 3.5 s without the pointer and returns on movement). |
| Rail | 72 wide, six items: Library, Playlists, Radio, **Podcasts** (a microphone), Rooms, Sound. A symbol over a 11 pt label (items 60 × 58, 6 pt apart); the selected item sits on a raised plate (radius 12). Radio shows stations only; Podcasts is its own page. Home and Settings are not on the rail. |
| Main panel | Rounded (16), on the window colour; the pages of a destination are pill chips along its top (Library: Albums, Artists, Songs, Composers, Works, Conductors, Ensembles, Folders, Deep Dive). |
| Queue | A rounded panel (340 wide) beside the main panel with three tabs (a pill switch under the title): **Queue** (add, clear, drag to reorder, ⌫ removes), **History** (songs played since the app opened, newest first, 200 at most, a click plays one again, a trash button clears it) and **Output** (the device and its rate, then the steps Source → Player → Output from the signal path, and a link to the output settings). |
| Player bar | 96 pt, three columns: cover 68 (radius 10), title 16 medium with the heart and add-to-playlist beside it, artist 14, format tags; transport (shuffle, previous, a 46 pt accent play circle, next, repeat) with a 5 pt slider; lyrics, queue, output, volume (96 wide). |
| Now Playing | The whole window. The top bar and the controls stay in view (a setting lets them rest after 3.5 s without the pointer). Seven layouts (below). |

Corners: panel 16, card 14, control 10, tag 6, pills fully round. Spacing on an 8 pt grid. Hairlines: the ink at 14 % (18 % on light themes).

## Colours

Thirteen **families**: a true-black **AMOLED** (dark only) and twelve colours, each with a **dark** half and a **light** half. A family is chosen once; the **mode**
(Dark, Light or Auto) picks the half; a **Pure black** switch puts any dark half on a black window; one **Brightness** slider lightens or darkens the surfaces. The
colours are one table (`ThemeTable.swift`); there is no code per theme. Each half is ten colours (hex).

**Dark halves**

| Family | window | panel | raised | step 3 | line | text | secondary | tertiary | accent | on accent |
|---|---|---|---|---|---|---|---|---|---|---|
| AMOLED | 000000 | 0A0A0C | 121215 | 1A1A1E | 26262B | F5F5F7 | ADB1B8 | 898C92 | 96C9FE | 06070A |
| Graphite | 0D1014 | 161A1F | 1E2227 | 282C31 | 34383E | EDEEF1 | AFB1B5 | 84868B | 89C3FE | 141619 |
| Midnight | 070F20 | 10192D | 172137 | 202B42 | 2C3850 | EAEFF8 | AAB1C0 | 7E8697 | 91C1FF | 0F1720 |
| Ocean | 001319 | 011E24 | 06262D | 103038 | 1D3D45 | E6F1F3 | A4B5B9 | 768A8F | 28D6DF | 0A191A |
| Forest | 061308 | 0E1E11 | 152619 | 1E3022 | 2B3D2E | EAF1EB | AAB4AB | 7E8A80 | 7BD77F | 111811 |
| Mint | 01140E | 071E18 | 0E2720 | 183129 | 243E36 | E8F1EE | A7B5B0 | 7A8A85 | 51DAA7 | 0E1914 |
| Plum | 180A16 | 231322 | 2C1B2B | 372435 | 443042 | F3ECF2 | B9ADB7 | 8F818D | F897E4 | 1C131A |
| Violet | 110B20 | 1B152C | 231C36 | 2D2642 | 3A334F | EFEDF8 | B2AEC0 | 878397 | BCB2FF | 161421 |
| Rose | 1B090D | 281217 | 31191F | 3C2329 | 4A2F35 | F6EBED | BDACAF | 948084 | FE9EAD | 1E1214 |
| Ember | 1D0903 | 29120A | 331A11 | 3E231A | 4C3026 | F7ECE8 | BFADA7 | 95817A | FFA47A | 1F130D |
| Cocoa | 180C05 | 23160D | 2D1E14 | 37271D | 443429 | F4EDE9 | B9AFA8 | 8F847C | F3AD66 | 1B150F |
| Dune | 150E03 | 1F180A | 282111 | 322A1A | 3F3726 | F1EEE8 | B5B1A7 | 8B867A | DCBA5C | 19160E |
| Slate | 091016 | 121B21 | 19232A | 222D34 | 2F3A41 | EBEFF2 | ACB2B7 | 80878D | 7AC8F5 | 12171A |

**Light halves** (AMOLED has none: in Light mode it shows Graphite's light half)

| Family | window | panel | raised | step 3 | line | text | secondary | tertiary | accent | on accent |
|---|---|---|---|---|---|---|---|---|---|---|
| Graphite | F4F7FB | EEF0F4 | E5E8EC | DCDEE2 | CBCED2 | 181B1F | 4A4D53 | 60636A | 0065B0 | F4F9FE |
| Midnight | F3F7FE | E9F0FF | E1E8F8 | D7DEEE | C7CEDD | 121A2B | 424D64 | 58637B | 0061BE | F5F9FE |
| Ocean | EAFAFE | E2F4F9 | DAECF0 | D0E2E6 | C0D1D6 | 061E24 | 365259 | 4C6970 | 007176 | F1FBFB |
| Forest | EFFAF1 | E8F4EA | E0EBE2 | D6E1D8 | C6D1C8 | 111E14 | 415244 | 57695A | 01791E | F4FAF4 |
| Mint | ECFBF5 | E5F4EF | DDECE6 | D3E2DD | C3D2CC | 0C1F19 | 3C534B | 516961 | 007654 | F3FBF7 |
| Plum | FFF2FD | F8ECF7 | F0E3EE | E6D9E4 | D6C9D4 | 231522 | 594657 | 6F5C6D | 983488 | FDF6FB |
| Violet | F7F5FF | F1EDFE | E9E5F7 | DFDBED | CECBDD | 1C172B | 4F4863 | 655E7B | 6649BE | F8F7FF |
| Rose | FFF4F6 | FDEBEE | F5E3E6 | EBD9DC | DAC9CC | 271419 | 5F454A | 765B60 | AF234C | FFF6F7 |
| Ember | FFF4F1 | FEECE5 | F6E3DD | ECD9D3 | DCC9C3 | 29150D | 61463C | 785C52 | A24100 | FFF6F3 |
| Cocoa | FEF5EF | F9EEE7 | F0E5DF | E6DCD5 | D6CBC5 | 231810 | 59493F | 705F55 | 8E5300 | FDF7F2 |
| Dune | FBF6EC | F5F0E5 | ECE7DD | E3DDD3 | D2CDC3 | 201A0D | 544C3C | 6A6252 | 7A6001 | FBF8F1 |
| Slate | F1F8FD | EAF1F6 | E2E9EE | D8DFE4 | C8CFD4 | 141C21 | 444F56 | 5A656D | 006C97 | F2FAFE |

Graphite is the default and opens in Dark with its own blue accent; each family's accent is its own until an accent is chosen. The picker lists AMOLED first, then the
others in the order of the tables.

Theme ids are the family name for the dark half (`graphite`), the name with `.light` for the light half (`graphite.light`) and the name with `.black` for the dark
half on pure black (`graphite.black`; AMOLED is already black and has no such id).

- **Mode.** *Dark* always shows the dark half, *Light* the light half, *Auto* follows the system's appearance and changes live when it changes (no restart). The
  order in Settings is Dark, Light, Auto. The command "Switch between light and dark" (⌘K) goes to the other half of the same family, with a soft circular reveal.
- **Pure black** (a switch, off by default, shown above the colour tiles; it affects only the dark half, in Dark and in Auto at night; AMOLED is unaffected). The
  window is `000000`; the panel is the dark panel colour mixed 55 % towards black, the raised surface 32 %, step 3 25 % and the line 20 %; the text and the accent are
  unchanged, so the family's tint stays.
- **Brightness** (one slider, −1 … +1, 0 is the design; it applies to every colour, dark and light). The window, panel, raised surface, step 3 and line all move by the
  same amount of perceived lightness: `slider × 0.04` in OKLab L (the perceptual lightness of OKLCH), keeping each colour's hue and chroma. The window's lightness is
  held to 0.10 … 0.26 in dark halves and 0.90 … 0.995 in light halves, and the step is halved until the text still reads at 7:1 on every surface. The text and the
  accent never move. On a true-black window (AMOLED, or any dark half on pure black) the window stays #000000 and only the surfaces above it move: up by `slider × 0.03`
  (down by `slider × 0.012`).
- **Accent**: a free colour picker; each theme's own accent is used until one is chosen. Text in the accent is nudged until it reads at 4.5:1 on every surface
  (towards white on dark themes, towards black on light ones); the label on a solid accent is black or white, whichever reads better. The second end of an
  accent gradient is the same hue turned 4 % and 14 % darker.
- **Secondary and tertiary text** are the ink at the lowest opacity that still gives 7:1 and 4.5:1 on every surface.
- **Contrast is checked for every family in every mode and at the ends of the brightness slider** (and with eight picked accent hues, and on pure black). The table
  itself must give: text 7:1 on the window and the surfaces, secondary text 4.5:1, tertiary text 3:1, the accent 3:1, the label on a solid accent 4.5:1; and the
  derived text colours must reach 7:1 / 4.5:1 on every surface after any adjustment.
- **Backdrop** per half of a family (the dark half and pure black share one): Flat, Soft (a quiet two-tone wash), Album (the cover, blurred) or Starlight. Dark
  halves open on Starlight, light halves on Soft. A cover-coloured veil on Full-bleed follows the theme's panel colour.
- **A fresh install** opens in Graphite, Dark, with the designed accent.
- **Settings page** (Settings → Appearance), top to bottom: Mode (Dark / Light / Auto), the Pure black switch, the colour tiles, Brightness, Accent, Density, Font and
  Text size, Backdrop, Page transitions, Scroll to change volume, Launch. Each colour tile is split down the middle (dark half on the left, light half on the right,
  each a miniature of the shell: rail, panel, title, tag and player bar, drawn from the real colours and the current brightness); the chosen family has an accent
  outline and a tick; AMOLED fills its tile and says "dark only".
- **Carried over from earlier builds** (applied once when no new choice is saved): Graphite, Midnight, Forest, Plum and Cocoa keep their name; AMOLED is AMOLED; Stone →
  Graphite, Light; Sage → Forest, Light; Paper → Cocoa, Light. If the old appearance was Auto the mode stays Auto and the family is that of the old dark choice. A saved
  light-only brightness (0 … 1, 0.35 the old design) becomes the new slider position `(old − 0.35) × 2`.

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

Seven layouts, chosen in Settings → Now Playing (a grid of previews, with lyrics on and off) and remembered. Each is drawn for a 1440 × 900 window and scaled by
`min(width / 1440, height / 900)` limited to 0.62 … 1.25; the window never has to be larger than 860 × 540 for anything to be reachable.

**The frame every layout shares.** Top to bottom: the top bar's space (56); the **body**, given exactly the room that is left and clipped to it; and the **dock**,
which is never inside the body and always has its natural height. The dock is: the seek bar with the played and remaining times above one row of controls — on
the left the song's heart / Add to playlist / More and the output chip (or the song itself), in the middle shuffle · previous · a 64 pt accent play circle · next ·
repeat, on the right the **cluster**: output chip, queue, mini player, volume. The cluster gives way in this order when the window is narrow: the output chip
leaves (it is then on the left), the volume slider shrinks to 60 %, then goes; the three buttons stay. The body sizes its covers from the room it has (never more
than the layout's design size) and what does not fit — lyrics, Up next, credits — shrinks or scrolls inside the body. The rule that must hold at every size and with
lyrics on or off: the dock is inside the window and uncovered, and nothing in the body touches the dock, the tag row or the heart / playlist / More buttons.

**Margins**: `max(28, 64 × scale)` left and right; the dock sits 14 × scale above the bottom edge. The controls stay in view; with "Hide the controls when the pointer rests" on, they and the top
bar fade after 3.5 s without the pointer and return on movement.

- **Stage**: tabs **Lyrics / Up next / Credits / Signal path** across the top, 46 pt centred lyrics in the middle, the waveform seek bar, the song
  (cover 120, title 30) at the foot of the dock's left side. Lyrics off: credits at the left, a 420 cover with its names in the middle, up next at the right.
- **Classic**: a 500 cover on the left; title 54, credits, tags, the tabs and 38 pt lyrics on the right. Lyrics off: a 580 cover, title 60, tags, credits, up next.
- **Full-bleed**: the cover is the whole window under a veil in the panel colour (35 % at the top to 78 % at the bottom); title 58 (108 with lyrics off) low on
  the left, up next at the top right.
- **Carousel**: the cover among its neighbours (200 centre, 140 and 100 beside); the neighbours play on a click; the title and an "Add to" line below.
- **Lumen**: a 420 cover with a radius of 38 on the left, title and credits and the heart / playlist / More under it; the words in the middle; up next on the right
  (only when the body is wider than 980); a rounded dock (radius 32, the raised colour) holding the times, a slim seek bar, the transport and the cluster in one row.
  Credits under the artist are dropped when the body is shorter than 500.
- **Chillax** (default): a 540 cover; a 76 pt title with the heart / playlist / More beside it, the format tags, the signal path; the queue as a shelf of five cards under the
  cover (dropped when the body is shorter than 470); the dock has a slim seek bar, the output chip on the left and the cluster without it.
- **Orbit**: the cover in a circle at the centre of the body, ringed by 96 bars that follow the spectrum. The ring is also the seek bar: a bright arc
  shows the played part, and a press or a drag on the ring seeks. The bars and the arc rest when playback pauses, when the window is hidden, with
  Reduce Motion on, or with the visualiser off.

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

Four layouts: Compact bar 520 × 96, Thin strip 520 × 48, Card 380 × 620, Menu bar popover 340 × 236. It is dragged by its body (the title strip is not needed). **Opening the mini player puts the main window away** (a setting, on by default; the window's size and place are remembered) and **closing the mini player — its expand button, a click on the Dock icon, the menu — brings the main window back exactly where it was**, so only one of the two is on screen, as in other music apps. A floating window stays above
others (an option), can follow to every desktop, remembers its place, and its opacity is a setting (40–100 %). Backgrounds: Solid, Gradient (from the cover's colour),
Blur and glow; a strength slider. Live preview only while that settings page is open. The menu bar item shows the logo, the logo and title, or the title; the popover
opens on click or on hover, closes on a click elsewhere, closes by itself after Never / 3 / 5 / 10 / 30 s (5 by default) and waits while the pointer is over it.
*Mac only*: the menu bar item; on Windows the same popover belongs to the notification area. The app must keep running while the mini player is the only thing on screen (the main window is put away, not closed). Position: remembered for each display, by the display's identity; the window is kept wholly on the screen it is mostly on (after a drag and at the next open). A drag starts on the cover, the names or any empty space; buttons, the seek bar and the volume have their own gestures and never move the window.

## Memory

Remembered between launches: the queue and the song with its place; the page, what is open on it and how far it is scrolled; the window's size and place **for each
display**; the output device; the theme and look; the Now Playing layout; the mini player and its place; the library's filters and sorting. Resume modes: Paused
(default, the song waits where it was left), Playing, Ask me (a card offers to continue), Start fresh. The volume is never restored: it belongs to the device.

## What differs on other platforms

- **Intel Macs**: the same code and the same screens. Features that need Apple Silicon (the on-device language model and audio enhancer) are shown switched off with the reason.
- **Windows**: a native application with the same tokens, layouts and behaviours; the web interface is not the design. Window glass and the menu bar item map to
  the platform's equivalents (acrylic, the notification area).

## Pop-ups

Every pop-up (the output list from the top bar, the player bar and Now Playing; Add to playlist; shuffle; quality details; folder actions; speaker set-up; DSP
plug-ins; the DJ layout; Home's "Why these?") is a card drawn inside the window, never a separate window that could hang over the desktop. It opens on the preferred
side of its button (above for the player bar, below for the top bar), flips to the other side when there is no room, is moved so that all of it is inside the window
(8 pt margin), and scrolls inside the window when it is taller than the window. One is open at a time; a click anywhere else, or Escape, closes it. Card: the panel
colour, a hairline, radius 14, a soft shadow.

## Seek bar

One choice in Settings → Now Playing → Seek bar applies to every seek bar (player bar, mini player, every Now Playing layout): *Layout's own* (each place keeps its
style), *Waveform* (a waveform replaces the thin track where there is one; places that already draw a waveform keep theirs) or *Line* (the thin 5 pt track with a 13 pt
thumb everywhere). It changes at once. Pressing or dragging on the bar seeks; the scroll wheel nudges.

## Settings pages

Settings has a search field and nine pages: General, **Appearance** (mode, pure black, the colours, brightness, accent, density, type, backdrop, motion, volume scrolling, launch), **Now Playing**
(layout previews, lyrics: show, size, timing, lookup choices; what else shows: Add to playlist button, credits, signal path and tags, whether the controls rest, seek bar style), **Mini player**
(form, background, strength, opacity, always on top, every desktop, remember place, keep floating, hide the Aureon window; menu bar item and popover timing),
**Startup & memory** (resume mode and what is remembered), Pages (which pages are on the rail), Connect, MIDI and System.

## Not in this version

Designed but not built: a colour theme of its own for the mini player and the menu bar player (they follow the app's), and the Now Playing layouts Vinyl, Hi-Fi,
Timeline and Poster. A native build should treat the seven layouts above as the complete set.
