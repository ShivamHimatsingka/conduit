// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import Foundation

/// Per-source routing, keyed by a stable id: "app:<bundle id>" or "mic:<device uid>".
struct SourceRouting: Codable, Equatable {
    var enabled = false
    var gainDB: Float = 0
    var mute = false
    var mono = false
    var silenceOriginal = false
    /// Stereo bus pairs (0 = channels 1-2, 1 = channels 3-4, ...) this source feeds.
    var pairs: [Int] = []
}

struct BusSettings: Codable, Equatable {
    var gainDB: Float = 0
    var mute = false
}

/// A saved mixer state. Plain JSON, human-editable, stable across versions via `version`.
struct Preset: Codable, Equatable {
    var version = 1
    var name: String
    var sources: [String: SourceRouting]
    var buses: [BusSettings]
}

enum PresetStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Conduit/Presets", isDirectory: true)
    }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func fileName(for name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "Untitled" : cleaned) + ".json"
    }

    static func list() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    @discardableResult
    static func save(_ preset: Preset) throws -> URL {
        try ensureDirectory()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = directory.appendingPathComponent(fileName(for: preset.name))
        try enc.encode(preset).write(to: url, options: .atomic)
        return url
    }

    static func load(name: String) throws -> Preset { try load(url: directory.appendingPathComponent(fileName(for: name))) }

    static func load(url: URL) throws -> Preset {
        let preset = try JSONDecoder().decode(Preset.self, from: Data(contentsOf: url))
        guard preset.version == 1 else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Unsupported preset version \(preset.version)"]) }
        return preset
    }

    static func delete(name: String) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(fileName(for: name)))
    }
}
