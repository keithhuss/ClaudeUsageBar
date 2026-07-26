import Foundation

/// Installs/removes a LaunchAgent so the app starts at login.
/// A LaunchAgent (rather than SMAppService) because this is an unbundled
/// executable; the binary is copied to Application Support first since the
/// iCloud Drive copy may not be materialized when launchd runs at login.
enum LoginItemManager {
    private static let label = "com.keith.ClaudeUsageBar"

    private static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var installedBinaryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeUsageBar/ClaudeUsageBar")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    /// Returns false if installation failed (toggle should revert).
    @discardableResult
    static func enable() -> Bool {
        let fm = FileManager.default
        guard let source = Bundle.main.executableURL else { return false }
        do {
            try fm.createDirectory(
                at: installedBinaryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fm.fileExists(atPath: installedBinaryURL.path) {
                try fm.removeItem(at: installedBinaryURL)
            }
            try fm.copyItem(at: source, to: installedBinaryURL)

            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [installedBinaryURL.path],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try fm.createDirectory(
                at: agentPlistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: agentPlistURL)
            return true
        } catch {
            return false
        }
    }

    static func disable() {
        try? FileManager.default.removeItem(at: agentPlistURL)
        try? FileManager.default.removeItem(at: installedBinaryURL)
    }
}
