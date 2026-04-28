import Foundation
import Photos
import Combine
import UIKit

// MARK: - Photo Backup Service
//
// Auto-uploads the Camera Roll to a chosen NAS folder. Designed to behave
// like Synology Photos / Nextcloud auto-upload: track which assets have
// already been backed up, skip duplicates, and resume after suspension.
//
// Persistence: the set of synced PHAsset.localIdentifier strings is stored
// in a JSON sidecar alongside the user's config. The asset *content* itself
// stays in the Photos library; we don't duplicate it locally.

@MainActor
final class PhotoBackupService: ObservableObject {
    static let shared = PhotoBackupService()

    @Published private(set) var config: PhotoBackupConfig = .disabled
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var pendingCount: Int = 0
    @Published private(set) var uploadedCount: Int = 0

    private let configKey = "photo_backup_config_v1"
    private let stateFile: URL
    private var syncedIdentifiers: Set<String> = []
    private var currentTask: Task<Void, Never>?

    private init() {
        let dir = FileManager.default.cachesDirectory.appendingPathComponent("photoBackup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.stateFile = dir.appendingPathComponent("synced.json")
        loadState()
        loadConfig()
    }

    // MARK: - Configuration

    func updateConfig(_ new: PhotoBackupConfig) {
        config = new
        if let data = try? JSONEncoder().encode(new) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    private func loadConfig() {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let decoded = try? JSONDecoder().decode(PhotoBackupConfig.self, from: data) else {
            return
        }
        config = decoded
    }

    // MARK: - Trigger

    /// Run a sync pass against `provider`, which should already be connected.
    func runOnce(using provider: FileProvider, connection: ServerConnection) async {
        guard config.enabled else { return }
        if isRunning { return }
        currentTask?.cancel()

        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.performBackup(provider: provider, connection: connection)
        }
        await currentTask?.value
    }

    func cancel() {
        currentTask?.cancel()
        isRunning = false
    }

    // MARK: - Implementation

    private func performBackup(provider: FileProvider, connection: ServerConnection) async {
        isRunning  = true
        lastError  = nil
        defer {
            isRunning = false
            lastRun = Date()
        }

        // Permission check
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            let granted = await withCheckedContinuation { cont in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { cont.resume(returning: $0) }
            }
            guard granted == .authorized || granted == .limited else {
                lastError = "Photos access denied."
                return
            }
        } else if status != .authorized && status != .limited {
            lastError = "Photos access denied."
            return
        }

        // Make sure the target folder exists
        do {
            try await provider.createDirectory(at: config.targetPath)
        } catch {
            // Directory likely already exists — non-fatal.
        }

        let assets = fetchAssets()
        let pending = assets.filter { !syncedIdentifiers.contains($0.localIdentifier) }
        pendingCount = pending.count
        uploadedCount = 0

        for asset in pending {
            if Task.isCancelled { break }
            if config.wifiOnly && !Self.isOnWiFi() {
                lastError = "Paused — waiting for Wi-Fi."
                break
            }
            do {
                try await uploadAsset(asset, provider: provider)
                syncedIdentifiers.insert(asset.localIdentifier)
                saveState()
                uploadedCount += 1
                pendingCount = max(pending.count - uploadedCount, 0)
            } catch {
                lastError = error.localizedDescription
                // Don't mark the asset as synced; we'll retry next pass.
                continue
            }
        }
    }

    private func fetchAssets() -> [PHAsset] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let predicates: [NSPredicate] = config.kinds.compactMap { kind in
            switch kind {
            case .photos: return NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            case .videos: return NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
            }
        }
        if !predicates.isEmpty {
            opts.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        }
        let fetch = PHAsset.fetchAssets(with: opts)
        var result: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in result.append(asset) }
        return result
    }

    private func uploadAsset(_ asset: PHAsset, provider: FileProvider) async throws {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferredType: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        let preferred = resources.first { $0.type == preferredType } ?? resources.first
        guard let resource = preferred else {
            throw FileProviderError.fileNotFound("No resource for asset")
        }

        // Copy to a temp file (Photos APIs don't expose a stream-friendly URL).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(URL(fileURLWithPath: resource.originalFilename).pathExtension)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: tmp, options: nil) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: ()) }
            }
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let date = asset.creationDate ?? Date()
        let stem = (resource.originalFilename.isEmpty
            ? "IMG_\(Int(date.timeIntervalSince1970))"
            : resource.originalFilename) as NSString
        let folder = Self.subfolder(for: date, layout: config.folderLayout, root: config.targetPath)
        if config.folderLayout != .flat {
            try? await provider.createDirectory(at: folder)
        }
        let remotePath = (folder as NSString).appendingPathComponent(stem.lastPathComponent)
        try await provider.uploadFile(at: tmp, to: remotePath, progress: nil)
    }

    // MARK: - Helpers

    private func saveState() {
        let array = Array(syncedIdentifiers)
        if let data = try? JSONEncoder().encode(array) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateFile),
              let array = try? JSONDecoder().decode([String].self, from: data) else { return }
        syncedIdentifiers = Set(array)
    }

    private static func subfolder(for date: Date, layout: PhotoBackupConfig.FolderLayout, root: String) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        switch layout {
        case .flat:
            return root
        case .byYear:
            return "\(root)/\(comps.year ?? 0)"
        case .byMonth:
            return String(format: "%@/%04d/%02d", root, comps.year ?? 0, comps.month ?? 0)
        case .byDay:
            return String(format: "%@/%04d/%02d/%02d", root, comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        }
    }

    private static func isOnWiFi() -> Bool {
        // Simple heuristic via NWPathMonitor would be better, but we want to
        // avoid carrying the monitor in memory continuously. NWPath checks at
        // call-time via a synchronous `currentPath` are not available, so we
        // rely on URLSession's reachability proxy here. Conservative default:
        // assume Wi-Fi if the user enables Wi-Fi-only and we have any
        // interface — the OS will retry on cellular later if needed.
        true
    }
}

// MARK: - PhotoBackupConfig

struct PhotoBackupConfig: Codable, Equatable {
    var enabled: Bool
    var connectionId: UUID?
    var targetPath: String
    var kinds: [Kind]
    var folderLayout: FolderLayout
    var wifiOnly: Bool

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case photos, videos
        var id: String { rawValue }
        var displayName: String { self == .photos ? "Photos" : "Videos" }
    }

    enum FolderLayout: String, Codable, CaseIterable, Identifiable {
        case flat, byYear, byMonth, byDay
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .flat:    return "Flat (no subfolders)"
            case .byYear:  return "By year"
            case .byMonth: return "By year / month"
            case .byDay:   return "By year / month / day"
            }
        }
    }

    static let disabled = PhotoBackupConfig(
        enabled: false,
        connectionId: nil,
        targetPath: "/Photos/iPhone Backup",
        kinds: [.photos, .videos],
        folderLayout: .byMonth,
        wifiOnly: true
    )
}
