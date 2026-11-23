// swift-tools-version:6.0
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import PackageDescription

let package = Package(
    name: "Conduit",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "ConduitBridge", targets: ["ConduitBridge"]),
        .executable(name: "conduitctl", targets: ["conduitctl"]),
        .executable(name: "Conduit", targets: ["Conduit"]),
        .executable(name: "conduit-bench", targets: ["conduit-bench"]),
    ],
    targets: [
        // Shared C layout + ring + Mach client; the very same headers the driver compiles.
        .target(name: "CConduit", path: "shared", sources: ["conduit_client.c", "conduit_tap_engine.c", "conduit_bench.c"], publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "ConduitBridge", dependencies: ["CConduit"], path: "app/Sources/ConduitBridge"),
        .executableTarget(name: "conduitctl", dependencies: ["ConduitBridge"], path: "app/Sources/conduitctl"),
        .executableTarget(name: "conduit-bench", dependencies: ["ConduitBridge"], path: "app/Sources/conduit-bench"),
        .executableTarget(name: "Conduit", dependencies: ["ConduitBridge"], path: "app/Sources/ConduitApp"),
    ]
)
