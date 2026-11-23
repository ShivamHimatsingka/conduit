# Conduit

Open-source virtual audio router and mixer for macOS 14.4+ (universal binary). A free, lightweight alternative to BlackHole + Loopback: a 16-channel virtual device today, with per-app routing and metering planned. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Phase 1: build, test, install

```bash
./build.sh build        # universal Conduit.driver in build/, ad-hoc signed
./build.sh test         # ring stress test + in-process driver harness (no sudo)
./build.sh install      # copy to /Library/Audio/Plug-Ins/HAL, restart coreaudiod (sudo)
```

Pick **Conduit 16ch** in System Settings → Sound or Audio MIDI Setup. Anything played to it is available on its input.

Variants (all optional):

```bash
make CHANNELS=2 DEVICE_NAME="Conduit 2ch" DEVICE_UID=com.conduit.driver.device.2ch \
     BUNDLE_ID=com.conduit.driver.2ch DRIVER_NAME=Conduit2 FACTORY_UUID=$(uuidgen) install
```

## Phase 4: the menu-bar app

```bash
make bundle && open build/Conduit.app      # universal, hardened runtime, ad-hoc signed
build/Conduit.app/Contents/MacOS/Conduit --snapshot ui.png --dark   # render the UI offscreen
make test-app                                # metering, FFT, presets, CPU cost
```

## Phase 2: control and telemetry

```bash
make app && make test-ipc          # Swift bridge + cross-process end-to-end test (no sudo)
.build/release/conduitctl info
.build/release/conduitctl route 3 0 1.0     # app audio on channel 0 -> bus 3
.build/release/conduitctl gain bus 3 -6
.build/release/conduitctl meters 1
```

## Phase 5: measure and release

```bash
make test-bench                                   # offline latency/drift characterisation (no hardware)
.build/release/conduit-bench loopback --buffer 64  # live round-trip latency through the installed driver
.build/release/conduit-bench clocks com.conduit.driver.device.16ch BuiltInSpeakerDevice
make pkg                                          # unsigned installer; signed + notarized: see docs/RELEASING.md
```

## If audio breaks

```bash
sudo scripts/recover.sh                 # quarantines Conduit*.driver, restarts coreaudiod
sudo scripts/recover.sh --purge         # delete instead of quarantine
sudo scripts/recover.sh --reset-prefs   # also reset CoreAudio preferences
sudo scripts/uninstall.sh               # clean uninstall
```

No working Terminal? Boot to Recovery, open Terminal and run
`rm -rf "/Volumes/Macintosh HD/Library/Audio/Plug-Ins/HAL/Conduit"*.driver`, then reboot.

## License

MIT, © 2026 Shivam Himatsingka. Clean-room implementation; no code from BlackHole or other GPL projects.
