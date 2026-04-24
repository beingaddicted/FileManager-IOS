import Foundation
import UniformTypeIdentifiers

// MARK: - FileTypeHelper

enum FileTypeHelper {
    // MARK: - Detect type from URL

    static func detectType(for url: URL) -> FileItemType {
        let ext = url.pathExtension.lowercased()
        if let type_ = typeFromExtension(ext) { return type_ }
        if let uti = UTType(filenameExtension: ext) { return typeFromUTI(uti) }
        return .unknown
    }

    // MARK: - Extension map

    // swiftlint:disable cyclomatic_complexity
    static func typeFromExtension(_ ext: String) -> FileItemType? {
        switch ext {
        // Images
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif",
             "heic", "heif", "webp", "svg", "ico", "raw", "cr2",
             "nef", "arw", "dng", "orf", "rw2", "psd", "ai":
            return .image

        // Videos
        case "mp4", "m4v", "mov", "avi", "mkv", "wmv", "flv",
             "webm", "mpg", "mpeg", "3gp", "ogv", "ts", "mts",
             "m2ts", "vob", "divx", "xvid", "rmvb", "asf":
            return .video

        // Audio
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus",
             "wma", "aiff", "aif", "caf", "mid", "midi", "ra",
             "amr", "ape", "dsd", "dsf":
            return .audio

        // PDF
        case "pdf":
            return .pdf

        // Documents
        case "doc", "docx", "odt", "rtf", "pages":
            return .document

        // Spreadsheets
        case "xls", "xlsx", "ods", "csv", "numbers", "tsv":
            return .spreadsheet

        // Presentations
        case "ppt", "pptx", "odp", "key":
            return .presentation

        // Archives
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz",
             "tgz", "tbz", "tbz2", "lzma", "lz4", "zst",
             "cab", "iso", "dmg", "pkg":
            return .archive

        // Code
        case "swift", "m", "h", "cpp", "c", "cs", "java", "kt",
             "py", "rb", "js", "ts", "jsx", "tsx", "vue", "go",
             "rs", "php", "pl", "sh", "bash", "zsh", "fish",
             "ps1", "psm1", "bat", "cmd", "r", "lua", "dart",
             "scala", "groovy", "clj", "hs", "elm", "ex", "exs",
             "erl", "f", "f90", "jl", "nim", "zig":
            return .code

        // Markup / text-like (code editor)
        case "html", "htm", "xml", "json", "yaml", "yml",
             "toml", "ini", "cfg", "conf", "properties",
             "gradle", "podspec", "gemspec", "makefile",
             "cmake", "dockerfile", "gitignore", "gitattributes",
             "editorconfig", "md", "markdown", "rst", "tex",
             "adoc", "asciidoc":
            return .code

        // Plain text
        case "txt", "log", "nfo", "text", "asc", "diff",
             "patch", "srt", "vtt", "sub", "ass", "ssa":
            return .text

        // Fonts
        case "ttf", "otf", "woff", "woff2", "eot":
            return .font

        // Databases
        case "db", "sqlite", "sqlite3", "realm", "mdf", "ldf":
            return .database

        // Executables
        case "ipa", "apk", "exe", "dll", "so", "dylib", "app",
             "deb", "rpm", "msi":
            return .executable

        default:
            return nil
        }
    }
    // swiftlint:enable cyclomatic_complexity

    // MARK: - UTI fallback

    private static func typeFromUTI(_ uti: UTType) -> FileItemType {
        if uti.conforms(to: .image)           { return .image }
        if uti.conforms(to: .movie)           { return .video }
        if uti.conforms(to: .audio)           { return .audio }
        if uti.conforms(to: .pdf)             { return .pdf }
        if uti.conforms(to: .archive)         { return .archive }
        if uti.conforms(to: .sourceCode)      { return .code }
        if uti.conforms(to: .text)            { return .text }
        if uti.conforms(to: .spreadsheet)     { return .spreadsheet }
        if uti.conforms(to: .presentation)    { return .presentation }
        return .unknown
    }

    // MARK: - MIME helpers

    static func mimeType(for ext: String) -> String {
        guard let uti = UTType(filenameExtension: ext),
              let mime = uti.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }

    static func isTextBased(_ item: FileItem) -> Bool {
        switch item.itemType {
        case .text, .code: return true
        default: return false
        }
    }

    static func canOpenInline(_ item: FileItem) -> Bool {
        item.isPreviewable
    }

    // MARK: - Size formatting

    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
