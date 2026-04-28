import Foundation
import Observation

// MARK: - FileProvider Protocol
//
// Streaming-first design. The primary download method returns a file URL
// because remote files can be many GB; loading them entirely into RAM (the
// previous `Data`-returning shape) would OOM the app on long videos and ISOs.
// `download(...) -> Data` is kept as a convenience wrapper for small files
// (text editor, thumbnails, etc.) and is implemented in terms of `downloadToTemp`.

protocol FileProvider: AnyObject {
    var providerType: ProviderType { get }
    var isConnected: Bool { get }

    func connect() async throws
    func disconnect()

    func listDirectory(at path: String) async throws -> [FileItem]
    func getInfo(at path: String) async throws -> FileItem

    /// Streams the remote file to a local temporary file. Use this for large files.
    func downloadToTemp(from path: String, progress: ProgressHandler?) async throws -> URL

    /// Convenience: downloads to RAM. Default implementation calls `downloadToTemp` and reads.
    /// Avoid for files larger than ~50 MB.
    func download(from path: String, progress: ProgressHandler?) async throws -> Data

    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws
    func uploadFile(at localURL: URL, to path: String, progress: ProgressHandler?) async throws

    func delete(at path: String) async throws
    func createDirectory(at path: String) async throws
    func rename(at path: String, to newName: String) async throws
    func move(from src: String, to dst: String) async throws
    func copy(from src: String, to dst: String) async throws

    /// Returns a streaming URL plus optional auth headers that can be passed to
    /// `AVURLAsset(url:options:)` (via `AVURLAssetHTTPHeaderFieldsKey`) so video
    /// can be played without first downloading the whole file. Returns nil for
    /// providers that can't expose HTTP byte-range URLs (e.g. SFTP/SMB), in
    /// which case callers should fall back to `downloadToTemp`.
    func streamingURL(for path: String) -> StreamingTarget?

    /// HTTP-shaped providers (WebDAV) return an authorised URLRequest that a
    /// `URLSessionConfiguration.background(...)` session can run while the
    /// app is suspended. SFTP/SMB return nil — those use libssh2/libsmb2
    /// sockets that iOS can't keep alive in the background.
    func backgroundDownloadRequest(for path: String) -> URLRequest?
    func backgroundUploadRequest(for path: String, sourceFile: URL) -> URLRequest?
}

typealias ProgressHandler = @Sendable (Double) -> Void

// MARK: - Streaming target

struct StreamingTarget {
    let url: URL
    let headers: [String: String]
}

// MARK: - Default implementations

extension FileProvider {
    func download(from path: String, progress: ProgressHandler? = nil) async throws -> Data {
        let url = try await downloadToTemp(from: path, progress: progress)
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    func uploadFile(at localURL: URL, to path: String, progress: ProgressHandler? = nil) async throws {
        let data = try Data(contentsOf: localURL, options: [.mappedIfSafe])
        try await upload(data, to: path, progress: progress)
    }

    func copy(from src: String, to dst: String) async throws {
        let url = try await downloadToTemp(from: src, progress: nil)
        try await uploadFile(at: url, to: dst, progress: nil)
    }

    func streamingURL(for path: String) -> StreamingTarget? { nil }

    func backgroundDownloadRequest(for path: String) -> URLRequest? { nil }
    func backgroundUploadRequest(for path: String, sourceFile: URL) -> URLRequest? { nil }
}

// MARK: - Errors

enum FileProviderError: LocalizedError {
    case notConnected
    case authenticationFailed(String)
    case fileNotFound(String)
    case permissionDenied
    case networkError(String)
    case unsupportedOperation
    case invalidPath(String)
    case transferFailed(String)
    case serverError(Int, String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected:                 return "Not connected to server."
        case .authenticationFailed(let m):  return "Authentication failed: \(m)"
        case .fileNotFound(let p):          return "File not found: \(p)"
        case .permissionDenied:             return "Permission denied."
        case .networkError(let m):          return "Network error: \(m)"
        case .unsupportedOperation:         return "This operation is not supported."
        case .invalidPath(let p):           return "Invalid path: \(p)"
        case .transferFailed(let m):        return "Transfer failed: \(m)"
        case .serverError(let c, let m):    return "Server error \(c): \(m)"
        case .cancelled:                    return "Operation was cancelled."
        }
    }
}

// MARK: - Provider Factory

@MainActor
enum FileProviderFactory {
    static func make(for connection: ServerConnection) -> FileProvider {
        switch connection.type {
        case .ftp:    return FTPService(connection: connection)
        case .sftp:   return SFTPService(connection: connection)
        case .smb:    return SMBService(connection: connection)
        case .webdav: return WebDAVService(connection: connection)
        case .upnp:   return UPnPService(connection: connection)
        }
    }

    static func makeLocal() -> FileProvider   { LocalFileService() }
    static func makeICloud() -> FileProvider  { ICloudService() }
}

// MARK: - Transfer Task (in-flight UI state)

@Observable
@MainActor
final class TransferTask: Identifiable {
    let id = UUID()
    let filename: String
    let direction: Direction
    var progress: Double = 0
    var state: State = .queued
    @ObservationIgnored var cancellable: Task<Void, Error>?

    enum Direction { case upload, download }
    enum State { case queued, active, paused, done, failed }

    init(filename: String, direction: Direction) {
        self.filename  = filename
        self.direction = direction
    }

    func cancel() {
        cancellable?.cancel()
        state = .failed
    }
}

// MARK: - URLSession streaming download helper

extension URLSession {
    /// Downloads `request` to a temporary file URL, reporting progress to `progress`.
    /// Uses a delegate-based session so we get byte-by-byte progress instead of
    /// only the binary 0/1 returned by `URLSession.shared.download(for:)`.
    func streamDownload(
        for request: URLRequest,
        progress: ProgressHandler?
    ) async throws -> URL {
        let (bytes, response) = try await self.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FileProviderError.networkError("Invalid response")
        }
        try Self.validate(http)

        let total = response.expectedContentLength
        let ext   = URL(fileURLWithPath: request.url?.path ?? "").pathExtension
        let dst   = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)

        FileManager.default.createFile(atPath: dst.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: dst) else {
            throw FileProviderError.transferFailed("Could not create temp file")
        }
        defer { try? handle.close() }

        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 {
                    progress?(Double(written) / Double(total))
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        progress?(1.0)
        return dst
    }

    static func validate(_ http: HTTPURLResponse) throws {
        switch http.statusCode {
        case 200...299, 207: return
        case 401, 403:       throw FileProviderError.authenticationFailed("HTTP \(http.statusCode)")
        case 404:            throw FileProviderError.fileNotFound("HTTP 404")
        default:             throw FileProviderError.serverError(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }
}
