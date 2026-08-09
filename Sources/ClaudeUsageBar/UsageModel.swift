import Foundation
import AppKit

// MARK: - Data types

struct UsageBucket: Identifiable, Sendable {
    let key: String
    let title: String
    let percent: Double   // 0...100
    let resetsAt: Date?

    var id: String { key }
}

/// Matches the `claudeAiOauth` payload Claude Code stores in the Keychain.
struct OAuthCredentials: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double?    // milliseconds since epoch
    var scopes: [String]?

    var hasProfileScope: Bool { scopes?.contains("user:profile") ?? false }

    var isExpiringSoon: Bool {
        guard let expiresAt else { return false }
        return Date(timeIntervalSince1970: expiresAt / 1000) < Date().addingTimeInterval(120)
    }
}

// MARK: - Model

@MainActor
final class UsageModel: ObservableObject {
    enum Status {
        case loading
        case ok
        case needsLogin(String)
        case error(String)
    }

    @Published var buckets: [UsageBucket] = []
    @Published var status: Status = .loading
    @Published var lastUpdated: Date?

    private var credentials: OAuthCredentials?
    private var timer: Timer?
    private var cooldownUntil: Date?          // set after a 429; automatic polls skip until then
    private var wakeDelayUntil: Date?         // set on system wake; silently skips one poll cycle
    private var lastTokenRefreshAttempt: Date?

    /// Claude Code's public OAuth client id, needed for the refresh-token grant.
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    /// Poll every 5 minutes. The wake-delay on NSWorkspace.didWakeNotification prevents
    /// maintenance-wake bursts that previously caused overnight rate limiting.
    private static let pollInterval: TimeInterval = 300

    init() {
        refresh()
        startRegularTimer()
        subscribeToWakeNotification()
    }

    /// `manual: true` (the Refresh button) bypasses the rate-limit cooldown.
    func refresh(manual: Bool = false) {
        Task { await reload(manual: manual) }
    }

    // MARK: Menu bar label

    var menuBarText: String {
        switch status {
        case .loading:    return "…"
        case .needsLogin: return "login"
        case .error:      return "!"
        case .ok:
            let bucket = buckets.first { $0.key == "session" || $0.key == "five_hour" } ?? buckets.first
            guard let bucket else { return "–" }
            return "\(Int(bucket.percent.rounded()))%"
        }
    }

    var menuBarSymbol: String {
        switch status {
        case .error, .needsLogin: return "exclamationmark.triangle"
        default:                  return "gauge.with.needle"
        }
    }

    // MARK: Scheduling

    private func startRegularTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// On system wake, delay the first poll by 2 minutes so we don't immediately
    /// hit the API on a fresh network connection — the direct cause of rate-limit
    /// errors seen after overnight sleep.
    private func subscribeToWakeNotification() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
    }

    private func handleWake() {
        wakeDelayUntil = Date().addingTimeInterval(120)
        // Reset the regular timer so the next fire is 15 min from now,
        // not an indeterminate leftover from before sleep.
        startRegularTimer()
    }

    // MARK: Core flow

    private func reload(manual: Bool) async {
        // Respect the wake delay (silent) and rate-limit cooldown for automatic polls.
        if !manual {
            if let wakeDelayUntil, wakeDelayUntil > Date() { return }
            if let cooldownUntil, cooldownUntil > Date() { return }
        }

        // 1. Find the freshest usable credentials (own store or Claude Code's Keychain items).
        guard let found = await Task.detached(operation: { CredentialStore.bestCredentials() }).value else {
            status = .needsLogin("No Claude Code login found on this Mac.")
            return
        }
        guard found.hasProfileScope else {
            status = .needsLogin("Only the Xcode integration's token was found — it can't read usage data.")
            return
        }

        // 2. Proactively refresh if the access token is about to expire —
        //    at most once per 10 minutes, so a failing refresh can't hammer the endpoint.
        var current = found
        if current.isExpiringSoon, mayAttemptTokenRefresh() {
            lastTokenRefreshAttempt = Date()
            if let refreshed = await Self.refreshAccessToken(current) {
                current = refreshed
                await Task.detached(operation: { CredentialStore.writeOwn(refreshed) }).value
            }
        }
        credentials = current

        // 3. Fetch usage, retrying once through a token refresh on 401.
        do {
            var (code, data, retryAfter) = try await Self.fetchUsage(token: current.accessToken)
            if code == 401 {
                lastTokenRefreshAttempt = Date()
                if let refreshed = await Self.refreshAccessToken(current) {
                    credentials = refreshed
                    await Task.detached(operation: { CredentialStore.writeOwn(refreshed) }).value
                    (code, data, retryAfter) = try await Self.fetchUsage(token: refreshed.accessToken)
                }
            }
            guard code == 200 else {
                if code == 401 {
                    status = .needsLogin("Token expired and couldn't be refreshed.")
                } else if code == 429 {
                    let wait = max(retryAfter ?? 900, 300)
                    let until = Date().addingTimeInterval(wait)
                    cooldownUntil = until
                    status = .error("Rate limited — retrying at \(until.formatted(date: .omitted, time: .shortened))")
                } else {
                    status = .error(Self.apiErrorMessage(from: data) ?? "HTTP \(code)")
                }
                return
            }
            let parsed = Self.parseBuckets(data)
            guard !parsed.isEmpty else {
                status = .error("Unexpected response format from the usage endpoint.")
                return
            }
            cooldownUntil = nil
            wakeDelayUntil = nil
            buckets = parsed
            lastUpdated = Date()
            status = .ok
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func mayAttemptTokenRefresh() -> Bool {
        guard let last = lastTokenRefreshAttempt else { return true }
        return Date().timeIntervalSince(last) > 600
    }

    // MARK: Networking

    private static func fetchUsage(token: String) async throws -> (Int, Data, TimeInterval?) {
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let retryAfter = http?.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
        return (http?.statusCode ?? 0, data, retryAfter)
    }

    private static func refreshAccessToken(_ creds: OAuthCredentials) async -> OAuthCredentials? {
        guard let refreshToken = creds.refreshToken else { return nil }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else { return nil }

        var updated = creds
        updated.accessToken = accessToken
        if let newRefresh = json["refresh_token"] as? String {
            updated.refreshToken = newRefresh
        }
        // Without this default, a response missing expires_in would leave the old
        // (past) expiry in place, making every poll re-attempt a refresh.
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        updated.expiresAt = (Date().timeIntervalSince1970 + expiresIn) * 1000
        return updated
    }

    // MARK: Parsing

    /// The `limits` array mirrors the desktop client's panel exactly
    /// (kind: session / weekly_all / weekly_scoped-with-model, percent, resets_at),
    /// so it's the primary source. The top-level bucket scan is a fallback for
    /// older/alternate response shapes.
    static func parseBuckets(_ data: Data) -> [UsageBucket] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        if let limits = object["limits"] as? [[String: Any]] {
            let parsed = limits.compactMap(bucketFromLimit)
            if !parsed.isEmpty { return parsed }
        }
        return legacyBuckets(object)
    }

    private static func bucketFromLimit(_ entry: [String: Any]) -> UsageBucket? {
        guard let percent = (entry["percent"] as? NSNumber)?.doubleValue else { return nil }
        let kind = entry["kind"] as? String ?? "limit"
        let scopeModel = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String

        let title: String
        switch kind {
        case "session":       title = "5-hour limit"
        case "weekly_all":    title = "Weekly · all models"
        case "weekly_scoped": title = "Weekly · \(scopeModel ?? "scoped")"
        default:
            let base = kind.replacingOccurrences(of: "_", with: " ").capitalized
            title = scopeModel.map { "\(base) · \($0)" } ?? base
        }

        return UsageBucket(
            key: scopeModel.map { "\(kind)-\($0)" } ?? kind,
            title: title,
            percent: min(max(percent, 0), 100),
            resetsAt: (entry["resets_at"] as? String).flatMap(parseISODate)
        )
    }

    private static func legacyBuckets(_ object: [String: Any]) -> [UsageBucket] {
        // extra_usage is credit spend, not a rate-limit bucket — the panel doesn't show it.
        let excluded: Set<String> = ["extra_usage", "spend"]
        let knownOrder = ["five_hour", "seven_day", "seven_day_opus", "seven_day_fable", "seven_day_sonnet"]

        var raw: [(key: String, utilization: Double, resetsAt: Date?)] = []
        for (key, value) in object where !excluded.contains(key) {
            guard let dict = value as? [String: Any],
                  let utilization = (dict["utilization"] as? NSNumber)?.doubleValue
            else { continue }
            raw.append((key, utilization, (dict["resets_at"] as? String).flatMap(parseISODate)))
        }
        guard !raw.isEmpty else { return [] }

        // Utilization may arrive as 0–100 or as a 0–1 fraction; if every value is ≤ 1, treat as fractions.
        let scale = raw.allSatisfy { $0.utilization <= 1.0 } ? 100.0 : 1.0

        func rank(_ key: String) -> Int { knownOrder.firstIndex(of: key) ?? knownOrder.count }
        func title(_ key: String) -> String {
            switch key {
            case "five_hour":        return "5-hour limit"
            case "seven_day":        return "Weekly · all models"
            case "seven_day_opus":   return "Weekly · Opus"
            case "seven_day_fable":  return "Weekly · Fable"
            case "seven_day_sonnet": return "Weekly · Sonnet"
            default:                 return key.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        return raw
            .sorted { (rank($0.key), $0.key) < (rank($1.key), $1.key) }
            .map { UsageBucket(key: $0.key, title: title($0.key), percent: min(max($0.utilization * scale, 0), 100), resetsAt: $0.resetsAt) }
    }

    private static func parseISODate(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: string) { return date }
        // The API sends 6-digit fractional seconds, which ISO8601DateFormatter
        // can't parse (it only accepts exactly 3) — strip the fraction entirely.
        if let dotRange = string.range(of: #"\.\d+"#, options: .regularExpression) {
            var stripped = string
            stripped.removeSubrange(dotRange)
            return plain.date(from: stripped)
        }
        return nil
    }

    private static func apiErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return nil }
        return message
    }
}

// MARK: - Keychain access (via /usr/bin/security)

enum CredentialStore {
    /// The app's own Keychain item, so refreshed tokens don't overwrite Claude Code's.
    static let ownService = "ClaudeUsageBar-credentials"

    /// Picks the credentials with the latest expiry, preferring ones with the user:profile scope
    /// (the Xcode integration's token lacks it and can't read usage data).
    static func bestCredentials() -> OAuthCredentials? {
        var candidates: [OAuthCredentials] = []
        if let own = read(service: ownService) {
            candidates.append(own)
        }
        for name in claudeCodeServiceNames() {
            if let creds = read(service: name) {
                candidates.append(creds)
            }
        }
        guard !candidates.isEmpty else { return nil }
        let profiled = candidates.filter { $0.hasProfileScope }
        let pool = profiled.isEmpty ? candidates : profiled
        return pool.max { ($0.expiresAt ?? 0) < ($1.expiresAt ?? 0) }
    }

    /// Claude Code may store its item as "Claude Code-credentials" or with a config-dir suffix
    /// (e.g. "Claude Code-credentials-1c40d5b7" for the Xcode integration) — find them all.
    static func claudeCodeServiceNames() -> [String] {
        let result = run("/usr/bin/security", ["dump-keychain"])
        var names = Set<String>()
        let text = result.stdout
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: "Claude Code-credentials", range: searchRange) {
            var end = range.upperBound
            while end < text.endIndex, text[end] != "\"" {
                end = text.index(after: end)
            }
            names.insert(String(text[range.lowerBound..<end]))
            searchRange = end..<text.endIndex
        }
        return names.sorted()
    }

    static func read(service: String) -> OAuthCredentials? {
        let result = run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
        guard result.status == 0, let data = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        // Claude Code wraps the payload in {"claudeAiOauth": {...}}; our own item stores it bare.
        struct Wrapper: Codable { let claudeAiOauth: OAuthCredentials? }
        if let wrapped = try? decoder.decode(Wrapper.self, from: data), let creds = wrapped.claudeAiOauth {
            return creds
        }
        return try? decoder.decode(OAuthCredentials.self, from: data)
    }

    static func writeOwn(_ creds: OAuthCredentials) {
        guard let data = try? JSONEncoder().encode(creds),
              let json = String(data: data, encoding: .utf8)
        else { return }
        // -U updates the item in place if it already exists.
        run("/usr/bin/security", ["add-generic-password", "-U", "-s", ownService, "-a", NSUserName(), "-w", json])
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
