import SwiftUI

// C1 UI — the audit log. Every move-to-Trash the app ever performed, newest
// first, with one-click "Put back" while the item is still in the Trash.
// Refusals are listed too: an audit log that hides failures isn't one.

struct HistoryView: View {
    @State private var entries: [JournalEntry] = []
    @State private var unreadable = 0
    @State private var states: [UUID: RestoreState] = [:]
    @State private var toast: String?
    @State private var toastStyle: ToastStyle = .success

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if entries.isEmpty {
                    EmptyStateView(
                        title: "No actions yet",
                        message: "Every move-to-Trash this app performs is recorded here, with a one-click way to put items back.",
                        systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity)
                } else {
                    if unreadable > 0 {
                        Text("\(unreadable) journal line\(unreadable == 1 ? "" : "s") could not be read — shown counts are a floor.")
                            .font(.caption).foregroundStyle(Theme.warning)
                    }
                    VStack(spacing: 10) {
                        ForEach(entries) { entry in
                            HistoryRow(entry: entry,
                                       state: states[entry.id] ?? .notRestorable,
                                       onRestore: { restore(entry) })
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .toast(message: $toast, style: toastStyle)
        .task { reload() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: 54, height: 54)
                .background(Theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).strokeBorder(Theme.primary.opacity(0.25), lineWidth: 1))
                .shadowGlow(Theme.primary, radius: 16, strength: 0.3)
            VStack(alignment: .leading, spacing: 6) {
                Text("History").font(Typo.h3).foregroundStyle(Theme.textPrimary)
                Text("The audit log: everything this app moved to Trash, and a way back.")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Refresh") { reload() }.buttonStyle(GlassButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func reload() {
        let loaded = UndoJournal.load()
        entries = loaded.entries
        unreadable = loaded.unreadableLines
        states = Dictionary(uniqueKeysWithValues: loaded.entries.map { ($0.id, UndoJournal.restoreState(of: $0)) })
    }

    private func restore(_ entry: JournalEntry) {
        switch UndoJournal.restore(entry) {
        case .success:
            toastStyle = .success
            toast = "Put back \(entry.name)"
        case .failure(let err):
            toastStyle = .warning
            toast = "Couldn't put back \(entry.name) — \(err.message)"
        }
        reload()
    }
}

private struct HistoryRow: View {
    let entry: JournalEntry
    let state: RestoreState
    let onRestore: () -> Void

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: entry.success ? "trash" : "hand.raised")
                .font(.system(size: 16))
                .foregroundStyle(entry.success ? Theme.textSecondary : Theme.warning)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(Typo.cardHeading).foregroundStyle(Theme.textPrimary)
                Text(entry.originalPath.replacingOccurrences(of: home, with: "~"))
                    .font(Typo.mono).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(entry.context) · \(entry.date.formatted(date: .abbreviated, time: .shortened))"
                     + (entry.success ? "" : " · refused: \(entry.error ?? "unknown")"))
                    .font(.caption).foregroundStyle(entry.success ? Theme.textTertiary : Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(entry.sizeText)
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
            switch state {
            case .restorable:
                Button("Put back", action: onRestore).buttonStyle(GlassButtonStyle())
            case .alreadyRestored:
                StatusBadge(kind: .safe, text: "Restored")
            case .trashItemGone:
                StatusBadge(kind: .neutral, text: "Trash emptied")
            case .originalOccupied:
                StatusBadge(kind: .caution, text: "Path occupied")
                    .help(state.explanation)
            case .notRestorable:
                if !entry.success { StatusBadge(kind: .caution, text: "Refused") }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: Theme.radiusXl)
    }
}
