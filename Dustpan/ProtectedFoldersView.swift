import SwiftUI
import AppKit

// Protected Folders — the GUI management surface for the user-chosen HARD-BLOCK
// exclusion list (engine: ExclusionList / SafeDeleteEngine.isExcluded). The user
// picks folders Dustpan must NEVER scan and NEVER offer to delete; the engine
// filters them out of every scan and verdict() refuses them at delete time, so
// neither GUI, CLI, nor any future caller can Trash anything inside one.
//
// This is a MANAGEMENT surface, not a cleaning one: the rows have no delete
// button for the folders' contents — only Add (a folder picker) and per-row
// Remove (un-protect). Tone mirrors LoginItemsView: it explains and protects,
// it never touches user files.

/// App-scoped store (StatsStore / ScanSession pattern) so the protected list
/// survives sidebar switches. Reads through the engine's persisted manifest;
/// every mutation round-trips to protected-paths.json and reloads, so the GUI
/// reflects exactly what the engine will enforce.
@MainActor @Observable final class ProtectedFoldersStore {
    var folders: [URL] = []
    /// Last user-facing feedback for an add/remove. Cleared when the toast fades
    /// or the next mutation starts. A failure here means persistence FAILED — the
    /// folder is NOT actually protected — so we report it honestly, never silently.
    var feedback: Feedback?

    struct Feedback: Equatable {
        var message: String
        var isError: Bool
    }

    func load() {
        folders = ExclusionList.list().map { URL(fileURLWithPath: $0) }
    }

    /// Add a folder by absolute path (a picker gives us `url.path`). The engine
    /// normalizes and de-dupes; we reload from its returned list so display and
    /// enforcement can't drift. On a persist failure the engine THROWS — we do
    /// NOT update the list or claim success, we surface the error instead.
    func add(_ url: URL) {
        do {
            folders = try ExclusionList.add(path: url.path).map { URL(fileURLWithPath: $0) }
            feedback = Feedback(message: "Protected \(url.lastPathComponent)", isError: false)
        } catch {
            // Persistence failed — keep the displayed list reloaded from disk so
            // it matches what the engine actually enforces, and report honestly.
            load()
            feedback = Feedback(
                message: "Couldn’t protect \(url.lastPathComponent) — \(error.localizedDescription)",
                isError: true)
        }
    }

    /// Un-protect a folder. No file is touched — this only removes the refusal.
    /// THROWS on a persist failure; we then reload from disk (the folder is still
    /// protected) and report it, so we never claim it was un-protected when it wasn't.
    func remove(_ url: URL) {
        do {
            folders = try ExclusionList.remove(path: url.path).map { URL(fileURLWithPath: $0) }
            feedback = Feedback(message: "Stopped protecting \(url.lastPathComponent)", isError: false)
        } catch {
            load()
            feedback = Feedback(
                message: "Couldn’t un-protect \(url.lastPathComponent) — \(error.localizedDescription)",
                isError: true)
        }
    }
}

struct ProtectedFoldersView: View {
    @Bindable var store: ProtectedFoldersStore

    /// The folder a pending un-protect confirmation targets (Finding 30: remove is
    /// destructive enough — it lifts a safety block — to deserve a confirm step).
    @State private var pendingRemoval: URL?

    /// Bridges the store's structured Feedback into the `.toast` modifier's
    /// `Binding<String?>` + style. A nil message hides the toast; the style is
    /// derived from whether the last feedback was an error.
    private var toastMessage: Binding<String?> {
        Binding(
            get: { store.feedback?.message },
            set: { if $0 == nil { store.feedback = nil } })
    }
    private var toastStyle: ToastStyle { (store.feedback?.isError ?? false) ? .error : .success }

    /// ~-collapsed display path — the same convention the rest of the app uses
    /// for showing home-relative locations.
    private func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                explainer
                addButton
                if store.folders.isEmpty {
                    EmptyStateView(
                        title: "No protected folders yet",
                        message: "Add a folder and Dustpan will leave it out of every cleanup scan and never offer to move anything inside it to the Trash — in the app or the command line.",
                        systemImage: "lock.open")
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 10) {
                        ForEach(store.folders, id: \.self) { folder in
                            ProtectedFolderRow(
                                folder: folder,
                                displayPath: displayPath(folder),
                                onReveal: { NSWorkspace.shared.activateFileViewerSelecting([folder]) },
                                onRemove: { pendingRemoval = folder })
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { store.load() }
        .toast(message: toastMessage, style: toastStyle)
        .confirmationDialog(
            "Stop protecting this folder?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { folder in
            Button("Stop Protecting", role: .destructive) { store.remove(folder) }
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            Text("Dustpan will be able to scan “\(folder.lastPathComponent)” and offer to move things inside it to the Trash again. No file is deleted by this — it only lifts the protection.")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: 54, height: 54)
                .background(Theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).strokeBorder(Theme.primary.opacity(0.25), lineWidth: 1))
            VStack(alignment: .leading, spacing: 6) {
                Text("Protected Folders").font(Typo.h3).foregroundStyle(Theme.textPrimary)
                Text("Folders Dustpan must never offer to delete from — and leaves out of every cleanup scan.")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            PillBadge(text: "excluded", tint: Theme.success)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var explainer: some View {
        Text("A hard block, not a preference. Any folder you add here — and everything inside it — is left out of every cleanup scan (caches, large files, clutter, duplicates) and refused at delete time by the safety gate, so nothing under it can ever move to the Trash from the app, the command line, or any future tool. It may still count toward the disk-usage totals on Overview and Disk Map, which measure size only and never delete. Removing a folder from this list only lifts the protection; it never touches your files.")
            .font(.caption).foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var addButton: some View {
        Button {
            pickFolder()
        } label: {
            Label("Add Folder…", systemImage: "plus")
        }
        .buttonStyle(PrimaryButtonStyle())
    }

    /// Folder-only NSOpenPanel — the protected list is folders, not files. We
    /// store the chosen path absolutely (`url.path`); the engine normalizes it.
    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Protect"
        panel.message = "Choose a folder Dustpan should never scan or offer to delete."
        if panel.runModal() == .OK, let url = panel.url {
            store.add(url)
        }
    }
}

/// One protected folder. No delete-the-contents action — the only mutating
/// control un-protects the folder; Reveal opens it in Finder (verify, don't trust).
private struct ProtectedFolderRow: View {
    let folder: URL
    let displayPath: String
    let onReveal: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "folder.badge.minus")
                .font(.system(size: 18))
                .foregroundStyle(Theme.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(folder.lastPathComponent).font(Typo.cardHeading).foregroundStyle(Theme.textPrimary)
                Text(displayPath).font(Typo.mono).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Reveal") { onReveal() }
                .buttonStyle(GlassButtonStyle())
            Button("Remove") { onRemove() }
                .buttonStyle(GlassButtonStyle())
                .help("Stop protecting this folder (does not delete anything)")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: Theme.radiusLg)
    }
}
