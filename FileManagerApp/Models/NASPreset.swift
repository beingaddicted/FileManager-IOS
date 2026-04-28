import Foundation
import SwiftUI

// MARK: - NAS Preset
//
// Quick-add wizards for the most common self-hosted server flavours. Each
// preset bakes in the canonical share/path layout, port, and SSL defaults so
// users don't have to memorise that Synology DSM exposes WebDAV on 5005, that
// TrueNAS keeps shares at /mnt/poolname, or that Nextcloud lives at
// /remote.php/dav/files/<user>.
//
// Adding a preset here automatically surfaces it in the "Add Server" sheet.

struct NASPreset: Identifiable, Hashable {
    let id: String
    let displayName: String
    let vendor: String
    let logo: String                 // SF Symbol
    let tint: Color
    let supportedTypes: [ConnectionType]
    let defaultType: ConnectionType
    let defaultPort: [ConnectionType: Int]
    let basePathTemplate: [ConnectionType: String]
    let usernameHint: String
    let helpURL: URL?
    let notes: String

    /// Builds a `ServerConnection` with sensible defaults for this vendor.
    /// `host`/`username` are user-supplied; everything else is filled in.
    func makeConnection(
        type: ConnectionType,
        host: String,
        username: String,
        sharedName: String?
    ) -> ServerConnection {
        let port = defaultPort[type] ?? type.defaultPort
        var basePath = basePathTemplate[type] ?? "/"

        if basePath.contains("{share}"), let share = sharedName, !share.isEmpty {
            basePath = basePath.replacingOccurrences(of: "{share}", with: share)
        }
        if basePath.contains("{user}") {
            basePath = basePath.replacingOccurrences(of: "{user}", with: username)
        }

        return ServerConnection(
            displayName: "\(displayName) (\(host))",
            type: type,
            host: host,
            port: port,
            username: username,
            basePath: basePath,
            presetId: id
        )
    }
}

// MARK: - Catalog

enum NASPresetCatalog {
    static let all: [NASPreset] = [
        synology, truenas, unraid, openMediaVault, nextcloud, raspberryPi, asustor, qnap, generic
    ]

    static func preset(id: String) -> NASPreset? {
        all.first { $0.id == id }
    }

    // ──────────────────────────────────────────────────────────────────
    static let synology = NASPreset(
        id: "synology",
        displayName: "Synology DSM",
        vendor: "Synology",
        logo: "externaldrive.fill.badge.icloud",
        tint: .blue,
        supportedTypes: [.smb, .sftp, .webdav],
        defaultType: .smb,
        defaultPort: [
            .smb: 445,
            .sftp: 22,
            .webdav: 5005   // WebDAV Server package default
        ],
        basePathTemplate: [
            .smb: "/{share}",
            .sftp: "/volume1",
            .webdav: "/{share}"
        ],
        usernameHint: "DSM user (admin/your-account)",
        helpURL: URL(string: "https://kb.synology.com/en-global/DSM/help/WebDAVServer/webdavserver_desc"),
        notes: "Enable SMB in Control Panel → File Services. WebDAV needs the WebDAV Server package."
    )

    static let truenas = NASPreset(
        id: "truenas",
        displayName: "TrueNAS",
        vendor: "iXsystems",
        logo: "externaldrive.fill",
        tint: .red,
        supportedTypes: [.smb, .sftp, .webdav],
        defaultType: .smb,
        defaultPort: [
            .smb: 445,
            .sftp: 22,
            .webdav: 8080
        ],
        basePathTemplate: [
            .smb: "/{share}",
            .sftp: "/mnt/{share}",
            .webdav: "/{share}"
        ],
        usernameHint: "TrueNAS user",
        helpURL: URL(string: "https://www.truenas.com/docs/scale/24.04/scaletutorials/shares/"),
        notes: "Enable the SMB or WebDAV service under Shares. SFTP works once the SSH service is started."
    )

    static let unraid = NASPreset(
        id: "unraid",
        displayName: "Unraid",
        vendor: "Lime Technology",
        logo: "externaldrive.fill.badge.plus",
        tint: .orange,
        supportedTypes: [.smb, .sftp],
        defaultType: .smb,
        defaultPort: [.smb: 445, .sftp: 22],
        basePathTemplate: [
            .smb: "/{share}",
            .sftp: "/mnt/user/{share}"
        ],
        usernameHint: "Unraid user (default: root)",
        helpURL: URL(string: "https://docs.unraid.net/unraid-os/manual/shares/"),
        notes: "Most users connect via SMB. Set SMB-Security to Public/Secure on your shares."
    )

    static let openMediaVault = NASPreset(
        id: "omv",
        displayName: "OpenMediaVault",
        vendor: "OpenMediaVault",
        logo: "externaldrive.fill.badge.timemachine",
        tint: .green,
        supportedTypes: [.smb, .sftp, .webdav, .ftp],
        defaultType: .smb,
        defaultPort: [.smb: 445, .sftp: 22, .webdav: 80, .ftp: 21],
        basePathTemplate: [
            .smb: "/{share}",
            .sftp: "/srv",
            .webdav: "/{share}",
            .ftp: "/{share}"
        ],
        usernameHint: "OMV user",
        helpURL: URL(string: "https://docs.openmediavault.org/en/stable/"),
        notes: "Install the SMB/CIFS or WebDAV plug-in from the OMV-Extras catalogue."
    )

    static let nextcloud = NASPreset(
        id: "nextcloud",
        displayName: "Nextcloud / ownCloud",
        vendor: "Nextcloud GmbH",
        logo: "cloud.fill",
        tint: .cyan,
        supportedTypes: [.webdav],
        defaultType: .webdav,
        defaultPort: [.webdav: 443],
        basePathTemplate: [
            .webdav: "/remote.php/dav/files/{user}"
        ],
        usernameHint: "Your Nextcloud user",
        helpURL: URL(string: "https://docs.nextcloud.com/server/latest/user_manual/en/files/access_webdav.html"),
        notes: "Use an app password (Settings → Security) instead of your login password if 2FA is enabled."
    )

    static let raspberryPi = NASPreset(
        id: "rpi",
        displayName: "Raspberry Pi (SSH)",
        vendor: "Raspberry Pi Foundation",
        logo: "cpu",
        tint: .pink,
        supportedTypes: [.sftp, .smb],
        defaultType: .sftp,
        defaultPort: [.sftp: 22, .smb: 445],
        basePathTemplate: [
            .sftp: "/home/{user}",
            .smb: "/{share}"
        ],
        usernameHint: "pi (default) or your user",
        helpURL: URL(string: "https://www.raspberrypi.com/documentation/computers/remote-access.html"),
        notes: "Enable SSH with raspi-config or `touch /boot/ssh` on the SD card."
    )

    static let asustor = NASPreset(
        id: "asustor",
        displayName: "Asustor ADM",
        vendor: "Asustor",
        logo: "externaldrive.fill.badge.minus",
        tint: .purple,
        supportedTypes: [.smb, .sftp, .webdav],
        defaultType: .smb,
        defaultPort: [.smb: 445, .sftp: 22, .webdav: 8000],
        basePathTemplate: [
            .smb: "/{share}",
            .sftp: "/volume1",
            .webdav: "/webdav/{share}"
        ],
        usernameHint: "ADM user",
        helpURL: URL(string: "https://www.asustor.com/admv2/?lang=en-US"),
        notes: "Install the WebDAV Server app from App Central if you want HTTP-based access."
    )

    static let qnap = NASPreset(
        id: "qnap",
        displayName: "QNAP QTS",
        vendor: "QNAP",
        logo: "externaldrive.connected.to.line.below",
        tint: .indigo,
        supportedTypes: [.smb, .sftp, .webdav],
        defaultType: .smb,
        defaultPort: [.smb: 445, .sftp: 22, .webdav: 8080],
        basePathTemplate: [
            .smb: "/{share}",
            .sftp: "/share",
            .webdav: "/{share}"
        ],
        usernameHint: "QTS user",
        helpURL: URL(string: "https://www.qnap.com/en/how-to/tutorial/article/how-to-use-webdav-on-qnap-nas"),
        notes: "Enable WebDAV under Control Panel → Web Server → WebDAV. Microsoft network share is on by default."
    )

    static let generic = NASPreset(
        id: "generic",
        displayName: "Other / Generic Server",
        vendor: "Custom",
        logo: "server.rack",
        tint: .gray,
        supportedTypes: [.smb, .sftp, .webdav, .ftp],
        defaultType: .smb,
        defaultPort: [.smb: 445, .sftp: 22, .webdav: 80, .ftp: 21],
        basePathTemplate: [:],
        usernameHint: "Server username",
        helpURL: nil,
        notes: "Configure the protocol, port, and base path manually."
    )
}
