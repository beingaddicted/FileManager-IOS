import Foundation
import AMSMB2

// MARK: - SMB / CIFS Service
//
// Real SMB2/3 client over libsmb2 via AMSMB2 (https://github.com/amosavian/AMSMB2).
// AMSMB2 ships an actor-friendly Swift API so we can use it directly with
// async/await — no extra serialisation queue needed.
//
// Synology, TrueNAS, Unraid, OpenMediaVault, Windows Server, macOS Sharing,
// and Samba 4 all speak SMB2/3 and have been verified against AMSMB2 in
// production apps.

final class SMBService: FileProvider {
    let providerType: ProviderType = .smb
    private(set) var isConnected: Bool = false

    private let connection: ServerConnection
    private var password: String { KeychainHelper.shared.password(for: connection) }

    private var client: SMB2Manager?

    init(connection: ServerConnection) {
        self.connection = connection
    }

    deinit {
        Task { [client] in try? await client?.disconnectShare() }
    }

    // MARK: - Connect

    func connect() async throws {
        // basePath holds the share name on SMB connections, e.g. "/volume1".
        // AMSMB2 requires the URL to point at the server root and connectShare()
        // to take the share name separately.
        let scheme = "smb"
        guard let url = URL(string: "\(scheme)://\(connection.host)") else {
            throw FileProviderError.invalidPath(connection.host)
        }

        let credential: URLCredential? = connection.anonymousLogin
            ? nil
            : URLCredential(user: connection.username, password: password, persistence: .forSession)

        guard let client = SMB2Manager(url: url, credential: credential) else {
            throw FileProviderError.networkError("Could not initialize SMB client")
        }
        client.timeout = 30

        let share = Self.shareName(from: connection.basePath)
        do {
            try await client.connectShare(name: share, encrypted: false)
        } catch {
            throw FileProviderError.authenticationFailed(error.localizedDescription)
        }

        self.client = client
        self.isConnected = true
    }

    func disconnect() {
        Task { [client] in try? await client?.disconnectShare() }
        client = nil
        isConnected = false
    }

    // MARK: - List

    func listDirectory(at path: String) async throws -> [FileItem] {
        guard let client = client else { throw FileProviderError.notConnected }
        let inSharePath = Self.pathInsideShare(connection.basePath, requested: path)
        let entries = try await client.contentsOfDirectory(atPath: inSharePath)
        return entries.compactMap { entry in
            Self.makeItem(from: Self.bridge(entry), parent: inSharePath, connectionId: connection.id)
        }
    }

    func getInfo(at path: String) async throws -> FileItem {
        guard let client = client else { throw FileProviderError.notConnected }
        let inShare = Self.pathInsideShare(connection.basePath, requested: path)
        // AMSMB2's attributesOfItem returns `[URLResourceKey: any Sendable]` on
        // recent versions; bridge through a homogeneous `[URLResourceKey: Any]`
        // so makeItem doesn't have to know about Sendable existentials.
        let attrs   = Self.bridge(try await client.attributesOfItem(atPath: inShare))
        let parent  = (inShare as NSString).deletingLastPathComponent
        return Self.makeItem(from: attrs, parent: parent, connectionId: connection.id)
            ?? FileItem(
                id: inShare, name: (inShare as NSString).lastPathComponent,
                path: inShare, size: 0, modifiedDate: Date(),
                isDirectory: false, isHidden: false, isSymlink: false,
                itemType: .unknown, providerType: .smb,
                connectionId: connection.id
            )
    }

    // MARK: - Download (streamed to a local file)

    func downloadToTemp(from path: String, progress: ProgressHandler?) async throws -> URL {
        guard let client = client else { throw FileProviderError.notConnected }
        let inShare = Self.pathInsideShare(connection.basePath, requested: path)
        let ext     = URL(fileURLWithPath: inShare).pathExtension
        let dst     = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)

        try await client.downloadItem(atPath: inShare, to: dst) { transferred, total in
            if total > 0 {
                progress?(Double(transferred) / Double(total))
            }
            return true
        }
        progress?(1.0)
        return dst
    }

    // MARK: - Upload

    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws {
        guard let client = client else { throw FileProviderError.notConnected }
        let inShare = Self.pathInsideShare(connection.basePath, requested: path)
        try await client.write(data: data, toPath: inShare) { sent in
            if data.count > 0 {
                progress?(Double(sent) / Double(data.count))
            }
            return true
        }
        progress?(1.0)
    }

    func uploadFile(at localURL: URL, to path: String, progress: ProgressHandler?) async throws {
        guard let client = client else { throw FileProviderError.notConnected }
        let inShare = Self.pathInsideShare(connection.basePath, requested: path)
        // AMSMB2's `uploadItem` uses `WriteProgressHandler = (Int64) -> Bool`
        // (single arg = bytes sent). Compute total from local file size for
        // the percentage we expose.
        let total = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
        try await client.uploadItem(at: localURL, toPath: inShare) { sent in
            if total > 0 {
                progress?(Double(sent) / Double(total))
            }
            return true
        }
        progress?(1.0)
    }

    // MARK: - Mutating ops

    func delete(at path: String) async throws {
        guard let client = client else { throw FileProviderError.notConnected }
        let inShare = Self.pathInsideShare(connection.basePath, requested: path)
        // AMSMB2 returns a not-a-directory error if we call removeDirectory on a
        // file; try file first, then dir.
        do {
            try await client.removeFile(atPath: inShare)
        } catch {
            try await client.removeDirectory(atPath: inShare, recursive: false)
        }
    }

    func createDirectory(at path: String) async throws {
        guard let client = client else { throw FileProviderError.notConnected }
        let inShare = Self.pathInsideShare(connection.basePath, requested: path)
        try await client.createDirectory(atPath: inShare)
    }

    func rename(at path: String, to newName: String) async throws {
        guard let client = client else { throw FileProviderError.notConnected }
        let src    = Self.pathInsideShare(connection.basePath, requested: path)
        let parent = (src as NSString).deletingLastPathComponent
        let dst    = (parent as NSString).appendingPathComponent(newName)
        try await client.moveItem(atPath: src, toPath: dst)
    }

    func move(from src: String, to dst: String) async throws {
        guard let client = client else { throw FileProviderError.notConnected }
        let s = Self.pathInsideShare(connection.basePath, requested: src)
        let d = Self.pathInsideShare(connection.basePath, requested: dst)
        try await client.moveItem(atPath: s, toPath: d)
    }

    // MARK: - Streaming URL (none — SMB isn't HTTP)

    func streamingURL(for path: String) -> StreamingTarget? { nil }

    // MARK: - Helpers

    private static func shareName(from basePath: String) -> String {
        // basePath examples: "/volume1", "/Public", "/data". Take the first
        // path component as share name, ignoring leading slash.
        let parts = basePath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/", maxSplits: 1)
        return parts.first.map(String.init) ?? ""
    }

    private static func pathInsideShare(_ basePath: String, requested: String) -> String {
        let share = shareName(from: basePath)
        let trimmed = requested.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return "" }
        // Strip the share prefix from the requested path if present so AMSMB2
        // sees the share-relative path.
        if !share.isEmpty, trimmed.hasPrefix(share + "/") {
            return String(trimmed.dropFirst(share.count + 1))
        }
        if !share.isEmpty, trimmed == share {
            return ""
        }
        return trimmed
    }

    /// Bridges AMSMB2's `[URLResourceKey: any Sendable]` to a plain
    /// `[URLResourceKey: Any]` so the rest of the file doesn't have to
    /// thread the Sendable existential through.
    private static func bridge<S>(_ dict: [URLResourceKey: S]) -> [URLResourceKey: Any] {
        var out: [URLResourceKey: Any] = [:]
        out.reserveCapacity(dict.count)
        for (key, value) in dict { out[key] = value }
        return out
    }

    private static func makeItem(
        from attrs: [URLResourceKey: Any],
        parent: String,
        connectionId: UUID
    ) -> FileItem? {
        guard let name = attrs[.nameKey] as? String,
              !name.isEmpty, name != ".", name != ".." else { return nil }
        let isDir = (attrs[.fileResourceTypeKey] as? URLFileResourceType) == .directory
        let size  = (attrs[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs[.contentModificationDateKey] as? Date) ?? Date()
        let path  = parent.isEmpty ? name : "\(parent)/\(name)"
        let url   = URL(fileURLWithPath: name)

        return FileItem(
            id:           path,
            name:         name,
            path:         path,
            size:         isDir ? 0 : size,
            modifiedDate: modified,
            isDirectory:  isDir,
            isHidden:     name.hasPrefix("."),
            isSymlink:    false,
            itemType:     isDir ? .folder : FileTypeHelper.detectType(for: url),
            providerType: .smb,
            connectionId: connectionId
        )
    }
}
