# DJ Pro console: handoff for other platforms

The Pro console is the full-window DJ layout (toolbar, one shared waveform stage, deck | mixer | deck, three effect units, library). It has the same code and behaviour on Apple Silicon and Intel Macs. This note lists what a port has to match.

## Layout rules (all in `DJProMetrics`, `Sources/Aureon/GUI/DJProModel.swift`)
- Minimum window 1180 × 760 pt. Below it the Compact layout is offered. Enforced on the window itself (`NSWindow.contentMinSize`, `WindowMinimum`).
- Controls have fixed sizes. Only the waveform stage, the library and the spacing flex. The disc grows between 136 and 196 pt, never moving anything around it.
- Column widths: mixer 21.5 % of the window clamped to 256…330 pt; the decks share the rest. `columns(window:)` and `jog(deckWidth:)` are covered by the `djpro.layout` test at every width from 1180 to 3840.
- Below the stage the page scrolls vertically; the toolbar and the stage stay put.

## Engine (platform-neutral logic worth porting as written)
| Feature | Where | Notes |
|---|---|---|
| Key lock, key shift | `Pipeline/Varispeed.swift`, `Pipeline/TimeStretch.swift` | Resample for pitch, then WSOLA (2048-frame Hann grains, ±20 % search, correlation on every 4th sample) restores tempo. Runs on the decode thread, never in the output callback. Exact pass-through when nothing is set. |
| Reverse, scratch | `VarispeedControl`, `VarispeedSource` | Signed speed. Reverse reads the window backwards a chunk at a time. Scratch is a signed speed set from the disc's angular velocity (1 turn per 1.8 s = speed 1). A held disc outputs silence. Loops wrap backwards too. |
| Slip | `DJDeck.slipBegin/slipEnd` | Remembers where the track would be; used by loops, reverse, scratch, slicer. |
| Sampler | `DJSampler` in `DJ/DJMixerCore.swift` | Eight one-shot slots. Samples are allocated off the audio thread and published through an RCU box; a trigger is a counter the audio thread compares. Nothing is allocated, locked or messaged in the callback. |
| Live inputs | `LineFeed`, `CoreAudioLineInput` | Microphone and auxiliary channels run through the same strip as a deck. Input ring → drift-controlled resampler → strip. An empty ring is silent. macOS needs `NSMicrophoneUsageDescription`. |
| Booth | `DJMixerCore.booth` | The post-limiter master at its own level into a ring read by a second device. |
| Effect units | `DJFXUnit`, `DJModel.applyFX` | Three shared units; a channel is sent through at most one. |
| Master / sync | `DJProActions.swift` | Sync follows the master deck's tempo every tick; turning it on also lines up the beats once. |
| Waveform | `DJWaveDetail` | 100 bins a second: peak of the band under ~250 Hz, and of everything above ~700 Hz. Built off the main thread when a track loads. |

## Interface
- Drawing: waveforms, discs and meters are `Canvas` inside `TimelineView(.animation)`; the disc art is rendered once and only rotated. Meters are capped at 60 fps. Nothing heavy runs on the main thread (analysis, waveform detail, library sorting are detached tasks).
- Every custom control forwards the scroll wheel (knobs, faders, crossfader, disc, pads where it applies).
- Pad modes: CUES (shift-click deletes), LOOP, ROLL (hold), FX (hold), SLICER (eight one-beat slices of a 32-beat phrase, four banks), SAMPLER (click an empty pad to capture four beats; right-click for more). Banks are only offered where a mode has more than eight pads.
- Library: sources (all, recently added, history, playlists), sortable columns, tempo ±6 % and key-match filters, harmonic highlight against the deck on air, side panel with cue points and suggestions. Sorting and filtering run in a detached task.
- Compact layout is the earlier console and keeps the hide/reorder customisation (`DJLayout`).

## Tests
`Aureon selftest djpro` (13 tests): stretcher keeps pitch, key lock and key shift in the source, reverse and scratch, sampler, live channels (including a 32 kHz input), booth, waveform detail, modes and grid store, effect units, master and sync, presets and window rules, layout at every width, disc and scratch maths.

## Not covered by automated tests
Scratch feel (the output buffer of the engine adds latency to a scratch), the microphone permission prompt, a real second device for booth or headphones, and the look on a Retina external display.
