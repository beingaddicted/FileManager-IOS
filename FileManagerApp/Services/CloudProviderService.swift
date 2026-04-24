import Foundation

// MARK: - Google Drive Service

final class GoogleDriveService: FileProvider {
    let providerType: ProviderType = .googleDrive
    private(set) var isConnected: Bool = false

    private let connection: ServerConnection
    private var accessToken: String { KeychainHelper.shared.token(for: .googleDrive) ?? "" }
    private let baseURL = "https://www.googleapis.com/drive/v3"
    private let uploadURL = "https://www.googleapis.com/upload/drive/v3"

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func connect() async throws {
        guard !accessToken.isEmpty else {
            throw FileProviderError.authenticationFailed("No access token. Please authenticate via OAuth.")
        }
        _ = try await apiRequest(path: "/about?fields=user")
        isConnected = true
    }

    func disconnect() { isConnected = false }

    // MARK: - List

    func listDirectory(at path: String) async throws -> [FileItem] {
        let parentId = path == "/" ? "root" : path
        let query    = "'\(parentId)' in parents and trashed=false"
        let fields   = "files(id,name,mimeType,size,modifiedTime,createdTime)"
        let encoded  = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let data     = try await apiRequest(path: "/files?q=\(encoded)&fields=\(fields)&pageSize=1000")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [[String: Any]] else { return [] }

        return files.compactMap { makeItem($0, parentPath: path) }
    }

    // MARK: - Info

    func getInfo(at path: String) async throws -> FileItem {
        let data = try await apiRequest(path: "/files/\(path)?fields=id,name,mimeType,size,modifiedTime,createdTime")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = makeItem(json, parentPath: "") else {
            throw FileProviderError.fileNotFound(path)
        }
        return item
    }

    // MARK: - Download

    func download(from path: String, progress: ProgressHandler?) async throws -> Data {
        let data = try await apiRequest(path: "/files/\(path)?alt=media")
        progress?(1.0)
        return data
    }

    // MARK: - Upload

    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws {
        let parent   = (path as NSString).deletingLastPathComponent
        let name     = (path as NSString).lastPathComponent
        let parentId = parent == "/" ? "root" : parent
        let metadata: [String: Any] = ["name": name, "parents": [parentId]]
        let metaData = try? JSONSerialization.data(withJSONObject: metadata)

        var req = URLRequest(url: URL(string: "\(uploadURL)/files?uploadType=multipart")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metaData ?? Data())
        body.append("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--".data(using: .utf8)!)
        req.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response)
        progress?(1.0)
    }

    func delete(at path: String) async throws {
        var req = URLRequest(url: URL(string: "\(baseURL)/files/\(path)")!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response)
    }

    func createDirectory(at path: String) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        let name   = (path as NSString).lastPathComponent
        let parentId = parent == "/" ? "root" : parent
        let metadata: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parentId]
        ]
        let body = try? JSONSerialization.data(withJSONObject: metadata)
        var req  = URLRequest(url: URL(string: "\(baseURL)/files")!)
        req.httpMethod  = "POST"
        req.httpBody    = body
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response)
    }

    func rename(at path: String, to newName: String) async throws {
        let body = try? JSONSerialization.data(withJSONObject: ["name": newName])
        var req  = URLRequest(url: URL(string: "\(baseURL)/files/\(path)")!)
        req.httpMethod  = "PATCH"
        req.httpBody    = body
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response)
    }

    func move(from src: String, to dst: String) async throws {
        let newParent    = (dst as NSString).deletingLastPathComponent
        let newParentId  = newParent == "/" ? "root" : newParent
        var req = URLRequest(url: URL(string: "\(baseURL)/files/\(src)?addParents=\(newParentId)&removeParents=root")!)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response)
    }

    // MARK: - Private

    private func apiRequest(path: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response)
        return data
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299: return
        case 401, 403:  throw FileProviderError.authenticationFailed("HTTP \(http.statusCode)")
        case 404:       throw FileProviderError.fileNotFound("Not found")
        default:        throw FileProviderError.serverError(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    private func makeItem(_ json: [String: Any], parentPath: String) -> FileItem? {
        guard let id   = json["id"]   as? String,
              let name = json["name"] as? String else { return nil }
        let mime     = json["mimeType"] as? String ?? ""
        let isDir    = mime == "application/vnd.google-apps.folder"
        let size     = Int64((json["size"] as? String) ?? "0") ?? 0
        let modified = parseDate(json["modifiedTime"] as? String) ?? Date()
        let created  = parseDate(json["createdTime"]  as? String)
        let ext      = (name as NSString).pathExtension
        let url      = URL(fileURLWithPath: name)

        return FileItem(
            id:           id,
            name:         name,
            path:         id,
            size:         isDir ? 0 : size,
            modifiedDate: modified,
            createdDate:  created,
            isDirectory:  isDir,
            isHidden:     false,
            isSymlink:    false,
            itemType:     isDir ? .folder : FileTypeHelper.detectType(for: url),
            providerType: .googleDrive,
            mimeType:     mime,
            connectionId: connection.id
        )
    }

    private func parseDate(_ str: String?) -> Date? {
        guard let str = str else { return nil }
        let f = ISO8601DateFormatter()
        return f.date(from: str)
    }
}

// MARK: - Dropbox Service

final class DropboxService: FileProvider {
    let providerType: ProviderType = .dropbox
    private(set) var isConnected: Bool = false

    private let connection: ServerConnection
    private var accessToken: String { KeychainHelper.shared.token(for: .dropbox) ?? "" }
    private let apiURL     = "https://api.dropboxapi.com/2"
    private let contentURL = "https://content.dropboxapi.com/2"

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func connect() async throws {
        guard !accessToken.isEmpty else {
            throw FileProviderError.authenticationFailed("No Dropbox access token. Please authenticate.")
        }
        _ = try await rpc(endpoint: "/users/get_current_account", body: nil)
        isConnected = true
    }

    func disconnect() { isConnected = false }

    func listDirectory(at path: String) async throws -> [FileItem] {
        let body: [String: Any] = [
            "path":                     path == "/" ? "" : path,
            "recursive":                false,
            "include_media_info":       false,
            "include_deleted":          false,
            "include_has_explicit_shared_members": false
        ]
        let data  = try await rpc(endpoint: "/files/list_folder", body: body)
        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else { return [] }
        return entries.compactMap { makeItem($0) }
    }

    func getInfo(at path: String) async throws -> FileItem {
        let data = try await rpc(endpoint: "/files/get_metadata", body: ["path": path])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = makeItem(json) else {
            throw FileProviderError.fileNotFound(path)
        }
        return item
    }

    func download(from path: String, progress: ProgressHandler?) async throws -> Data {
        var req = URLRequest(url: URL(string: "\(contentURL)/files/download")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let arg = try! JSONSerialization.data(withJSONObject: ["path": path])
        req.setValue(String(data: arg, encoding: .utf8)!, forHTTPHeaderField: "Dropbox-API-Arg")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response)
        progress?(1.0)
        return data
    }

    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws {
        var req = URLRequest(url: URL(string: "\(contentURL)/files/upload")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let arg = try! JSONSerialization.data(withJSONObject: [
            "path": path, "mode": "overwrite", "autorename": false, "mute": false
        ])
        req.setValue(String(data: arg, encoding: .utf8)!, forHTTPHeaderField: "Dropbox-API-Arg")
        req.httpBody = data
        let (_, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response)
        progress?(1.0)
    }

    func delete(at path: String) async throws {
        _ = try await rpc(endpoint: "/files/delete_v2", body: ["path": path])
    }

    func createDirectory(at path: String) async throws {
        _ = try await rpc(endpoint: "/files/create_folder_v2", body: ["path": path])
    }

    func rename(at path: String, to newName: String) async throws {
        let parent  = (path as NSString).deletingLastPathComponent
        let newPath = (parent as NSString).appendingPathComponent(newName)
        _ = try await rpc(endpoint: "/files/move_v2", body: [
            "from_path": path, "to_path": newPath
        ])
    }

    func move(from src: String, to dst: String) async throws {
        _ = try await rpc(endpoint: "/files/move_v2", body: [
            "from_path": src, "to_path": dst
        ])
    }

    // MARK: - Private

    private func rpc(endpoint: String, body: [String: Any]?) async throws -> Data {
        var req = URLRequest(url: URL(string: "\(apiURL)\(endpoint)")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body = body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        } else {
            req.httpBody = "null".data(using: .utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response)
        return data
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299: return
        case 401, 403:  throw FileProviderError.authenticationFailed("HTTP \(http.statusCode)")
        case 404:       throw FileProviderError.fileNotFound("Not found")
        default:        throw FileProviderError.serverError(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    private func makeItem(_ json: [String: Any]) -> FileItem? {
        guard let tag  = json[".tag"] as? String,
              let path = json["path_display"] as? String,
              let name = json["name"] as? String else { return nil }
        let isDir    = tag == "folder"
        let size     = (json["size"] as? Int).flatMap { Int64($0) } ?? 0
        let modified = parseDate(json["server_modified"] as? String) ?? Date()
        let url      = URL(fileURLWithPath: name)
        return FileItem(
            id:           path,
            name:         name,
            path:         path,
            size:         isDir ? 0 : size,
            modifiedDate: modified,
            isDirectory:  isDir,
            isHidden:     false,
            isSymlink:    false,
            itemType:     isDir ? .folder : FileTypeHelper.detectType(for: url),
            providerType: .dropbox,
            connectionId: connection.id
        )
    }

    private func parseDate(_ str: String?) -> Date? {
        guard let str = str else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }
}

// MARK: - OneDrive Service (Microsoft Graph)

final class OneDriveService: FileProvider {
    let providerType: ProviderType = .oneDrive
    private(set) var isConnected: Bool = false

    private let connection: ServerConnection
    private var accessToken: String { KeychainHelper.shared.token(for: .oneDrive) ?? "" }
    private let baseURL = "https://graph.microsoft.com/v1.0/me/drive"

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func connect() async throws {
        guard !accessToken.isEmpty else {
            throw FileProviderError.authenticationFailed("No OneDrive access token. Please authenticate.")
        }
        _ = try await graphRequest(path: "/root")
        isConnected = true
    }

    func disconnect() { isConnected = false }

    func listDirectory(at path: String) async throws -> [FileItem] {
        let itemPath = path == "/" ? "/root/children" : "/items/\(path)/children"
        let data     = try await graphRequest(path: itemPath)
        guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["value"] as? [[String: Any]] else { return [] }
        return items.compactMap { makeItem($0) }
    }

    func getInfo(at path: String) async throws -> FileItem {
        let itemPath = path == "/" ? "/root" : "/items/\(path)"
        let data     = try await graphRequest(path: itemPath)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = makeItem(json) else {
            throw FileProviderError.fileNotFound(path)
        }
        return item
    }

    func download(from path: String, progress: ProgressHandler?) async throws -> Data {
        let data = try await graphRequest(path: "/items/\(path)/content")
        progress?(1.0)
        return data
    }

    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws {
        let name   = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        let parentId = parent == "/" ? "root" : parent
        var req = URLRequest(url: URL(string: "\(baseURL)/items/\(parentId):/\(name):/content")!)
        req.httpMethod = "PUT"
        req.httpBody   = data
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response)
        progress?(1.0)
    }

    func delete(at path: String) async throws {
        var req = URLRequest(url: URL(string: "\(baseURL)/items/\(path)")!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response)
    }

    func createDirectory(at path: String) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        let name   = (path as NSString).lastPathComponent
        let parentId = parent == "/" ? "root" : parent
        let body: [String: Any] = ["name": name, "folder": [:], "@microsoft.graph.conflictBehavior": "rename"]
        var req = URLRequest(url: URL(string: "\(baseURL)/items/\(parentId)/children")!)
        req.httpMethod = "POST"
        req.httpBody   = try? JSONSerialization.data(withJSONObject: body)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response)
    }

    func rename(at path: String, to newName: String) async throws {
        let body = ["name": newName]
        var req  = URLRequest(url: URL(string: "\(baseURL)/items/\(path)")!)
        req.httpMethod = "PATCH"
        req.httpBody   = try? JSONSerialization.data(withJSONObject: body)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response)
    }

    func move(from src: String, to dst: String) async throws {
        let newParent = (dst as NSString).deletingLastPathComponent
        let body: [String: Any] = ["parentReference": ["id": newParent]]
        var req = URLRequest(url: URL(string: "\(baseURL)/items/\(src)")!)
        req.httpMethod = "PATCH"
        req.httpBody   = try? JSONSerialization.data(withJSONObject: body)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response)
    }

    // MARK: - Private

    private func graphRequest(path: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response)
        return data
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299: return
        case 401, 403:  throw FileProviderError.authenticationFailed("HTTP \(http.statusCode)")
        case 404:       throw FileProviderError.fileNotFound("Not found")
        default:        throw FileProviderError.serverError(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    private func makeItem(_ json: [String: Any]) -> FileItem? {
        guard let id   = json["id"]   as? String,
              let name = json["name"] as? String else { return nil }
        let isDir    = json["folder"] != nil
        let size     = (json["size"] as? Int).flatMap { Int64($0) } ?? 0
        let modified = parseDate((json["lastModifiedDateTime"] as? String) ?? "") ?? Date()
        let created  = parseDate(json["createdDateTime"] as? String ?? "")
        let url      = URL(fileURLWithPath: name)
        return FileItem(
            id:           id,
            name:         name,
            path:         id,
            size:         isDir ? 0 : size,
            modifiedDate: modified,
            createdDate:  created,
            isDirectory:  isDir,
            isHidden:     false,
            isSymlink:    false,
            itemType:     isDir ? .folder : FileTypeHelper.detectType(for: url),
            providerType: .oneDrive,
            connectionId: connection.id
        )
    }

    private func parseDate(_ str: String) -> Date? {
        ISO8601DateFormatter().date(from: str)
    }
}
