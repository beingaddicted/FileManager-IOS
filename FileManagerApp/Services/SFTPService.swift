import Foundation
import NMSSH

// MARK: - SFTP Service
//
// Real SFTP over libssh2 via NMSSH (https://github.com/NMSSH/NMSSH, BSD).
//
// libssh2 is not thread-safe across a single session — see the warning in
// NMSSH's docs: "NMSSH classes are not thread safe" and the analogous note
// in libssh2's docs about sessions belonging to one thread. We respect that
// in two ways:
//
//   1. Each session owns a private serial DispatchQueue; every call against
//      that session runs on its queue.
//   2. We hold a *pool* of sessions. The pool grows lazily up to a small
//      maximum (3) so that, e.g., a long video download can run in parallel
//      with a folder listing or a thumbnail fetch. Without a pool, every
//      operation against a single SFTP session is serialised behind the
//      slowest in-flight transfer — which is what every other "single-shared-
//      session" SFTP iOS app does, and is what users perceive as "this
//      app freezes when I download a movie."

final class SFTPService: FileProvider {
    let providerType: ProviderType = .sftp
    private(set) var isConnected: Bool = false

    private let connection: ServerConnection
    private var password: String { KeychainHelper.shared.password(for: connection) }
    private let pool: SFTPSessionPool

    init(connection: ServerConnection) {
        self.connection = connection
        self.pool = SFTPSessionPool(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            password: KeychainHelper.shared.password(for: connection),
            maxSessions: 3
        )
    }

    deinit {
        pool.disconnectAll()
    }

    // MARK: - Connect

    func connect() async throws {
        // Eagerly build one session to validate credentials; the rest of the
        // pool comes up on demand.
        try await pool.warmUp()
        isConnected = true
    }

    func disconnect() {
        pool.disconnectAll()
        isConnected = false
    }

    // MARK: - List

    func listDirectory(at path: String) async throws -> [FileItem] {
        let resolved = resolvePath(path)
        let items = try await pool.withSession { sftp in
            guard let entries = sftp.contentsOfDirectory(atPath: resolved) as? [NMSFTPFile] else {
                throw FileProviderError.fileNotFound(resolved)
            }
            return entries.compactMap { Self.makeItem(from: $0, parent: resolved, connectionId: self.connection.id) }
        }
        return items
    }

    func getInfo(at path: String) async throws -> FileItem {
        let resolved = resolvePath(path)
        let connId = connection.id
        return try await pool.withSession { sftp in
            guard let info = sftp.infoForFile(atPath: resolved) else {
                throw FileProviderError.fileNotFound(resolved)
            }
            return Self.makeItem(from: info, parent: (resolved as NSString).deletingLastPathComponent, connectionId: connId)
                ?? FileItem(
                    id: resolved, name: (resolved as NSString).lastPathComponent,
                    path: resolved, size: 0, modifiedDate: Date(),
                    isDirectory: false, isHidden: false, isSymlink: false,
                    itemType: .unknown, providerType: .sftp,
                    connectionId: connId
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

        try await pool.withSession { sftp in
            guard let stream = OutputStream(url: dst, append: false) else {
                throw FileProviderError.transferFailed("Could not create temp file")
            }
            stream.open()
            defer { stream.close() }

            let ok = sftp.contents(atPath: resolved, to: stream) { received, total in
                progress?(Self.fractionDone(received: received, total: total))
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
        try await pool.withSession { sftp in
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
        let total = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int) ?? 0
        try await pool.withSession { sftp in
            let ok = sftp.writeFile(atPath: localURL.path, toFileAtPath: resolved) { sent in
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
        try await pool.withSession { sftp in
            if sftp.removeFile(atPath: resolved) { return }
            if sftp.removeDirectory(atPath: resolved) { return }
            throw FileProviderError.transferFailed("Could not delete \(resolved)")
        }
    }

    func createDirectory(at path: String) async throws {
        let resolved = resolvePath(path)
        try await pool.withSession { sftp in
            if !sftp.createDirectory(atPath: resolved) {
                throw FileProviderError.transferFailed("Could not create \(resolved)")
            }
        }
    }

    func rename(at path: String, to newName: String) async throws {
        let resolved = resolvePath(path)
        let parent   = (resolved as NSString).deletingLastPathComponent
        let dst      = (parent as NSString).appendingPathComponent(newName)
        try await pool.withSession { sftp in
            if !sftp.moveItem(atPath: resolved, toPath: dst) {
                throw FileProviderError.transferFailed("Rename failed")
            }
        }
    }

    func move(from src: String, to dst: String) async throws {
        let s = resolvePath(src)
        let d = resolvePath(dst)
        try await pool.withSession { sftp in
            if !sftp.moveItem(atPath: s, toPath: d) {
                throw FileProviderError.transferFailed("Move failed")
            }
        }
    }

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

    private static func makeItem(from file: NMSFTPFile, parent: String, connectionId: UUID) -> FileItem? {
        guard let name = file.filename, !name.isEmpty, name != ".", name != ".." else { return nil }
        let isDir = file.isDirectory
        let path  = (parent as NSString).appendingPathComponent(name)
        let size  = file.fileSize?.int64Value ?? 0
        let url   = URL(fileURLWithPath: name)
        let isSymlink = (file.permissions ?? "").hasPrefix("l")

        return FileItem(
            id:           path,
            name:         name,
            path:         path,
            size:         isDir ? 0 : size,
            modifiedDate: file.modificationDate ?? Date(),
            isDirectory:  isDir,
            isHidden:     name.hasPrefix("."),
            isSymlink:    isSymlink,
            itemType:     isDir ? .folder : FileTypeHelper.detectType(for: url),
            providerType: .sftp,
            connectionId: connectionId
        )
    }
}

// MARK: - SFTPSessionPool
//
// Holds up to `maxSessions` independent SSH+SFTP sessions to one host. Each
// session is single-threaded (per libssh2 rules) and runs on its own serial
// dispatch queue. `withSession` checks out a free session for the duration
// of one operation and returns it on completion, blocking the caller if
// every session is busy.

final class SFTPSessionPool {
    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let maxSessions: Int

    private struct Slot {
        let id: Int
        let session: NMSSHSession
        let sftp: NMSFTP
        let queue: DispatchQueue
    }

    /// All mutable state — the slot inventory and the waiter list — lives
    /// behind this serial queue. We don't use Swift's `actor` here because
    /// we need to dispatch onto NMSSH's per-session queue inside a continuation,
    /// and that's awkward inside actor-isolated methods.
    private let stateQueue = DispatchQueue(label: "sftp.pool.state")
    private var slots: [Slot] = []
    private var inUse: Set<Int> = []
    private var waiters: [CheckedContinuation<Slot, Never>] = []
    private var nextSlotId = 0

    init(host: String, port: Int, username: String, password: String, maxSessions: Int) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.maxSessions = max(1, maxSessions)
    }

    // MARK: - Public

    func warmUp() async throws {
        let slot = try await openSlot()
        stateQueue.sync { slots.append(slot) }
    }

    func withSession<T>(_ work: @escaping (NMSFTP) throws -> T) async throws -> T {
        let slot = await acquire()
        defer { release(slot) }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            slot.queue.async {
                guard slot.sftp.isConnected else {
                    cont.resume(throwing: FileProviderError.notConnected)
                    return
                }
                do {
                    let value = try work(slot.sftp)
                    cont.resume(returning: value)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func disconnectAll() {
        stateQueue.sync {
            for slot in slots {
                slot.queue.async {
                    slot.sftp.disconnect()
                    slot.session.disconnect()
                }
            }
            slots.removeAll()
            inUse.removeAll()
            // Resume any pending waiters with a fresh slot will be impossible —
            // they need to fail. We don't resume here because callers will see
            // their session work fail with notConnected on the next dispatch.
        }
    }

    // MARK: - Acquire / release

    private func acquire() async -> Slot {
        // Fast path: a free slot already exists.
        if let slot = stateQueue.sync(execute: { takeFreeSlot() }) {
            return slot
        }
        // Slow path: try to grow the pool, otherwise wait.
        let canGrow = stateQueue.sync { slots.count < maxSessions }
        if canGrow {
            do {
                let slot = try await openSlot()
                stateQueue.sync {
                    slots.append(slot)
                    inUse.insert(slot.id)
                }
                return slot
            } catch {
                // Fall through to wait — another caller might release a slot.
            }
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Slot, Never>) in
            stateQueue.sync {
                if let slot = takeFreeSlot() {
                    cont.resume(returning: slot)
                } else {
                    waiters.append(cont)
                }
            }
        }
    }

    /// Must run on `stateQueue`.
    private func takeFreeSlot() -> Slot? {
        for slot in slots where !inUse.contains(slot.id) {
            inUse.insert(slot.id)
            return slot
        }
        return nil
    }

    private func release(_ slot: Slot) {
        stateQueue.sync {
            inUse.remove(slot.id)
            // If a caller was waiting, hand the slot directly to them.
            if !waiters.isEmpty {
                let waiter = waiters.removeFirst()
                inUse.insert(slot.id)
                waiter.resume(returning: slot)
            }
        }
    }

    // MARK: - Slot construction

    private func openSlot() async throws -> Slot {
        let id = stateQueue.sync { () -> Int in
            defer { nextSlotId += 1 }
            return nextSlotId
        }
        let queue = DispatchQueue(label: "sftp.slot.\(id)")
        let host = self.host, port = self.port, user = self.username, pwd = self.password

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Slot, Error>) in
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
                cont.resume(returning: Slot(id: id, session: session, sftp: sftp, queue: queue))
            }
        }
    }
}
