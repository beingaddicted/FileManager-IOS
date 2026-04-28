import Foundation
import SwiftUI

// MARK: - Connection Type

enum ConnectionType: String, Codable, CaseIterable {
    case smb    = "SMB"
    case sftp   = "SFTP"
    case webdav = "WebDAV"
    case ftp    = "FTP"
    case upnp   = "UPnP / DLNA"

    var defaultPort: Int {
        switch self {
        case .smb:    return 445
        case .sftp:   return 22
        case .webdav: return 80
        case .ftp:    return 21
        case .upnp:   return 0
        }
    }

    var usesAuth: Bool {
        switch self {
        case .upnp: return false
        default:    return true
        }
    }

    var usesSSL: Bool {
        self == .sftp
    }

    var requiresPath: Bool {
        switch self {
        case .ftp, .sftp, .smb, .webdav: return true
        default: return false
        }
    }

    var providerType: ProviderType {
        switch self {
        case .ftp:    return .ftp
        case .sftp:   return .sftp
        case .smb:    return .smb
        case .webdav: return .webdav
        case .upnp:   return .upnp
        }
    }

    var systemImage: String { providerType.systemImage }
    var tintColor: Color   { providerType.tintColor }
}

// MARK: - Server Connection

struct ServerConnection: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var displayName: String
    var type: ConnectionType
    var host: String
    var port: Int
    var username: String
    var basePath: String = "/"
    var usesSSL: Bool = false
    var passiveMode: Bool = true   // FTP
    var anonymousLogin: Bool = false
    var lastConnected: Date?
    var isBookmarked: Bool = false
    /// Optional vendor preset that produced this connection (Synology, TrueNAS, etc.).
    var presetId: String?

    var keychainKey: String { "fm_pwd_\(id.uuidString)" }

    var displayHost: String {
        port == type.defaultPort ? host : "\(host):\(port)"
    }

    var subtitle: String {
        switch type {
        case .upnp:
            return host.isEmpty ? "Auto-discover on network" : host
        default:
            return "\(username.isEmpty ? "anonymous" : username)@\(displayHost)"
        }
    }

    init(
        displayName: String,
        type: ConnectionType,
        host: String = "",
        port: Int? = nil,
        username: String = "",
        basePath: String = "/",
        presetId: String? = nil
    ) {
        self.displayName = displayName
        self.type = type
        self.host = host
        self.port = port ?? type.defaultPort
        self.username = username
        self.basePath = basePath
        self.usesSSL = type.usesSSL
        self.presetId = presetId
    }
}

// MARK: - UPnP Device

struct UPnPDevice: Identifiable, Hashable {
    var id: String          { location }
    var friendlyName: String
    var modelName: String
    var manufacturer: String
    var location: String
    var services: [UPnPService]

    struct UPnPService: Hashable {
        var serviceType: String
        var controlURL: String
        var eventSubURL: String
    }
}
