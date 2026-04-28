import SwiftUI

// MARK: - Add / Edit Connection View
//
// Used for editing existing connections and for the "Manual" / generic
// preset entry point. The vendor-specific setup flow lives in
// `NASPresetWizardView` and is what gets shown for new connections by
// default.

struct AddConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var connVM: ConnectionViewModel

    var existing: ServerConnection?

    @State private var displayName: String = ""
    @State private var connectionType: ConnectionType = .smb
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
        _connectionType = State(initialValue: preferredType ?? .smb)
    }

    var body: some View {
        NavigationStack {
            Form {
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
                            portText = "\(new.defaultPort)"
                        }
                        usesSSL = new.usesSSL
                    }
                } header: {
                    Text("Connection Type")
                }

                Section("Display Name") {
                    TextField("My Server", text: $displayName)
                }

                if connectionType.requiresPath || connectionType == .upnp {
                    Section("Server") {
                        if connectionType != .upnp {
                            HStack {
                                Text("Host").foregroundStyle(.secondary)
                                Spacer()
                                TextField("192.168.1.100", text: $host)
                                    .multilineTextAlignment(.trailing)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.URL)
                            }
                            HStack {
                                Text("Port").foregroundStyle(.secondary)
                                Spacer()
                                TextField("\(connectionType.defaultPort)", text: $portText)
                                    .multilineTextAlignment(.trailing)
                                    .keyboardType(.numberPad)
                                    .frame(width: 80)
                            }
                            HStack {
                                Text(connectionType == .smb ? "Share / Path" : "Path")
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
                                Text("Description URL / Host").foregroundStyle(.secondary)
                                Spacer()
                                TextField("Optional", text: $host)
                                    .multilineTextAlignment(.trailing)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.URL)
                            }
                            HStack {
                                Text("Port").foregroundStyle(.secondary)
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
                    }
                }

                if connectionType.usesAuth && connectionType != .upnp {
                    Section("Authentication") {
                        if connectionType == .ftp {
                            Toggle("Anonymous Login", isOn: $anonymousLogin)
                        }
                        if !anonymousLogin {
                            HStack {
                                Text("Username").foregroundStyle(.secondary)
                                Spacer()
                                TextField("username", text: $username)
                                    .multilineTextAlignment(.trailing)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                            HStack {
                                Text("Password").foregroundStyle(.secondary)
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
                    }
                }

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
                    Button("Save") { save() }.bold()
                }
            }
            .onAppear { populate() }
        }
    }

    private func populate() {
        guard let c = existing else {
            portText = "\(connectionType.defaultPort)"
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

    private func save() {
        validationError = nil
        if displayName.isBlank { displayName = connectionType.rawValue }
        if connectionType != .upnp && host.isBlank {
            validationError = "Host is required."; return
        }
        let port = Int(portText) ?? connectionType.defaultPort

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
}
