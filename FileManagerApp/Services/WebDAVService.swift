import Foundation

// MARK: - WebDAV Service
//
// Streaming-first WebDAV (RFC 4918) client. Supports Synology, Nextcloud,
// ownCloud, mod_dav, sabredav, and Box-style WebDAV endpoints.

final class WebDAVService: FileProvider {
    let providerType: ProviderType = .webdav
    private(set) var isConnected: Bool = false

    private let connection: ServerConnection
    private var password: String { KeychainHelper.shared.password(for: connection) }
    private let session: URLSession
    private let baseURL: URL
    private let rootPath: String

    init(connection: ServerConnection) {
        self.connection = connection
        let scheme   = connection.usesSSL ? "https" : "http"
        let port     = connection.port
        self.baseURL = URL(string: "\(scheme)://\(connection.host):\(port)") ?? URL(string: "http://localhost")!

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 30
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity       = true
        config.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: config)

        let normalized = connection.basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == "/" {
            self.rootPath = "/"
        } else {
            self.rootPath = normalized.hasPrefix("/") ? normalized : "/\(normalized)"
        }
    }

    // MARK: - Connect

    func connect() async throws {
        _ = try await propfind(path: connection.basePath, depth: "0")
        isConnected = true
    }

    func disconnect() { isConnected = false }

    // MARK: - List / Info

    func listDirectory(at path: String) async throws -> [FileItem] {
        let xml   = try await propfind(path: path, depth: "1")
        let items = try parseMultiStatus(xml: xml, basePath: path)
        return items.filter { $0.path != path }
    }

    func getInfo(at path: String) async throws -> FileItem {
        let xml   = try await propfind(path: path, depth: "0")
        let items = try parseMultiStatus(xml: xml, basePath: path)
        guard let item = items.first else { throw FileProviderError.fileNotFound(path) }
        return item
    }

    // MARK: - Download (streaming → file URL)

    func downloadToTemp(from path: String, progress: ProgressHandler?) async throws -> URL {
        let req = authorizedRequest(method: "GET", path: path)
        return try await session.streamDownload(for: req, progress: progress)
    }

    // MARK: - Upload

    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws {
        var req       = authorizedRequest(method: "PUT", path: path)
        req.httpBody  = data
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        let (_, response) = try await session.data(for: req)
        try validate(response, path: path)
        progress?(1.0)
    }

    func uploadFile(at localURL: URL, to path: String, progress: ProgressHandler?) async throws {
        // Use upload(fromFile:) so large files don't hit RAM.
        let req = authorizedRequest(method: "PUT", path: path)
        let (_, response) = try await session.upload(for: req, fromFile: localURL)
        try validate(response, path: path)
        progress?(1.0)
    }

    // MARK: - Mutating ops

    func delete(at path: String) async throws {
        let req = authorizedRequest(method: "DELETE", path: path)
        let (_, response) = try await session.data(for: req)
        try validate(response, path: path)
    }

    func createDirectory(at path: String) async throws {
        let req = authorizedRequest(method: "MKCOL", path: path)
        let (_, response) = try await session.data(for: req)
        try validate(response, path: path)
    }

    func rename(at path: String, to newName: String) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        let dst    = (parent as NSString).appendingPathComponent(newName)
        try await move(from: path, to: dst)
    }

    func move(from src: String, to dst: String) async throws {
        var req = authorizedRequest(method: "MOVE", path: src)
        req.setValue(absoluteURL(for: dst).absoluteString, forHTTPHeaderField: "Destination")
        req.setValue("T", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await session.data(for: req)
        try validate(response, path: src)
    }

    func copy(from src: String, to dst: String) async throws {
        var req = authorizedRequest(method: "COPY", path: src)
        req.setValue(absoluteURL(for: dst).absoluteString, forHTTPHeaderField: "Destination")
        req.setValue("T", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await session.data(for: req)
        try validate(response, path: src)
    }

    // MARK: - Streaming URL for AVPlayer

    func streamingURL(for path: String) -> StreamingTarget? {
        var headers: [String: String] = [:]
        if !connection.anonymousLogin {
            let creds   = "\(connection.username):\(password)"
            let encoded = Data(creds.utf8).base64EncodedString()
            headers["Authorization"] = "Basic \(encoded)"
        }
        return StreamingTarget(url: absoluteURL(for: path), headers: headers)
    }

    // MARK: - Private

    private func propfind(path: String, depth: String) async throws -> Data {
        var req = authorizedRequest(method: "PROPFIND", path: path)
        req.setValue(depth, forHTTPHeaderField: "Depth")
        req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        req.httpBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:displayname/>
            <D:resourcetype/>
            <D:getcontentlength/>
            <D:getlastmodified/>
            <D:creationdate/>
            <D:getetag/>
            <D:getcontenttype/>
          </D:prop>
        </D:propfind>
        """.data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        try validate(response, path: path)
        return data
    }

    private func authorizedRequest(method: String, path: String) -> URLRequest {
        var req = URLRequest(url: absoluteURL(for: path))
        req.httpMethod = method
        req.setValue("Mozilla/5.0 (FileManagerApp WebDAV/2.0)", forHTTPHeaderField: "User-Agent")
        if !connection.anonymousLogin {
            let creds   = "\(connection.username):\(password)"
            let encoded = Data(creds.utf8).base64EncodedString()
            req.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func absoluteURL(for path: String) -> URL {
        let resolved = resolvePath(path)
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        // WebDAV servers vary on percent-encoding; use a path-allowed escape so
        // names with spaces / Unicode round-trip correctly.
        let encoded = resolved.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? resolved
        components?.percentEncodedPath = encoded
        return components?.url ?? baseURL
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

    private func validate(_ response: URLResponse, path: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299, 207: return
        case 401, 403:       throw FileProviderError.authenticationFailed("HTTP \(http.statusCode)")
        case 404:            throw FileProviderError.fileNotFound(path)
        default:             throw FileProviderError.serverError(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    private func parseMultiStatus(xml: Data, basePath: String) throws -> [FileItem] {
        try DAVMultiStatusParser(data: xml, basePath: basePath, connectionId: connection.id).parse()
    }
}

// MARK: - DAV XML Parser

private final class DAVMultiStatusParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let basePath: String
    private let connectionId: UUID
    private var items: [FileItem] = []

    private var currentHref         = ""
    private var currentDisplayName  = ""
    private var currentSize         = ""
    private var currentModified     = ""
    private var currentCreated      = ""
    private var currentContentType  = ""
    private var currentIsCollection = false
    private var inResponse          = false
    private var currentElement      = ""
    private var parseError: Error?

    init(data: Data, basePath: String, connectionId: UUID) {
        self.data         = data
        self.basePath     = basePath
        self.connectionId = connectionId
    }

    func parse() throws -> [FileItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        if let err = parseError { throw err }
        return items
    }

    func parser(_ p: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = element.components(separatedBy: ":").last ?? element
        currentElement = local
        if local == "response" {
            inResponse          = true
            currentHref         = ""
            currentDisplayName  = ""
            currentSize         = ""
            currentModified     = ""
            currentCreated      = ""
            currentContentType  = ""
            currentIsCollection = false
        }
    }

    func parser(_ p: XMLParser, foundCharacters string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        switch currentElement {
        case "href":              currentHref        += s
        case "displayname":       currentDisplayName += s
        case "getcontentlength":  currentSize        += s
        case "getlastmodified":   currentModified    += s
        case "creationdate":      currentCreated     += s
        case "getcontenttype":    currentContentType += s
        case "collection":        currentIsCollection = true
        default: break
        }
    }

    func parser(_ p: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        let local = element.components(separatedBy: ":").last ?? element
        guard local == "response", inResponse else { return }
        inResponse = false

        let path = currentHref.removingPercentEncoding ?? currentHref
        let name = currentDisplayName.isEmpty
            ? (path as NSString).lastPathComponent
            : currentDisplayName
        guard !name.isEmpty, name != ".", name != ".." else { return }

        let size = Int64(currentSize) ?? 0
        let url  = URL(fileURLWithPath: path)

        items.append(FileItem(
            id:           path,
            name:         name,
            path:         path,
            size:         currentIsCollection ? 0 : size,
            modifiedDate: parseDate(currentModified),
            createdDate:  parseDate(currentCreated),
            isDirectory:  currentIsCollection,
            isHidden:     name.hasPrefix("."),
            isSymlink:    false,
            itemType:     currentIsCollection ? .folder : FileTypeHelper.detectType(for: url),
            providerType: .webdav,
            mimeType:     currentContentType.isEmpty ? nil : currentContentType,
            connectionId: connectionId
        ))
    }

    private func parseDate(_ str: String) -> Date {
        let fmts = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        ]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in fmts {
            f.dateFormat = fmt
            if let d = f.date(from: str) { return d }
        }
        return Date()
    }
}
