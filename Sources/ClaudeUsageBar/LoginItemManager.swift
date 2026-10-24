import Foundation

/// Installs/removes a LaunchAgent so the app starts at login.
/// When running from a proper .app bundle (install.sh), the bundle executable
/// is used directly. When running unbundled (swift run), the binary is copied
/// to Application Support first since the iCloud Drive source may not be
/// materialized when launchd runs at login.
enum LoginItemManager {
    private static let label = "com.keith.ClaudeUsageBar"

    private static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    // Fallback path used only when running unbundled.
    private static var installedBinaryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeUsageBar/ClaudeUsageBar")
    }

    // True when running from a proper .app bundle rather than via swift run.
    private static var isRunningBundled: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    // The binary path the LaunchAgent plist should reference.
    private static var launchBinaryURL: URL {
        if isRunningBundled, let url = Bundle.main.executableURL {
            return url
        }
        return installedBinaryURL
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    /// Rewrites the LaunchAgent if it points anywhere other than this bundle's
    /// executable. The agent written by an early unbundled build pointed at a
    /// private copy under Application Support, so every login relaunched a
    /// months-old binary (found 2026-10-24: a July build with none of the later
    /// fixes). Running from the proper .app is the only time we know the right
    /// path, so that is when it gets corrected.
    static func repairIfStale() {
        guard isRunningBundled, isEnabled,
              let data = try? Data(contentsOf: agentPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String]
        else { return }
        if args.first != launchBinaryURL.path {
            enable()
            try? FileManager.default.removeItem(at: installedBinaryURL)
        }
    }

    /// Returns false if installation failed (toggle should revert).
    @discardableResult
    static func enable() -> Bool {
        let fm = FileManager.default
        do {
            // Only copy the binary when running unbundled (iCloud Drive source
            // may not be materialized when launchd fires at login).
            if !isRunningBundled {
                guard let source = Bundle.main.executableURL else { return false }
                try fm.createDirectory(
                    at: installedBinaryURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fm.fileExists(atPath: installedBinaryURL.path) {
                    try fm.removeItem(at: installedBinaryURL)
                }
                try fm.copyItem(at: source, to: installedBinaryURL)
            }

            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [launchBinaryURL.path],
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
        // Only clean up the Application Support copy when running unbundled.
        if !isRunningBundled {
            try? FileManager.default.removeItem(at: installedBinaryURL)
        }
    }
}
