import SwiftUI
import AppKit

struct UsagePanelView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var appDelegate: AppDelegate
    var isFloating: Bool = false
    @State private var startAtLogin = LoginItemManager.isEnabled

    // The floating window renders at ~75% of the menu-bar panel: narrower,
    // tighter spacing, smaller type and controls. The panel itself is unchanged.
    private var panelWidth: CGFloat { isFloating ? 210 : 280 }
    private var outerPadding: CGFloat { isFloating ? 10 : 14 }
    private var rowSpacing: CGFloat { isFloating ? 9 : 12 }
    private var barHeight: CGFloat { isFloating ? 3 : 4 }
    private var bodyFont: Font { isFloating ? .system(size: 9) : .callout }
    private var detailFont: Font { isFloating ? .system(size: 8) : .caption }
    private var buttonSize: ControlSize { isFloating ? .mini : .small }

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
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
                    .font(bodyFont)
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
                        .font(detailFont)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { model.refresh(manual: true) }
                    .controlSize(buttonSize)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .controlSize(buttonSize)
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
        .padding(outerPadding)
        .frame(width: panelWidth)
        .onAppear { model.refresh() }
    }

    private var bucketRows: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(model.buckets) { bucket in
                VStack(alignment: .leading, spacing: isFloating ? 3 : 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(bucket.title)
                            .font(bodyFont)
                        Spacer()
                        Text(resetText(bucket.resetsAt))
                            .font(detailFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("\(Int(bucket.percent.rounded()))%")
                            .font(bodyFont.monospacedDigit())
                            .foregroundStyle(bucket.percent >= 90 ? .red : .primary)
                            .layoutPriority(1)
                    }
                    UsageProgressBar(percent: bucket.percent, color: tint(for: bucket.percent), height: barHeight)
                }
            }
        }
    }

    private func tint(for percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        // Not .accentColor, and not Color(nsColor: .controlAccentColor) either —
        // both are dynamic colors that SwiftUI desaturates to grey in inactive
        // windows (the NSColor path started doing so on macOS 27). Resolve the
        // accent to plain sRGB components each render instead: a concrete color
        // has no key-state dependency for any future mechanism to hook into.
        return Self.concreteAccentColor
    }

    /// The user's accent color as a fixed RGB value, re-read on every call so a
    /// change in System Settings still shows up on the next redraw.
    private static var concreteAccentColor: Color {
        guard let rgb = NSColor.controlAccentColor.usingColorSpace(.sRGB) else {
            return .blue
        }
        return Color(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
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
        var height: CGFloat = 4

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
            .frame(height: height)
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
