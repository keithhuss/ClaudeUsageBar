import SwiftUI
import AppKit

struct UsagePanelView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var appDelegate: AppDelegate
    var isFloating: Bool = false
    @State private var startAtLogin = LoginItemManager.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isFloating {
                HStack {
                    Text("Claude Usage")
                        .font(.headline)
                    Spacer()
                    Button {
                        appDelegate.toggleFloatingWindow()
                    } label: {
                        Image(systemName: appDelegate.isWindowVisible ? "macwindow.badge.plus" : "macwindow")
                    }
                    .buttonStyle(.borderless)
                    .help(appDelegate.isWindowVisible ? "Hide the floating window" : "Show a floating window with these bars")
                }
            }

            switch model.status {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }

            case .needsLogin(let message):
                needsLoginView(message)

            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                if !model.buckets.isEmpty {
                    bucketRows
                }

            case .ok:
                bucketRows
            }

            Divider()

            HStack {
                if let updated = model.lastUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { model.refresh(manual: true) }
                    .controlSize(.small)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }

            if !isFloating {
                Toggle("Fast polling (Fable mode)", isOn: $model.fastPollingEnabled)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.caption)
                    .help("Poll every 5 minutes instead of the normal cadence — turn on while actively using Fable.")

                Toggle("Start at login", isOn: $startAtLogin)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.caption)
                    .onChange(of: startAtLogin) { _, enabled in
                        if enabled {
                            if !LoginItemManager.enable() {
                                startAtLogin = false
                            }
                        } else {
                            LoginItemManager.disable()
                        }
                    }
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { model.refresh() }
    }

    private var bucketRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.buckets) { bucket in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(bucket.title)
                            .font(.callout)
                        Spacer()
                        Text(resetText(bucket.resetsAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("\(Int(bucket.percent.rounded()))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(bucket.percent >= 90 ? .red : .primary)
                            .layoutPriority(1)
                    }
                    UsageProgressBar(percent: bucket.percent, color: tint(for: bucket.percent))
                }
            }
        }
    }

    private func tint(for percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return .accentColor
    }

    private func resetText(_ date: Date?) -> String {
        guard let date else { return "" }
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "Resets soon" }
        if interval < 24 * 3600 {
            let hours = Int(interval) / 3600
            let minutes = (Int(interval) % 3600) / 60
            return hours > 0 ? "Resets in \(hours) hr \(minutes) min" : "Resets in \(minutes) min"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        return "Resets \(formatter.string(from: date))"
    }

    // Pure SwiftUI bar — bypasses NSProgressIndicator, which desaturates when the window is inactive.
    private struct UsageProgressBar: View {
        let percent: Double
        let color: Color

        var body: some View {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geo.size.width * min(percent / 100, 1))
                }
            }
            .frame(height: 4)
        }
    }

    private func needsLoginView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.orange)
                .font(.callout)
            Text("One-time setup:")
                .font(.caption.bold())
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Install Claude Code in Terminal:")
                Text("curl -fsSL https://claude.ai/install.sh | bash")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text("2. Run `claude`, log in with your Claude account, then quit it.")
                Text("3. Click Refresh below.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
