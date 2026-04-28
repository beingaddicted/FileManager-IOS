import SwiftUI
import UIKit
import AVFoundation

@main
struct AllFilesApp: App {
    @StateObject private var appState: AppState
    @StateObject private var connVM: ConnectionViewModel

    /// Bridges `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// into the SwiftUI app so background-session completions get delivered.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
                .onOpenURL { url in
                    Task { @MainActor in
                        handleIncomingOpenURL(url)
                    }
                }
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

    private func handleIncomingOpenURL(_ url: URL) {
        let isSecured = url.startAccessingSecurityScopedResource()
        defer {
            if isSecured { url.stopAccessingSecurityScopedResource() }
        }

        let fm = FileManager.default
        let inbox = fm.temporaryDirectory.appendingPathComponent("OpenedFiles", isDirectory: true)
        do {
            try fm.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: nil)
            let name = url.lastPathComponent.isEmpty ? UUID().uuidString : url.lastPathComponent
            let destination = inbox.appendingPathComponent("\(UUID().uuidString)-\(name)")

            do {
                try fm.copyItem(at: url, to: destination)
            } catch {
                let data = try Data(contentsOf: url)
                try data.write(to: destination, options: .atomic)
            }

            if let item = FileItem.fromLocalURL(destination, provider: .local) {
                appState.presentIncomingFile(item)
            } else {
                appState.showError("Opened file is not supported.")
            }
        } catch {
            appState.showError("Failed to open shared file: \(error.localizedDescription)")
        }
    }
}

// MARK: - AppDelegate
//
// SwiftUI doesn't surface the background-session relaunch hook, so we pipe
// it through a `UIApplicationDelegateAdaptor`. iOS calls
// `handleEventsForBackgroundURLSession` when it relaunches us in the
// background to deliver completions for `BackgroundWebDAVSession`'s
// transfers; we hand the system completion handler to the session, which
// invokes it once the queue of pending events has drained.

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == "app.filemanager.webdav.background" {
            BackgroundWebDAVSession.shared.pendingSystemCompletionHandler = completionHandler
        } else {
            // Some other background session identifier we don't recognise —
            // call the completion immediately so iOS can sleep us again.
            completionHandler()
        }
    }
}
