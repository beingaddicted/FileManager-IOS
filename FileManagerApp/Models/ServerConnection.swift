import Foundation

// MARK: - Connection Type

enum ConnectionType: String, Codable, CaseIterable {
    case ftp        = "FTP"
    case sftp       = "SFTP"
    case smb        = "SMB"
    case webdav     = "WebDAV"
    case upnp       = "UPnP / DLNA"
    case googleDrive = "Google Drive"
    case dropbox    = "Dropbox"
    case oneDrive   = "OneDrive"

    var defaultPort: Int {
        switch self {
        case .ftp:          return 21
        case .sftp:         return 22
        case .smb:          return 445
        case .webdav:       return 80
        case .upnp:         return 0
        case .googleDrive,
             .dropbox,
             .oneDrive:     return 443
        }
    }

    var usesAuth: Bool {
        switch self {
        case .upnp: return false
        default:    return true
        }
    }

    var usesSSL: Bool {
        switch self {
        case .sftp, .googleDrive, .dropbox, .oneDrive: return true
        default: return false
        }
    }

    var requiresPath: Bool {
        switch self {
        case .ftp, .sftp, .smb, .webdav: return true
        default: return false
        }
    }

    var providerType: ProviderType {
        switch self {
        case .ftp:          return .ftp
        case .sftp:         return .sftp
        case .smb:          return .smb
        case .webdav:       return .webdav
        case .upnp:         return .upnp
        case .googleDrive:  return .googleDrive
        case .dropbox:      return .dropbox
        case .oneDrive:     return .oneDrive
        }
    }

    var systemImage: String { providerType.systemImage }
    var tintColor: Color   { providerType.tintColor }
}

// MARK: - Import SwiftUI for Color

import SwiftUI

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
    var passiveMode: Bool = true      // FTP
    var anonymousLogin: Bool = false
    var lastConnected: Date?
    var isBookmarked: Bool = false

    var keychainKey: String { "fm_pwd_\(id.uuidString)" }

    var displayHost: String {
        port == type.defaultPort ? host : "\(host):\(port)"
    }

    var subtitle: String {
        switch type {
        case .googleDrive, .dropbox, .oneDrive:
            return username.isEmpty ? type.rawValue : username
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
        basePath: String = "/"
    ) {
        self.displayName = displayName
        self.type = type
        self.host = host
        self.port = port ?? type.defaultPort
        self.username = username
        self.basePath = basePath
        self.usesSSL = type.usesSSL
    }
}

// MARK: - UPnP Device

struct UPnPDevice: Identifiable, Hashable {
    var id: String          { location }
    var friendlyName: String
    var modelName: String
    var manufacturer: String
    var location: String     // Base URL
    var services: [UPnPService]

    struct UPnPService: Hashable {
        var serviceType: String
        var controlURL: String
        var eventSubURL: String
    }
}
