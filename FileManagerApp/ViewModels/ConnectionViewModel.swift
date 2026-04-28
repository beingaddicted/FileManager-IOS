import Foundation
import SwiftUI
import Combine

// MARK: - ConnectionViewModel

@MainActor
final class ConnectionViewModel: ObservableObject {
    @Published var activeProviders: [UUID: FileProvider] = [:]
    @Published var connectionStates: [UUID: ConnectionState] = [:]
    @Published var error: String?

    private let appState: AppState
    private lazy var localBrowserVM = FileBrowserViewModel(
        provider:     FileProviderFactory.makeLocal(),
        providerType: .local,
        appState:     appState
    )

    enum ConnectionState {
        case disconnected, connecting, connected, failed(String)
    }

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Connect

    func connect(to connection: ServerConnection) async -> FileProvider? {
        connectionStates[connection.id] = .connecting
        let provider = FileProviderFactory.make(for: connection)

        do {
            try await provider.connect()
            activeProviders[connection.id]   = provider
            connectionStates[connection.id]  = .connected
            var updated = connection
            updated.lastConnected = Date()
            appState.updateConnection(updated)
            return provider
        } catch {
            connectionStates[connection.id] = .failed(error.localizedDescription)
            self.error = error.localizedDescription
            return nil
        }
    }

    func disconnect(from connection: ServerConnection) {
        activeProviders[connection.id]?.disconnect()
        activeProviders.removeValue(forKey: connection.id)
        connectionStates[connection.id] = .disconnected
    }

    func disconnectAll() {
        activeProviders.values.forEach { $0.disconnect() }
        activeProviders.removeAll()
        connectionStates.keys.forEach { connectionStates[$0] = .disconnected }
    }

    func isConnected(_ connection: ServerConnection) -> Bool {
        activeProviders[connection.id]?.isConnected ?? false
    }

    func provider(for connection: ServerConnection) -> FileProvider? {
        activeProviders[connection.id]
    }

    // MARK: - Browser factory

    func makeBrowser(for provider: FileProvider, providerType: ProviderType) -> FileBrowserViewModel {
        FileBrowserViewModel(provider: provider, providerType: providerType, appState: appState)
    }

    func makeLocalBrowser() -> FileBrowserViewModel {
        localBrowserVM
    }

    func makeICloudBrowser() -> FileBrowserViewModel {
        FileBrowserViewModel(
            provider:     FileProviderFactory.makeICloud(),
            providerType: .iCloud,
            appState:     appState
        )
    }
}
