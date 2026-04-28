import SwiftUI

// MARK: - Add / Edit Connection View

struct AddConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    var existing: ServerConnection?

    @State private var displayName: String = ""
    @State private var connectionType: ConnectionType = .ftp
    @State private var host: String = ""
    @State private var portText: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var basePath: String = "/"
    @State private var usesSSL: Bool = false
    @State private var anonymousLogin: Bool = false
    @State private var showPassword: Bool = false
    @State private var validationError: String?

    private var isEditing: Bool { existing != nil }

    init(existing: ServerConnection? = nil, preferredType: ConnectionType? = nil) {
        self.existing = existing
        _connectionType = State(initialValue: preferredType ?? .ftp)
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Type picker
                Section {
                    Picker("Protocol", selection: $connectionType) {
                        ForEach(ConnectionType.allCases, id: \.self) { type in
                            HStack {
                                Image(systemName: type.systemImage)
                                    .foregroundStyle(type.tintColor)
                                Text(type.rawValue)
                            }
                            .tag(type)
                        }
                    }
                    .onChange(of: connectionType) { new in
                        if portText.isEmpty {
                            let defaultPort = new == .upnp ? 80 : new.defaultPort
                            portText = "\(defaultPort)"
                        }
                        usesSSL = new.usesSSL
                    }
                } header: {
                    Text("Connection Type")
                }

                // MARK: - Display name
                Section {
                    TextField("My Server", text: $displayName)
                } header: {
                    Text("Display Name")
                }

                // MARK: - Server details
                if connectionType.requiresPath || connectionType == .upnp {
                    Section {
                        if connectionType != .upnp {
                            HStack {
                                Text("Host")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                TextField("192.168.1.100", text: $host)
                                    .multilineTextAlignment(.trailing)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.URL)
                            }

                            HStack {
                                Text("Port")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                TextField("\(connectionType.defaultPort)", text: $portText)
                                    .multilineTextAlignment(.trailing)
                                    .keyboardType(.numberPad)
                                    .frame(width: 80)
                            }

                            HStack {
                                Text("Path")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                TextField("/", text: $basePath)
                                    .multilineTextAlignment(.trailing)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }

                            if connectionType == .ftp || connectionType == .webdav {
                                Toggle("Use SSL / TLS", isOn: $usesSSL)
                            }
                        } else {
                            HStack {
                                Text("Description URL / Host")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                TextField("Optional", text: $host)
                                    .multilineTextAlignment(.trailing)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.URL)
                            }
                            HStack {
                                Text("Port")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                TextField("80", text: $portText)
                                    .multilineTextAlignment(.trailing)
                                    .keyboardType(.numberPad)
                                    .frame(width: 80)
                            }
                            Text("Leave blank to use discovery. Set URL/host for manual connect without multicast entitlement.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Server")
                    }
                }

                // MARK: - Auth
                if connectionType.usesAuth && connectionType != .upnp {
                    Section {
                        if connectionType == .ftp {
                            Toggle("Anonymous Login", isOn: $anonymousLogin)
                        }

                        if !anonymousLogin {
                            HStack {
                                Text("Username")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                TextField("username", text: $username)
                                    .multilineTextAlignment(.trailing)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }

                            HStack {
                                Text("Password")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if showPassword {
                                    TextField("••••••••", text: $password)
                                        .multilineTextAlignment(.trailing)
                                        .autocorrectionDisabled()
                                        .textInputAutocapitalization(.never)
                                } else {
                                    SecureField("••••••••", text: $password)
                                        .multilineTextAlignment(.trailing)
                                }
                                Button {
                                    showPassword.toggle()
                                } label: {
                                    Image(systemName: showPassword ? "eye.slash" : "eye")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Authentication")
                    }

                    if [ConnectionType.googleDrive, .dropbox, .oneDrive].contains(connectionType) {
                        Section {
                            Button {
                                openOAuthFlow(for: connectionType)
                            } label: {
                                HStack {
                                    Image(systemName: connectionType.systemImage)
                                        .foregroundStyle(connectionType.tintColor)
                                    Text("Sign in with \(connectionType.rawValue)")
                                    Spacer()
                                    Image(systemName: "arrow.up.right.square")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } header: {
                            Text("OAuth Sign-In")
                        } footer: {
                            Text("Sign-in opens a browser for secure OAuth 2.0 authorisation.")
                        }
                    }
                }

                // MARK: - Validation error
                if let err = validationError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Connection" : "Add Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .bold()
                }
            }
            .onAppear { populate() }
        }
    }

    // MARK: - Populate (edit mode)

    private func populate() {
        guard let c = existing else {
            let defaultPort = connectionType == .upnp ? 80 : connectionType.defaultPort
            portText = "\(defaultPort)"
            return
        }
        displayName    = c.displayName
        connectionType = c.type
        host           = c.host
        portText       = "\(c.port)"
        username       = c.username
        basePath       = c.basePath
        usesSSL        = c.usesSSL
        password       = KeychainHelper.shared.password(for: c)
    }

    // MARK: - Save

    private func save() {
        validationError = nil

        // Validate
        if displayName.isBlank { validationError = "Display name is required."; return }
        if connectionType != .upnp && !connectionType.isCloud && host.isBlank {
            validationError = "Host is required."; return
        }
        let defaultPort = connectionType == .upnp ? 80 : connectionType.defaultPort
        let port = Int(portText) ?? defaultPort

        var conn = existing ?? ServerConnection(
            displayName:  displayName,
            type:         connectionType,
            host:         host,
            port:         port,
            username:     username,
            basePath:     basePath
        )
        conn.displayName    = displayName
        conn.type           = connectionType
        conn.host           = host
        conn.port           = port
        conn.username       = username
        conn.basePath       = basePath.isEmpty ? "/" : basePath
        conn.usesSSL        = usesSSL
        conn.anonymousLogin = anonymousLogin

        KeychainHelper.shared.savePassword(password, for: conn)

        if isEditing {
            appState.updateConnection(conn)
        } else {
            appState.addConnection(conn)
        }
        dismiss()
    }

    // MARK: - OAuth

    private func openOAuthFlow(for type: ConnectionType) {
        // Real implementation would open ASWebAuthenticationSession
        // For now we just show a placeholder
        validationError = "OAuth: open browser to \(type.rawValue) sign-in and paste the token."
    }
}

// MARK: - Extensions

extension ConnectionType {
    var isCloud: Bool {
        switch self {
        case .googleDrive, .dropbox, .oneDrive: return true
        default: return false
        }
    }
}
