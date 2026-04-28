import Foundation

// MARK: - FTP Service (URLSession / CFStream based)

final class FTPService: FileProvider {
    let providerType: ProviderType = .ftp
    private(set) var isConnected: Bool = false

    private let connection: ServerConnection
    private var password: String { KeychainHelper.shared.password(for: connection) }
    private var baseURL: URL
    private let rootPath: String
    private let session: URLSession

    init(connection: ServerConnection) {
        self.connection = connection
        let scheme = connection.usesSSL ? "ftps" : "ftp"
        self.baseURL = URL(string: "\(scheme)://\(connection.host):\(connection.port)")
            ?? URL(string: "ftp://localhost")!
        let normalizedBase = connection.basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedBase.isEmpty || normalizedBase == "/" {
            self.rootPath = "/"
        } else {
            self.rootPath = normalizedBase.hasPrefix("/") ? normalizedBase : "/\(normalizedBase)"
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    // MARK: - Connect / Disconnect

    func connect() async throws {
        // Validate credentials with a LIST of basePath
        _ = try await performList(path: connection.basePath)
        isConnected = true
    }

    func disconnect() {
        isConnected = false
    }

    // MARK: - List

    func listDirectory(at path: String) async throws -> [FileItem] {
        let resolved = resolvePath(path)
        let lines = try await performList(path: resolved)
        return parseFTPListing(lines, basePath: resolved)
    }

    // MARK: - Info

    func getInfo(at path: String) async throws -> FileItem {
        let parent = (path as NSString).deletingLastPathComponent
        let name   = (path as NSString).lastPathComponent
        let items  = try await listDirectory(at: parent)
        guard let item = items.first(where: { $0.name == name }) else {
            throw FileProviderError.fileNotFound(path)
        }
        return item
    }

    // MARK: - Download

    func download(from path: String, progress: ProgressHandler?) async throws -> Data {
        let url = ftpURL(for: resolvePath(path))
        let request = authorisedRequest(url: url)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        progress?(1.0)
        return data
    }

    // MARK: - Upload

    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws {
        let url = ftpURL(for: resolvePath(path))
        var request = authorisedRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody   = data
        let (_, response)  = try await session.data(for: request)
        try validateResponse(response)
        progress?(1.0)
    }

    // MARK: - Mutating ops (via FTP commands over URLSession)

    func delete(at path: String) async throws {
        throw FileProviderError.unsupportedOperation
    }

    func createDirectory(at path: String) async throws {
        throw FileProviderError.unsupportedOperation
    }

    func rename(at path: String, to newName: String) async throws {
        throw FileProviderError.unsupportedOperation
    }

    func move(from src: String, to dst: String) async throws {
        throw FileProviderError.unsupportedOperation
    }

    // MARK: - Private helpers

    private func ftpURL(for path: String) -> URL {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(clean)
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

    private func authorisedRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        if !connection.anonymousLogin {
            let creds = "\(connection.username):\(password)"
            if let encoded = creds.data(using: .utf8)?.base64EncodedString() {
                req.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
            }
        }
        return req
    }

    private func performList(path: String) async throws -> String {
        let url  = ftpURL(for: path.hasSuffix("/") ? path : path + "/")
        let req  = authorisedRequest(url: url)
        let (data, response) = try await session.data(for: req)
        try validateResponse(response)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func validateResponse(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 530 {
                throw FileProviderError.authenticationFailed("Invalid credentials")
            }
            throw FileProviderError.serverError(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    // MARK: - Unix listing parser (MLSD / LIST)

    private func parseFTPListing(_ listing: String, basePath: String) -> [FileItem] {
        var items: [FileItem] = []
        let lines = listing.components(separatedBy: "\n").filter { !$0.isEmpty }
        for line in lines {
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
            id: path,
            name: name,
            path: path,
            size: isDir ? 0 : size,
            modifiedDate: parseDate(parts: parts),
            isDirectory: isDir,
            isHidden: name.hasPrefix("."),
            isSymlink: isLink,
            itemType: isDir ? .folder : FileTypeHelper.detectType(for: url),
            providerType: .ftp,
            connectionId: connection.id
        )
    }

    private func parseMLSDLine(_ line: String, basePath: String) -> FileItem? {
        // Format: Type=file;Size=1234;Modify=20230101120000; filename
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
            id: path,
            name: name,
            path: path,
            size: isDir ? 0 : size,
            modifiedDate: parseMLSDDate(facts["modify"]),
            isDirectory: isDir,
            isHidden: name.hasPrefix("."),
            isSymlink: false,
            itemType: isDir ? .folder : FileTypeHelper.detectType(for: url),
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

// MARK: - SFTP Service (via NMSSH)

final class SFTPService: FileProvider {
    let providerType: ProviderType = .sftp
    private(set) var isConnected: Bool = false

    private let connection: ServerConnection
    private var password: String { KeychainHelper.shared.password(for: connection) }

    // NMSSH session – imported via CocoaPods
    // private var session: NMSSHSession?
    // private var sftp:    NMSFTP?

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func connect() async throws {
        // NMSSH integration:
        // session = NMSSHSession(host: connection.host, port: connection.port, andUsername: connection.username)
        // session?.connect()
        // session?.authenticate(byPassword: password)
        // sftp = NMSFTP.connect(with: session!)
        // isConnected = sftp?.isConnected ?? false
        //
        // Stub until NMSSH pod is linked:
        throw FileProviderError.networkError("SFTP requires NMSSH pod. Run `pod install` first.")
    }

    func disconnect() {
        // sftp?.disconnect()
        // session?.disconnect()
        isConnected = false
    }

    func listDirectory(at path: String) async throws -> [FileItem] {
        guard isConnected else { throw FileProviderError.notConnected }
        // let entries = sftp?.contentsOfDirectory(atPath: path) ?? []
        // return entries.compactMap { makeItem($0, parent: path) }
        return []
    }

    func getInfo(at path: String) async throws -> FileItem {
        throw FileProviderError.unsupportedOperation
    }

    func download(from path: String, progress: ProgressHandler?) async throws -> Data {
        guard isConnected else { throw FileProviderError.notConnected }
        // return sftp?.contents(atPath: path) ?? Data()
        throw FileProviderError.unsupportedOperation
    }

    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws {
        guard isConnected else { throw FileProviderError.notConnected }
        // sftp?.writeContents(data, toFileAtPath: path)
    }

    func delete(at path: String) async throws {
        // sftp?.removeFile(atPath: path)
    }

    func createDirectory(at path: String) async throws {
        // sftp?.createDirectory(atPath: path)
    }

    func rename(at path: String, to newName: String) async throws {
        let parent  = (path as NSString).deletingLastPathComponent
        let newPath = (parent as NSString).appendingPathComponent(newName)
        _ = newPath
        // sftp?.moveItem(atPath: path, toPath: newPath)
    }

    func move(from src: String, to dst: String) async throws {
        // sftp?.moveItem(atPath: src, toPath: dst)
    }
}

// MARK: - SMB Service

final class SMBService: FileProvider {
    let providerType: ProviderType = .smb
    private(set) var isConnected: Bool = false

    private let connection: ServerConnection

    init(connection: ServerConnection) {
        self.connection = connection
    }

    // SMB/CIFS on iOS requires a third-party library such as AMSMB2.
    // https://github.com/amosavian/AMSMB2

    func connect() async throws {
        throw FileProviderError.networkError("SMB support requires AMSMB2 pod. Run `pod install`.")
    }

    func disconnect() { isConnected = false }

    func listDirectory(at path: String) async throws -> [FileItem] { [] }
    func getInfo(at path: String) async throws -> FileItem { throw FileProviderError.unsupportedOperation }
    func download(from path: String, progress: ProgressHandler?) async throws -> Data { Data() }
    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws {}
    func delete(at path: String) async throws {}
    func createDirectory(at path: String) async throws {}
    func rename(at path: String, to newName: String) async throws {}
    func move(from src: String, to dst: String) async throws {}
}
