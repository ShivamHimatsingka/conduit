# Conduit

**A free, open-source virtual audio router and mixer for macOS.** Send any app's audio, or your microphone, into a 16-channel virtual audio device, mix and route it from the menu bar, and pick that device as the input in OBS, Zoom, Discord or your DAW.

[![CI](https://github.com/ShivamHimatsingka/conduit/actions/workflows/ci.yml/badge.svg)](https://github.com/ShivamHimatsingka/conduit/actions/workflows/ci.yml)
![macOS 14.4+](https://img.shields.io/badge/macOS-14.4%2B-blue)
![Universal](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-lightgrey)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

<p align="center">
  <img src="docs/images/mixer-dark.png" alt="Conduit mixer, dark mode" width="49%">
  <img src="docs/images/mixer-light.png" alt="Conduit mixer, light mode" width="49%">
</p>
<p align="center"><sub>Screenshots use demo data.</sub></p>

> **Status: v0.0.1, early alpha.** It works and is tested end to end on one Mac (details under [Status](#status-and-known-limitations)), but it is not yet notarized, the driver is installed from source, and it has had little real-world use. Expect rough edges and please [open issues](https://github.com/ShivamHimatsingka/conduit/issues).

## Why

* [BlackHole](https://github.com/ExistentialAudio/BlackHole) is an excellent virtual loopback driver, but it has no interface, no per-app routing and no metering.
* Loopback (Rogue Amoeba) does all of that, but it is paid, closed source and runs background daemons.

Conduit is the missing middle: a small native app and a driver, both MIT licensed, with per-app capture, a routing matrix, meters and presets.

## Features

* **16-channel virtual audio device** ("Conduit 16ch"): 44.1, 48 and 96 kHz, 32-bit float. Whatever an app plays to it is available on its input.
* **Per-app capture** using Core Audio Process Taps (macOS 14.2+). No screen-recording permission, no ScreenCaptureKit. An app and all of its helper processes (Chrome, Electron, ...) are captured as one source.
* **Microphones and audio interfaces** as sources, drift-compensated against the Conduit clock.
* **Routing matrix**: sources × eight stereo buses (1-2 … 15-16). Click a cell to route; drag across cells to paint. One source can feed several buses.
* **Per-source** level, mute, mono-fold, and "silence the app on its normal output while it is captured". **Per-bus** level and mute.
* **Meters at 60 fps** (peak, RMS, peak-hold) and a **32-band FFT spectrum**, built on Accelerate/vDSP and drawn with Core Animation layers (about 0.2 % of one core while the mixer is open, nothing while it is closed).
* **Presets** as plain JSON, plus automatic restore of your last routing.
* **Menu-bar app** with a popover and a detachable floating window; light and dark mode; optional launch at login.
* **Command-line tools** for scripting and benchmarking (`conduitctl`, `conduit-bench`).
* **Real-time safe by construction.** The driver's IO path and the capture callback use no allocation, locks, logging or Objective-C/Swift runtime; the capture callback is written in C for that reason.

## How it works

```
 Spotify, Chrome, ... ─ Process Taps ─┐
 Microphones ─────────────────────────┼─► private aggregate device ─► C real-time IOProc ─┐
                                      │   (Conduit device = clock master, drift-compensated)│ mix into stereo buses
                                                                                           ▼
 Any app (OBS, Zoom, DAW) ◄──── input ──── Conduit 16ch (HAL driver) ◄── shared memory ring ┘
        ▲                                        ▲
        └── apps can also play straight to it    └── control, meters and clock over a Mach service + shared memory
                          Conduit.app (menu bar) ─┘
```

* **Driver** (`driver/`, C++20): a clean-room Core Audio `AudioServerPlugIn`. A lock-free, sample-time-indexed ring keeps its input and output sample-accurate with no latency of its own.
* **App** (`app/`, Swift 6 + AppKit, zero third-party dependencies): discovery, taps, UI, presets.
* **Shared** (`shared/`, C): the memory layout, the ring buffer algorithm and the real-time capture engine, compiled into both the driver and the app so they cannot drift apart.

Design write-up with all measurements: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Requirements

* macOS 14.4 or later (Process Taps need 14.2+).
* Apple silicon or Intel. Both architectures are built; only Apple silicon has been tested.
* To build the driver: Xcode or the Command Line Tools (`xcode-select --install`). Admin rights (`sudo`) to install it.

## Install

Conduit has two parts. The **driver** is the virtual audio device; the **app** is the mixer. The app alone runs in meter-only mode.

### 1. Install the driver (from source)

```bash
git clone https://github.com/ShivamHimatsingka/conduit.git
cd conduit
make install        # builds a universal driver, installs it to /Library/Audio/Plug-Ins/HAL, restarts coreaudiod
```

Audio pauses for a moment while Core Audio restarts. Afterwards **Conduit 16ch** appears in System Settings → Sound and in Audio MIDI Setup. The driver is ad-hoc signed locally, which macOS accepts for plug-ins you built yourself.

The channel count, names and IDs are build-time options (see the top of the `Makefile`), but the app currently expects the default 16-channel device, so change them only if you use the driver without the app.

### 2. Install the app

**Option A, download:** get `Conduit-0.0.1.zip` from the [latest release](https://github.com/ShivamHimatsingka/conduit/releases/latest), unzip it and drag **Conduit.app** to `/Applications`.

The release build is **not notarized**, so Gatekeeper blocks it the first time. Either open System Settings → Privacy & Security and click **Open Anyway**, or remove the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/Conduit.app
```

**Option B, build it yourself** (no Gatekeeper prompt):

```bash
make bundle                              # builds build/Conduit.app (universal, hardened runtime)
cp -R build/Conduit.app /Applications/
open /Applications/Conduit.app
```

Conduit lives in the **menu bar** (the sliders icon). Left-click opens the mixer; right-click has *Show Floating Mixer*, *Reconnect to Driver*, *Launch at Login* and *Quit*.

### Permissions

macOS asks the first time you use each feature, and Conduit never sends audio anywhere:

* **Audio Capture** (System Settings → Privacy & Security → Audio Capture): required to capture an app. If an app is clearly playing but its meter stays at zero, Conduit shows a hint pointing here.
* **Microphone**: required to use a microphone or audio interface as a source.

## Using it

1. Click the menu-bar icon. Apps that are producing audio appear first, with a green dot. Microphones are listed below them.
2. Flip a source's **switch** on, then click a cell in the matrix to route it to a bus. Bus **1-2** is the stereo pair that most apps read.
3. In the app you want to feed (OBS, Zoom, Discord, your DAW), choose **Conduit 16ch** as the **input** device. Bus 1-2 is input channels 1-2, bus 3-4 is channels 3-4, and so on. Apps that only read a stereo pair see bus 1-2; DAWs can use all 16 channels.
4. Adjust level and mute per source and per bus. Pick a source in the **Spectrum** menu to see its spectrum.
5. **Presets → Save Current Routing As…** stores everything as JSON in `~/Library/Application Support/Conduit/Presets/`.

Tips: *Silence on normal output while captured* (the `⋯` menu on an app) sends the app *only* to Conduit, so you do not hear it twice. Output *from* an app straight to **Conduit 16ch** (select it as that app's output device) also works; the app's channels 1-2 arrive on the device's input channels 1-2.

## Command-line tools

```bash
conduitctl apps                                  # audio apps (bundle id, pid, playing)
conduitctl tap com.spotify.client 60 --bus 2     # capture an app into channels 3-4 for 60 s
conduitctl meters 1                              # driver-side peak/RMS for every channel
conduitctl route 3 0 1.0                         # matrix: bus 3 <- input 0 at unity
conduit-bench loopback --buffer 64               # measure round-trip latency through the driver
conduit-bench clocks com.conduit.driver.device.16ch BuiltInSpeakerDevice
```

Build them with `swift build -c release`; binaries land in `.build/release/`.

## Measured performance

Measured on an installed driver (MacBook Air, Apple silicon, macOS 26), 48 kHz. Round trip is an impulse written by one client and read by another:

| IO buffer | sample offset | round trip |
|---|---|---|
| 32 frames | 0 | 1.333 ms |
| 64 frames | 0 | 2.667 ms |
| 128 frames | 0 | 5.333 ms |
| 256 frames | 0 | 10.665 ms |

That is exactly two buffers: the driver adds no latency of its own. Sample-rate switching (44.1/48/96 kHz) keeps the device clock within 6 ppm of nominal. For tapped apps, the injection stage adds 3.3 ms mean / 4.0 ms worst at 64-frame buffers (default). **This excludes the Process Tap's own capture latency, which has not been measured yet.** Method and full tables: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#phase-5-implemented-benchmarking-hardening-distribution).

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Driver not found · capture is meter-only" | Run `make install`, then right-click the menu-bar icon → *Reconnect to Driver*. Check Audio MIDI Setup lists "Conduit 16ch". |
| A tapped app shows no level | Allow Conduit under Privacy & Security → Audio Capture. Start playback first: an app only appears once it has opened an audio stream. |
| Audio is broken or `coreaudiod` keeps restarting | `sudo scripts/recover.sh` quarantines the driver and restarts Core Audio. Cannot reach Terminal? Boot to Recovery, open Terminal and run `rm -rf "/Volumes/Macintosh HD/Library/Audio/Plug-Ins/HAL/Conduit.driver"`, then reboot. |
| "Launch at Login" fails | It only works for the app installed in `/Applications`. |
| Another virtual device (BlackHole, Loopback) | They coexist. Conduit lists them as sources like any input; its own device is never offered as a source, so it cannot feed back into itself. |

## Uninstall

```bash
sudo scripts/uninstall.sh      # removes the driver, /Applications/Conduit.app and installer receipts, restarts coreaudiod
rm -rf ~/Library/Application\ Support/Conduit      # optional: your presets
```

## Building and testing

```bash
make build            # universal driver, -Werror
make test-all         # ring buffer, driver harness, tap engine, offline latency/drift, IPC end-to-end, app self-test (no sudo, no audio hardware)
make test-live        # end to end against the INSTALLED driver: a real playing app, real mouse events on the UI
make bundle           # build/Conduit.app
```

`make test-live` needs the driver installed and the Audio Capture permission; it plays a tone through `afplay`, routes it, and checks levels, faders, mutes, drag-painting, the spectrum and presets. Continuous integration runs the hardware-free suites on every push.

Layout: `driver/` HAL driver · `shared/` C core (ring, layout, capture engine, benchmarks) · `app/` Swift (bridge library, `Conduit` app, `conduitctl`, `conduit-bench`) · `tests/` · `scripts/` · `distribution/` installer · `docs/`.

## Status and known limitations

* **Tested:** one MacBook Air (Apple silicon, macOS 26). The driver loads in the real `coreaudiod`; per-app capture, routing, meters, presets and the UI were verified live there. The Intel slice builds but has not been run.
* **macOS 14.4 – 15** are the stated minimum but untested; they should work (the APIs exist since 14.2) but please report problems.
* **Not notarized:** the app in the release is ad-hoc signed. The signing, notarization and installer pipeline (`scripts/build_release.sh`, [docs/RELEASING.md](docs/RELEASING.md)) is written but has not been run with an Apple Developer ID yet. A signed installer package will follow.
* **Driver installs from source** for now.
* **Process Tap capture latency** and **physically mismatched sample rates** (for example a 44.1 kHz microphone into the 48 kHz device) are verified structurally but not yet measured on real hardware.
* **The driver's own 16×16 matrix** (for apps that play straight into Conduit, such as a DAW) is not in the UI yet; it is available through `conduitctl route` and the `ConduitBridge` library.
* A capture session is rebuilt, with a brief gap, when the set of enabled sources changes. Level, mute and routing changes are live and click-free.

## Contributing

Issues and pull requests are welcome. Please run `make test-all` before opening a PR; changes to the driver's real-time path must not allocate, lock, log or call into the Swift/Objective-C runtime (the tests and `-Werror` build catch some of this, not all). Security-sensitive reports: please open a private security advisory on GitHub.

## License

MIT, © 2026 Shivam Himatsingka. The driver is a clean-room implementation against Apple's public `AudioServerPlugIn` interface; it contains no code from BlackHole or other GPL projects.
