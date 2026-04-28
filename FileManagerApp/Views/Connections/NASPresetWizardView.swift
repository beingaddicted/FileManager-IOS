import SwiftUI

// MARK: - NAS Preset Wizard
//
// Two-step "Add Server" flow. Step 1: pick a vendor (Synology, TrueNAS, etc.)
// or "custom." Step 2: fill in host/credentials with vendor-specific defaults
// pre-applied. Saving spawns a normal `ServerConnection`.

struct NASPresetWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(ConnectionViewModel.self) private var connVM

    @State private var selectedPreset: NASPreset?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Pick your server type and we'll fill in ports, paths, and protocol defaults for you.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section("Popular") {
                    ForEach([NASPresetCatalog.synology,
                             NASPresetCatalog.truenas,
                             NASPresetCatalog.unraid,
                             NASPresetCatalog.openMediaVault,
                             NASPresetCatalog.nextcloud]) { preset in
                        button(for: preset)
                    }
                }
                Section("Other") {
                    ForEach([NASPresetCatalog.qnap,
                             NASPresetCatalog.asustor,
                             NASPresetCatalog.raspberryPi]) { preset in
                        button(for: preset)
                    }
                }
                Section("Manual") {
                    button(for: NASPresetCatalog.generic)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(item: $selectedPreset) { preset in
                NASPresetDetailView(preset: preset, onComplete: { dismiss() })
            }
        }
    }

    private func button(for preset: NASPreset) -> some View {
        Button {
            selectedPreset = preset
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(preset.tint.opacity(0.15))
                        .frame(width: 42, height: 42)
                    Image(systemName: preset.logo)
                        .foregroundStyle(preset.tint)
                        .font(.title3)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(preset.vendor)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detail / form

struct NASPresetDetailView: View {
    let preset: NASPreset
    let onComplete: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(ConnectionViewModel.self) private var connVM
    @Environment(\.dismiss) private var dismiss

    @State private var connectionType: ConnectionType
    @State private var host: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var sharedName: String = ""
    @State private var displayName: String = ""
    @State private var error: String?
    @State private var isConnecting: Bool = false

    init(preset: NASPreset, onComplete: @escaping () -> Void) {
        self.preset = preset
        self.onComplete = onComplete
        _connectionType = State(initialValue: preset.defaultType)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: preset.logo)
                        .foregroundStyle(preset.tint)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.displayName).font(.headline)
                        Text(preset.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if preset.supportedTypes.count > 1 {
                Section("Protocol") {
                    Picker("Protocol", selection: $connectionType) {
                        ForEach(preset.supportedTypes, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            Section("Server") {
                LabeledTextField(label: "Host / IP", text: $host, placeholder: "192.168.1.10", keyboard: .URL)
                if needsShare {
                    LabeledTextField(label: "Share / Volume", text: $sharedName, placeholder: "Public", keyboard: .default)
                }
                LabeledTextField(label: "Username", text: $username, placeholder: preset.usernameHint, keyboard: .default)
                LabeledSecureField(label: "Password", text: $password)
            }

            Section("Display") {
                TextField("Connection name (optional)", text: $displayName)
            }

            if let url = preset.helpURL {
                Section {
                    Link(destination: url) {
                        Label("Setup Guide", systemImage: "book")
                    }
                }
            }

            if let err = error {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(preset.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .disabled(host.isBlank || isConnecting)
            }
        }
    }

    private var needsShare: Bool {
        guard let template = preset.basePathTemplate[connectionType] else { return false }
        return template.contains("{share}")
    }

    private func save() {
        error = nil
        if host.isBlank { error = "Host is required."; return }

        var conn = preset.makeConnection(
            type: connectionType,
            host: host,
            username: username,
            sharedName: sharedName.isBlank ? nil : sharedName
        )
        if !displayName.isBlank {
            conn.displayName = displayName
        }
        KeychainHelper.shared.savePassword(password, for: conn)

        appState.addConnection(conn)

        // Try to connect right away to give the user instant feedback.
        isConnecting = true
        Task {
            _ = await connVM.connect(to: conn)
            isConnecting = false
            onComplete()
            dismiss()
        }
    }
}

// MARK: - Form helpers

private struct LabeledTextField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    let keyboard: UIKeyboardType

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(keyboard)
        }
    }
}

private struct LabeledSecureField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            SecureField("", text: $text)
                .multilineTextAlignment(.trailing)
        }
    }
}
