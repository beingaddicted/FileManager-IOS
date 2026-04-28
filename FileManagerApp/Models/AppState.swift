import Foundation
import SwiftUI
import Observation

// MARK: - Enums

enum ViewMode: String, CaseIterable, Codable {
    case list, grid

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }
}

enum SortField: String, CaseIterable, Codable {
    case name, size, date, type
    var label: String { rawValue.capitalized }
}

enum AppTheme: String, CaseIterable, Codable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - AppState

@Observable
@MainActor
final class AppState {
    // Navigation
    var selectedTab: AppTab = .local
    var activeConnection: ServerConnection?

    // Preferences
    var viewMode: ViewMode = .list
    var sortField: SortField = .name
    var sortAscending: Bool = true
    var showHiddenFiles: Bool = false
    var theme: AppTheme = .system
    var thumbnailsEnabled: Bool = true
    var previewOnTap: Bool = true

    // Connections (persisted)
    var connections: [ServerConnection] = [] {
        didSet { saveConnections() }
    }

    // Recent & favorites (persisted)
    var recentFiles: [FileItem] = [] {
        didSet { saveRecents() }
    }
    var favorites: [FileItem] = [] {
        didSet { saveFavorites() }
    }
    var localPinnedLocations: [LocalPinnedLocation] = [] {
        didSet { saveLocalPinnedLocations() }
    }

    // Global error banner
    var alertError: String?
    var incomingPreviewItem: FileItem?

    @ObservationIgnored private let connectionsKey = "app_connections_v2"
    @ObservationIgnored private let recentsKey     = "app_recents_v1"
    @ObservationIgnored private let favoritesKey   = "app_favorites_v1"
    @ObservationIgnored private let pinnedLocalKey = "app_local_pinned_v1"

    init() {
        loadAll()
    }

    // MARK: - Connections

    func addConnection(_ conn: ServerConnection) {
        connections.append(conn)
    }

    func updateConnection(_ conn: ServerConnection) {
        if let i = connections.firstIndex(where: { $0.id == conn.id }) {
            connections[i] = conn
        }
    }

    func removeConnection(_ conn: ServerConnection) {
        connections.removeAll { $0.id == conn.id }
        KeychainHelper.shared.delete(key: conn.keychainKey)
    }

    func removeConnections(at offsets: IndexSet) {
        offsets.forEach { i in
            KeychainHelper.shared.delete(key: connections[i].keychainKey)
        }
        connections.remove(atOffsets: offsets)
    }

    // MARK: - Recents

    func addRecent(_ item: FileItem) {
        recentFiles.removeAll { $0.path == item.path && $0.providerType == item.providerType }
        recentFiles.insert(item, at: 0)
        if recentFiles.count > 100 {
            recentFiles = Array(recentFiles.prefix(100))
        }
    }

    func clearRecents() {
        recentFiles.removeAll()
    }

    // MARK: - Favorites

    func toggleFavorite(_ item: FileItem) {
        if isFavorite(item) {
            favorites.removeAll { $0.id == item.id }
        } else {
            favorites.append(item)
        }
    }

    func isFavorite(_ item: FileItem) -> Bool {
        favorites.contains { $0.id == item.id }
    }

    // MARK: - Local pinned locations

    func isPinnedLocalLocation(path: String) -> Bool {
        localPinnedLocations.contains { $0.path == path }
    }

    func togglePinnedLocalLocation(_ item: FileItem) {
        if isPinnedLocalLocation(path: item.path) {
            localPinnedLocations.removeAll { $0.path == item.path }
        } else {
            localPinnedLocations.append(LocalPinnedLocation(name: item.name, path: item.path))
        }
    }

    func movePinnedLocalLocations(from source: IndexSet, to destination: Int) {
        localPinnedLocations.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Persistence

    private func loadAll() {
        connections = decode([ServerConnection].self, key: connectionsKey) ?? []
        recentFiles = decode([FileItem].self, key: recentsKey) ?? []
        favorites   = decode([FileItem].self, key: favoritesKey) ?? []
        localPinnedLocations = decode([LocalPinnedLocation].self, key: pinnedLocalKey) ?? []
    }

    private func saveConnections() {
        encode(connections, key: connectionsKey)
    }

    private func saveRecents() {
        encode(recentFiles, key: recentsKey)
    }

    private func saveFavorites() {
        encode(favorites, key: favoritesKey)
    }

    private func saveLocalPinnedLocations() {
        encode(localPinnedLocations, key: pinnedLocalKey)
    }

    private func encode<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Error

    func showError(_ message: String) {
        alertError = message
    }

    func presentIncomingFile(_ item: FileItem) {
        selectedTab = .local
        incomingPreviewItem = item
    }
}

struct LocalPinnedLocation: Codable, Hashable, Identifiable {
    var id: String { path }
    let name: String
    let path: String
}

// MARK: - App Tabs

enum AppTab: String, CaseIterable {
    case local     = "local"
    case network   = "network"
    case transfers = "transfers"
    case recents   = "recents"
    case settings  = "settings"

    var title: String {
        switch self {
        case .local:     return "Files"
        case .network:   return "Servers"
        case .transfers: return "Transfers"
        case .recents:   return "Recents"
        case .settings:  return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .local:     return "internaldrive.fill"
        case .network:   return "externaldrive.connected.to.line.below.fill"
        case .transfers: return "arrow.up.arrow.down.circle.fill"
        case .recents:   return "clock.fill"
        case .settings:  return "gearshape.fill"
        }
    }
}
