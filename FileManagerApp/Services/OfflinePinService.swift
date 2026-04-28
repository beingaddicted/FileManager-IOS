import Foundation
import Observation

// MARK: - Offline Pin Service
//
// "Pin a folder" makes a remote folder available offline. Files are mirrored
// into a local cache folder under `Documents/Pinned/<connection>/<path>`.
// Pins are persisted in JSON so they survive launches.

@Observable
@MainActor
final class OfflinePinService {
    @ObservationIgnored static let shared = OfflinePinService()

    private(set) var pins: [OfflinePin] = []
    private(set) var isSyncing: Bool = false
    private(set) var lastError: String?

    @ObservationIgnored private let pinsKey = "offline_pins_v1"
    @ObservationIgnored private let rootDir: URL

    private init() {
        let docs = FileManager.default.documentsDirectory
        self.rootDir = docs.appendingPathComponent("Pinned", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Public

    func isPinned(connectionId: UUID, path: String) -> Bool {
        pins.contains { $0.connectionId == connectionId && $0.remotePath == path }
    }

    func togglePin(item: FileItem, connection: ServerConnection) {
        if let existing = pins.first(where: { $0.connectionId == connection.id && $0.remotePath == item.path }) {
            removePin(existing)
        } else {
            addPin(item: item, connection: connection)
        }
    }

    func addPin(item: FileItem, connection: ServerConnection) {
        let pin = OfflinePin(
            id: UUID(),
            connectionId: connection.id,
            connectionName: connection.displayName,
            remotePath: item.path,
            displayName: item.name,
            isDirectory: item.isDirectory,
            sizeBytes: item.size,
            lastSyncedAt: nil,
            localPath: localPath(for: connection, remotePath: item.path).path
        )
        pins.append(pin)
        save()
    }

    func removePin(_ pin: OfflinePin) {
        pins.removeAll { $0.id == pin.id }
        try? FileManager.default.removeItem(atPath: pin.localPath)
        save()
    }

    /// Local file URL for a pin.
    func localURL(for pin: OfflinePin) -> URL {
        URL(fileURLWithPath: pin.localPath)
    }

    /// Returns the cached local URL if a pinned file is present and up to date,
    /// else `nil` (caller should fall back to streaming/downloading).
    func cachedURL(for connectionId: UUID, path: String) -> URL? {
        guard let pin = pins.first(where: { $0.connectionId == connectionId && $0.remotePath == path }) else {
            return nil
        }
        let url = URL(fileURLWithPath: pin.localPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Sync

    /// Fetches all pinned items for the supplied provider+connection. Files are
    /// downloaded only if missing locally or if the remote modification date
    /// is newer than the cached copy.
    func sync(connection: ServerConnection, provider: FileProvider) async {
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        let relevant = pins.filter { $0.connectionId == connection.id }
        for pin in relevant {
            do {
                try await syncPin(pin, provider: provider, connection: connection)
            } catch {
                lastError = "\(pin.displayName): \(error.localizedDescription)"
            }
        }
    }

    private func syncPin(_ pin: OfflinePin, provider: FileProvider, connection: ServerConnection) async throws {
        if pin.isDirectory {
            try await syncFolder(remote: pin.remotePath,
                                 local: URL(fileURLWithPath: pin.localPath),
                                 provider: provider)
        } else {
            try await syncFile(remote: pin.remotePath,
                               local: URL(fileURLWithPath: pin.localPath),
                               provider: provider)
        }
        if let i = pins.firstIndex(where: { $0.id == pin.id }) {
            pins[i].lastSyncedAt = Date()
            save()
        }
    }

    private func syncFolder(remote: String, local: URL, provider: FileProvider) async throws {
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let entries = try await provider.listDirectory(at: remote)
        for entry in entries {
            let childLocal = local.appendingPathComponent(entry.name)
            if entry.isDirectory {
                try await syncFolder(remote: entry.path, local: childLocal, provider: provider)
            } else {
                try await syncFile(remote: entry.path, local: childLocal, provider: provider)
            }
        }
    }

    private func syncFile(remote: String, local: URL, provider: FileProvider) async throws {
        // If the file already exists with the same modification date, skip.
        let info = try await provider.getInfo(at: remote)
        if let existing = try? FileManager.default.attributesOfItem(atPath: local.path),
           let mtime = existing[.modificationDate] as? Date,
           abs(mtime.timeIntervalSince(info.modifiedDate)) < 1 {
            return
        }
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = try await provider.downloadToTemp(from: remote, progress: nil)
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: tmp, to: local)
        try? FileManager.default.setAttributes([.modificationDate: info.modifiedDate], ofItemAtPath: local.path)
    }

    // MARK: - Persistence

    private func localPath(for connection: ServerConnection, remotePath: String) -> URL {
        let safe = sanitize(remotePath)
        return rootDir
            .appendingPathComponent(connection.id.uuidString)
            .appendingPathComponent(safe)
    }

    private func sanitize(_ remotePath: String) -> String {
        // Keep slashes for hierarchy, but strip illegal characters.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/.- _"))
        return remotePath.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: pinsKey),
              let decoded = try? JSONDecoder().decode([OfflinePin].self, from: data) else { return }
        pins = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pins) {
            UserDefaults.standard.set(data, forKey: pinsKey)
        }
    }
}

// MARK: - OfflinePin

struct OfflinePin: Identifiable, Codable, Hashable {
    let id: UUID
    let connectionId: UUID
    var connectionName: String
    let remotePath: String
    var displayName: String
    var isDirectory: Bool
    var sizeBytes: Int64
    var lastSyncedAt: Date?
    var localPath: String
}
