import Foundation
import SwiftUI
import Combine

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

@MainActor
final class AppState: ObservableObject {
    // Navigation
    @Published var selectedTab: AppTab = .local
    @Published var activeConnection: ServerConnection?

    // Preferences
    @Published var viewMode: ViewMode = .list
    @Published var sortField: SortField = .name
    @Published var sortAscending: Bool = true
    @Published var showHiddenFiles: Bool = false
    @Published var theme: AppTheme = .system
    @Published var thumbnailsEnabled: Bool = true
    @Published var previewOnTap: Bool = true

    // Connections (persisted)
    @Published var connections: [ServerConnection] = [] {
        didSet { saveConnections() }
    }

    // Recent & favorites (persisted)
    @Published var recentFiles: [FileItem] = [] {
        didSet { saveRecents() }
    }
    @Published var favorites: [FileItem] = [] {
        didSet { saveFavorites() }
    }

    // Global error banner
    @Published var alertError: String?

    private let connectionsKey = "app_connections_v2"
    private let recentsKey     = "app_recents_v1"
    private let favoritesKey   = "app_favorites_v1"

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

    // MARK: - Persistence

    private func loadAll() {
        connections = decode([ServerConnection].self, key: connectionsKey) ?? []
        recentFiles = decode([FileItem].self, key: recentsKey) ?? []
        favorites   = decode([FileItem].self, key: favoritesKey) ?? []
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
}

// MARK: - App Tabs

enum AppTab: String, CaseIterable {
    case local   = "local"
    case network = "network"
    case cloud   = "cloud"
    case recents = "recents"

    var title: String {
        switch self {
        case .local:   return "Local"
        case .network: return "Network"
        case .cloud:   return "Cloud"
        case .recents: return "Recents"
        }
    }

    var systemImage: String {
        switch self {
        case .local:   return "internaldrive.fill"
        case .network: return "network"
        case .cloud:   return "cloud.fill"
        case .recents: return "clock.fill"
        }
    }
}
