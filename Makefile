# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Shivam Himatsingka
#
# Conduit HAL driver build.   make help   for targets.
#
# Every device property is overridable, so several differently-shaped virtual
# devices can coexist, e.g.:
#   make CHANNELS=2 DEVICE_NAME="Conduit 2ch" DEVICE_UID=com.conduit.driver.device.2ch \
#        BUNDLE_ID=com.conduit.driver.2ch FACTORY_UUID=$(uuidgen) DRIVER_NAME=Conduit2ch

CHANNELS      ?= 16
DEVICE_NAME   ?= Conduit $(CHANNELS)ch
DEVICE_UID    ?= com.conduit.driver.device.$(CHANNELS)ch
MODEL_UID     ?= com.conduit.driver.model
MANUFACTURER  ?= Conduit Audio
BUNDLE_ID     ?= com.conduit.driver
MACH_SERVICE  ?= $(BUNDLE_ID).ipc
DRIVER_NAME   ?= Conduit
VERSION       ?= 0.0.2
FACTORY_UUID  ?= DFC5549D-39B8-42EF-8A6A-A2496570C2BB
# "-" = ad-hoc. For distribution: SIGN_IDENTITY="Developer ID Application: ..." SIGN_FLAGS="--timestamp --options runtime"
# (scripts/build_release.sh does this). The driver needs no entitlements.
SIGN_IDENTITY ?= -
SIGN_FLAGS    ?= --timestamp=none
MIN_MACOS     ?= 14.4
ARCHS         ?= arm64 x86_64

BUILD_DIR   := build
BUNDLE      := $(BUILD_DIR)/$(DRIVER_NAME).driver
EXECUTABLE  := $(BUNDLE)/Contents/MacOS/$(DRIVER_NAME)
INSTALL_DIR := /Library/Audio/Plug-Ins/HAL
SRC         := $(wildcard driver/src/*.cpp)
HDR         := $(wildcard driver/src/*.hpp shared/include/*.h)

ARCH_FLAGS := $(foreach a,$(ARCHS),-arch $(a))
CXXFLAGS   := -std=c++20 -O3 -Wall -Wextra -Wpedantic -Werror \
              -Ishared/include -fno-exceptions -fno-rtti -fvisibility=hidden -fvisibility-inlines-hidden \
              -mmacosx-version-min=$(MIN_MACOS) $(ARCH_FLAGS) \
              -DCONDUIT_CHANNELS=$(CHANNELS) \
              '-DCONDUIT_DEVICE_NAME="$(DEVICE_NAME)"' \
              '-DCONDUIT_DEVICE_UID="$(DEVICE_UID)"' \
              '-DCONDUIT_MODEL_UID="$(MODEL_UID)"' \
              '-DCONDUIT_MANUFACTURER="$(MANUFACTURER)"' \
              '-DCONDUIT_MACH_SERVICE="$(MACH_SERVICE)"'
LDFLAGS    := -bundle -lbsm -framework CoreFoundation -framework CoreAudio \
              -mmacosx-version-min=$(MIN_MACOS) $(ARCH_FLAGS)

.PHONY: all build sign verify install uninstall restart-coreaudiod test test-ipc test-tap test-bench test-app test-live test-all app bundle clean help

all: build

build: $(EXECUTABLE) $(BUNDLE)/Contents/Info.plist sign

$(EXECUTABLE): $(SRC) $(HDR) Makefile
	@mkdir -p $(dir $@)
	clang++ $(CXXFLAGS) $(SRC) $(LDFLAGS) -o $@

$(BUNDLE)/Contents/Info.plist: driver/Info.plist.in Makefile
	@mkdir -p $(dir $@)
	sed -e 's|@EXECUTABLE@|$(DRIVER_NAME)|g' \
	    -e 's|@BUNDLE_ID@|$(BUNDLE_ID)|g' \
	    -e 's|@DEVICE_NAME@|$(DEVICE_NAME)|g' \
	    -e 's|@VERSION@|$(VERSION)|g' \
	    -e 's|@MACH_SERVICE@|$(MACH_SERVICE)|g' \
	    -e 's|@FACTORY_UUID@|$(FACTORY_UUID)|g' $< > $@
	plutil -lint $@

sign: $(EXECUTABLE) $(BUNDLE)/Contents/Info.plist
	codesign --force --sign "$(SIGN_IDENTITY)" $(SIGN_FLAGS) $(BUNDLE)
	@$(MAKE) --no-print-directory verify

verify:
	@plutil -lint $(BUNDLE)/Contents/Info.plist >/dev/null
	@lipo -info $(EXECUTABLE)
	@file $(EXECUTABLE) | grep -q "bundle" || { echo "not a Mach-O bundle"; exit 1; }
	@codesign --verify --strict --verbose=1 $(BUNDLE)
	@echo "OK: $(BUNDLE)"

install: build
	@echo "==> Installing $(DRIVER_NAME).driver to $(INSTALL_DIR) (sudo required)"
	sudo mkdir -p $(INSTALL_DIR)
	sudo rm -rf "$(INSTALL_DIR)/$(DRIVER_NAME).driver"
	sudo ditto $(BUNDLE) "$(INSTALL_DIR)/$(DRIVER_NAME).driver"
	sudo chown -R root:wheel "$(INSTALL_DIR)/$(DRIVER_NAME).driver"
	@$(MAKE) --no-print-directory restart-coreaudiod
	@echo "==> Installed. Select \"$(DEVICE_NAME)\" in System Settings > Sound or Audio MIDI Setup."

uninstall:
	sudo rm -rf "$(INSTALL_DIR)/$(DRIVER_NAME).driver"
	@$(MAKE) --no-print-directory restart-coreaudiod

# killall makes launchd respawn coreaudiod immediately; kickstart is the fallback.
restart-coreaudiod:
	@echo "==> Restarting coreaudiod (audio will drop out for a moment)"
	sudo killall coreaudiod 2>/dev/null || sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
	@sleep 2

# Host-side tests: ring buffer stress test + driver harness (no sudo, no coreaudiod).
test: build
	@mkdir -p $(BUILD_DIR)
	clang++ -std=c++20 -O2 -g -Wall -Wextra -pthread -Idriver/src -Ishared/include tests/ring_test.cpp -o $(BUILD_DIR)/ring_test
	$(BUILD_DIR)/ring_test
	clang++ -std=c++20 -O2 -g -Wall -Wextra -framework CoreFoundation -framework CoreAudio \
	    -Ishared/include -DCONDUIT_CHANNELS=$(CHANNELS) tests/driver_harness.cpp -o $(BUILD_DIR)/driver_harness
	$(BUILD_DIR)/driver_harness $(EXECUTABLE)

app:
	swift build -c release

# Cross-process Phase 2 test: driver host process + Swift client over Mach IPC (no sudo).
test-ipc: build app
	clang++ -std=c++20 -O2 -Wall -Wextra -framework CoreFoundation -framework CoreAudio \
	    -DCONDUIT_CHANNELS=$(CHANNELS) tests/driver_host.cpp -o $(BUILD_DIR)/driver_host
	tests/ipc_e2e.sh

# Drives the real IOProc with synthetic aggregate buffers against a real shared region.
test-tap:
	@mkdir -p $(BUILD_DIR)
	cc -std=c11 -O2 -Wall -Wextra -Ishared/include tests/tap_engine_test.c shared/conduit_tap_engine.c \
	    -framework CoreAudio -o $(BUILD_DIR)/tap_engine_test
	$(BUILD_DIR)/tap_engine_test

# Builds build/Conduit.app (universal, hardened runtime, ad-hoc signed by default).
bundle:
	scripts/make_app.sh

# UI/metering/preset tests, including per-frame CPU cost. Runs the real code with demo data.
test-app: app
	.build/release/Conduit --selftest

# Offline latency/drift characterisation: real driver binary + real tap engine on a simulated HAL schedule.
test-bench: build
	@mkdir -p $(BUILD_DIR)
	cc -std=c11 -O2 -Wall -Wextra -Ishared/include -c shared/conduit_bench.c -o $(BUILD_DIR)/conduit_bench.o
	cc -std=c11 -O2 -Wall -Wextra -Ishared/include -c shared/conduit_tap_engine.c -o $(BUILD_DIR)/conduit_tap_engine.o
	clang++ -std=c++20 -O2 -Wall -Wextra -Ishared/include tests/bench_offline.cpp $(BUILD_DIR)/conduit_bench.o $(BUILD_DIR)/conduit_tap_engine.o \
	    -framework CoreFoundation -framework CoreAudio -o $(BUILD_DIR)/bench_offline
	$(BUILD_DIR)/bench_offline $(EXECUTABLE)

# End-to-end against the INSTALLED driver and a real playing app (needs `make install` and the Audio Capture permission).
test-live: app
	.build/release/Conduit --livetest
	@mkdir -p $(BUILD_DIR)/ui && .build/release/Conduit --uitest $(BUILD_DIR)/ui

test-all: test test-tap test-bench test-ipc test-app

clean:
	rm -rf $(BUILD_DIR) .build

help:
	@echo "make [build]      compile universal $(DRIVER_NAME).driver + ad-hoc sign"
	@echo "make install      build, copy to $(INSTALL_DIR), restart coreaudiod (sudo)"
	@echo "make uninstall    remove driver, restart coreaudiod (sudo)"
	@echo "make test         run ring-buffer stress test and in-process driver harness"
	@echo "make app          build the Swift bridge + conduitctl (swift build)"
	@echo "make test-bench   offline latency / injection-budget / drift characterisation"
	@echo "make pkg          installer package (see docs/RELEASING.md)"
	@echo "make test-tap     tap engine (routing/gain/latency/resync) unit test"
	@echo "make bundle        build the menu-bar app: build/Conduit.app"
	@echo "make test-live    end-to-end with the installed driver: real app audio, real mouse events on the UI"
	@echo "make test-app     app self-test (vDSP metering, FFT calibration, presets, CPU cost)"
	@echo "make test-ipc     cross-process Mach IPC / shared-memory end-to-end test"
	@echo "scripts/recover.sh   emergency removal of ALL Conduit drivers"

# Distributable installer (unsigned unless APP_SIGN_IDENTITY / INSTALLER_SIGN_IDENTITY are set). See docs/RELEASING.md.
.PHONY: pkg
pkg:
	scripts/build_release.sh
