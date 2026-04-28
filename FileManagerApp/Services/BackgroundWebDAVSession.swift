import Foundation
import UIKit

// MARK: - Background WebDAV Session
//
// One process-wide `URLSession` configured with `.background(withIdentifier:)`
// so HTTP-based transfers (WebDAV) keep running while the app is suspended,
// and *resume across launches* if iOS terminates the app mid-transfer.
//
// Plumbing model:
//
//   1. `BackgroundTransferService` calls `enqueueDownload`/`enqueueUpload`
//      with an authorised `URLRequest` and the `TransferRecord.id`.
//   2. We persist `URLSessionTask.taskIdentifier → recordId` so progress
//      and completion callbacks find the right record after a relaunch.
//   3. iOS hands us `urlSessionDidFinishEvents(forBackgroundURLSession:)`
//      to call when our delegate has finished consuming all queued events
//      from a relaunched background session. The `AppDelegate` parks the
//      OS-supplied completion handler here; we invoke it once the queue is
//      drained so iOS can put us back to sleep.
//
// SFTP and SMB cannot use this — libssh2 and libsmb2 keep their own sockets
// and iOS can't keep them open in the background. Those providers run on a
// brief `UIApplication.beginBackgroundTask` lease (~30 s) and the user has
// to keep the app foregrounded for a long backup. WebDAV gets the real
// background treatment.

final class BackgroundWebDAVSession: NSObject {
    static let shared = BackgroundWebDAVSession()

    private static let sessionIdentifier = "app.filemanager.webdav.background"
    private static let mappingKey = "bgwebdav_task_to_record_v1"

    /// Set by the AppDelegate when iOS resumes us in the background to deliver
    /// a finished transfer. We invoke it once `urlSessionDidFinishEvents` runs.
    var pendingSystemCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary           = false
        config.sessionSendsLaunchEvents  = true
        config.allowsCellularAccess      = true
        config.httpMaximumConnectionsPerHost = 6
        // 1 hour per request; daemon will retry as appropriate.
        config.timeoutIntervalForRequest  = 60
        config.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Lock-protected `taskIdentifier → recordId` map. Persisted to disk so
    /// completions survive app relaunches.
    private let mapLock = NSLock()
    private var taskToRecord: [Int: UUID] = [:]
    /// Where the user wants downloads to land. Keyed by record id.
    private var downloadDestinationFolder: [UUID: URL] = [:]
    /// Last reported progress, keyed by record id, so we don't spam the
    /// `BackgroundTransferService` on every byte of an HLS-style playlist.
    private var lastProgressReportAt: [UUID: Date] = [:]

    private override init() {
        super.init()
        loadMapping()
        // Force `session` to materialise so the URLSession exists and any
        // pending background events get delivered.
        _ = session
    }

    // MARK: - Public API

    func enqueueDownload(request: URLRequest, recordId: UUID, destinationFolder: URL?) {
        let task = session.downloadTask(with: request)
        track(task: task, recordId: recordId, destinationFolder: destinationFolder)
        task.resume()
    }

    func enqueueUpload(request: URLRequest, fromFile localURL: URL, recordId: UUID) {
        let task = session.uploadTask(with: request, fromFile: localURL)
        track(task: task, recordId: recordId, destinationFolder: nil)
        task.resume()
    }

    func cancel(recordId: UUID) {
        session.getAllTasks { tasks in
            for task in tasks {
                if let id = self.recordId(for: task.taskIdentifier), id == recordId {
                    task.cancel()
                }
            }
        }
    }

    // MARK: - Mapping helpers

    private func track(task: URLSessionTask, recordId: UUID, destinationFolder: URL?) {
        mapLock.lock()
        taskToRecord[task.taskIdentifier] = recordId
        if let folder = destinationFolder {
            downloadDestinationFolder[recordId] = folder
        }
        mapLock.unlock()
        saveMapping()
    }

    private func recordId(for taskIdentifier: Int) -> UUID? {
        mapLock.lock(); defer { mapLock.unlock() }
        return taskToRecord[taskIdentifier]
    }

    private func untrack(taskIdentifier: Int) -> UUID? {
        mapLock.lock()
        let id = taskToRecord.removeValue(forKey: taskIdentifier)
        if let id { downloadDestinationFolder.removeValue(forKey: id) }
        mapLock.unlock()
        saveMapping()
        return id
    }

    private func saveMapping() {
        // Snapshot under the lock, write outside.
        mapLock.lock()
        let snapshot: [String: String] = taskToRecord.reduce(into: [:]) {
            $0["\($1.key)"] = $1.value.uuidString
        }
        let folderSnapshot: [String: String] = downloadDestinationFolder.reduce(into: [:]) {
            $0[$1.key.uuidString] = $1.value.path
        }
        mapLock.unlock()

        let payload: [String: Any] = [
            "tasks": snapshot,
            "folders": folderSnapshot
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            UserDefaults.standard.set(data, forKey: Self.mappingKey)
        }
    }

    private func loadMapping() {
        guard let data = UserDefaults.standard.data(forKey: Self.mappingKey),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let tasks = payload["tasks"] as? [String: String] {
            for (taskIdStr, recordIdStr) in tasks {
                if let taskId = Int(taskIdStr), let recordId = UUID(uuidString: recordIdStr) {
                    taskToRecord[taskId] = recordId
                }
            }
        }
        if let folders = payload["folders"] as? [String: String] {
            for (recordIdStr, path) in folders {
                if let recordId = UUID(uuidString: recordIdStr) {
                    downloadDestinationFolder[recordId] = URL(fileURLWithPath: path)
                }
            }
        }
    }
}

// MARK: - Delegate

extension BackgroundWebDAVSession: URLSessionDownloadDelegate, URLSessionTaskDelegate {

    // Download progress
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0,
              let recordId = recordId(for: downloadTask.taskIdentifier) else { return }
        // Throttle progress updates to ~10/s; a background download can fire
        // hundreds of these per second on a fast LAN.
        if !shouldReportProgress(for: recordId) { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            BackgroundTransferService.shared.updateProgress(recordId: recordId, fraction: fraction)
        }
    }

    // Download finished (file is at `location`, valid only inside this delegate call)
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let recordId = recordId(for: downloadTask.taskIdentifier) else { return }
        // Move the system-temp file to a stable location synchronously inside
        // the delegate callback — `location` is reaped immediately after.
        mapLock.lock()
        let folder = downloadDestinationFolder[recordId]
        mapLock.unlock()
        let destination = stageDownloadedFile(at: location, folder: folder, recordId: recordId)

        Task { @MainActor in
            BackgroundTransferService.shared.completeDownload(
                recordId: recordId,
                localURL: destination
            )
        }
    }

    // Upload progress
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0,
              let recordId = recordId(for: task.taskIdentifier) else { return }
        if !shouldReportProgress(for: recordId) { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor in
            BackgroundTransferService.shared.updateProgress(recordId: recordId, fraction: fraction)
        }
    }

    // Final completion (success or failure)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let recordId = untrack(taskIdentifier: task.taskIdentifier) else { return }
        let httpStatus = (task.response as? HTTPURLResponse)?.statusCode ?? 0

        Task { @MainActor in
            if let error = error {
                BackgroundTransferService.shared.failTransfer(
                    recordId: recordId,
                    message: error.localizedDescription
                )
            } else if httpStatus >= 400 {
                BackgroundTransferService.shared.failTransfer(
                    recordId: recordId,
                    message: "HTTP \(httpStatus)"
                )
            } else if task is URLSessionUploadTask {
                BackgroundTransferService.shared.completeUpload(recordId: recordId)
            }
            // For downloads, completion was already announced in
            // didFinishDownloadingTo.
        }
    }

    // Background session relaunched and we've delivered all events.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let handler = self.pendingSystemCompletionHandler
            self.pendingSystemCompletionHandler = nil
            handler?()
        }
    }

    // MARK: - Helpers

    private func shouldReportProgress(for recordId: UUID) -> Bool {
        mapLock.lock(); defer { mapLock.unlock() }
        let now = Date()
        if let last = lastProgressReportAt[recordId], now.timeIntervalSince(last) < 0.1 {
            return false
        }
        lastProgressReportAt[recordId] = now
        return true
    }

    private func stageDownloadedFile(at tempURL: URL, folder: URL?, recordId: UUID) -> URL {
        let fm = FileManager.default
        // Prefer the user-specified folder; fall back to Documents/Downloads.
        let targetDir: URL = folder
            ?? fm.documentsDirectory.appendingPathComponent("Downloads", isDirectory: true)
        try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        // Use the suggested filename from the response if available; otherwise
        // make one up from the record id (the real filename gets patched into
        // the TransferRecord by completeDownload).
        let suggested = (tempURL.lastPathComponent.isEmpty ? recordId.uuidString : tempURL.lastPathComponent)
        let target = uniqueURL(in: targetDir, name: suggested)

        do {
            try? fm.removeItem(at: target)
            try fm.moveItem(at: tempURL, to: target)
        } catch {
            // Last-resort: read+write so we don't lose the bytes.
            if let data = try? Data(contentsOf: tempURL) {
                try? data.write(to: target, options: .atomic)
            }
        }
        return target
    }

    private func uniqueURL(in dir: URL, name: String) -> URL {
        let initial = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: initial.path) { return initial }
        let stem = initial.deletingPathExtension().lastPathComponent
        let ext  = initial.pathExtension
        for i in 2...500 {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent("\(stem)-\(UUID().uuidString)")
    }
}
