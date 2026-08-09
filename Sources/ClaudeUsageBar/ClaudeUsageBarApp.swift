import SwiftUI
import AppKit

@main
struct ClaudeUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            UsagePanelView(model: AppDelegate.model, appDelegate: appDelegate)
        } label: {
            MenuBarLabel(model: AppDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        Label {
            Text(model.menuBarText)
        } icon: {
            Image(systemName: model.menuBarSymbol)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    static let model = UsageModel()

    /// Drives the show/hide-window button label in the panel.
    @Published var isWindowVisible = false

    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unbundled binaries (swift run) start in prohibited mode and need this
        // to reach the window server. A proper .app with LSUIElement=true in its
        // Info.plist handles activation correctly without it (and suppresses the
        // Dock icon that .regular would otherwise add).
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
        }
        // The floating window is opt-in — open it from the menu-bar panel.
    }

    func toggleFloatingWindow() {
        if let window, window.isVisible {
            window.orderOut(nil)
            isWindowVisible = false
        } else {
            showFloatingWindow()
        }
    }

    func showFloatingWindow() {
        if window == nil {
            window = makeWindow()
        }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        isWindowVisible = true
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: UsagePanelView(model: Self.model, appDelegate: self, isFloating: true)
            .environment(\.controlActiveState, .active))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Claude Usage"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.level = .floating                                  // stays above Xcode
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self

        // Give the window its real content size BEFORE positioning — at creation
        // time window.frame is ~1pt wide, which once put the "top-right corner"
        // position almost entirely off the right screen edge.
        window.setContentSize(hosting.view.fittingSize)

        // Restore the last position, or start in the top-right corner.
        if !window.setFrameUsingName("ClaudeUsageWindow"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(
                x: visible.maxX - size.width - 20,
                y: visible.maxY - size.height - 20
            ))
        }
        window.setFrameAutosaveName("ClaudeUsageWindow")

        // Clamp fully on-screen — also heals a bad frame saved by earlier builds.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            var frame = window.frame
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
            window.setFrame(frame, display: false)
        }
        return window
    }

    // Clicking the Dock icon opens the floating window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showFloatingWindow()
        }
        return true
    }

    // Closing the window just hides it — the menu-bar item stays.
    func windowWillClose(_ notification: Notification) {
        isWindowVisible = false
    }
}
