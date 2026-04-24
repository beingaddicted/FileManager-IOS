import SwiftUI
import Foundation

// MARK: - View Modifiers

struct CardModifier: ViewModifier {
    @Environment(\.colorScheme) var cs
    func body(content: Content) -> some View {
        content
            .background(cs == .dark ? Color(.systemGray6) : .white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(cs == .dark ? 0.3 : 0.08), radius: 6, x: 0, y: 2)
    }
}

struct GlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardModifier()) }
    func glassStyle() -> some View { modifier(GlassModifier()) }

    func onLoad(perform action: @escaping () async -> Void) -> some View {
        task { await action() }
    }

    func errorAlert(error: Binding<String?>) -> some View {
        alert("Error", isPresented: Binding(
            get: { error.wrappedValue != nil },
            set: { if !$0 { error.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) { error.wrappedValue = nil }
        } message: {
            if let msg = error.wrappedValue {
                Text(msg)
            }
        }
    }

    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - Color

extension Color {
    static let systemBackground      = Color(UIColor.systemBackground)
    static let secondaryBackground   = Color(UIColor.secondarySystemBackground)
    static let groupedBackground     = Color(UIColor.systemGroupedBackground)
    static let tertiaryBackground    = Color(UIColor.tertiarySystemBackground)
    static let primaryLabel          = Color(UIColor.label)
    static let secondaryLabel        = Color(UIColor.secondaryLabel)
    static let tertiaryLabel         = Color(UIColor.tertiaryLabel)
}

// MARK: - String

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespaces).isEmpty }

    var pathExtension: String {
        (self as NSString).pathExtension.lowercased()
    }

    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }

    var deletingLastPathComponent: String {
        (self as NSString).deletingLastPathComponent
    }

    func appendingPathComponent(_ component: String) -> String {
        (self as NSString).appendingPathComponent(component)
    }
}

// MARK: - Date

extension Date {
    var relativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    var shortDescription: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }
}

// MARK: - URL

extension URL {
    var isReachable: Bool {
        (try? checkResourceIsReachable()) ?? false
    }
}

// MARK: - Data

extension Data {
    var prettyJSON: String? {
        guard let obj = try? JSONSerialization.jsonObject(with: self),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
              let str = String(data: pretty, encoding: .utf8) else { return nil }
        return str
    }
}

// MARK: - Task retry helper

extension Task where Failure == Error {
    static func retrying(
        maxAttempts: Int = 3,
        delay: TimeInterval = 1.0,
        operation: @escaping @Sendable () async throws -> Success
    ) -> Task {
        Task {
            var lastError: Error?
            for attempt in 0..<maxAttempts {
                do {
                    return try await operation()
                } catch {
                    lastError = error
                    if attempt < maxAttempts - 1 {
                        try await Task<Never, Never>.sleep(nanoseconds: UInt64(delay * Double(attempt + 1) * 1_000_000_000))
                    }
                }
            }
            throw lastError!
        }
    }
}

// MARK: - FileManager helpers

extension FileManager {
    var documentsDirectory: URL {
        urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var cachesDirectory: URL {
        urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    var tempDirectory: URL {
        temporaryDirectory
    }

    func createDirectoryIfNeeded(at url: URL) throws {
        guard !fileExists(atPath: url.path) else { return }
        try createDirectory(at: url, withIntermediateDirectories: true)
    }
}

// MARK: - Progress formatting

extension Double {
    var percentString: String {
        String(format: "%.0f%%", self * 100)
    }
}
