// Cloud providers (Google Drive / Dropbox / OneDrive) were removed in the
// v2 pivot toward a NAS-first product. Each one needed its own OAuth
// configuration, app-store ticket, and ongoing API maintenance — for a
// feature users get for free in the iOS Files app via iCloud.
//
// The iCloud Drive integration lives in LocalFileService.swift (`ICloudService`).
// Self-hosted clouds (Nextcloud, ownCloud, Synology Drive) work through the
// WebDAVService and the NASPreset wizard.
//
// File kept so the existing pbxproj reference stays valid.
import Foundation
