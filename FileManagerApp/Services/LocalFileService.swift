import Foundation

// MARK: - Local File Service

final class LocalFileService: FileProvider {
    let providerType: ProviderType = .local
    private(set) var isConnected: Bool = true

    func connect() async throws {}
    func disconnect() {}

    // MARK: - List

    func listDirectory(at path: String) async throws -> [FileItem] {
        let fm  = FileManager.default
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [
            .nameKey, .isDirectoryKey, .fileSizeKey,
            .contentModificationDateKey, .creationDateKey,
            .isHiddenKey, .isSymbolicLinkKey
        ]
        let contents = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        )
        return contents.compactMap { FileItem.fromLocalURL($0) }
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

        // Documents
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            paths.append(("Documents", docs.path))
        }
        // Downloads (iOS 16+)
        if let dl = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
           fm.fileExists(atPath: dl.path) {
            paths.append(("Downloads", dl.path))
        }
        // iCloud container root if available
        if let icloud = fm.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents") {
            paths.append(("iCloud Documents", icloud.path))
        }
        return paths
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
