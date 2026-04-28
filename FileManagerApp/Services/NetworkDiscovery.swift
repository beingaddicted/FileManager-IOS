import Foundation
import Network
import Combine

// MARK: - Network Discovery (SSDP + mDNS)

@MainActor
final class NetworkDiscovery: ObservableObject {
    @Published var discoveredDevices: [UPnPDevice] = []
    @Published var isDiscovering: Bool = false

    private var connections: [NWConnection] = []
    private var discoveryTask: Task<Void, Never>?
    private var knownLocations = Set<String>()

    static let shared = NetworkDiscovery()
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
            "urn:schemas-upnp-org:device:MediaServer:1"
        ]

        for (index, target) in searchTargets.enumerated() {
            guard !Task.isCancelled else { break }
            let message = """
            M-SEARCH * HTTP/1.1\r
            HOST: \(ssdpAddress):\(ssdpPort)\r
            MAN: "ssdp:discover"\r
            MX: 3\r
            ST: \(target)\r
            \r
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
        let lines = response.components(separatedBy: "\r\n")
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
                    <ObjectID>\(objectId)</ObjectID>
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

        let (data, _) = try await URLSession.shared.data(for: req)
        return parseDidlResponse(data, parentPath: path)
    }

    func getInfo(at path: String) async throws -> FileItem {
        throw FileProviderError.unsupportedOperation
    }

    func download(from path: String, progress: ProgressHandler?) async throws -> Data {
        guard let url = URL(string: path) else { throw FileProviderError.invalidPath(path) }
        let (data, _) = try await URLSession.shared.data(from: url)
        progress?(1.0)
        return data
    }

    func upload(_ data: Data, to path: String, progress: ProgressHandler?) async throws {
        throw FileProviderError.unsupportedOperation
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
        // Extract DIDL from SOAP envelope
        guard let str      = String(data: data, encoding: .utf8),
              let start    = str.range(of: "<Result>"),
              let end      = str.range(of: "</Result>") else { return [] }

        var didl = String(str[start.upperBound..<end.lowerBound])
        didl     = didl.replacingOccurrences(of: "&lt;",  with: "<")
            .replacingOccurrences(of: "&gt;",  with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")

        guard let didlData = didl.data(using: .utf8) else { return [] }
        let parser         = XMLParser(data: didlData)
        parser.delegate    = self
        parser.parse()
        return items
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
