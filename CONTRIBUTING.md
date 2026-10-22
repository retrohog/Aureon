# Contributing

Thanks for helping make a better open-source music player.

## Ground rules

1. **Bit-perfect by default.** Anything that changes sample values must be opt-in, flagged `transparent = false`
   on its `StreamInfo`, and visible in the signal-path panel.
2. **The audio callback is sacred.** In `Renderer.render`, `RTProcessor.process` and the sink callbacks: no locks, no allocation, no I/O, no
   Objective-C messaging that you can avoid. Communicate with it through atomics (`RingBuffer`) and hand new objects over with `RCUBox`.
3. **Test the delivered samples.** New pipeline stages get an end-to-end test using `RecordingSink`.
4. **Clean-room.** Do not copy code from, or decompile, commercial players. Describe observed *behaviour* in your
   pull request and implement from first principles.

## Workflow

```bash
swift build -c release
.build/release/Aureon selftest          # must stay green (~1 min)
.build/release/Aureon selftest remote   # run a subset by name
./Packaging/build_app.sh /tmp           # builds an app bundle without touching your Desktop
```

Add a test by writing a method on one of the structs in `Sources/Aureon/SelfTest/` and registering it in `Registry.swift`.

## Reporting hardware results

Run `Aureon hwdebug --all --json report.json` with your DAC selected (`--device "name"`) and attach the report to an issue.
Mention the DAC model and macOS version.

## Where things live

`Sources/Aureon/` — `Core` (decode, ring, RCU, device) · `Pipeline` (resampler, DSD, ReplayGain, stages) · `Processing` (crossfeed, AutoEQ, convolution) · `Engine` (player, sinks) ·
`Analysis` · `Library` · `Metadata` · `Social` · `Remote` · `System` · `GUI` · `SelfTest`; the helper is `AureonHelperKit` + `AureonHelper`.
