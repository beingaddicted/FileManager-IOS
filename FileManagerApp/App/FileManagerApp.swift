import SwiftUI
import AVFoundation

@main
struct AllFilesApp: App {
    @StateObject private var appState: AppState
    @StateObject private var connVM: ConnectionViewModel

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        _connVM   = StateObject(wrappedValue: ConnectionViewModel(appState: state))

        // Configure audio session for background playback
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(connVM)
        }
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            options: [.allowAirPlay, .allowBluetooth]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}
