import Foundation
import Network
import Observation

// MARK: - Network Discovery (SSDP + mDNS)

@Observable
@MainActor
final class NetworkDiscovery {
    var discoveredDevices: [UPnPDevice] = []
    var isDiscovering: Bool = false

    @ObservationIgnored private var connections: [NWConnection] = []
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var knownLocations = Set<String>()

    @ObservationIgnored static let shared = NetworkDiscovery()
    private init() {}

    // MARK: - Start discovery

    func startDiscovery() {
        guard !isDiscovering else { return }
        isDiscovering     = true
        discoveredDevices = []
        knownLocations    = []

        discoveryTask = Task {
            await sendSSDPSearch()
        }
    }

    func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask   = nil
        connections.forEach { $0.cancel() }
        connections     = []
        isDiscovering   = false
    }

    // MARK: - SSDP M-SEARCH

    private func sendSSDPSearch() async {
        defer { isDiscovering = false }

        let ssdpAddress  = "239.255.255.250"
        let ssdpPort: UInt16 = 1900

        let searchTargets = [
            "ssdp:all",
            "upnp:rootdevice",
            "urn:schemas-upnp-org:device:MediaServer:1",
            "urn:schemas-upnp-org:service:ContentDirectory:1"
        ]

        for (index, target) in searchTargets.enumerated() {
            guard !Task.isCancelled else { break }
            let message = """
            M-SEARCH * HTTP/1.1\r\n
            HOST: \(ssdpAddress):\(ssdpPort)\r\n
            MAN: "ssdp:discover"\r\n
            MX: 3\r\n
            ST: \(target)\r\n
            \r\n
            """

            // Use one UDP connection per search target and keep receiving
            // responses on that socket briefly after sending M-SEARCH.
            await sendUDPAndCollectResponses(
                message: message,
                host: ssdpAddress,
                port: ssdpPort,
                receiveDuration: index == searchTargets.count - 1 ? 5.0 : 2.5
            )
        }
    }

    private func sendUDPAndCollectResponses(
        message: String,
        host: String,
        port: UInt16,
        receiveDuration: TimeInterval
    ) async {
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )
        connections.append(conn)
        conn.start(queue: DispatchQueue(label: "ssdp.discovery.\(UUID().uuidString)"))

        let deadline = Date().addingTimeInterval(receiveDuration)
        receiveResponses(on: conn, until: deadline)

        let data = message.data(using: .utf8) ?? Data()
        conn.send(content: data, completion: .idempotent)
        try? await Task.sleep(nanoseconds: UInt64(receiveDuration * 1_000_000_000))
        conn.cancel()
    }

    private func receiveResponses(on connection: NWConnection, until deadline: Date) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }

            guard let data = data,
                  let str = String(data: data, encoding: .utf8) else {
                if error == nil, Date() < deadline {
                    self.receiveResponses(on: connection, until: deadline)
                }
                return
            }

            Task { @MainActor in
                self.parseSSDPResponse(str)
            }

            if error == nil, Date() < deadline {
                self.receiveResponses(on: connection, until: deadline)
            }
        }
    }

    // MARK: - Parse SSDP response

    private func parseSSDPResponse(_ response: String) {
        var headers: [String: String] = [:]
        let lines = response.components(separatedBy: .newlines)
        for line in lines {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let valueStart = line.index(after: idx)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty && !value.isEmpty {
                headers[key] = value
            }
        }

        guard let location = headers["LOCATION"],
              !knownLocations.contains(location) else { return }

        knownLocations.insert(location)

        Task {
            await fetchDeviceDescription(location: location)
        }
    }

    // MARK: - Fetch UPnP device description

    private func fetchDeviceDescription(location: String) async {
        guard let url = URL(string: location) else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }

        let parser = UPnPDeviceParser(data: data, location: location)
        if let device = parser.parse() {
            await MainActor.run {
                if !discoveredDevices.contains(where: { $0.location == device.location }) {
                    discoveredDevices.append(device)
                }
            }
        }
    }
}

// MARK: - UPnP Device XML Parser

private final class UPnPDeviceParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let location: String
    private var current     = ""
    private var friendlyName = ""
    private var modelName   = ""
    private var manufacturer = ""
    private var services: [UPnPDevice.UPnPService] = []
    private var currentServiceType = ""
    private var currentControlURL  = ""
    private var currentEventSubURL = ""
    private var inService = false
    private var baseURL: String

    init(data: Data, location: String) {
        self.data     = data
        self.location = location
        self.baseURL  = URL(string: location).flatMap {
            "\($0.scheme ?? "http")://\($0.host ?? ""):\($0.port ?? 80)"
        } ?? ""
    }

    func parse() -> UPnPDevice? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        guard !friendlyName.isEmpty else { return nil }
        return UPnPDevice(
            friendlyName: friendlyName,
            modelName:    modelName,
            manufacturer: manufacturer,
            location:     location,
            services:     services
        )
    }

    func parser(_ p: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = element.components(separatedBy: ":").last ?? element
        current = local
        if local == "service" {
            inService          = true
            currentServiceType = ""
            currentControlURL  = ""
            currentEventSubURL = ""
        }
    }

    func parser(_ p: XMLParser, foundCharacters string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        switch current {
        case "friendlyName": friendlyName += s
        case "modelName":    modelName    += s
        case "manufacturer": manufacturer += s
        case "serviceType":  if inService { currentServiceType  += s }
        case "controlURL":   if inService { currentControlURL   += s }
        case "eventSubURL":  if inService { currentEventSubURL  += s }
        default: break
        }
    }

    func parser(_ p: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        let local = element.components(separatedBy: ":").last ?? element
        if local == "service", inService {
            inService = false
            let ctrl  = currentControlURL.hasPrefix("/") ? baseURL + currentControlURL : currentControlURL
            let event = currentEventSubURL.hasPrefix("/") ? baseURL + currentEventSubURL : currentEventSubURL
            services.append(UPnPDevice.UPnPService(
                serviceType:  currentServiceType,
                controlURL:   ctrl,
                eventSubURL:  event
            ))
        }
    }
}

// MARK: - UPnP File Service

final class UPnPService: FileProvider {
    let providerType: ProviderType = .upnp
    private(set) var isConnected: Bool = false

    private let connection: ServerConnection
    private var device: UPnPDevice?
    private var contentDirectoryURL: String = ""

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func connect() async throws {
        if connection.host.isEmpty {
            // Wait for discovery
            await NetworkDiscovery.shared.startDiscovery()
            try await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                device = NetworkDiscovery.shared.discoveredDevices.first
            }
        } else {
            device = try await resolveDeviceFromManualEndpoint()
        }

        contentDirectoryURL = device?.services
            .first(where: { $0.serviceType.contains("ContentDirectory") })?
            .controlURL ?? ""
        isConnected = !contentDirectoryURL.isEmpty
        if !isConnected { throw FileProviderError.notConnected }
    }

    func disconnect() { isConnected = false }

    // MARK: - Browse via UPnP ContentDirectory

    func listDirectory(at path: String) async throws -> [FileItem] {
        let objectId = path == "/" ? "0" : path
        let soapBody = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
            <s:Body>
                <u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
                    <ObjectID>\(xmlEscape(objectId))</ObjectID>
                    <BrowseFlag>BrowseDirectChildren</BrowseFlag>
                    <Filter>*</Filter>
                    <StartingIndex>0</StartingIndex>
                    <RequestedCount>0</RequestedCount>
                    <SortCriteria></SortCriteria>
                </u:Browse>
            </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: contentDirectoryURL) else {
            throw FileProviderError.invalidPath(contentDirectoryURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody   = soapBody.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FileProviderError.serverError(http.statusCode, "UPnP browse failed")
        }
        return parseDidlResponse(data, parentPath: path)
    }

    func getInfo(at path: String) async throws -> FileItem {
        throw FileProviderError.unsupportedOperation
    }

    func downloadToTemp(from path: String, progress: ProgressHandler?) async throws -> URL {
        guard let url = URL(string: path) else { throw FileProviderError.invalidPath(path) }
        let req = URLRequest(url: url)
        return try await URLSession.shared.streamDownload(for: req, progress: progress)
    }

    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws {
        throw FileProviderError.unsupportedOperation
    }

    func streamingURL(for path: String) -> StreamingTarget? {
        // UPnP DIDL-Lite already returns a direct HTTP URL in the path.
        guard let url = URL(string: path) else { return nil }
        return StreamingTarget(url: url, headers: [:])
    }

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

    // MARK: - Manual endpoint fallback (no multicast required)

    private func resolveDeviceFromManualEndpoint() async throws -> UPnPDevice {
        for location in manualDescriptionCandidates() {
            if let device = await fetchDeviceDescription(at: location) {
                return device
            }
        }
        throw FileProviderError.notConnected
    }

    private func manualDescriptionCandidates() -> [String] {
        let hostInput = connection.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostInput.isEmpty else { return [] }

        // If user entered a full description URL, use it first.
        if hostInput.hasPrefix("http://") || hostInput.hasPrefix("https://"),
           let url = URL(string: hostInput),
           let host = url.host {
            let basePort = url.port ?? (url.scheme == "https" ? 443 : 80)
            let base = "\(url.scheme ?? "http")://\(host):\(basePort)"
            var candidates: [String] = [hostInput]
            // BubbleUPnP Server commonly uses 58050.
            if basePort != 58050 {
                candidates.append(contentsOf: bubbleUPnPCandidates(host: host))
            }
            candidates.append(contentsOf: genericDescriptionCandidates(base: base))
            return Array(Set(candidates))
        }

        let baseHost = hostInput.replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let scheme = connection.usesSSL ? "https" : "http"
        let requestedPort = connection.port > 0 ? connection.port : 80
        let requestedBase = "\(scheme)://\(baseHost):\(requestedPort)"

        var candidates = genericDescriptionCandidates(base: requestedBase)
        // BubbleUPnP-specific fallback endpoints.
        if requestedPort != 58050 {
            candidates.append(contentsOf: bubbleUPnPCandidates(host: baseHost))
        }

        return Array(Set(candidates))
    }

    private func genericDescriptionCandidates(base: String) -> [String] {
        [
            "\(base)/rootDesc.xml",
            "\(base)/RootDevice.xml",
            "\(base)/rootDevice.xml",
            "\(base)/description.xml",
            "\(base)/device.xml",
            "\(base)/xml/device_description.xml",
            "\(base)/"
        ]
    }

    private func bubbleUPnPCandidates(host: String) -> [String] {
        let base = "http://\(host):58050"
        return [
            "\(base)/rootDesc.xml",
            "\(base)/RootDevice.xml",
            "\(base)/rootDevice.xml",
            "\(base)/description.xml",
            "\(base)/"
        ]
    }

    private func fetchDeviceDescription(at location: String) async -> UPnPDevice? {
        guard let url = URL(string: location) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        let parser = UPnPDeviceParser(data: data, location: location)
        return parser.parse()
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - DIDL-Lite parser

    private func parseDidlResponse(_ data: Data, parentPath: String) -> [FileItem] {
        let parser = DIDLParser(data: data, parentPath: parentPath, connectionId: connection.id)
        return (try? parser.parse()) ?? []
    }
}

// MARK: - DIDL-Lite Parser

private final class DIDLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let parentPath: String
    private let connectionId: UUID
    private var items: [FileItem]    = []
    private var current              = ""
    private var currentId            = ""
    private var currentTitle         = ""
    private var currentClass         = ""
    private var currentSize          = ""
    private var currentRes           = ""
    private var inItem               = false
    private var inContainer          = false

    init(data: Data, parentPath: String, connectionId: UUID) {
        self.data         = data
        self.parentPath   = parentPath
        self.connectionId = connectionId
    }

    func parse() throws -> [FileItem] {
        guard let str = String(data: data, encoding: .utf8),
              let didl = extractDIDL(fromSOAP: str) else { return [] }

        guard let didlData = didl.data(using: .utf8) else { return [] }
        let parser         = XMLParser(data: didlData)
        parser.delegate    = self
        parser.parse()
        return items
    }

    private func extractDIDL(fromSOAP xml: String) -> String? {
        let pattern = "<(?:\\w+:)?Result[^>]*>(.*?)</(?:\\w+:)?Result>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: xml, options: [], range: NSRange(location: 0, length: xml.utf16.count)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }

        var didl = String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        if didl.hasPrefix("<![CDATA["), didl.hasSuffix("]]>") {
            didl = String(didl.dropFirst(9).dropLast(3))
        } else {
            didl = didl
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
        }
        return didl
    }

    func parser(_ p: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = element.components(separatedBy: ":").last ?? element
        current   = local
        if local == "item" {
            inItem        = true; inContainer = false
            currentId     = attributes["id"] ?? ""; currentTitle = ""
            currentClass  = ""; currentSize = ""; currentRes = ""
        } else if local == "container" {
            inContainer   = true; inItem = false
            currentId     = attributes["id"] ?? ""; currentTitle = ""
        } else if local == "res", let size = attributes["size"] {
            currentSize   = size
        }
    }

    func parser(_ p: XMLParser, foundCharacters string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        switch current {
        case "title":   currentTitle += s
        case "class":   currentClass += s
        case "res":     if currentRes.isEmpty { currentRes = s }
        default: break
        }
    }

    func parser(_ p: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        let local = element.components(separatedBy: ":").last ?? element
        guard (local == "item" && inItem) || (local == "container" && inContainer) else { return }

        let isDir  = inContainer
        let path   = currentId
        let resURL = currentRes
        let url    = URL(fileURLWithPath: resURL.isEmpty ? path : resURL)

        items.append(FileItem(
            id:            path,
            name:          currentTitle,
            path:          isDir ? path : (resURL.isEmpty ? path : resURL),
            size:          Int64(currentSize) ?? 0,
            modifiedDate:  Date(),
            isDirectory:   isDir,
            isHidden:      false,
            isSymlink:     false,
            itemType:      isDir ? .folder : FileTypeHelper.detectType(for: url),
            providerType:  .upnp,
            connectionId:  connectionId
        ))
        inItem = false; inContainer = false
    }
}
