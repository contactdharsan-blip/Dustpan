import SwiftUI

/// Dustpan — a free, open-source, transparent macOS storage cleaner.
///
/// Design contract (see PRD.md): preview before every action, move to Trash
/// (never `rm`), label every item Safe/Caution, and never touch SIP-protected
/// paths. This is the app shell; cleaning engines land per the roadmap.
@main
struct DustpanApp: App {
    // App-scoped so the main window and the menu-bar item share ONE measurement
    // run — the menu bar reads this store, it never triggers its own scan.
    @State private var store = StatsStore()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(store: store)
                .frame(minWidth: 760, minHeight: 480)
                .tint(Theme.primary)               // emerald accent (§2.4)
                .preferredColorScheme(.dark)       // dark-first canvas (§1)
                .onAppear { Self.clampRestoredWindow() }
        }
        .defaultSize(width: 900, height: 560)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarScoreView(store: store)
        } label: {
            // Calm: an SF Symbol plus the score number when fully measured,
            // an em-dash otherwise. Never a half-measured value, never alarm color.
            if store.snapshot?.isComplete == true, let score = store.snapshot?.score {
                Image(systemName: "sparkles")
                Text("\(score.value)")
            } else {
                Image(systemName: "sparkles")
                Text("—")
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// One-shot guard: macOS state restoration has been observed (once, on a
    /// 27.0 beta) restoring the window at ~108x101pt despite minWidth/minHeight
    /// + .contentMinSize. If the restored CONTENT is below the minimum, snap it
    /// back to the default size. Compares content-to-content (frame includes
    /// the title bar, so a window exactly at minimum is left alone).
    private static func clampRestoredWindow() {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first
            else { return }
            let content = window.contentRect(forFrameRect: window.frame).size
            if content.width < 760 || content.height < 480 {
                window.setContentSize(NSSize(width: 900, height: 560))
            }
        }
    }
}

/// Compact .window-style menu-bar panel. Reads the app-scoped StatsStore — it
/// never starts its own scan. Honest: shows "Measuring…"/em-dash until `score`
/// is non-nil, and lists the engine's inputs verbatim, same spirit as the
/// dashboard ScoreCard.
private struct MenuBarScoreView: View {
    let store: StatsStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cleanliness score").typoLabel()

            if let score = store.snapshot?.score {
                Text("\(score.value)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.primary)

                ForEach(score.inputsSummary, id: \.self) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text(store.snapshot == nil ? "—" : "Measuring…")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }

            Divider()

            HStack {
                Button("Refresh") { store.refresh() }
                Spacer()
                Button("Open Dustpan") { openMainWindow() }
            }
        }
        .padding(16)
        .frame(width: 280)
        .tint(Theme.primary)
        .preferredColorScheme(.dark)
    }

    /// Bring the existing main window to front; if none exists, ask SwiftUI to
    /// open one.
    private func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}
