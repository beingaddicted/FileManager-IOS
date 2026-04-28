import SwiftUI

// MARK: - Transfers Tab
//
// Lists every download/upload tracked by `BackgroundTransferService`. Lets
// the user inspect progress, retry failed transfers, and clear completed.

struct TransfersView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var connVM: ConnectionViewModel
    @StateObject private var service = BackgroundTransferService.shared

    var body: some View {
        NavigationStack {
            Group {
                if service.transfers.isEmpty {
                    emptyView
                } else {
                    List {
                        if !active.isEmpty {
                            Section("In Progress (\(active.count))") {
                                ForEach(active) { row($0) }
                            }
                        }
                        if !pending.isEmpty {
                            Section("Queued (\(pending.count))") {
                                ForEach(pending) { row($0) }
                            }
                        }
                        if !completed.isEmpty {
                            Section("Completed (\(completed.count))") {
                                ForEach(completed) { row($0) }
                            }
                        }
                        if !failed.isEmpty {
                            Section("Failed (\(failed.count))") {
                                ForEach(failed) { row($0) }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Transfers")
            .toolbar {
                if !service.transfers.isEmpty {
                    Menu {
                        Button("Clear Completed") {
                            service.clearCompleted()
                        }
                        Button("Clear All", role: .destructive) {
                            service.clearAll()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var active:    [TransferRecord] { service.transfers.filter { $0.state == .active } }
    private var pending:   [TransferRecord] { service.transfers.filter { $0.state == .queued } }
    private var completed: [TransferRecord] { service.transfers.filter { $0.state == .done } }
    private var failed:    [TransferRecord] { service.transfers.filter { $0.state == .failed } }

    // MARK: - Row

    @ViewBuilder
    private func row(_ record: TransferRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: record.kind == .download ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .foregroundStyle(record.kind == .download ? Color.blue : Color.orange)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.filename)
                        .font(.subheadline)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(record.connectionName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text(record.formattedSize)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                statusBadge(record)
            }

            if record.state == .active || record.state == .queued {
                ProgressView(value: record.progress)
            }

            if let err = record.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            if record.state == .active || record.state == .queued {
                Button(role: .destructive) {
                    service.cancel(record)
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            } else {
                Button(role: .destructive) {
                    service.cancel(record)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ record: TransferRecord) -> some View {
        switch record.state {
        case .active:
            Text(record.progress.percentString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .queued:
            Text("Queued").font(.caption).foregroundStyle(.secondary)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("No transfers yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Downloads and uploads from your servers will appear here.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

