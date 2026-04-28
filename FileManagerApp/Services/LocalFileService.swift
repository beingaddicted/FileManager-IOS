import Foundation

// MARK: - Local File Service

final class LocalFileService: FileProvider {
    let providerType: ProviderType = .local
    private(set) var isConnected: Bool = true
    static let smartRootPrefix = "/__smart__"

    private struct SmartFolder {
        let name: String
        let path: String
        let kind: Kind

        enum Kind {
            case images
            case videos
            case documents
        }
    }

    private static let smartFolders: [SmartFolder] = [
        SmartFolder(name: "All Images", path: "\(smartRootPrefix)/images", kind: .images),
        SmartFolder(name: "All Videos", path: "\(smartRootPrefix)/videos", kind: .videos),
        SmartFolder(name: "All Documents", path: "\(smartRootPrefix)/documents", kind: .documents)
    ]

    private var smartFolderCache: [String: (timestamp: Date, items: [FileItem])] = [:]
    private let cacheTTL: TimeInterval = 30

    func connect() async throws {}
    func disconnect() {}

    // MARK: - List

    func listDirectory(at path: String) async throws -> [FileItem] {
        if path == "/" {
            let roots = Self.rootPaths.map { root in
                FileItem(
                    id: root.path,
                    name: root.name,
                    path: root.path,
                    size: 0,
                    modifiedDate: Date(),
                    isDirectory: true,
                    isHidden: false,
                    isSymlink: false,
                    itemType: .folder,
                    providerType: .local
                )
            }
            let smart = Self.smartFolders.map { folder in
                FileItem(
                    id: folder.path,
                    name: folder.name,
                    path: folder.path,
                    size: 0,
                    modifiedDate: Date(),
                    isDirectory: true,
                    isHidden: false,
                    isSymlink: false,
                    itemType: .folder,
                    providerType: .local
                )
            }
            return roots + smart
        }

        if path.hasPrefix(Self.smartRootPrefix) {
            return try await listSmartFolder(at: path)
        }

        let fm  = FileManager.default
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [
            .nameKey, .isDirectoryKey, .fileSizeKey,
            .contentModificationDateKey, .creationDateKey,
            .isHiddenKey, .isSymbolicLinkKey
        ]
        do {
            let contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants]
            )
            return contents.compactMap { FileItem.fromLocalURL($0) }
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain &&
                (nsError.code == CocoaError.fileReadNoPermission.rawValue ||
                 nsError.code == CocoaError.fileReadInvalidFileName.rawValue) {
                throw FileProviderError.permissionDenied
            }
            throw error
        }
    }

    private func listSmartFolder(at path: String) async throws -> [FileItem] {
        if let cached = smartFolderCache[path], Date().timeIntervalSince(cached.timestamp) < cacheTTL {
            return cached.items
        }

        guard let folder = Self.smartFolders.first(where: { $0.path == path }) else {
            throw FileProviderError.invalidPath(path)
        }

        let roots = Self.rootPaths.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        let scanned = try await Task.detached(priority: .userInitiated) {
            try Self.scanFiles(in: roots, kind: folder.kind)
        }.value

        smartFolderCache[path] = (Date(), scanned)
        return scanned
    }

    // MARK: - Info

    func getInfo(at path: String) async throws -> FileItem {
        let url = URL(fileURLWithPath: path)
        guard let item = FileItem.fromLocalURL(url) else {
            throw FileProviderError.fileNotFound(path)
        }
        return item
    }

    // MARK: - Download / Upload

    func download(from path: String, progress: ProgressHandler?) async throws -> Data {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        progress?(1.0)
        return data
    }

    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws {
        let url = URL(fileURLWithPath: path)
        try data.write(to: url, options: .atomic)
        progress?(1.0)
    }

    // MARK: - Operations

    func delete(at path: String) async throws {
        try FileManager.default.removeItem(atPath: path)
    }

    func createDirectory(at path: String) async throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
    }

    func rename(at path: String, to newName: String) async throws {
        let src = URL(fileURLWithPath: path)
        let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: src, to: dst)
    }

    func move(from src: String, to dst: String) async throws {
        try FileManager.default.moveItem(
            atPath: src,
            toPath: dst
        )
    }

    func copy(from src: String, to dst: String) async throws {
        try FileManager.default.copyItem(
            atPath: src,
            toPath: dst
        )
    }

    // MARK: - Helpers

    static var rootPaths: [(name: String, path: String)] {
        let fm  = FileManager.default
        var paths: [(String, String)] = []

        // App container root
        let home = NSHomeDirectory()
        if fm.fileExists(atPath: home) {
            paths.append(("App Container", home))
        }

        // Documents
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            paths.append(("Documents", docs.path))
            let inbox = docs.appendingPathComponent("Inbox")
            if fm.fileExists(atPath: inbox.path) {
                paths.append(("Inbox", inbox.path))
            }
        }
        // Downloads (iOS 16+)
        if let dl = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
           fm.fileExists(atPath: dl.path) {
            paths.append(("Downloads", dl.path))
        }
        // Library
        if let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first,
           fm.fileExists(atPath: lib.path) {
            paths.append(("Library", lib.path))
        }
        // Caches
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
           fm.fileExists(atPath: caches.path) {
            paths.append(("Caches", caches.path))
        }
        // Temporary
        paths.append(("Temporary", fm.temporaryDirectory.path))
        // iCloud container root if available
        if let icloud = fm.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents") {
            paths.append(("iCloud Documents", icloud.path))
        }
        return paths
    }

    private static func scanFiles(in roots: [String], kind: SmartFolder.Kind) throws -> [FileItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isHiddenKey,
            .contentModificationDateKey, .creationDateKey, .fileSizeKey, .isSymbolicLinkKey
        ]

        var items: [FileItem] = []

        for rootPath in roots {
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isDirectory != true,
                      values.isRegularFile == true else {
                    continue
                }

                let type = FileTypeHelper.detectType(for: url)
                guard matches(kind: kind, type: type) else { continue }
                if let item = FileItem.fromLocalURL(url, provider: .local) {
                    items.append(item)
                }
            }
        }

        return items
    }

    private static func matches(kind: SmartFolder.Kind, type: FileItemType) -> Bool {
        switch kind {
        case .images:
            return type == .image
        case .videos:
            return type == .video
        case .documents:
            switch type {
            case .document, .spreadsheet, .presentation, .pdf, .text, .code, .archive, .database:
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - iCloud Service

final class ICloudService: FileProvider {
    let providerType: ProviderType = .iCloud
    private(set) var isConnected: Bool = false
    private var baseURL: URL?

    func connect() async throws {
        guard let url = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            throw FileProviderError.notConnected
        }
        baseURL = url
        isConnected = true
    }

    func disconnect() { isConnected = false }

    func listDirectory(at path: String) async throws -> [FileItem] {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [
            .nameKey, .isDirectoryKey, .fileSizeKey,
            .contentModificationDateKey, .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        let contents = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: []
        )
        return contents.compactMap { FileItem.fromLocalURL($0, provider: .iCloud) }
    }

    func getInfo(at path: String) async throws -> FileItem {
        let url = URL(fileURLWithPath: path)
        guard let item = FileItem.fromLocalURL(url, provider: .iCloud) else {
            throw FileProviderError.fileNotFound(path)
        }
        return item
    }

    func download(from path: String, progress: ProgressHandler?) async throws -> Data {
        let url = URL(fileURLWithPath: path)
        // Trigger iCloud download if needed
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        // Wait briefly for download
        var attempts = 0
        while attempts < 30 {
            if let data = try? Data(contentsOf: url) {
                progress?(1.0)
                return data
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            attempts += 1
        }
        throw FileProviderError.transferFailed("iCloud download timed out")
    }

    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws {
        let url = URL(fileURLWithPath: path)
        try data.write(to: url, options: .atomic)
        progress?(1.0)
    }

    func delete(at path: String) async throws {
        try FileManager.default.removeItem(atPath: path)
    }

    func createDirectory(at path: String) async throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func rename(at path: String, to newName: String) async throws {
        let src = URL(fileURLWithPath: path)
        let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: src, to: dst)
    }

    func move(from src: String, to dst: String) async throws {
        try FileManager.default.moveItem(atPath: src, toPath: dst)
    }
}
