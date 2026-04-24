import Foundation
import SwiftUI

// MARK: - File Item Type

enum FileItemType: String, Codable, CaseIterable {
    case folder
    case image
    case video
    case audio
    case pdf
    case text
    case code
    case archive
    case document
    case spreadsheet
    case presentation
    case font
    case database
    case executable
    case unknown

    var systemImage: String {
        switch self {
        case .folder:       return "folder.fill"
        case .image:        return "photo.fill"
        case .video:        return "film.fill"
        case .audio:        return "music.note"
        case .pdf:          return "doc.richtext.fill"
        case .text:         return "doc.text.fill"
        case .code:         return "chevron.left.forwardslash.chevron.right"
        case .archive:      return "archivebox.fill"
        case .document:     return "doc.fill"
        case .spreadsheet:  return "tablecells.fill"
        case .presentation: return "rectangle.stack.fill"
        case .font:         return "textformat"
        case .database:     return "cylinder.split.1x2.fill"
        case .executable:   return "hammer.fill"
        case .unknown:      return "doc.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .folder:       return .accentColor
        case .image:        return .green
        case .video:        return .red
        case .audio:        return .purple
        case .pdf:          return .red
        case .text:         return Color(.systemGray)
        case .code:         return .orange
        case .archive:      return .yellow
        case .document:     return .blue
        case .spreadsheet:  return .green
        case .presentation: return .orange
        case .font:         return .pink
        case .database:     return .cyan
        case .executable:   return .gray
        case .unknown:      return Color(.systemGray2)
        }
    }
}

// MARK: - Provider Type

enum ProviderType: String, Codable, CaseIterable, Identifiable {
    var id: String { rawValue }

    case local      = "On This Device"
    case iCloud     = "iCloud Drive"
    case googleDrive = "Google Drive"
    case dropbox    = "Dropbox"
    case oneDrive   = "OneDrive"
    case ftp        = "FTP"
    case sftp       = "SFTP"
    case smb        = "SMB / Windows Share"
    case webdav     = "WebDAV"
    case upnp       = "UPnP / DLNA"

    var systemImage: String {
        switch self {
        case .local:        return "internaldrive.fill"
        case .iCloud:       return "icloud.fill"
        case .googleDrive:  return "square.stack.3d.up.fill"
        case .dropbox:      return "shippingbox.fill"
        case .oneDrive:     return "cloud.fill"
        case .ftp:          return "network"
        case .sftp:         return "lock.shield.fill"
        case .smb:          return "desktopcomputer"
        case .webdav:       return "globe"
        case .upnp:         return "tv.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .local:        return .blue
        case .iCloud:       return .cyan
        case .googleDrive:  return .green
        case .dropbox:      return Color(red: 0.0, green: 0.47, blue: 1.0)
        case .oneDrive:     return Color(red: 0.0, green: 0.47, blue: 0.87)
        case .ftp:          return .orange
        case .sftp:         return .purple
        case .smb:          return Color(.systemGray)
        case .webdav:       return .teal
        case .upnp:         return .red
        }
    }

    var isCloud: Bool {
        switch self {
        case .iCloud, .googleDrive, .dropbox, .oneDrive: return true
        default: return false
        }
    }

    var isNetwork: Bool {
        switch self {
        case .ftp, .sftp, .smb, .webdav, .upnp: return true
        default: return false
        }
    }
}

// MARK: - File Item

struct FileItem: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var path: String
    var size: Int64
    var modifiedDate: Date
    var createdDate: Date?
    var isDirectory: Bool
    var isHidden: Bool
    var isSymlink: Bool
    var itemType: FileItemType
    var providerType: ProviderType
    var mimeType: String?
    var connectionId: UUID?

    // MARK: - Computed

    var fileExtension: String {
        URL(fileURLWithPath: name).pathExtension.lowercased()
    }

    var formattedSize: String {
        guard !isDirectory else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: modifiedDate, relativeTo: Date())
    }

    var systemImage: String {
        isDirectory ? "folder.fill" : itemType.systemImage
    }

    var accentColor: Color {
        isDirectory ? .accentColor : itemType.accentColor
    }

    var isPreviewable: Bool {
        guard !isDirectory else { return false }
        switch itemType {
        case .image, .video, .audio, .pdf, .text, .code: return true
        default: return false
        }
    }

    var isTextEditable: Bool {
        guard !isDirectory else { return false }
        switch itemType {
        case .text, .code: return true
        default: return false
        }
    }
}

// MARK: - Factory

extension FileItem {
    static func fromLocalURL(_ url: URL, provider: ProviderType = .local, connectionId: UUID? = nil) -> FileItem? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            .creationDateKey, .isHiddenKey, .isSymbolicLinkKey
        ]
        guard let resources = try? url.resourceValues(forKeys: keys) else { return nil }
        let isDirectory = resources.isDirectory ?? false
        return FileItem(
            id: url.path,
            name: url.lastPathComponent,
            path: url.path,
            size: Int64(resources.fileSize ?? 0),
            modifiedDate: resources.contentModificationDate ?? Date(),
            createdDate: resources.creationDate,
            isDirectory: isDirectory,
            isHidden: resources.isHidden ?? false,
            isSymlink: resources.isSymbolicLink ?? false,
            itemType: isDirectory ? .folder : FileTypeHelper.detectType(for: url),
            providerType: provider,
            connectionId: connectionId
        )
    }
}
