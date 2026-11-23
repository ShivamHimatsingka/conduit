# Conduit architecture

```
 ┌────────────── user session ──────────────┐        ┌──────────── coreaudiod (_coreaudiod, sandboxed) ───────────┐
 │  Conduit.app (Swift 6 / AppKit)          │        │  Conduit.driver (C++20 AudioServerPlugIn)                  │
 │                                          │        │                                                            │
 │  Process Tap IOProc ──► per-app mixer ───┼─ mach ─┼─► control block (gain/mute/solo/matrix/meters)  [Phase 2]  │
 │  (Phase 3, RT thread)    crosspoints     │  shm   │   bus rings (app → device input)                [Phase 2]  │
 │  AppKit UI, vDSP meters (Phase 4) ◄──────┼────────┼── meters (atomics, read at 60 fps)                         │
 └──────────────────────────────────────────┘        │                                                            │
                                                     │  Device "Conduit 16ch"                                     │
   Any app (OBS, Zoom, DAW) ◄── input stream ◄───────┼── TimelineRing ◄── output stream ◄── any app   [Phase 1]   │
                                                     └────────────────────────────────────────────────────────────┘
```

## Decisions that differ from the original brief

| Topic | Brief | Decision | Why |
|---|---|---|---|
| Ring buffer | Classic SPSC head/tail | **Sample-time-indexed SPSC "timeline" ring** (still lock-free, cache-line-aligned, zero allocation) | Output (`WriteMix`) and input (`ReadInput`) IO cycles arrive independently with different buffer sizes, each tagged with a device sample time. Addressing by sample time keeps them phase-locked at zero added latency, and dropouts self-heal. A head/tail FIFO needs fill-level servoing and drifts permanently after one missed cycle. |
| BlackHole as base | Clone and modify | **Clean-room**, MIT | BlackHole is GPL-3.0. Modifying it forces GPL-3.0 on the result and contradicts the "clean-room" requirement. The HAL interface is public (`AudioServerPlugIn.h`), so nothing needed to be copied. |
| Zero timestamp | Stateful | **Stateless**: pure function of `(anchorHostTime, now, rate)` | No mutable state on the RT thread; concurrent callers always agree. |
| Sandbox IPC | `shm_open` / XPC | **Mach service declared in the driver's `Info.plist` (`AudioServerPlugIn_MachServices`)** + shared memory passed as a Mach memory-entry port | `coreaudiod`'s sandbox denies `shm_open` on arbitrary names and XPC listener creation, but allows a Mach service the plug-in declares. See Phase 2 below. |
| Aggregate device | Tap(s) + virtual device | Same, with the **virtual device as clock master** and drift compensation on the taps | Our device's clock is the host clock exactly; taps follow the output device they tap, so only they need resampling. |

## Phase 1 (this commit): the HAL driver

| File | Responsibility |
|---|---|
| `driver/src/Driver.cpp` | COM vtable (`AudioServerPlugInDriverInterface`), CFPlugIn factory, `PlugIn` object, object-ID routing |
| `driver/src/Device.cpp` | Device properties, StartIO/StopIO, stateless zero-timestamp clock, **RT IO path**, async sample-rate change |
| `driver/src/Stream.cpp` | Input/output stream properties, 32-bit float interleaved format negotiation |
| `driver/src/RingBuffer.hpp` | `TimelineRing`: lock-free SPSC, `alignas(64)` producer/consumer/config lines, seqlock torn-read guard |
| `driver/src/Config.hpp` | Compile-time config: channels (1–64, default 16), rates 44.1/48/96 kHz, ring size |
| `driver/Info.plist.in` | Bundle + CFPlugIn registration template |

### Real-time rules, and how they are enforced

The RT surface is exactly: `GetZeroTimeStamp`, `WillDoIOOperation`, `BeginIOOperation`, `DoIOOperation`, `EndIOOperation`.

* Only `std::atomic` loads/stores, `memcpy`/`memset` on pre-faulted memory, and `mach_absolute_time()`.
* No `malloc`/`new`, no mutex, no logging, no CF/ObjC calls. All of that lives in the control plane (`get`/`set`/`startIO`/`stopIO`), which is the only code that takes `controlMutex_`.
* The ring is one `mmap` allocated in the `Device` constructor, then touched page-by-page by `reset()` (and `mlock`ed best-effort) so IO never page-faults.
* All atomics are statically asserted lock-free.
* Sample-rate changes use the HAL's `RequestDeviceConfigurationChange` → `PerformDeviceConfigurationChange` handshake, so rate, clock ratio and formats only mutate while IO is stopped.

### TimelineRing semantics

* `write(start, n, src)` (producer): publishes `writeBegin = start+n`, release-fence, zero-fills any skipped time (so stale audio from a previous lap can never replay), copies, then publishes `writeEnd` with release.
* `read(start, n, dst)` (consumer): acquires `writeEnd`, copies the valid window `[max(start, writeEnd-cap), min(start+n, writeEnd))`, silences the rest, then re-reads `writeBegin` after an acquire fence and silences any frames the producer began overwriting during the copy.
* The consumer never stores to producer-owned cache lines. Underrun/lap/gap counters feed Phase 2 telemetry.
* The ring is a non-owning view (`create`/`attach`), so Phase 2 moves it into shared memory unchanged.

### Verified so far

| Check | Result |
|---|---|
| Universal build (arm64 + x86_64), `-Wall -Wextra -Wpedantic -Werror`, macOS 14.4 target | pass |
| Ad-hoc codesign, `plutil -lint`, `codesign --verify --strict` | pass |
| Ring unit tests + 2-thread stress (6.8M samples, lap path exercised, 0 corrupt) | pass |
| In-process driver harness (object graph, UID translation, formats, rate handshake, IO round trip, clock = 96000.0 Hz, restart semantics) | pass |
| `CHANNELS=2` variant builds and passes the same harness | pass |
| **Installed into a live `coreaudiod` and used by a real app** | **not yet done**, needs `sudo`; do this first on your machine |

## Phase 2 (implemented): sandbox-safe IPC and control/telemetry plane

```
 conduitctl / app (Swift)                      coreaudiod
 ConduitLink ── bootstrap_look_up ──────────►  IpcServer thread (HELLO, audit-token check)
             ◄─ memory-entry port (COPY_SEND) ─┘
 vm_map ═══════════ one shared region ═════════ mach_vm_allocate'd, owned by the driver
   [ControlBlock: gains/mute/solo/matrix  app→driver]   read by Mixer on the RT thread
   [Meters + Clock                         driver→app]  written by Mixer / StartIO
   [App injection ring                     app→driver]  TimelineRing, same C code both sides
```

| Piece | Where |
|---|---|
| Wire layout, atomic accessors, clock seqlock | `shared/include/conduit_shared.h` (plain C; compiled by the driver and imported by Swift) |
| Ring algorithm (single implementation) | `shared/include/conduit_ring.h`; C++ `TimelineRing` and Swift both call it |
| Mach client handshake | `shared/conduit_client.c` |
| Region allocation + memory entry | `driver/src/SharedRegion.hpp` |
| Mach server (own thread, never on the IO path) | `driver/src/IpcServer.cpp` |
| RT mixing + metering | `driver/src/Mixer.cpp` |
| Swift API | `app/Sources/ConduitBridge/ConduitLink.swift` |
| CLI | `app/Sources/conduitctl` |

**Why this is sandbox-compliant.** No filesystem name, no `shm_open`, no XPC listener. The only things the driver does are `bootstrap_check_in` for a Mach service it declares in `Info.plist` (`AudioServerPlugIn_MachServices`), and hand out a memory-entry send right. The app's side is ordinary `bootstrap_look_up` plus `mach_vm_map`.

**Access control.** The service is reachable from any process in the bootstrap namespace, so the server reads the sender's audit token from the message trailer and only answers euid 0, the console user, or its own uid. Messages are size/id/magic validated and the reply uses the client's send-once right, so a dead client cannot block the server.

**Real-time contract.** The control block holds only 32/64-bit integers accessed with relaxed atomics; floats travel as bit patterns. The Mixer reads ~16 gains plus the 16x16 matrix per block, rebuilds a sparse row list in preallocated memory, and ramps changed coefficients linearly across the block, so gain/route changes never click. Meters are max-hold peaks (reader takes-and-clears) plus per-block mean-square; the UI reads them at any rate with no locks.

**Signal flow.**
`WriteMix`: strip gain / mute / solo, then the crosspoint matrix, then the loopback ring.
`ReadInput`: loopback ring, plus the app injection ring summed in, then bus gain / mute.
Input meters are pre-fader; bus meters are post-fader.

**Clock for Phase 3.** The driver publishes `(anchorHostTime, hostTicksPerFrame, rate, seed)` under a seqlock whenever IO starts/stops or the rate changes. The app converts `mach_absolute_time()` to device sample time and writes into the injection ring slightly ahead of it; a changed `seed` tells it the driver restarted.

### Phase 2 verification

| Check | Result |
|---|---|
| Ring/driver/harness suites from Phase 1 with the mixer now in the IO path | pass |
| `make test-ipc`: separate driver-host and Swift processes; handshake, identity routing, crosspoint re-route, strip gain, bus gain, mute, solo, bus mute, meters (pre/post fader, peak and RMS), app injection via the published clock, clean failure on an unknown service | 17/17 pass |
| Swift 6 language mode, release build, zero warnings | pass |
| **Mach service claim inside the real sandboxed `coreaudiod`** | **not verified**: needs `sudo` install. The test host claims the name via `bootstrap_register` (enabled only by `CONDUIT_IPC_ALLOW_REGISTER=1`); the real driver uses `bootstrap_check_in`. If the system does not pre-create the declared service, the fallback is a tiny LaunchDaemon that owns the name and hands the port to the driver; try the plain path first. |

## Phase 3 (implemented): per-app capture with Core Audio Process Taps

```
 Spotify ─┐                                  ┌───────────────────────────────┐
 Chrome  ─┼─ CATapDescription (per app) ──►  │ private aggregate device      │
 (+helpers│   stereo mixdown, drift-comp     │  main sub-device = Conduit    │──► conduit_tap_ioproc (C)
  grouped)┘                                  │  + tap list                   │      per-tap gain/mute/bus
                                             └───────────────────────────────┘      ramped, metered
                                                                                      │ device-time aligned
                                                     Conduit driver ◄── injection ring ┘
```

| Piece | File |
|---|---|
| Process list, helper-to-app grouping, change monitor | `app/Sources/ConduitBridge/ProcessDiscovery.swift` |
| Tap + aggregate lifecycle, live route control | `app/Sources/ConduitBridge/TapSession.swift` |
| Real-time IOProc and mixer (C) | `shared/conduit_tap_engine.c` |
| CLI | `conduitctl apps`, `conduitctl tap` |

**Discovery.** `kAudioHardwarePropertyProcessObjectList` gives process objects (pid, bundle id, is-running-output/input). Helper processes (Chrome renderers, Electron helpers) are rolled up into their GUI app by walking the parent-pid chain, falling back to bundle-id prefix, so a tap on "Chrome" covers every Chrome process that makes sound. `ProcessMonitor` fires when the list changes; icons come from `NSRunningApplication` on the main actor.

**Taps.** One `CATapDescription(stereoMixdownOfProcesses:)` per app, private, with `muteBehavior` `.muted` when you want the app routed *only* into Conduit. No ScreenCaptureKit and no screen-recording prompt.

**Aggregate and clocking.** The private aggregate's main sub-device is the Conduit device, so each IO cycle is driven by the driver's own clock and starting the aggregate starts the driver; taps are drift-compensated against it. If no driver is reachable, the same session runs in monitor-only mode clocked by the default output device (meters only).

**Why the IOProc is C.** The brief forbids the Swift/ObjC runtime on the IO thread. A Swift IOProc closure can retain/release and allocate; the C function touches only preallocated memory and atomics. Swift only creates the engine, flips route atomics and reads peaks.

**Injection timing.** For each cycle the engine converts the capture's host time to device sample time using the driver's published clock, adds a latency budget (default 192 frames, tunable) so the driver has not already consumed that slot, and writes contiguously. It re-aligns only if the two clocks disagree by more than 48 frames or the driver restarts (seed change), so jitter never produces gaps. Gain/mute changes ramp across the block.

**Latency.** capture buffer (default 128 frames, 2.7 ms at 48 kHz) + injection budget; the budget is the knob to trade against underruns. Measuring the real number is the Phase 5 impulse harness.

**Permissions.** Taps are gated by the *Audio Capture* privacy permission. The hosting app must carry `NSAudioCaptureUsageDescription` in its Info.plist (added with the app bundle in Phase 4); the prompt is not a screen-recording one.

### Phase 3 verification

| Check | Result |
|---|---|
| `make test-tap`: real `conduit_tap_ioproc` fed synthetic aggregate buffers: stereo routing, gain, mono fold, latency offset, outputs zeroed, contiguity, jitter tolerance, resync on big jump, mute, idle when driver stopped, missing buffers, monitor-only | pass |
| Live: `conduitctl apps` finds the running app and groups its helpers | pass |
| Live: real Process Tap + private aggregate + C IOProc on this Mac in monitor mode, tapping a 440 Hz / 0.5 amplitude `afplay` tone: peak 0.500, 128-frame buffers honored, ~375 cycles/s, 0 idle | pass |
| Swift 6, release build, no warnings; earlier suites unchanged | pass |
| **Tap into the installed driver (aggregate with Conduit as clock master, end-to-end audio on a bus channel)** | **not yet done**: needs the driver installed with `sudo` |
| Tap set changes at runtime | rebuild the session (brief gap); route/gain/mute/bus changes are live |

## Phase 4 (implemented): native menu-bar mixer

`build/Conduit.app` is a pure-AppKit, zero-dependency, `LSUIElement` menu-bar app (no Dock icon). Screenshots of the real views are rendered by `Conduit --snapshot out.png [--dark]` (demo data, same code path as the live app).

```
 NSStatusItem ─ click ─► NSPopover ─┐
        │ right-click: menu         ├─► MixerViewController ◄── MixerModel ──► ConduitLink  (control + telemetry)
        └─ "Show floating mixer" ─► NSPanel ┘   (many views, one model)             └─► TapSession (taps + mics)
```

| Piece | File |
|---|---|
| Status item, popover (applicationDefined, closes on outside click), detachable floating `NSPanel`, right-click menu | `AppDelegate.swift` |
| Single owner of the driver link, capture session, routing state, autosave, meter state | `MixerModel.swift` |
| Source rows, routing matrix (click toggles, drag paints), bus labels, bus strips, CALayer meters and spectrum | `Views.swift` |
| Layout, presets menu, 60 fps display link | `MixerViewController.swift` |
| vDSP level math, ballistics, FFT spectrum | `Metering.swift` |
| JSON presets, `Application Support/Conduit/Presets` | `Routing.swift` |
| Info.plist, entitlements, bundling | `app/Info.plist.in`, `app/Conduit.entitlements`, `scripts/make_app.sh` |

**Routing model.** Rows are the audio-producing apps (helpers grouped into their app) plus input devices. Columns are 8 stereo buses (device channels 1-2 … 15-16). A cell means "this source feeds this bus"; a source can feed any number of buses. Each source has an enable switch, level, mute, and a menu for mono-fold and "silence on normal output while captured". Each bus has a driver-side level and mute with a post-fader meter. Hardware microphones join the same private aggregate as drift-compensated sub-devices, so they are clocked and mixed exactly like taps.

**Engine changes for this phase.** The C engine now takes any mix of tap and hardware sources, per-source sends into any number of stereo pairs (ramped), and publishes a mono pre-fader analysis feed per source for the UI.

**Metering with Accelerate.** Per frame: `vDSP_vdbcon` + `vDSP_vclip` convert every peak/RMS to clamped dBFS in one call each; `vDSP_rmsqv` computes source RMS from the engine's analysis feed; the spectrum is `vDSP_hann_window` → `vDSP_fft_zrip` (2048-point real FFT) → `vDSP_zvmags` → `vDSP_vdbcon` → 32 log bands (40 Hz–16 kHz) with release smoothing. Normalisation is calibrated by a test (full-scale sine reads 0 dBFS; 0.5 reads −6.6 dBFS including Hann scalloping).

**Rendering.** Meters and the spectrum are `CALayer` trees: a gradient layer revealed by mask layers whose frames are the only thing updated per frame (inside a no-actions `CATransaction`, skipped when nothing moved >0.2 %). There is no `drawRect` in the hot path. The display link exists only while a mixer view is on screen, so a closed popover costs nothing; with it open, one frame of poll + render measures ~32 µs ≈ 0.2 % of a core at 60 fps (demo signal generation included).

**Presets.** Plain, human-editable JSON with a `version` field; unknown versions and corrupt files are rejected with an alert, never a crash. Sources are keyed `app:<bundle id>` / `mic:<device uid>`, so a preset applies to whichever of those are running; absent ones stay greyed in the list. The live state is autosaved to a hidden `_last` preset and restored at launch.

**Permissions.** The Info.plist carries `NSAudioCaptureUsageDescription` (process taps) and `NSMicrophoneUsageDescription`; the entitlements file adds `device.audio-input` for the hardened runtime. If an app is clearly playing while its tap stays at exact silence for 5 s, the UI shows a hint pointing at the Audio Capture privacy pane.

### Phase 4 verification

| Check | Result |
|---|---|
| `make test-app` (`Conduit --selftest`): dBFS/RMS/peak math on vDSP; ballistics and hold; FFT bin placement, calibration, silence and off-band rejection; preset save/load round trip, version and corruption rejection; matrix toggle/ordering/range logic; snapshot/apply; per-frame CPU cost | 20/20 pass (0.19 % of a core at 60 fps) |
| Offscreen render of the real views in light and dark appearance | reviewed by eye, correct |
| Real (non-demo) launch on this Mac | starts, 0.1 % CPU and 46 MB idle |
| `make bundle`: universal arm64+x86_64, hardened runtime, entitlements, ad-hoc signature, self-test passes from inside the `.app` | pass |
| Engine test extended for microphones, multi-bus sends and the analysis feed | pass |
| **Clicking through the popover/panel with a human** | **not done**: I rendered and exercised the views programmatically but did not drive the live menu-bar UI |
| **Live capture into the installed driver from the UI** | **not done**: needs `sudo` install |
| Routing the *driver's own* 16×16 matrix (apps that play straight into the Conduit device, e.g. a DAW) from the UI | not in the UI; available through `conduitctl route`/`ConduitLink` |

## Phase 5 (implemented): benchmarking, hardening, distribution

### Measurement tools

| Tool | What it does |
|---|---|
| `conduit-bench loopback` | Live. Writes a unit impulse into a loopback device's output at a known device sample time and detects it on the input. Reports **sample offset** (0 = sample-accurate), **app-write→app-read round trip**, output lead and input lag. Works on any loopback device (`--uid`). |
| `conduit-bench clocks A [B]` | Live. Regresses each device's sample time against the host clock: real sample rate, ppm error, and the relative drift between two devices. |
| `conduit-bench rates` | Live. Switches the Conduit device through 44.1/48/96 kHz and verifies the real clock each time. |
| `conduit-bench devices` | Lists devices. |
| `make test-bench` | Offline. The same C measurement code against the real driver binary and the real tap engine on a simulated HAL schedule: deterministic, no hardware. |

The per-cycle measurement code (`shared/conduit_bench.c`) is C and real-time safe, and is shared by the live IOProc and the offline harness, so both measure the same way.

### Results on an installed driver (MacBook Air, macOS 26, Conduit 16ch)

Round trip through the driver (impulse written by an app, read back by another client), 48 kHz:

| IO buffer | sample offset | round trip | = 2 × buffer |
|---|---|---|---|
| 32 frames | 0 | 1.333 ms | 1.333 ms |
| 64 frames | 0 | 2.667 ms | 2.667 ms |
| 128 frames | 0 | 5.333 ms | 5.333 ms |
| 256 frames | 0 | 10.665 ms | 10.667 ms |

Every impulse came back (0 lost), the spread was ~3 µs, and the driver adds **no latency of its own**: the round trip is exactly the one output buffer of lead plus one input buffer of lag that Core Audio imposes. The same tool on this Mac's BlackHole 16ch (128 frames at 44.1 kHz) gave 5.806 ms and offset 0, i.e. the same 2 × buffer behaviour, which validates the harness.

Clocks and sample rates, live:

| Measurement | Result |
|---|---|
| Conduit device clock vs host clock | −0.1 ppm (the driver derives its clock from the host clock) |
| Built-in speakers (44.1 kHz) vs host | +1.1 ppm; so Conduit (48 kHz) ↔ speakers differ by −1.2 ppm |
| `conduit-bench rates`: 44.1 / 48 / 96 kHz through the real HAL handshake | measured within 6 ppm of nominal each time |
| Real app (`afplay`, 0.5/0.25 stereo tone) tapped into the installed driver | bus channels 2/3 read peak 0.500 / 0.250, 0 idle cycles, 0 re-alignments over 7 s at 128 frames; same at the new 64-frame default (758 cycles/s) |

### Injection budget (offline, deterministic)

Tapped audio is written into the driver's injection ring at `capture time + budget`. The budget must be at least one IO buffer, otherwise the data lands in a slot the driver has already read. Measured with the consumer ordered *before* the engine (worst case), every capture offset:

| buffer | budget | lost | capture → readable (frames, mean / max) | ms @ 48 kHz (mean / max) |
|---|---|---|---|---|
| 64 | 63 (one short) | 1 | 95 / 125 | 1.98 / 2.60 |
| 64 | 64 | 0 | 96.5 / 128 | 2.01 / 2.67 |
| **64** | **128 (default)** | **0** | **160.5 / 192** | **3.34 / 4.00** |
| 128 | 128 | 0 | 193 / 256 | 4.02 / 5.33 |
| 128 | 192 | 0 | 255.5 / 318 | 5.32 / 6.62 |

Worst-case latency is exactly `budget + one buffer`. `TapSession` therefore defaults to **64-frame buffers and a budget of buffer + 64 frames**: 3.3 ms mean / 4.0 ms worst for the injection stage at 48 kHz, inside the 5 ms target. *This excludes the Process Tap's own capture latency, which I have not measured*; with 128-frame buffers the injection stage alone is 5.3 ms mean.

### Drift and clock handling

| Case (120 s simulated, 128-frame buffers) | engine re-alignments |
|---|---|
| exact clock, ±4 and ±40 frame timestamp jitter | 0 |
| +50 ppm, no compensation | 5 (analytic 6) |
| −200 ppm, no compensation | 23 (analytic 24) |
| driver switched 48 → 96 kHz mid-stream | exactly 1, and the next impulse lands in the right slot |

The engine keeps writes contiguous and only re-aligns when its clock disagrees with the driver's by more than 48 frames (or the driver restarts). Uncompensated drift would therefore cause one audible re-alignment every `48 / (ppm × rate)` seconds, e.g. ~20 s at 50 ppm. That is not what happens in practice: the capture aggregate marks every tap and microphone **drift-compensated against the Conduit device**, so Core Audio resamples them to the driver's clock. Measured relative drift between real clocks on this Mac is ~1 ppm (one re-alignment per ~14 minutes *if* compensation were absent). Mismatched nominal rates (a 44.1 kHz microphone into a 48 kHz device) rely on the same aggregate resampling, which I could only verify structurally, not with a physical 44.1 kHz input.

### Distribution

| Piece | File |
|---|---|
| Release build: sign, `pkgbuild` ×2, `productbuild`, notarize, staple, verify | `scripts/build_release.sh`, `make pkg` |
| Installer UI, OS gate (14.4+), arch list, component choices | `distribution/distribution.xml`, `distribution/resources/` |
| Driver install scripts (replace old copy, restart `coreaudiod`) | `distribution/scripts/driver/{preinstall,postinstall}` |
| Entitlements | `app/Conduit.entitlements` (app: audio-input). The driver needs none. |
| CI and tag-triggered release | `.github/workflows/{ci,release}.yml` |
| Walkthrough: certificates, notary credentials, secrets, verification, uninstall | `docs/RELEASING.md` |
| Launch at login | menu item, `SMAppService.mainApp` (works from `/Applications`) |

### Phase 5 verification

| Check | Result |
|---|---|
| `make test-all`: ring, driver harness, tap engine, **offline bench**, IPC end-to-end, app self-test | all pass |
| **Driver installed into the real `coreaudiod`**; device appears; `conduitctl` connects over the declared Mach service | works (resolves the Phase 2 question: `bootstrap_check_in` succeeds for a service declared in `AudioServerPlugIn_MachServices`) |
| Live loopback latency, sample accuracy, rate switching, clock probe | measured, tables above |
| Live per-app capture into the driver | works, tables above |
| Unsigned installer builds; `distribution.xml` valid; both payload signatures verify after expansion; postinstall/preinstall present; workflow YAML parses | pass |
| **Signing, notarization, stapling** | **not run**: needs your Developer ID certificates and notary credentials. The path is written and documented but unexercised. |
| **Tap capture latency; physical mismatched-rate input; installing from the .pkg; the GitHub workflows** | not measured / not run |
| Unsigned package payload | contains `._*` AppleDouble entries when built from this environment (protected `com.apple.provenance` attribute on every file created here); the script refuses to ship a *signed* release in that state. Build releases in CI. |
