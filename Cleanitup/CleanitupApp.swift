import SwiftUI

/// Cleanitup — a free, open-source, transparent macOS storage cleaner.
///
/// Design contract (see PRD.md): preview before every action, move to Trash
/// (never `rm`), label every item Safe/Caution, and never touch SIP-protected
/// paths. This is the app shell; cleaning engines land per the roadmap.
@main
struct CleanitupApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 480)
                .tint(Theme.primary)               // emerald accent (§2.4)
                .preferredColorScheme(.dark)       // dark-first canvas (§1)
        }
        .windowResizability(.contentMinSize)
    }
}
