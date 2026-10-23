# Architecture

## The dual path

```
                producer thread (non-real-time)                              real-time thread
 ┌──────┐  ┌────────┐  ┌─────┐  ┌──────────┐  ┌────────┐  ┌─────┐  ┌──────┐  ┌──────────────────────────┐
 │ file │→ │ decode │→ │ RAM │→ │ resample │→ │ gain / │→ │ DoP │→ │ ring │→ │ Renderer                 │→ DAC
 │      │  │        │  │cache│  │ (opt-in) │  │ polar. │  │stamp│  │      │  │  DSP off: ring.read      │
 └──────┘  └────────┘  └─────┘  └──────────┘  └────────┘  └─────┘  └──────┘  │  DSP on : AVAudioEngine  │
                                                                              │   manualRenderingBlock   │
                                                                              └──────────────────────────┘
```

* **Ingestion** (`Pipeline/`) is a chain of `FrameSource` stages. Each pulls from the one before and yields interleaved
  Int32 frames (24-bit audio is left-justified, so 16/24-bit sources are exact). Every stage that alters sample values sets
  `StreamInfo.transparent = false`; the UI derives "bit-perfect" from that flag plus whether the device accepted the
  native rate.
* **Ring buffer** (`Core/Ring.swift`) is a lock-free SPSC ring. Besides read/write it supports two producer requests that the
  *consumer* executes, so the two threads never race: `flush` (drop everything) and `truncate(to:)` (drop only the tail).
* **Renderer** (`Engine/Sink.swift`) is the only code the audio callback runs. With DSP off it is a single `ring.read`.
  With DSP on it calls the engine's manual-rendering block, whose source node reads the same ring.
* **Sinks** abstract the output: `CoreAudioSink` (HAL IOProc, device clock, hog mode, physical formats) and
  `RecordingSink` (consumes the ring like a DAC and keeps every sample).

## Real-time rules

In code that runs on the audio thread (`Renderer.render`, `CoreAudioSink` IOProc block, `DSPChain.render`, the source node block,
`RingBuffer.read`): no locks, no heap allocation, no I/O, no logging. State flows in through atomics (`paused`,
`flushRequested`, `useDSP`, truncate target/limit). Buffers are preallocated; the DSP render target is an `AudioBufferList` we
own, avoiding Objective-C messaging in the callback. Caveats: Swift ARC traffic and Apple's own render block are outside
our control.

Structural changes that would race the audio thread (rebuilding the AVAudioEngine graph, swapping plugins) are done on the
engine thread *after* switching the renderer to the direct path and waiting one callback period.

## Threads

| Thread | Does |
|---|---|
| main / UI | SwiftUI, user actions; mutates `Player` through thread-safe setters (queue, settings, plugins, commands) |
| engine (`aureon.engine`) | decoding, chaining, seeking, queue/settings reconciliation, status |
| background utility | RAM prefetch, ReplayGain measurement |
| device IOProc | `Renderer.render` only |

## Groups, gapless and format changes

A *group* is a run of tracks with the same output rate, channel count and DoP-ness. Within a group, tracks chain in one ring
with no gap; `Boundary` records map "frames consumed by the device" back to (track, position) exactly. At a format change
the group drains, the sink reconfigures the device clock, and a new group starts.

## Transitions (crossfade and smart)

Off by default: songs chain gapless as above. With Audio → Transitions on, the engine thread blends the end of one track into the start
of the next **before the ring**, so the render callback, `RingBuffer` and `RCUBox` are unchanged (`Pipeline/Transition.swift`):

```
outgoing chain ─┐
                ├─► TransitionMixer ─► ring ─► Renderer ─► DAC
incoming chain ─┘
```

* Near the end of a track the engine decides once (`TransitionPlanner`): the overlap length (the setting, at most 45 % of either track),
  where it ends (trailing digital silence left out) and where the next track starts (leading silence skipped). In Smart mode a track that
  fades out by itself keeps its fade and the next one comes in underneath it. The loudness handover starts the next track at the level the
  current one ends at (BS.1770 loudness of its first 10 s and the last 6 s, the stretch a crossfade covers, after ReplayGain) and eases it to its own level, by at most −max / +max/2 dB.
* `EdgeAnalyzer` decodes only the first and last 20 s of a file on a utility queue when it becomes upcoming; results are cached on disk
  next to the loudness cache. A missing analysis never blocks playback: that transition simply uses the plain settings.
* `TransitionMixer` sums both complete chains in Double with the chosen curve. A peak guard working one block ahead turns the mix down only
  where it would exceed full scale, with gain ramps and no steps. All of its buffers are allocated when the overlap starts.
* The overlap writes three `Boundary` records: the outgoing track's fading half, the incoming track from the midpoint (the title flips
  there) and the incoming track after the overlap. The overlap is marked not transparent, so the signal path is orange only while it plays.
* A queue edit that changes the next track while its overlap is still in the ring truncates at the overlap's start and writes the outgoing
  tail again, unmixed; a seek rebuilds the heard track's chain rather than seeking inside a mixer.
* Never blended, always gapless: DoP, internet radio, format changes, repeat-one, and songs from the same folder ("keep albums gapless").

## Live queue editing

The queue is `[QueueEntry]` with stable UUIDs plus a version counter. The engine thread notices a new version and
reconciles against the buffered boundaries:

* the audible track removed → continue with the entry now at its position;
* an upcoming, already-buffered track changed → `ring.truncate(to:)` at that track's start and re-chain from the queue
  (the audible track is untouched); if the audio was consumed meanwhile, fall back to flush + seek in place;
* nothing buffered beyond the audible track → nothing to undo; the next chain step reads the new queue.

## DSD

`DsdContainer` normalises DSF (LSB-first, block-interleaved) and DFF (MSB-first, byte-interleaved) into MSB-first bytes.
`DoPSource` packs 16 DSD bits per channel per frame; `DoPStampSource` writes the 0x05/0xFA marker from a clock shared by the
whole group so the alternation never breaks at a track boundary. `DsdToPcmSource` decimates with a Kaiser FIR (`vDSP_desampD`).

## Resampler

`PolyphaseDesign` builds an L-phase bank from a Kaiser-windowed sinc sized for the requested stop-band and pass-band; for
minimum phase it applies the homomorphic (cepstral) transform. `ResamplingSource` streams it with a sliding double-precision
window and `vDSP_dotprD`. Output frame *m* is aligned to input time *m·M/L* (linear-phase delay is compensated), so seeking
is deterministic: seek(n) reproduces the same samples as reading to n.

## Memory playback

`MemoryTrack` is the fully decoded stream *before* resampling/gain, so changing those settings does not re-decode. `TrackCache`
keeps the playing track and the next two within a byte budget. `DiskStats` counts file reads, and stays at zero during RAM playback.

## Real-time processing chain

After the ring, the `Renderer` runs an optional chain of processors **inside the audio callback**, on both the direct and the DSP path:

```
ring ─► [DSP engine] ─► convolution ─► crossfeed ─► headphone EQ ─► analysis tap ─► device
```

* Each processor works on interleaved Float32 in place (`RTProcessor.process`): partitioned FFT convolution (Accelerate,
  `vDSP_fft_zript` — the temp-buffer variant, so nothing allocates in the callback), the Bauer BS2B crossfeed, and a Double-precision
  biquad cascade for AutoEQ profiles. With nothing enabled the chain is empty and the direct path is untouched and bit-exact.
* The chain is built off the audio thread for the current stream format (loading and resampling an impulse response, designing filters)
  and published through an **`RCUBox`**: a lock-free read-copy-update cell. The callback does two atomic increments and one load; the
  publisher swaps the pointer, waits (bounded) for any read that may still use the old object, and only then releases it. If the wait
  times out the old object is leaked rather than risking a use-after-free.
* A format change rebuilds the chain for the new rate. Chain latency (one convolution block) is reported in the signal path.

## Visualisers

The only thing the audio thread does is copy the frames it just rendered into a lock-free ring (`AnalysisTap`; nothing is copied while
no view is open; if the consumer lags, frames are dropped — the callback never waits). An analysis thread at 60 Hz computes a 4096-point
Hann FFT (192 log bands), the spectrogram columns, VU ballistics (99 % of a step in 300 ms) and peak-hold, and SwiftUI `Canvas`
draws from those snapshots.

## Library, remote, helper

See [LIBRARY.md](LIBRARY.md) (schema and tag mapping), [REMOTE-PROTOCOL.md](REMOTE-PROTOCOL.md) (headless daemon, WebSocket API, sync)
and [SYSTEM-OPTIMIZATION.md](SYSTEM-OPTIMIZATION.md) (privileged helper, scheduling).
