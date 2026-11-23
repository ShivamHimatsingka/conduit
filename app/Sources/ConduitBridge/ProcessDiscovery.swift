// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import AppKit
import CoreAudio
import Darwin

/// One Core Audio client process (an entry of kAudioHardwarePropertyProcessObjectList).
public struct AudioProcess: Sendable, Hashable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let isRunningOutput: Bool
    public let isRunningInput: Bool

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String, isRunningOutput: Bool, isRunningInput: Bool) {
        self.objectID = objectID; self.pid = pid; self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput; self.isRunningInput = isRunningInput
    }
}

/// What a user thinks of as "an app": the GUI application plus all of its helper
/// processes (Chrome renderers, Electron helpers, ...) that talk to Core Audio.
public struct AudioApp: Sendable, Identifiable, Hashable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let pid: pid_t                       // the GUI process
    public let processObjectIDs: [AudioObjectID]
    public let isProducingAudio: Bool

    public init(bundleID: String, name: String, pid: pid_t, processObjectIDs: [AudioObjectID], isProducingAudio: Bool) {
        self.bundleID = bundleID; self.name = name; self.pid = pid
        self.processObjectIDs = processObjectIDs; self.isProducingAudio = isProducingAudio
    }

    /// Icon lookup touches AppKit, so it is main-thread only and kept out of the Sendable model.
    @MainActor public var icon: NSImage? { NSRunningApplication(processIdentifier: pid)?.icon }
}

public enum ProcessDiscovery {
    // MARK: Property helpers
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func scalar<T: BitwiseCopyable>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var addr = address(selector), value = initial, size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var ref: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    // MARK: Enumeration
    /// Every process currently registered with Core Audio.
    public static func processes() -> [AudioProcess] {
        var addr = address(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        let me = getpid()
        return ids.compactMap { id in
            guard let pid: pid_t = scalar(id, kAudioProcessPropertyPID, 0), pid != me else { return nil }
            let out: UInt32 = scalar(id, kAudioProcessPropertyIsRunningOutput, 0) ?? 0
            let inp: UInt32 = scalar(id, kAudioProcessPropertyIsRunningInput, 0) ?? 0
            return AudioProcess(objectID: id, pid: pid, bundleID: string(id, kAudioProcessPropertyBundleID) ?? "",
                                isRunningOutput: out != 0, isRunningInput: inp != 0)
        }
    }

    /// Core Audio processes grouped by owning application, sorted audible-first then by name.
    public static func apps() -> [AudioApp] {
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        var byPID: [pid_t: NSRunningApplication] = [:]
        for app in regular { byPID[app.processIdentifier] = app }

        var groups: [String: (app: NSRunningApplication, procs: [AudioProcess])] = [:]
        for p in processes() {
            guard let owner = owningApp(of: p, byPID: byPID, regular: regular), let bid = owner.bundleIdentifier else { continue }
            groups[bid, default: (owner, [])].procs.append(p)
        }
        return groups.map { bid, g in
            AudioApp(bundleID: bid, name: g.app.localizedName ?? bid, pid: g.app.processIdentifier,
                     processObjectIDs: g.procs.map(\.objectID), isProducingAudio: g.procs.contains { $0.isRunningOutput })
        }.sorted { ($0.isProducingAudio ? 0 : 1, $0.name.lowercased()) < ($1.isProducingAudio ? 0 : 1, $1.name.lowercased()) }
    }

    /// Finds an app by bundle identifier, case-insensitive name, or pid.
    public static func app(matching query: String) -> AudioApp? {
        let all = apps(), q = query.lowercased()
        if let pid = pid_t(query), let hit = all.first(where: { $0.pid == pid || $0.processObjectIDs.contains { oid in processes().first { $0.objectID == oid }?.pid == pid } }) { return hit }
        return all.first { $0.bundleID.lowercased() == q } ?? all.first { $0.name.lowercased() == q } ?? all.first { $0.name.lowercased().contains(q) }
    }

    // MARK: Owner resolution
    /// Helper processes (Chrome Helper, Electron renderers, XPC services) are mapped to their GUI app by
    /// walking the parent-process chain, then by bundle-id prefix as a fallback.
    private static func owningApp(of p: AudioProcess, byPID: [pid_t: NSRunningApplication], regular: [NSRunningApplication]) -> NSRunningApplication? {
        var pid = p.pid
        for _ in 0..<8 {
            if let app = byPID[pid] { return app }
            guard let parent = parentPID(of: pid), parent > 1 else { break }
            pid = parent
        }
        guard !p.bundleID.isEmpty else { return nil }
        return regular.filter { p.bundleID.hasPrefix($0.bundleIdentifier! + ".") }
            .max { $0.bundleIdentifier!.count < $1.bundleIdentifier!.count }
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

/// Calls `onChange` whenever a process appears in or leaves Core Audio's process list.
/// (Per-process "is playing" state changes are cheap to poll via `ProcessDiscovery.apps()`.)
public final class ProcessMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "conduit.process-monitor")
    private var listener: AudioObjectPropertyListenerBlock?
    private var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    public init(onChange: @escaping @Sendable () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
    }

    deinit {
        if let listener { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener) }
    }
}
