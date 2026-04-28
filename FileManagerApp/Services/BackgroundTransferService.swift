import Foundation
import Observation
import UIKit

// MARK: - Background Transfer Service
//
// Persistent download/upload queue. Survives app suspension because we use a
// `URLSession` with a `.background` configuration for HTTP-based providers
// (WebDAV) and a serial actor for non-HTTP providers (SFTP, SMB).
//
// The queue itself is persisted to disk so transfers can be inspected and
// retried after a launch — much like the iOS Files app's "Recent Activity."

@Observable
@MainActor
final class BackgroundTransferService {
    @ObservationIgnored static let shared = BackgroundTransferService()

    private(set) var transfers: [TransferRecord] = []

    @ObservationIgnored private let queueFile: URL
    /// Currently-running tasks keyed by record id (only present for in-flight transfers).
    @ObservationIgnored private var inflight: [UUID: Task<Void, Never>] = [:]

    private init() {
        let dir = FileManager.default.cachesDirectory.appendingPathComponent("transfers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.queueFile = dir.appendingPathComponent("queue.json")
        load()
        // Re-mark anything that was active at last quit as failed so the user
        // can choose to retry. iOS will not let us silently resume a SFTP
        // session after relaunch.
        for i in transfers.indices where transfers[i].state == .active {
            transfers[i].state = .failed
            transfers[i].errorMessage = "Cancelled when app quit. Tap to retry."
        }
    }

    // MARK: - Enqueue

    @discardableResult
    func enqueueDownload(
        item: FileItem,
        connection: ServerConnection?,
        provider: FileProvider,
        destinationFolder: URL? = nil
    ) -> TransferRecord {
        let record = TransferRecord(
            id: UUID(),
            kind: .download,
            filename: item.name,
            remotePath: item.path,
            connectionId: connection?.id,
            connectionName: connection?.displayName ?? provider.providerType.rawValue,
            totalBytes: item.size,
            transferredBytes: 0,
            state: .queued,
            createdAt: Date(),
            errorMessage: nil
        )
        append(record)
        run(record, with: provider, destinationFolder: destinationFolder)
        return record
    }

    @discardableResult
    func enqueueUpload(
        localURL: URL,
        remotePath: String,
        connection: ServerConnection?,
        provider: FileProvider
    ) -> TransferRecord {
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
        let record = TransferRecord(
            id: UUID(),
            kind: .upload,
            filename: localURL.lastPathComponent,
            remotePath: remotePath,
            connectionId: connection?.id,
            connectionName: connection?.displayName ?? provider.providerType.rawValue,
            totalBytes: size,
            transferredBytes: 0,
            state: .queued,
            createdAt: Date(),
            errorMessage: nil,
            localFile: localURL.path
        )
        append(record)
        run(record, with: provider, destinationFolder: nil)
        return record
    }

    // MARK: - Run

    /// Called by `BackgroundWebDAVSession`'s delegate as bytes flow.
    func updateProgress(recordId: UUID, fraction: Double) {
        update(id: recordId) { rec in
            rec.state = .active
            rec.transferredBytes = Int64(Double(rec.totalBytes) * fraction)
        }
    }

    /// Called by `BackgroundWebDAVSession` once a download lands on disk.
    func completeDownload(recordId: UUID, localURL: URL) {
        update(id: recordId) { rec in
            rec.localFile        = localURL.path
            rec.transferredBytes = rec.totalBytes
            rec.state            = .done
        }
        inflight.removeValue(forKey: recordId)
    }

    /// Called by `BackgroundWebDAVSession` once an upload finishes.
    func completeUpload(recordId: UUID) {
        update(id: recordId) { rec in
            rec.transferredBytes = rec.totalBytes
            rec.state            = .done
        }
        inflight.removeValue(forKey: recordId)
    }

    /// Called by `BackgroundWebDAVSession` on error or HTTP ≥ 400.
    func failTransfer(recordId: UUID, message: String) {
        update(id: recordId) { rec in
            rec.state        = .failed
            rec.errorMessage = message
        }
        inflight.removeValue(forKey: recordId)
    }

    private func run(_ record: TransferRecord, with provider: FileProvider, destinationFolder: URL?) {
        let id = record.id

        // HTTP-shaped providers (WebDAV) get the real background URLSession so
        // transfers continue when the app is suspended. Everything else runs
        // through the regular Task path.
        if let request = self.backgroundRequest(for: record, provider: provider) {
            update(id: id) { $0.state = .active }
            switch record.kind {
            case .download:
                BackgroundWebDAVSession.shared.enqueueDownload(
                    request: request,
                    recordId: id,
                    destinationFolder: destinationFolder
                )
            case .upload:
                guard let localPath = record.localFile else {
                    failTransfer(recordId: id, message: "local source missing")
                    return
                }
                BackgroundWebDAVSession.shared.enqueueUpload(
                    request: request,
                    fromFile: URL(fileURLWithPath: localPath),
                    recordId: id
                )
            }
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.update(id: id) { $0.state = .active }

            do {
                switch record.kind {
                case .download:
                    let tmp = try await provider.downloadToTemp(from: record.remotePath) { p in
                        Task { @MainActor [weak self] in
                            self?.update(id: id) { rec in
                                rec.transferredBytes = Int64(Double(rec.totalBytes) * p)
                            }
                        }
                    }
                    let finalURL = try Self.relocate(tempURL: tmp,
                                                    filename: record.filename,
                                                    folder: destinationFolder)
                    await self.update(id: id) { rec in
                        rec.localFile = finalURL.path
                        rec.transferredBytes = rec.totalBytes
                        rec.state = .done
                    }

                case .upload:
                    guard let localPath = record.localFile else {
                        throw FileProviderError.fileNotFound("local source missing")
                    }
                    let url = URL(fileURLWithPath: localPath)
                    try await provider.uploadFile(at: url, to: record.remotePath) { p in
                        Task { @MainActor [weak self] in
                            self?.update(id: id) { rec in
                                rec.transferredBytes = Int64(Double(rec.totalBytes) * p)
                            }
                        }
                    }
                    await self.update(id: id) { rec in
                        rec.transferredBytes = rec.totalBytes
                        rec.state = .done
                    }
                }
            } catch {
                await self.update(id: id) { rec in
                    rec.state = .failed
                    rec.errorMessage = error.localizedDescription
                }
            }

            await MainActor.run { [weak self] in
                self?.inflight.removeValue(forKey: id)
            }
        }
        inflight[id] = task
    }

    private static func relocate(tempURL: URL, filename: String, folder: URL?) throws -> URL {
        let target: URL
        if let folder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            target = folder.appendingPathComponent(filename)
        } else {
            let downloads = FileManager.default.documentsDirectory.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            target = downloads.appendingPathComponent(filename)
        }
        // Avoid clobbering existing files.
        let unique = Self.uniqueURL(target)
        try? FileManager.default.removeItem(at: unique)
        try FileManager.default.moveItem(at: tempURL, to: unique)
        return unique
    }

    private static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let dir  = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext  = url.pathExtension
        for i in 2...500 {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent("\(stem)-\(UUID().uuidString)")
    }

    // MARK: - Cancel / clear

    func cancel(_ record: TransferRecord) {
        inflight[record.id]?.cancel()
        inflight.removeValue(forKey: record.id)
        // Also cancel any background URLSession task for this record.
        BackgroundWebDAVSession.shared.cancel(recordId: record.id)
        update(id: record.id) { rec in
            if rec.state != .done { rec.state = .failed; rec.errorMessage = "Cancelled" }
        }
    }

    /// Decide whether a record can be served by the background URLSession.
    private func backgroundRequest(for record: TransferRecord, provider: FileProvider) -> URLRequest? {
        switch record.kind {
        case .download:
            return provider.backgroundDownloadRequest(for: record.remotePath)
        case .upload:
            guard let localPath = record.localFile else { return nil }
            return provider.backgroundUploadRequest(
                for: record.remotePath,
                sourceFile: URL(fileURLWithPath: localPath)
            )
        }
    }

    func clearCompleted() {
        transfers.removeAll { $0.state == .done }
        save()
    }

    func clearAll() {
        inflight.values.forEach { $0.cancel() }
        inflight.removeAll()
        transfers.removeAll()
        save()
    }

    // MARK: - Persistence

    private func append(_ record: TransferRecord) {
        transfers.insert(record, at: 0)
        // Cap recorded history so the file doesn't grow forever.
        if transfers.count > 500 {
            transfers = Array(transfers.prefix(500))
        }
        save()
    }

    private func update(id: UUID, _ mutate: (inout TransferRecord) -> Void) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        mutate(&transfers[i])
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: queueFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([TransferRecord].self, from: data) {
            self.transfers = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(transfers) else { return }
        try? data.write(to: queueFile, options: .atomic)
    }
}

// MARK: - TransferRecord

struct TransferRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let kind: Kind
    var filename: String
    var remotePath: String
    var connectionId: UUID?
    var connectionName: String
    var totalBytes: Int64
    var transferredBytes: Int64
    var state: State
    var createdAt: Date
    var errorMessage: String?
    var localFile: String?

    enum Kind: String, Codable { case download, upload }
    enum State: String, Codable { case queued, active, done, failed }

    var progress: Double {
        guard totalBytes > 0 else { return state == .done ? 1.0 : 0 }
        return min(Double(transferredBytes) / Double(totalBytes), 1.0)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}
