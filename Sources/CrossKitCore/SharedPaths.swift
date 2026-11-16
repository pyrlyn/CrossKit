import Foundation

public enum SharedPaths {
    public static let appGroupIdentifier = "group.dev.pyrlyn.CrossKit"
    public static let hostBundleIdentifier = "dev.pyrlyn.CrossKit"

    /// The real home directory, even inside the App Sandbox (where `NSHomeDirectory()` is the container).
    public static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var groupContainerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return url
        }
        return realHomeDirectory.appendingPathComponent("Library/Group Containers/\(appGroupIdentifier)", isDirectory: true)
    }

    /// Mach message port served by the host app. Sandboxed extensions may only look up names
    /// prefixed with their App Group identifier.
    public static let bridgePortName = "\(appGroupIdentifier).bridge"

    /// Debug builds of loose files and per-session lldb/jdb command files.
    public static var debugDirectory: URL {
        realHomeDirectory.appendingPathComponent("Library/Caches/CrossKit/Debug", isDirectory: true)
    }

    public static var scratchDirectory: URL {
        realHomeDirectory.appendingPathComponent("Library/Caches/CrossKit/Scratch", isDirectory: true)
    }
}
