// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Installs, updates and removes the bundled Conduit audio driver, so a single download is enough.
//
// The driver (Conduit.app/Contents/Resources/Conduit.driver) has to live in /Library/Audio/Plug-Ins/HAL, which is
// root-owned, and Core Audio only scans that folder when coreaudiod starts. We therefore run one short shell script
// with the standard macOS administrator prompt (`do shell script ... with administrator privileges`), which copies the
// bundle, strips the download quarantine flag, fixes ownership and restarts coreaudiod. The app never holds elevated
// rights and installs no helper tool or daemon.
import AppKit
import CryptoKit

enum DriverInstaller {
    static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/Conduit.driver")
    private static let executableName = "Conduit"

    enum Status: Equatable {
        case notBundled                    // a development build run outside the .app: nothing to install
        case notInstalled
        case upToDate
        case outdated(installed: String?)  // installed copy differs from the bundled one (version or binary)

        /// True when the user should be offered an install/update.
        var needsAction: Bool { switch self { case .notInstalled, .outdated: return true; default: return false } }
    }

    enum Failure: LocalizedError {
        case cancelled
        case notBundled
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "The password prompt was cancelled."
            case .notBundled: return "This copy of Conduit does not contain the driver. Download Conduit.app from the GitHub release, or run “make install”."
            case .failed(let m): return m
            }
        }
    }

    // MARK: Inspection
    static var bundledURL: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Conduit.driver"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path) else { return nil }
        return url
    }

    static func version(of driver: URL) -> String? {
        (NSDictionary(contentsOf: driver.appendingPathComponent("Contents/Info.plist")))?["CFBundleShortVersionString"] as? String
    }

    static func executableHash(of driver: URL) -> String? {
        guard let data = try? Data(contentsOf: driver.appendingPathComponent("Contents/MacOS/\(executableName)"), options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func status() -> Status { status(bundled: bundledURL, installed: installedURL) }

    /// Pure function of two paths, so it can be unit-tested with temporary folders.
    static func status(bundled: URL?, installed: URL) -> Status {
        guard let bundled else { return .notBundled }
        guard FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/Info.plist").path) else { return .notInstalled }
        let sameVersion = version(of: bundled) == version(of: installed)
        let sameBinary = executableHash(of: bundled) != nil && executableHash(of: bundled) == executableHash(of: installed)
        return sameVersion && sameBinary ? .upToDate : .outdated(installed: version(of: installed))
    }

    // MARK: Actions
    static func install() async throws {
        guard let src = bundledURL else { throw Failure.notBundled }
        try await runAsAdmin(installScript(source: src, destination: installedURL),
                             prompt: "Conduit needs to install its audio driver. Core Audio will restart, so audio pauses for a moment.")
    }

    static func uninstall() async throws {
        try await runAsAdmin(uninstallScript(destination: installedURL),
                             prompt: "Conduit needs to remove its audio driver. Core Audio will restart, so audio pauses for a moment.")
    }

    // MARK: Scripts (exposed for tests)
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptEscape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

    private static let restartCoreAudio = "/usr/bin/killall coreaudiod 2>/dev/null || /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod || true"

    static func installScript(source: URL, destination: URL) -> String {
        let src = shellQuote(source.path), dst = shellQuote(destination.path), dir = shellQuote(destination.deletingLastPathComponent().path)
        return "set -e; /bin/mkdir -p \(dir); /bin/rm -rf \(dst); /usr/bin/ditto --norsrc --noqtn \(src) \(dst); "
            + "/usr/bin/xattr -dr com.apple.quarantine \(dst) 2>/dev/null || true; "
            + "/usr/sbin/chown -R root:wheel \(dst); /bin/chmod -R go-w \(dst); \(restartCoreAudio)"
    }

    static func uninstallScript(destination: URL) -> String { "/bin/rm -rf \(shellQuote(destination.path)); \(restartCoreAudio)" }

    private static func runAsAdmin(_ command: String, prompt: String) async throws {
        let apple = "do shell script \"\(appleScriptEscape(command))\" with prompt \"\(appleScriptEscape(prompt))\" with administrator privileges"
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process(), err = Pipe()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", apple]
                p.standardError = err; p.standardOutput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(throwing: Failure.failed("\(error)")); return }
                p.waitUntilExit()   // blocks on the user typing their password; this is a background queue
                if p.terminationStatus == 0 { cont.resume(); return }
                let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(throwing: msg.contains("-128") || msg.localizedCaseInsensitiveContains("canceled") ? Failure.cancelled : Failure.failed(msg.isEmpty ? "exit status \(p.terminationStatus)" : msg))
            }
        }
    }
}
