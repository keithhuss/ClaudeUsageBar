import Foundation
import AppKit
import CoreGraphics
import Network

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

    /// Manual override for the Fable-usage case — polls at `fastPollInterval` while on.
    @Published var fastPollingEnabled: Bool = false

    private var credentials: OAuthCredentials?
    private var timer: Timer?
    private var cooldownUntil: Date?          // set after a 429; automatic polls skip until then
    private var lastTokenRefreshAttempt: Date?
    private var lastPollAttempt: Date?        // gates automatic polls against currentPollInterval
    private var consecutive429s: Int = 0      // backs off harder if the server keeps saying no
    private var authFailureSince: Date?       // first 401-with-failed-refresh; cleared on success

    // A manual Refresh click bypasses the throttles below, so without this a click made
    // while an automatic poll is already mid-flight (e.g. during the auth-retry grace
    // period) could start a second, fully independent reload — both reading and possibly
    // both trying to refresh the same single-use refresh token, guaranteeing one fails.
    private var isReloading = false

    // The desktop Claude app polls the same usage endpoint every ~15 min whenever it's
    // running (which is always, for Keith) and writes the results to this local cache.
    // The endpoint's rate-limit bucket is shared per-token across clients and appears
    // sized for roughly one — so our own polls stacked on the desktop app's were what
    // kept tripping 429s. Piggybacking on its cache costs zero API calls; the network
    // fetch below then only needs to run hourly to fill in what the cache lacks (the
    // weekly-Fable bucket and reset timestamps).
    private var lastCacheMTime: Date?
    private static let desktopCacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    private static let cacheFreshWindow: TimeInterval = 1200      // desktop app writes every ~15 min
    private static let cacheBackedNetworkInterval: TimeInterval = 3600
    private static let seedMaxSampleAge: TimeInterval = 3600      // don't seed bars from stale data

    private var cacheIsFresh: Bool {
        guard let lastCacheMTime else { return false }
        return Date().timeIntervalSince(lastCacheMTime) < Self.cacheFreshWindow
    }

    // Since this app is the only client that ever refreshes its Keychain credential (Keith
    // doesn't run Claude Code CLI directly), a refresh attempt that starts before the network
    // has actually stabilized post-wake risks the single-use refresh token being rotated
    // server-side while the response carrying the new one is lost — permanently killing it
    // with nothing else around to recover it. Wait for confirmed-stable connectivity instead
    // of guessing with a fixed timer.
    private var pathMonitor: NWPathMonitor?
    private var networkSatisfiedSince: Date?
    private var wakePending: Date?
    private static let requiredStableNetworkDuration: TimeInterval = 20
    private static let maxWakeNetworkWait: TimeInterval = 600     // give up waiting and try anyway

    /// Claude Code's public OAuth client id, needed for the refresh-token grant.
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    /// Actual polling cadence is one of these three, chosen by `currentPollInterval` below.
    /// A short timer just checks every `tickInterval` whether the chosen interval has
    /// elapsed since the last attempt — this lets the effective rate change instantly
    /// (toggling fast mode, or the Mac going idle/active) without recreating the Timer.
    private static let fastPollInterval: TimeInterval = 300      // Fable mode
    private static let normalPollInterval: TimeInterval = 900
    private static let idlePollInterval: TimeInterval = 1800
    private static let idleThreshold: TimeInterval = 600         // Mac idle this long → slow down
    private static let tickInterval: TimeInterval = 30

    /// Most 401s turn out to be transient (a flaky refresh call, a momentary server hiccup) and
    /// clear up on their own — retry quickly and quietly rather than immediately telling the user
    /// they need to redo the one-time setup. The grace period only controls which message is
    /// shown (`Reconnecting…` vs the full needsLogin screen); polling itself stays at this fast
    /// interval for as long as the failure is unresolved, even past the grace period. Keith is
    /// the sole client ever refreshing this Keychain item, and a plain retry — manual or
    /// automatic — has consistently cleared these episodes just as well as a real re-login would,
    /// so backing off to the normal 15-30 min cadence here would just mean sitting on the
    /// needsLogin screen until he happens to click Refresh himself.
    private static let authRetryInterval: TimeInterval = 90
    private static let authRetryGracePeriod: TimeInterval = 1200

    private var currentPollInterval: TimeInterval {
        if authFailureSince != nil {
            return Self.authRetryInterval
        }
        if fastPollingEnabled { return Self.fastPollInterval }
        // While the desktop app's cache is feeding the bars, the network fetch only needs
        // to run hourly (for the Fable bucket and reset timestamps the cache lacks).
        if cacheIsFresh { return Self.cacheBackedNetworkInterval }
        if Self.systemIdleSeconds() >= Self.idleThreshold { return Self.idlePollInterval }
        return Self.normalPollInterval
    }

    private static func systemIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .null)
    }

    init() {
        refresh()
        startRegularTimer()
        subscribeToWakeNotification()
        startNetworkMonitor()
    }

    /// `manual: true` (the Refresh button) bypasses the rate-limit cooldown.
    func refresh(manual: Bool = false) {
        Task {
            await pollDesktopCache()
            await reload(manual: manual)
        }
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
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// On system wake, hold off polling until the network has been confirmed stable for a
    /// while (see `isAwaitingStableNetwork`) rather than guessing with a fixed delay.
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
        wakePending = Date()
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.handleNetworkPathUpdate(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "ClaudeUsageBar.NWPathMonitor"))
        pathMonitor = monitor
    }

    private func handleNetworkPathUpdate(satisfied: Bool) {
        if satisfied {
            if networkSatisfiedSince == nil { networkSatisfiedSince = Date() }
        } else {
            networkSatisfiedSince = nil
        }
    }

    /// True while we should keep silently skipping automatic polls after a wake: either the
    /// network hasn't been continuously reachable for `requiredStableNetworkDuration` yet, or
    /// we don't have positive confirmation of connectivity at all. Gives up and proceeds anyway
    /// past `maxWakeNetworkWait` so a monitor glitch can't wedge polling forever.
    private func isAwaitingStableNetwork(since wokeAt: Date, now: Date) -> Bool {
        if now.timeIntervalSince(wokeAt) >= Self.maxWakeNetworkWait { return false }
        guard let networkSatisfiedSince else { return true }
        return now.timeIntervalSince(networkSatisfiedSince) < Self.requiredStableNetworkDuration
    }

    // MARK: Desktop-cache piggyback

    /// Updates the 5-hour and weekly-all bars from the desktop app's local cache when it has
    /// a newer sample than our last update. Zero API calls. The cache's `u` dict holds integer
    /// percentages: `fh` (five-hour) and `sd` (seven-day all-models); it has no Fable bucket
    /// and no reset timestamps, so those keep whatever the last real network fetch supplied.
    private func pollDesktopCache() async {
        let url = Self.desktopCacheURL
        let previousMTime = lastCacheMTime
        let result: (mtime: Date, sampleDate: Date, fiveHour: Double?, weekly: Double?)? =
            await Task.detached {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let mtime = attrs[.modificationDate] as? Date
                else { return nil }
                // Only re-parse when the file has actually changed (it's ~0.5MB of history).
                if let previousMTime, mtime <= previousMTime { return nil }
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let samples = object["samples"] as? [[String: Any]],
                      let last = samples.last,
                      let t = (last["t"] as? NSNumber)?.doubleValue,
                      let usage = last["u"] as? [String: Any]
                else { return nil }
                return (
                    mtime,
                    Date(timeIntervalSince1970: t / 1000),
                    (usage["fh"] as? NSNumber)?.doubleValue,
                    (usage["sd"] as? NSNumber)?.doubleValue
                )
            }.value

        guard let result else { return }
        lastCacheMTime = result.mtime

        guard result.sampleDate > (lastUpdated ?? .distantPast) else { return }

        if buckets.isEmpty {
            // Seed the bars outright when there's nothing to update — e.g. the app relaunched
            // straight into a rate-limit cooldown, where the network path can stay blocked for
            // hours. Previously the empty-buckets case just returned here, so the panel showed
            // a bare error for the entire cooldown while fresh cache data was discarded every
            // tick. Reset times aren't in the cache; they arrive with the next real fetch.
            guard Date().timeIntervalSince(result.sampleDate) < Self.seedMaxSampleAge else { return }
            var seeded: [UsageBucket] = []
            if let fiveHour = result.fiveHour {
                seeded.append(UsageBucket(key: "session", title: "5-hour limit",
                                          percent: min(max(fiveHour, 0), 100), resetsAt: nil))
            }
            if let weekly = result.weekly {
                seeded.append(UsageBucket(key: "weekly_all", title: "Weekly · all models",
                                          percent: min(max(weekly, 0), 100), resetsAt: nil))
            }
            guard !seeded.isEmpty else { return }
            buckets = seeded
            Self.log("seeded bars from desktop cache (sample \(result.sampleDate.formatted()))")
        } else {
            buckets = buckets.map { bucket in
                let percent: Double?
                switch bucket.key {
                case "session", "five_hour":  percent = result.fiveHour
                case "weekly_all", "seven_day": percent = result.weekly
                default: percent = nil
                }
                guard let percent else { return bucket }
                return UsageBucket(
                    key: bucket.key,
                    title: bucket.title,
                    percent: min(max(percent, 0), 100),
                    resetsAt: bucket.resetsAt
                )
            }
        }
        lastUpdated = result.sampleDate
        // The bars are current again — clear the initial loading spinner or a lingering
        // rate-limited/error banner (either would hide or overshadow them). A real login
        // problem (needsLogin) stays; the cache can't fix authentication.
        switch status {
        case .loading, .error: status = .ok
        case .ok, .needsLogin: break
        }
    }

    // MARK: Core flow

    private func reload(manual: Bool) async {
        // Never let two reloads run concurrently — a manual click while an automatic one is
        // already in flight would otherwise race it (see isReloading's doc comment above).
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }

        // Respect the post-wake network-stability wait (silent), rate-limit cooldown, and
        // normal polling cadence for automatic polls — the tick timer fires far more often
        // than we actually want to hit the network.
        if !manual {
            let now = Date()
            if let wakePending, isAwaitingStableNetwork(since: wakePending, now: now) { return }
            if let cooldownUntil, cooldownUntil > now { return }
            if let lastPollAttempt, now.timeIntervalSince(lastPollAttempt) < currentPollInterval { return }
        }
        wakePending = nil
        lastPollAttempt = Date()

        // 1. Find the freshest usable credentials (own store or Claude Code's Keychain items).
        guard let found = await Task.detached(operation: { CredentialStore.bestFound() }).value else {
            status = .needsLogin("No Claude Code login found on this Mac.")
            return
        }
        guard found.credentials.hasProfileScope else {
            status = .needsLogin("Only the Xcode integration's token was found — it can't read usage data.")
            return
        }

        // Refreshes are written back to whichever Keychain item the credential came from
        // (almost always Claude Code CLI's own item, not a private copy). Anthropic's refresh
        // tokens are single-use/rotating — forking a private copy that refreshes independently
        // of the CLI meant whichever side refreshed first invalidated the other's copy, causing
        // "Token expired and couldn't be refreshed" every time the CLI was used heavily.
        let service = found.service

        // 2. Proactively refresh if the access token is about to expire —
        //    at most once per 10 minutes, so a failing refresh can't hammer the endpoint.
        var current = found.credentials
        if current.isExpiringSoon, mayAttemptTokenRefresh() {
            lastTokenRefreshAttempt = Date()
            if let refreshed = await Self.refreshAccessToken(current) {
                current = refreshed
                await Task.detached(operation: { CredentialStore.write(service: service, rawData: found.rawData, refreshed: refreshed) }).value
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
                    await Task.detached(operation: { CredentialStore.write(service: service, rawData: found.rawData, refreshed: refreshed) }).value
                    (code, data, retryAfter) = try await Self.fetchUsage(token: refreshed.accessToken)
                }
            }
            guard code == 200 else {
                // Each counter below only accumulates across consecutive occurrences of its
                // own failure type — reset on the others so a stale timer/count from an
                // already-resolved incident can't distort how a later, unrelated failure is
                // handled (e.g. a 429 in between two 401s shouldn't shorten the grace period
                // the second 401 gets, and vice versa).
                if code == 401 {
                    consecutive429s = 0
                    let failingSince = authFailureSince ?? Date()
                    authFailureSince = failingSince
                    Self.log("401, refresh failed (failing since \(failingSince.formatted()))")
                    if Date().timeIntervalSince(failingSince) < Self.authRetryGracePeriod {
                        status = .error("Reconnecting…")
                    } else {
                        status = .needsLogin("Token expired and couldn't be refreshed.")
                    }
                } else if code == 429 {
                    // Back off harder on repeated 429s — resuming at full cadence right when a
                    // single cooldown expires can retrigger the limit if its window hasn't really
                    // cleared, turning one hiccup into a cascading multi-hour lockout. Only
                    // automatic polls escalate the multiplier, though: manual Refresh clicks
                    // bypass the cooldown, so during an episode each hopeful click was re-429ing
                    // and re-doubling the wait — user-visible as the retry time leaping hours
                    // into the future precisely because they asked it to try again.
                    authFailureSince = nil
                    if !manual { consecutive429s += 1 }
                    let base = max(retryAfter ?? 900, 300)
                    let wait = base * pow(2.0, Double(min(max(consecutive429s, 1) - 1, 4)))
                    let until = Date().addingTimeInterval(wait)
                    cooldownUntil = until
                    Self.log("429 (manual: \(manual), retry-after: \(retryAfter.map { String(Int($0)) } ?? "none"), consecutive: \(consecutive429s)) — cooldown until \(until.formatted())")
                    status = .error("Rate limited — retrying at \(until.formatted(date: .omitted, time: .shortened))")
                } else {
                    authFailureSince = nil
                    consecutive429s = 0
                    Self.log("HTTP \(code): \(Self.apiErrorMessage(from: data) ?? "no error message")")
                    status = .error(Self.apiErrorMessage(from: data) ?? "HTTP \(code)")
                }
                return
            }
            let parsed = Self.parseBuckets(data)
            guard !parsed.isEmpty else {
                status = .error("Unexpected response format from the usage endpoint.")
                return
            }
            if cooldownUntil != nil || authFailureSince != nil { Self.log("recovered — 200 OK") }
            cooldownUntil = nil
            consecutive429s = 0
            authFailureSince = nil
            buckets = parsed
            lastUpdated = Date()
            status = .ok
        } catch {
            authFailureSince = nil
            consecutive429s = 0
            Self.log("network error: \(error.localizedDescription)")
            status = .error(error.localizedDescription)
        }
    }

    private func mayAttemptTokenRefresh() -> Bool {
        guard let last = lastTokenRefreshAttempt else { return true }
        return Date().timeIntervalSince(last) > 600
    }

    // MARK: Diagnostics

    /// Appends one line to ~/Library/Logs/ClaudeUsageBar.log — the panel only ever shows the
    /// latest state, so recurring failures (like the repeated-429 mornings) have been
    /// undiagnosable after the fact. Starts over past ~512KB rather than rotating.
    nonisolated private static func log(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeUsageBar.log")
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .omitted))
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > 512_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
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

        // A network-layer failure (timeout, connection lost — data(for:) throws) means the
        // request most likely never reached the server, so the single-use refresh token
        // wasn't consumed and it's safe to retry with the same one. An actual HTTP response,
        // even a non-200 one, means the server saw the request — no such guarantee there, so
        // that case returns immediately rather than retrying. This app is typically the only
        // client that ever refreshes this credential, so losing this race even once leaves
        // nothing else around to recover it.
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            guard let (data, response) = try? await URLSession.shared.data(for: request) else {
                continue
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
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
        return nil
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
    struct Found {
        let service: String
        let credentials: OAuthCredentials
        let rawData: Data   // exact bytes read from Keychain, so write(service:) can preserve unknown fields
    }

    /// Picks the credentials with the latest expiry, preferring ones with the user:profile scope
    /// (the Xcode integration's token lacks it and can't read usage data).
    static func bestFound() -> Found? {
        var candidates: [Found] = []
        for name in claudeCodeServiceNames() {
            if let found = read(service: name) {
                candidates.append(found)
            }
        }
        guard !candidates.isEmpty else { return nil }
        let profiled = candidates.filter { $0.credentials.hasProfileScope }
        let pool = profiled.isEmpty ? candidates : profiled
        return pool.max { ($0.credentials.expiresAt ?? 0) < ($1.credentials.expiresAt ?? 0) }
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

    static func read(service: String) -> Found? {
        let result = run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
        guard result.status == 0, let data = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        // Claude Code wraps the payload in {"claudeAiOauth": {...}}; our own item stores it bare.
        struct Wrapper: Codable { let claudeAiOauth: OAuthCredentials? }
        if let wrapped = try? decoder.decode(Wrapper.self, from: data), let creds = wrapped.claudeAiOauth {
            return Found(service: service, credentials: creds, rawData: data)
        }
        if let creds = try? decoder.decode(OAuthCredentials.self, from: data) {
            return Found(service: service, credentials: creds, rawData: data)
        }
        return nil
    }

    /// Writes back to whichever service the credential was read from. Claude Code's real items
    /// carry extra fields we don't model (refreshTokenExpiresAt, subscriptionType, rateLimitTier,
    /// clientId) — re-encoding a bare OAuthCredentials would silently drop them and corrupt
    /// Claude Code CLI's own session, so this merges only the changed fields into the ORIGINAL
    /// JSON read from this service instead of replacing the object wholesale.
    static func write(service: String, rawData: Data, refreshed: OAuthCredentials) {
        guard var top = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any] else { return }
        var inner = top["claudeAiOauth"] as? [String: Any] ?? [:]

        inner["accessToken"] = refreshed.accessToken
        if let refreshToken = refreshed.refreshToken { inner["refreshToken"] = refreshToken }
        if let expiresAt = refreshed.expiresAt { inner["expiresAt"] = expiresAt }

        top["claudeAiOauth"] = inner

        guard let payload = try? JSONSerialization.data(withJSONObject: top),
              let json = String(data: payload, encoding: .utf8)
        else { return }
        // -U updates the item in place if it already exists.
        run("/usr/bin/security", ["add-generic-password", "-U", "-s", service, "-a", NSUserName(), "-w", json])
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
