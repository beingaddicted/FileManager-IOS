import Foundation
import Combine

// MARK: - FileProvider Protocol

protocol FileProvider: AnyObject {
    var providerType: ProviderType { get }
    var isConnected: Bool { get }

    func connect() async throws
    func disconnect()

    func listDirectory(at path: String) async throws -> [FileItem]
    func getInfo(at path: String) async throws -> FileItem

    func download(from path: String, progress: ProgressHandler?) async throws -> Data
    func downloadToTemp(from path: String, progress: ProgressHandler?) async throws -> URL
    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws

    func delete(at path: String) async throws
    func createDirectory(at path: String) async throws
    func rename(at path: String, to newName: String) async throws
    func move(from src: String, to dst: String) async throws
    func copy(from src: String, to dst: String) async throws
}

typealias ProgressHandler = @Sendable (Double) -> Void

// MARK: - Default implementations

extension FileProvider {
    func downloadToTemp(from path: String, progress: ProgressHandler? = nil) async throws -> URL {
        let data = try await download(from: path, progress: progress)
        let ext  = URL(fileURLWithPath: path).pathExtension
        let tmp  = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try data.write(to: tmp)
        return tmp
    }

    func copy(from src: String, to dst: String) async throws {
        let data = try await download(from: src, progress: nil)
        try await upload(data, to: dst, progress: nil)
    }
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
        case .ftp:          return FTPService(connection: connection)
        case .sftp:         return SFTPService(connection: connection)
        case .smb:          return SMBService(connection: connection)
        case .webdav:       return WebDAVService(connection: connection)
        case .upnp:         return UPnPService(connection: connection)
        case .googleDrive:  return GoogleDriveService(connection: connection)
        case .dropbox:      return DropboxService(connection: connection)
        case .oneDrive:     return OneDriveService(connection: connection)
        }
    }

    static func makeLocal() -> FileProvider   { LocalFileService() }
    static func makeICloud() -> FileProvider  { ICloudService() }
}

// MARK: - Transfer Task (for progress tracking)

@MainActor
final class TransferTask: ObservableObject, Identifiable {
    let id = UUID()
    let filename: String
    let direction: Direction
    @Published var progress: Double = 0
    @Published var state: State = .queued
    var cancellable: Task<Void, Error>?

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
