import SwiftUI

/// Dustpan — a free, open-source, transparent macOS storage cleaner.
///
/// Design contract (see PRD.md): preview before every action, move to Trash
/// (never `rm`), label every item Safe/Caution, and never touch SIP-protected
/// paths. This is the app shell; cleaning engines land per the roadmap.
@main
struct DustpanApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 480)
                .tint(Theme.primary)               // emerald accent (§2.4)
                .preferredColorScheme(.dark)       // dark-first canvas (§1)
                .onAppear { Self.clampRestoredWindow() }
        }
        .defaultSize(width: 900, height: 560)
        .windowResizability(.contentMinSize)
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
