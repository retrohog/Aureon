# Contributing

Thanks for helping make a better open-source music player.

## Ground rules

1. **Bit-perfect by default.** Anything that changes sample values must be opt-in, flagged `transparent = false`
   on its `StreamInfo`, and visible in the signal-path panel.
2. **The audio callback is sacred.** In `Renderer.render`, `RTProcessor.process` and the sink callbacks: no locks, no allocation, no I/O, no
   Objective-C messaging that you can avoid. Communicate with it through atomics (`RingBuffer`) and hand new objects over with `RCUBox`.
3. **Clean-room.** Do not copy code from, or decompile, commercial players. Describe observed *behaviour* in your
   pull request and implement from first principles.

## Workflow

```bash
swift build -c release
./Packaging/build_app.sh /tmp           # builds an app bundle without touching your Desktop
```

Run the checks before you open a pull request. The whole suite, or one group by name:

```bash
swift build
.build/debug/Aureon selftest              # everything (a few minutes)
.build/debug/Aureon selftest slsk.        # one group, here Soulseek
```

Useful groups: `ui`, `search`, `np` (Now Playing), `lyrics`, `perf`, `edge`, `djpro`, `slsk.`, `transport`. A change that touches a layout should also run `pulse.layoutFit`.

## Issues and pull requests

Found a bug, or something that does not feel right? [Open an issue](https://github.com/retrohog/Aureon/issues) with what you did, what you expected, what happened, your Mac model and your macOS version. A screenshot helps.

Pull requests are welcome, small or large. Fork the repository, make your change on a branch, and open a pull request against `main`. Keep it focused, describe what you changed and why, and say which checks you ran. We read every one.

## Reporting hardware results

Run `Aureon hwdebug --all --json report.json` with your DAC selected (`--device "name"`) and attach the report to an issue.
Mention the DAC model and macOS version.

## Where things live

`Sources/Aureon/` — `Core` (decode, ring, RCU, device) · `Pipeline` (resampler, DSD, ReplayGain, stages) · `Processing` (crossfeed, AutoEQ, convolution) · `Engine` (player, sinks) ·
`Analysis` · `Library` · `Metadata` · `Social` · `Remote` · `System` · `GUI`; the helper is `AureonHelperKit` + `AureonHelper`.
