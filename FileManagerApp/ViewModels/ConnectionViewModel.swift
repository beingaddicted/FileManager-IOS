import Foundation
import SwiftUI
import Combine
import AuthenticationServices
import CryptoKit
import UIKit

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

    // MARK: - Cloud OAuth

    func authenticateCloud(_ type: ConnectionType) async -> String? {
        do {
            let token = try await CloudOAuthSession.shared.authenticate(type: type)
            KeychainHelper.shared.saveToken(token, provider: type.providerType)
            return token
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

// MARK: - Cloud OAuth Session

@MainActor
private final class CloudOAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = CloudOAuthSession()

    private var authSession: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    private override init() {}

    func authenticate(type: ConnectionType) async throws -> String {
        let config = try OAuthProviderConfig.make(for: type)
        let state = UUID().uuidString
        let verifier = PKCE.makeVerifier()
        let challenge = PKCE.challenge(for: verifier)

        var components = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)
        var query: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "scope", value: config.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        query.append(contentsOf: config.extraAuthorizeQueryItems)
        components?.queryItems = query

        guard let loginURL = components?.url else {
            throw OAuthError.invalidConfiguration("Failed to construct OAuth URL.")
        }

        let callbackURL = try await startWebAuth(url: loginURL, callbackScheme: config.callbackScheme)
        let callbackState = callbackURL.queryValue("state")
        if callbackState != state {
            throw OAuthError.invalidResponse("State mismatch from OAuth callback.")
        }
        if let oauthError = callbackURL.queryValue("error") {
            let description = callbackURL.queryValue("error_description") ?? oauthError
            throw OAuthError.provider(description)
        }
        guard let code = callbackURL.queryValue("code") else {
            throw OAuthError.invalidResponse("OAuth callback did not include code.")
        }

        var req = URLRequest(url: config.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = FormURLEncoder.encode([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": config.clientID,
            "redirect_uri": config.redirectURI,
            "code_verifier": verifier
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OAuthError.provider("Token exchange failed.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String,
              !token.isEmpty else {
            throw OAuthError.invalidResponse("No access token returned.")
        }
        return token
    }

    func startWebAuth(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            self.continuation = continuation

            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                guard let self else { return }
                defer {
                    self.continuation = nil
                    self.authSession = nil
                }
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: OAuthError.invalidResponse("No callback URL received."))
                    return
                }
                continuation.resume(returning: callbackURL)
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.authSession = session

            if !session.start() {
                self.continuation = nil
                self.authSession = nil
                continuation.resume(throwing: OAuthError.invalidConfiguration("Unable to start web authentication session."))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
    }
}

private struct OAuthProviderConfig {
    let clientID: String
    let authorizeURL: URL
    let tokenURL: URL
    let scopes: String
    let redirectURI: String
    let callbackScheme: String
    let extraAuthorizeQueryItems: [URLQueryItem]

    static func make(for type: ConnectionType) throws -> OAuthProviderConfig {
        let callbackScheme = "allfiles"
        let redirectURI = "\(callbackScheme)://oauth"

        switch type {
        case .googleDrive:
            let clientID = Bundle.main.string(forInfoDictionaryKey: "GoogleOAuthClientID") ?? ""
            guard !clientID.isBlank else { throw OAuthError.invalidConfiguration("Set GoogleOAuthClientID in Info.plist.") }
            return OAuthProviderConfig(
                clientID: clientID,
                authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
                scopes: "https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/drive.file",
                redirectURI: redirectURI,
                callbackScheme: callbackScheme,
                extraAuthorizeQueryItems: [URLQueryItem(name: "access_type", value: "offline")]
            )
        case .dropbox:
            let clientID = Bundle.main.string(forInfoDictionaryKey: "DropboxOAuthClientID") ?? ""
            guard !clientID.isBlank else { throw OAuthError.invalidConfiguration("Set DropboxOAuthClientID in Info.plist.") }
            return OAuthProviderConfig(
                clientID: clientID,
                authorizeURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
                tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
                scopes: "files.metadata.read files.content.read files.content.write",
                redirectURI: redirectURI,
                callbackScheme: callbackScheme,
                extraAuthorizeQueryItems: [
                    URLQueryItem(name: "token_access_type", value: "offline")
                ]
            )
        case .oneDrive:
            let clientID = Bundle.main.string(forInfoDictionaryKey: "OneDriveOAuthClientID") ?? ""
            guard !clientID.isBlank else { throw OAuthError.invalidConfiguration("Set OneDriveOAuthClientID in Info.plist.") }
            return OAuthProviderConfig(
                clientID: clientID,
                authorizeURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
                tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
                scopes: "offline_access User.Read Files.ReadWrite",
                redirectURI: redirectURI,
                callbackScheme: callbackScheme,
                extraAuthorizeQueryItems: []
            )
        default:
            throw OAuthError.invalidConfiguration("OAuth is supported for cloud providers only.")
        }
    }
}

private enum OAuthError: LocalizedError {
    case invalidConfiguration(String)
    case invalidResponse(String)
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let m): return m
        case .invalidResponse(let m): return m
        case .provider(let m): return m
        }
    }
}

private enum PKCE {
    static func makeVerifier() -> String {
        let charset = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<64).compactMap { _ in charset.randomElement() })
    }

    static func challenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private enum FormURLEncoder {
    static func encode(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = values.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        .joined(separator: "&")
        return Data(body.utf8)
    }
}

private extension URL {
    func queryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}
