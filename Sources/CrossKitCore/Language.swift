import Foundation

public enum Language: String, CaseIterable, Codable, Identifiable, Sendable {
    case kotlin
    case zig
    case rust

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .kotlin: return "Kotlin"
        case .zig: return "Zig"
        case .rust: return "Rust"
        }
    }

    /// LSP `languageId` used in `textDocument/didOpen`.
    public var languageID: String { rawValue }

    /// Executable name of the language server.
    public var serverBinaryName: String {
        switch self {
        case .kotlin: return "kotlin-language-server"
        case .zig: return "zls"
        case .rust: return "rust-analyzer"
        }
    }

    public var defaultExtensions: [String] {
        switch self {
        case .kotlin: return ["kt", "kts"]
        case .zig: return ["zig"]
        case .rust: return ["rs"]
        }
    }

    public var defaultArguments: [String] { [] }

    /// Files that mark a project root, nearest first.
    public var rootMarkers: [String] {
        switch self {
        case .kotlin: return ["settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle", "pom.xml"]
        case .zig: return ["build.zig", "zls.json"]
        case .rust: return ["Cargo.toml", "rust-project.json"]
        }
    }

    /// mise install directory names that may contain the server.
    public var miseToolDirectoryNames: [String] {
        switch self {
        case .kotlin: return ["github-fwcd-kotlin-language-server", "kotlin-language-server", "ubi-fwcd-kotlin-language-server", "aqua-fwcd-kotlin-language-server"]
        case .zig: return ["zls", "aqua-zigtools-zls", "github-zigtools-zls", "ubi-zigtools-zls"]
        case .rust: return ["rust-analyzer", "aqua-rust-lang-rust-analyzer", "github-rust-lang-rust-analyzer"]
        }
    }

    public var installHint: String {
        switch self {
        case .kotlin: return "mise install github:fwcd/kotlin-language-server@latest"
        case .zig: return "mise install zls@<your zig version>"
        case .rust: return "rustup component add rust-analyzer"
        }
    }

    /// Kotlin LS indexes slowly; give it more time.
    public var initializeTimeout: TimeInterval { self == .kotlin ? 240 : 90 }
    public var requestTimeout: TimeInterval { self == .kotlin ? 180 : 60 }
    public var diagnosticsTimeout: TimeInterval { self == .kotlin ? 120 : 45 }

    public var lineCommentPrefix: String { "//" }

    /// Guess from an Xcode content UTI such as `public.rust-source`.
    public static func guess(fromUTI uti: String) -> Language? {
        let lower = uti.lowercased()
        if lower.contains("kotlin") { return .kotlin }
        if lower.contains("zig") { return .zig }
        if lower.contains("rust") { return .rust }
        return nil
    }
}

public enum Feature: String, CaseIterable, Codable, Identifiable, Sendable {
    case completion
    case definition
    case references
    case diagnostics
    case hover

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .completion: return "Completion"
        case .definition: return "Go to Definition"
        case .references: return "Find References"
        case .diagnostics: return "Diagnostics"
        case .hover: return "Hover"
        }
    }
}
