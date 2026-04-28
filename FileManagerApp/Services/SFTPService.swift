import Foundation
import NMSSH

// MARK: - SFTP Service
//
// Real SFTP over libssh2 via NMSSH (https://github.com/NMSSH/NMSSH, BSD).
// NMSSH is Objective-C; we wrap each call in a `Task.detached` so the Swift
// concurrency model doesn't pin libssh2's blocking sockets to the main thread.

final class SFTPService: FileProvider {
    let providerType: ProviderType = .sftp
    private(set) var isConnected: Bool = false

    private let connection: ServerConnection
    private var password: String { KeychainHelper.shared.password(for: connection) }

    /// All NMSSH calls happen on this serial queue. libssh2 is not thread-safe
    /// across a single session, so we serialize everything here.
    private let queue = DispatchQueue(label: "sftp.session.\(UUID().uuidString)")
    private var session: NMSSHSession?
    private var sftp: NMSFTP?

    init(connection: ServerConnection) {
        self.connection = connection
    }

    deinit {
        sftp?.disconnect()
        session?.disconnect()
    }

    // MARK: - Connect

    func connect() async throws {
        let host = connection.host
        let port = connection.port
        let user = connection.username
        let pwd  = password

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                let session = NMSSHSession(host: host, port: port, andUsername: user)
                session.connect()
                guard session.isConnected else {
                    cont.resume(throwing: FileProviderError.networkError("Could not reach \(host):\(port)"))
                    return
                }
                session.authenticate(byPassword: pwd)
                guard session.isAuthorized else {
                    session.disconnect()
                    cont.resume(throwing: FileProviderError.authenticationFailed("Bad username or password"))
                    return
                }
                let sftp = NMSFTP(session: session)
                sftp.connect()
                guard sftp.isConnected else {
                    session.disconnect()
                    cont.resume(throwing: FileProviderError.networkError("SFTP subsystem unavailable"))
                    return
                }
                self.session = session
                self.sftp    = sftp
                self.isConnected = true
                cont.resume(returning: ())
            }
        }
    }

    func disconnect() {
        queue.sync {
            sftp?.disconnect()
            session?.disconnect()
            sftp = nil
            session = nil
            isConnected = false
        }
    }

    // MARK: - List

    func listDirectory(at path: String) async throws -> [FileItem] {
        let resolved = resolvePath(path)
        return try await onQueue { sftp in
            guard let entries = sftp.contentsOfDirectory(atPath: resolved) as? [NMSFTPFile] else {
                throw FileProviderError.fileNotFound(resolved)
            }
            return entries.compactMap { Self.makeItem(from: $0, parent: resolved, connectionId: self.connection.id) }
        }
    }

    func getInfo(at path: String) async throws -> FileItem {
        let resolved = resolvePath(path)
        return try await onQueue { sftp in
            guard let info = sftp.infoForFile(atPath: resolved) else {
                throw FileProviderError.fileNotFound(resolved)
            }
            return Self.makeItem(from: info, parent: (resolved as NSString).deletingLastPathComponent, connectionId: self.connection.id)
                ?? FileItem(
                    id: resolved, name: (resolved as NSString).lastPathComponent,
                    path: resolved, size: 0, modifiedDate: Date(),
                    isDirectory: false, isHidden: false, isSymlink: false,
                    itemType: .unknown, providerType: .sftp,
                    connectionId: self.connection.id
                )
        }
    }

    // MARK: - Download (streamed to disk so big files don't OOM)

    func downloadToTemp(from path: String, progress: ProgressHandler?) async throws -> URL {
        let resolved = resolvePath(path)
        let ext      = URL(fileURLWithPath: resolved).pathExtension
        let dst      = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)

        try await onQueue { sftp in
            guard let stream = OutputStream(url: dst, append: false) else {
                throw FileProviderError.transferFailed("Could not create temp file")
            }
            stream.open()
            defer { stream.close() }

            // NMSSH provides write-to-stream with a progress callback that returns
            // a Bool to indicate whether to continue (allows cancellation).
            let ok = sftp.writeFile(atPath: resolved, to: stream) { received in
                progress?(Self.fractionDone(received: received, total: 0))
                return true
            }
            if !ok {
                throw FileProviderError.transferFailed("SFTP read failed for \(resolved)")
            }
            progress?(1.0)
        }
        return dst
    }

    // MARK: - Upload

    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws {
        let resolved = resolvePath(path)
        try await onQueue { sftp in
            let ok = sftp.writeContents(data, toFileAtPath: resolved) { sent in
                progress?(Self.fractionDone(received: sent, total: UInt(data.count)))
                return true
            }
            if !ok {
                throw FileProviderError.transferFailed("SFTP write failed for \(resolved)")
            }
            progress?(1.0)
        }
    }

    func uploadFile(at localURL: URL, to path: String, progress: ProgressHandler?) async throws {
        let resolved = resolvePath(path)
        try await onQueue { sftp in
            guard let stream = InputStream(url: localURL) else {
                throw FileProviderError.transferFailed("Could not open local file")
            }
            stream.open()
            defer { stream.close() }
            let total = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int) ?? 0
            let ok = sftp.writeStream(stream, toFileAtPath: resolved) { sent in
                progress?(Self.fractionDone(received: sent, total: UInt(total)))
                return true
            }
            if !ok {
                throw FileProviderError.transferFailed("SFTP upload failed for \(resolved)")
            }
            progress?(1.0)
        }
    }

    // MARK: - Mutating ops

    func delete(at path: String) async throws {
        let resolved = resolvePath(path)
        try await onQueue { sftp in
            // Try as file first, fall through to directory.
            if sftp.removeFile(atPath: resolved) { return }
            if sftp.removeDirectory(atPath: resolved) { return }
            throw FileProviderError.transferFailed("Could not delete \(resolved)")
        }
    }

    func createDirectory(at path: String) async throws {
        let resolved = resolvePath(path)
        try await onQueue { sftp in
            if !sftp.createDirectory(atPath: resolved) {
                throw FileProviderError.transferFailed("Could not create \(resolved)")
            }
        }
    }

    func rename(at path: String, to newName: String) async throws {
        let resolved = resolvePath(path)
        let parent   = (resolved as NSString).deletingLastPathComponent
        let dst      = (parent as NSString).appendingPathComponent(newName)
        try await onQueue { sftp in
            if !sftp.moveItem(atPath: resolved, toPath: dst) {
                throw FileProviderError.transferFailed("Rename failed")
            }
        }
    }

    func move(from src: String, to dst: String) async throws {
        let s = resolvePath(src)
        let d = resolvePath(dst)
        try await onQueue { sftp in
            if !sftp.moveItem(atPath: s, toPath: d) {
                throw FileProviderError.transferFailed("Move failed")
            }
        }
    }

    // MARK: - Streaming URL (none — SFTP isn't an HTTP byte-range source)

    func streamingURL(for path: String) -> StreamingTarget? { nil }

    // MARK: - Helpers

    private func resolvePath(_ path: String) -> String {
        let input = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let base  = connection.basePath.isEmpty ? "/" : connection.basePath
        if base == "/" {
            return input.hasPrefix("/") ? input : "/\(input)"
        }
        if input == "/" || input.isEmpty {
            return base
        }
        if input.hasPrefix(base + "/") || input == base {
            return input
        }
        let clean = input.hasPrefix("/") ? String(input.dropFirst()) : input
        return (base as NSString).appendingPathComponent(clean)
    }

    private static func fractionDone(received: UInt, total: UInt) -> Double {
        guard total > 0 else { return 0 }
        return Double(received) / Double(total)
    }

    private func onQueue<T>(_ work: @escaping (NMSFTP) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                guard let sftp = self.sftp, sftp.isConnected else {
                    cont.resume(throwing: FileProviderError.notConnected)
                    return
                }
                do {
                    let result = try work(sftp)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func makeItem(from file: NMSFTPFile, parent: String, connectionId: UUID) -> FileItem? {
        guard let name = file.filename, !name.isEmpty, name != ".", name != ".." else { return nil }
        let isDir = file.isDirectory
        let path  = (parent as NSString).appendingPathComponent(name)
        let size  = file.fileSize?.int64Value ?? 0
        let url   = URL(fileURLWithPath: name)

        return FileItem(
            id:           path,
            name:         name,
            path:         path,
            size:         isDir ? 0 : size,
            modifiedDate: file.modificationDate ?? Date(),
            isDirectory:  isDir,
            isHidden:     name.hasPrefix("."),
            isSymlink:    file.isSymbolicLink,
            itemType:     isDir ? .folder : FileTypeHelper.detectType(for: url),
            providerType: .sftp,
            connectionId: connectionId
        )
    }
}
