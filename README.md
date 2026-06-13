# Dustpan

**A free, open-source, transparent macOS storage cleaner.**

![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)
![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-lightgrey.svg)

Dustpan shows you every file before it touches anything, moves things to the
Trash (never `rm`), and only cleans what genuinely reclaims space — app
leftovers, large files, and developer caches. No subscription, no upsell, no
telemetry, and you can read every line that touches your disk.

> **Status:** working core. The **Overview** dashboard measures your real disk
> across 20 disjoint categories (every number measured or shown as "—", with an
> honest unitemized remainder); `SafeDeleteEngine` gates all deletion behind a
> home-only `verdict()` safety check and only ever moves items to the Trash; and
> **Developer Caches** runs a real Quick/Deep scan with preview, risk labels,
> and confirm-before-Trash. The other categories are design previews with
> clearly-labeled sample data, being built per the [roadmap](#roadmap).

---

## Why another Mac cleaner?

The category is trust-starved: the leader is closed-source and subscription-first,
and the whole space is tainted by scareware (MacKeeper, MacBooster). Meanwhile the
best free tools are decaying — Pearcleaner is "on hold indefinitely," AppCleaner is
stale, and BleachBit's Mac build is command-line only.

A cleaner needs **Full Disk Access** — the same permission profile as malware. The
only honest way to earn that is to let anyone read exactly what the tool deletes.
That is the entire point of Dustpan. See [`PRD.md`](PRD.md) for the full product
rationale and competitive analysis.

## Safe by default

- 👁  **Preview everything** — full file paths and sizes shown before any deletion.
- ↩️  **Trash, not `rm`** — every action is reversible. No permanent delete.
- 🛡  **Never touches SIP-protected system files.**
- 📡  **Zero network calls, zero telemetry** — verifiable in this source tree.
- 🚫  **No placebo** — no "free up RAM," no fake threat counts, no alarmist framing.

## Download & open

**Requirements:** macOS 14 (Sonoma) or later, and [Xcode](https://developer.apple.com/xcode/) 16 or later.

```sh
git clone https://github.com/contactdharsan-blip/Dustpan.git
cd Dustpan
open Dustpan.xcodeproj
```

Then press **▶ Run** (⌘R) in Xcode. The app is configured to sign locally
("Sign to Run Locally"), so it builds and runs with no Apple Developer account.

Prefer the command line?

```sh
xcodebuild -scheme Dustpan -configuration Debug build
```

## Command-line interface

The engines are Foundation-only, so the same cleaner runs headless — useful for
CI, cron, or "I'll just script it" workflows. Build it with `scripts/build-cli.sh`
(universal `arm64+x86_64`; `--thin` for a fast host-arch build):

```sh
dustpan scan                 # disk, categories, cleanliness, reclaimable summary
dustpan caches --deep        # reclaimable developer/app caches
dustpan duplicates           # byte-identical duplicate groups
dustpan large --deep         # large files
dustpan apps / orphans       # installed apps · leftover files
dustpan login-items          # launchd login items (report-only)
dustpan history              # the Trash audit journal

dustpan trash <path>...      # move to Trash — verdict()-gated, journaled, reversible
dustpan restore <id>         # put a trashed item back (id from `history`)

dustpan scan --json          # machine-readable output for any command
```

`scan` consumes the exact same measurement stream the GUI dashboard does, so the
numbers can't diverge. Denied paths print `—`, never a fake `0`. The only verbs
that touch disk are `trash`/`restore`, and both route through the same Trash-only
safety gate as the app — nothing is ever permanently deleted.

## Roadmap

| Milestone | Scope |
|---|---|
| **v1.0 — trust-first core** | App uninstaller · orphaned-file scan · large-file finder · mandatory preview · move-to-Trash with Safe/Caution labels |
| **v1.1 — the developer's cleaner** | Xcode DerivedData & old simulator runtimes · `node_modules` · Docker reclaim · npm/pip/gradle/cargo caches · scriptable CLI |
| **later** | Recursive project scan · "System Data" explainer · scheduled-scan reminders (notification only) |

Distribution will be a notarized DMG via GitHub Releases + Homebrew Cask — **not**
the Mac App Store, because Full Disk Access is incompatible with the App Sandbox.

## Project layout

```
Dustpan.xcodeproj       # Xcode project (file-system-synchronized groups)
Dustpan/                # app sources
  DustpanApp.swift       # @main entry point
  ContentView.swift        # sidebar + scan flow (preview → confirm → Trash)
  DashboardView.swift      # storage Overview (live measurements, honest "—"s)
  StatsEngine.swift        # 20 disjoint disk categories, progressive snapshots
  SafeDeleteEngine.swift   # safety gate, sizing, scans, Trash-only deletion
  DesignSystem.swift       # theme tokens + glass-card styling
  Components/              # reusable UI (buttons, mode switcher, feedback kit)
  Dustpan.entitlements   # intentionally NOT sandboxed (needs Full Disk Access)
  Assets.xcassets/
cli/main.swift            # scriptable CLI over the same engines (no xcodeproj target)
scripts/build-cli.sh      # swiftc build → dist/dustpan (universal)
PRD.md                    # product requirements & competitive research
```

(Planning notes live in a local `tasks/` directory that is gitignored — it
won't exist in a clone.)

## Contributing

Dustpan is built to survive single-maintainer abandonment — the failure mode that
killed the tools it replaces. Cleaning rules will live in community-editable manifests
so contributors can keep paths current as macOS shifts them each release. Issues and
PRs welcome.

## License

[GPL-3.0](LICENSE) — copyleft, so it can't be re-skinned into closed adware.
