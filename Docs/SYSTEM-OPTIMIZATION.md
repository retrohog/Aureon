# System optimisation

Three independent pieces, from harmless to privileged.

## 1. Scheduling of Aureon's own threads (no privileges)

* **Engine thread**: the thread that decodes ahead into the ring buffer can ask for a Mach *time-constraint* policy
  (`thread_policy_set(THREAD_TIME_CONSTRAINT_POLICY)`, default 1 ms of every 5 ms, due within 4 ms) and the user-interactive QoS class.
  This keeps the ring full when the machine is busy. Setting: System → "Raise the priority of Aureon's decoding thread".
* **IO cycle usage**: `kAudioDevicePropertyIOCycleUsage` is how much of each IO cycle the HAL lets our callback use before it counts
  as an overload (default 50 %). Raising it helps heavy processing such as long convolution.
* The CoreAudio IOProc thread is already real-time and cannot be raised beyond what the system grants.

Verified by tests that read the policy back from the kernel (the kernel may raise the *computation* time to its own minimum).

## 2. Quiet mode (privileged helper)

While Aureon plays, **pause** — never kill — Spotlight indexing (`mds`, `mds_stores`, `mdworker`, `mdworker_shared`), Time Machine
(`backupd`) and the Photos/media analysis daemons (`photoanalysisd`, `mediaanalysisd`), and raise Aureon's own priority
(`setpriority`, −20…0). Everything is put back afterwards.

### Safety design

| Risk | Mitigation |
|---|---|
| Suspending the wrong thing | The **helper** enforces a fixed allowlist; a request can narrow it but never widen it. pid 1 and the helper itself are refused. Only `SIGSTOP`/`SIGCONT` are ever sent. |
| Leaving daemons paused (helper crash, app crash, power loss) | Resumes on: explicit request · the app's XPC connection closing or being interrupted · 20 s without a heartbeat · a hard 4-hour cap · SIGTERM/SIGINT/SIGHUP/`atexit` in the helper · **next start** (the paused pids are written to disk with their process start times and continued; a recycled pid is detected by its start time and left alone). |
| Taking over processes someone else paused | Processes already stopped are not tracked and not resumed. |
| A rogue local process talking to the helper | One client at a time; production builds require the caller's code signature to match (`setCodeSigningRequirement`). Priority changes apply only to the calling process. |
| Hanging playback | The app never waits more than 3 s for the helper. |

### Installing (signed builds only)

`SMJobBless` is deprecated; Aureon uses `SMAppService.daemon`. That requires a **signed** app (Developer ID or development
certificate) with the helper inside the bundle:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Packaging/build_app.sh --with-helper
```

then System → "Install helper…" and approve it in System Settings → General → Login Items. An ad-hoc signed build can build the helper but macOS
will refuse to register it; the settings then show "Helper not installed". The helper's code requirement defaults to
`identifier "org.aureon.player" and anchor apple generic`; override with `AUREON_HELPER_REQUIREMENT` for your own team.

### What is tested, and what is not

Tested (172+ self-tests): the suspender against real stand-in processes (SIGSTOP/SIGCONT verified through the kernel's process state),
crash recovery including pid reuse, the heartbeat watchdog and hard cap, the whole XPC protocol over an in-process anonymous listener,
refusal of out-of-range priorities, resume when the client vanishes, and the app-side controller with a fake helper.

**Not tested**: registering and running the helper as root under launchd (it needs a signing identity and your approval), and
pausing the *real* Spotlight/Time Machine daemons. Do a supervised first run: start playback, check `ps -o stat -p $(pgrep mds)`
shows `T`, stop playback, check it returns to `S`.

## 3. Why not "absolute maximum" priority?

Raising a non-real-time thread to priority 127 does not help audio (the IOProc is already time-constrained) and can starve the window
server and the HAL itself. Aureon therefore asks for a modest time-constraint policy on its own decode thread and leaves the rest alone.
