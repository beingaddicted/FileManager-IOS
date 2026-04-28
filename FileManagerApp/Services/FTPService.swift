import Foundation

// MARK: - FTP Service
//
// Plain FTP (RFC 959) is deprecated by Apple and largely dying in real
// deployments. iOS 16+ still routes `ftp://` URLs through URLSession but with
// limited semantics: reliable for read + simple list, no MKDIR / DELE / RNFR
// over a vanilla data connection. We expose what's safe and surface
// `unsupportedOperation` for the rest with a hint to use SFTP instead.

final class FTPService: FileProvider {
    let providerType: ProviderType = .ftp
    private(set) var isConnected: Bool = false

    private let connection: ServerConnection
    private var password: String { KeychainHelper.shared.password(for: connection) }
    private let baseURL: URL
    private let rootPath: String
    private let session: URLSession

    init(connection: ServerConnection) {
        self.connection = connection
        let scheme   = connection.usesSSL ? "ftps" : "ftp"
        self.baseURL = URL(string: "\(scheme)://\(connection.host):\(connection.port)")
            ?? URL(string: "ftp://localhost")!

        let normalized = connection.basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == "/" {
            self.rootPath = "/"
        } else {
            self.rootPath = normalized.hasPrefix("/") ? normalized : "/\(normalized)"
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 30
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity       = true
        self.session = URLSession(configuration: config)
    }

    func connect() async throws {
        _ = try await listingString(at: connection.basePath)
        isConnected = true
    }

    func disconnect() { isConnected = false }

    func listDirectory(at path: String) async throws -> [FileItem] {
        let resolved = resolvePath(path)
        let listing  = try await listingString(at: resolved)
        return parseListing(listing, basePath: resolved)
    }

    func getInfo(at path: String) async throws -> FileItem {
        let parent = (path as NSString).deletingLastPathComponent
        let name   = (path as NSString).lastPathComponent
        let items  = try await listDirectory(at: parent)
        guard let item = items.first(where: { $0.name == name }) else {
            throw FileProviderError.fileNotFound(path)
        }
        return item
    }

    func downloadToTemp(from path: String, progress: ProgressHandler?) async throws -> URL {
        let req = authorisedRequest(url: ftpURL(for: resolvePath(path)))
        return try await session.streamDownload(for: req, progress: progress)
    }

    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws {
        var req = authorisedRequest(url: ftpURL(for: resolvePath(path)))
        req.httpMethod = "PUT"
        req.httpBody   = data
        let (_, response) = try await session.data(for: req)
        try validate(response)
        progress?(1.0)
    }

    // MARK: - Mutating ops (unsupported on plain FTP via URLSession)

    func delete(at path: String) async throws {
        throw FileProviderError.networkError("Delete not supported over FTP. Use SFTP for full management.")
    }

    func createDirectory(at path: String) async throws {
        throw FileProviderError.networkError("Create folder not supported over FTP. Use SFTP for full management.")
    }

    func rename(at path: String, to newName: String) async throws {
        throw FileProviderError.networkError("Rename not supported over FTP. Use SFTP for full management.")
    }

    func move(from src: String, to dst: String) async throws {
        throw FileProviderError.networkError("Move not supported over FTP. Use SFTP for full management.")
    }

    // MARK: - Streaming URL (AVPlayer can play ftp:// directly)

    func streamingURL(for path: String) -> StreamingTarget? {
        StreamingTarget(url: ftpURL(for: resolvePath(path)), headers: [:])
    }

    // MARK: - Private

    private func ftpURL(for path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.user     = connection.anonymousLogin ? nil : connection.username
        components?.password = connection.anonymousLogin ? nil : password
        components?.path     = path.hasPrefix("/") ? path : "/\(path)"
        return components?.url ?? baseURL
    }

    private func authorisedRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        return req
    }

    private func resolvePath(_ path: String) -> String {
        let input = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if rootPath == "/" {
            return input.hasPrefix("/") ? input : "/\(input)"
        }
        if input == "/" || input.isEmpty {
            return rootPath
        }
        if input.hasPrefix(rootPath + "/") || input == rootPath {
            return input
        }
        let clean = input.hasPrefix("/") ? String(input.dropFirst()) : input
        return rootPath + "/" + clean
    }

    private func listingString(at path: String) async throws -> String {
        // Trailing slash signals directory mode to Apple's FTP loader.
        let url = ftpURL(for: path.hasSuffix("/") ? path : path + "/")
        let req = authorisedRequest(url: url)
        let (data, response) = try await session.data(for: req)
        try validate(response)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func validate(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 530 {
                throw FileProviderError.authenticationFailed("Invalid credentials")
            }
            throw FileProviderError.serverError(
                http.statusCode,
                HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            )
        }
    }

    // MARK: - Listing parser (Unix LIST + MLSD)

    private func parseListing(_ listing: String, basePath: String) -> [FileItem] {
        var items: [FileItem] = []
        for line in listing.components(separatedBy: "\n") where !line.isEmpty {
            if let item = parseUnixLine(line, basePath: basePath) {
                items.append(item)
            }
        }
        return items
    }

    private func parseUnixLine(_ line: String, basePath: String) -> FileItem? {
        let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard parts.count >= 9 else { return parseMLSDLine(line, basePath: basePath) }

        let permissions = String(parts[0])
        let isDir       = permissions.hasPrefix("d")
        let isLink      = permissions.hasPrefix("l")
        let size        = Int64(parts[4]) ?? 0
        let name        = String(parts[8]).components(separatedBy: " -> ").first ?? ""
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        let path = (basePath as NSString).appendingPathComponent(name)
        let url  = URL(fileURLWithPath: path)

        return FileItem(
            id:           path,
            name:         name,
            path:         path,
            size:         isDir ? 0 : size,
            modifiedDate: parseDate(parts: parts),
            isDirectory:  isDir,
            isHidden:     name.hasPrefix("."),
            isSymlink:    isLink,
            itemType:     isDir ? .folder : FileTypeHelper.detectType(for: url),
            providerType: .ftp,
            connectionId: connection.id
        )
    }

    private func parseMLSDLine(_ line: String, basePath: String) -> FileItem? {
        var facts: [String: String] = [:]
        let parts = line.components(separatedBy: "; ")
        guard parts.count >= 2 else { return nil }

        let name = parts.last?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        for fact in parts.dropLast().first?.components(separatedBy: ";") ?? [] {
            let kv = fact.components(separatedBy: "=")
            if kv.count == 2 { facts[kv[0].lowercased()] = kv[1] }
        }

        let isDir = facts["type"]?.lowercased().hasPrefix("dir") ?? false
        let size  = Int64(facts["size"] ?? "0") ?? 0
        let path  = (basePath as NSString).appendingPathComponent(name)
        let url   = URL(fileURLWithPath: path)

        return FileItem(
            id:           path,
            name:         name,
            path:         path,
            size:         isDir ? 0 : size,
            modifiedDate: parseMLSDDate(facts["modify"]),
            isDirectory:  isDir,
            isHidden:     name.hasPrefix("."),
            isSymlink:    false,
            itemType:     isDir ? .folder : FileTypeHelper.detectType(for: url),
            providerType: .ftp,
            connectionId: connection.id
        )
    }

    private func parseDate(parts: [Substring]) -> Date {
        guard parts.count >= 8 else { return Date() }
        let dateStr = "\(parts[5]) \(parts[6]) \(parts[7])"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["MMM dd HH:mm", "MMM  d HH:mm", "MMM dd yyyy", "MMM  d yyyy"] {
            formatter.dateFormat = fmt
            if let date = formatter.date(from: dateStr) { return date }
        }
        return Date()
    }

    private func parseMLSDDate(_ str: String?) -> Date {
        guard let str = str else { return Date() }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: str) ?? Date()
    }
}
