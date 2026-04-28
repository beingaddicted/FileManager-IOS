import Foundation

// MARK: - WebDAV Service

final class WebDAVService: FileProvider {
    let providerType: ProviderType = .webdav
    private(set) var isConnected: Bool = false

    private let connection: ServerConnection
    private var password: String { KeychainHelper.shared.password(for: connection) }
    private var session: URLSession
    private var baseURL: URL
    private let rootPath: String

    init(connection: ServerConnection) {
        self.connection = connection
        let scheme      = connection.usesSSL ? "https" : "http"
        let port        = connection.port
        self.baseURL    = URL(string: "\(scheme)://\(connection.host):\(port)") ?? URL(string: "http://localhost")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        let normalizedBase = connection.basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedBase.isEmpty || normalizedBase == "/" {
            self.rootPath = "/"
        } else {
            self.rootPath = normalizedBase.hasPrefix("/") ? normalizedBase : "/\(normalizedBase)"
        }
    }

    // MARK: - Connect

    func connect() async throws {
        _ = try await propfind(path: connection.basePath, depth: "0")
        isConnected = true
    }

    func disconnect() { isConnected = false }

    // MARK: - List

    func listDirectory(at path: String) async throws -> [FileItem] {
        let xml   = try await propfind(path: path, depth: "1")
        let items = try parseMultiStatus(xml: xml, basePath: path)
        return items.filter { $0.path != path }   // remove self
    }

    // MARK: - Info

    func getInfo(at path: String) async throws -> FileItem {
        let xml   = try await propfind(path: path, depth: "0")
        let items = try parseMultiStatus(xml: xml, basePath: path)
        guard let item = items.first else { throw FileProviderError.fileNotFound(path) }
        return item
    }

    // MARK: - Download

    func download(from path: String, progress: ProgressHandler?) async throws -> Data {
        var req = request(method: "GET", path: path)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        try validate(response, path: path)
        progress?(1.0)
        return data
    }

    // MARK: - Upload

    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws {
        var req       = request(method: "PUT", path: path)
        req.httpBody  = data
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        let (_, response) = try await session.data(for: req)
        try validate(response, path: path)
        progress?(1.0)
    }

    // MARK: - Delete

    func delete(at path: String) async throws {
        let req = request(method: "DELETE", path: path)
        let (_, response) = try await session.data(for: req)
        try validate(response, path: path)
    }

    // MARK: - Create directory

    func createDirectory(at path: String) async throws {
        let req = request(method: "MKCOL", path: path)
        let (_, response) = try await session.data(for: req)
        try validate(response, path: path)
    }

    // MARK: - Rename / Move

    func rename(at path: String, to newName: String) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        let dst    = (parent as NSString).appendingPathComponent(newName)
        try await move(from: path, to: dst)
    }

    func move(from src: String, to dst: String) async throws {
        var req = request(method: "MOVE", path: src)
        req.setValue(absoluteURL(for: dst).absoluteString, forHTTPHeaderField: "Destination")
        req.setValue("T", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await session.data(for: req)
        try validate(response, path: src)
    }

    func copy(from src: String, to dst: String) async throws {
        var req = request(method: "COPY", path: src)
        req.setValue(absoluteURL(for: dst).absoluteString, forHTTPHeaderField: "Destination")
        req.setValue("T", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await session.data(for: req)
        try validate(response, path: src)
    }

    // MARK: - Private

    private func propfind(path: String, depth: String) async throws -> Data {
        var req = request(method: "PROPFIND", path: path)
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
            </D:prop>
        </D:propfind>
        """.data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        try validate(response, path: path)
        return data
    }

    private func request(method: String, path: String) -> URLRequest {
        var req = URLRequest(url: absoluteURL(for: path))
        req.httpMethod = method
        if !connection.anonymousLogin {
            let creds   = "\(connection.username):\(password)"
            let encoded = Data(creds.utf8).base64EncodedString()
            req.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func absoluteURL(for path: String) -> URL {
        let resolvedPath = resolvePath(path)
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = resolvedPath
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

    // MARK: - XML parser for DAV multistatus

    private func parseMultiStatus(xml: Data, basePath: String) throws -> [FileItem] {
        let parser = DAVMultiStatusParser(data: xml, basePath: basePath, connectionId: connection.id)
        return try parser.parse()
    }
}

// MARK: - DAV XML Parser

private final class DAVMultiStatusParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let basePath: String
    private let connectionId: UUID
    private var items: [FileItem] = []

    private var currentHref        = ""
    private var currentDisplayName = ""
    private var currentSize        = ""
    private var currentModified    = ""
    private var currentCreated     = ""
    private var currentIsCollection = false
    private var inResponse         = false
    private var currentElement     = ""
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
            currentIsCollection = false
        }
    }

    func parser(_ p: XMLParser, foundCharacters string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        switch currentElement {
        case "href":         currentHref        += s
        case "displayname":  currentDisplayName += s
        case "getcontentlength": currentSize    += s
        case "getlastmodified":  currentModified += s
        case "creationdate":     currentCreated  += s
        case "collection":       currentIsCollection = true
        default: break
        }
    }

    func parser(_ p: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        let local = element.components(separatedBy: ":").last ?? element
        guard local == "response", inResponse else { return }
        inResponse = false

        let path   = currentHref.removingPercentEncoding ?? currentHref
        let name   = currentDisplayName.isEmpty
            ? (path as NSString).lastPathComponent
            : currentDisplayName
        guard !name.isEmpty, name != ".", name != ".." else { return }

        let size = Int64(currentSize) ?? 0
        let url  = URL(fileURLWithPath: path)

        items.append(FileItem(
            id: path,
            name: name,
            path: path,
            size: currentIsCollection ? 0 : size,
            modifiedDate: parseDate(currentModified),
            createdDate:  parseDate(currentCreated),
            isDirectory:  currentIsCollection,
            isHidden:     name.hasPrefix("."),
            isSymlink:    false,
            itemType:     currentIsCollection ? .folder : FileTypeHelper.detectType(for: url),
            providerType: .webdav,
            connectionId: connectionId
        ))
    }

    private func parseDate(_ str: String) -> Date {
        let fmts = ["EEE, dd MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ssXXXXX"]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in fmts {
            f.dateFormat = fmt
            if let d = f.date(from: str) { return d }
        }
        return Date()
    }
}
