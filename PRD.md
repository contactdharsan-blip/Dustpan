# PRD — Cleanitup (working name)

**A free, open-source, transparent macOS storage cleaner.**
It shows you every file before it touches anything, moves to Trash (never `rm`), and only
cleans what genuinely reclaims space — app leftovers, large files, and developer caches.

| | |
|---|---|
| **Status** | Draft v0.1 — pre-build |
| **Platform** | macOS (Apple Silicon + Intel TBD), direct-distributed (not Mac App Store) |
| **Model** | 100% free, open-source (OSI license), no ads, no upsell, no telemetry |
| **Author** | kesavand@gmail.com |
| **Date** | 2026-06-09 |
| **Source** | Synthesized from a 6-researcher deep-research workflow (`tasks/research-claude-setups.md` sibling: workflow `wf_ec9a0f44-9f6`). Point-in-time facts labeled inline. |

---

## 1. Problem & opportunity

The macOS cleaner market is **trust-starved and abandonment-vacated**:

- **The leader is closed and expensive.** CleanMyMac (MacPaw) is the polished benchmark but
  subscription-first (~$35–90+/yr; one-time license only covers the current major version).
  Pricing differs confusingly between App Store and web store. *(Pricing as of June 2026; MacPaw's canonical store page could not be loaded directly — treat figures as point-in-time.)*
- **The category is poisoned by scareware.** MacKeeper (court-documented scareware, $2M
  settlement, 13M-user breach), MacBooster (Macworld: "no surprise people think it's malware"),
  and fake-CleanMyMac malware lures mean the technical audience reflexively calls all cleaners
  "snake oil."
- **The best free tools are decaying.** Pearcleaner (the beloved ~13.5k-star OSS uninstaller) is
  **"on hold indefinitely"** and ships under Apache-2.0 **+ Commons Clause** (source-available,
  *not* OSI). AppCleaner hasn't shipped since Jan 2024 and isn't tested on macOS 26 Tahoe.
  BleachBit's Mac build is CLI-only and "experimental" since 2016. DaisyDisk/GrandPerspective
  visualize but don't clean. OnyX is powerful but expert-only and can brick a novice's system.
- **No single free tool unifies** safe app-uninstall + leftover/orphan removal + large-file
  finding + developer-cache cleaning under a real OSI license with a trustworthy, preview-first GUI.

**The opening:** be the well-executed, auditable, safe-by-default Mac-native cleaner that
BleachBit never shipped and that Pearcleaner/AppCleaner can no longer maintain.

> **Why this isn't "just another snake-oil cleaner":** A cleaner needs Full Disk Access — the
> same permission profile as malware. The *only* honest way to earn that grant is to let anyone
> read exactly what the tool deletes. Closed-source incumbents structurally cannot offer this.
> **Trust is the product.**

---

## 2. Target users & the wedge

| Segment | Need | Why us |
|---|---|---|
| **Primary v1.0 — the trust-seeking Mac user** | A safe uninstaller + leftover/orphan remover + large-file finder they can actually trust with Full Disk Access | Open-source + preview-before-delete + Trash-not-rm directly answers "is this safe?" Fills the Pearcleaner/AppCleaner vacuum. |
| **Differentiation bet v1.1 — developers** | Reclaim the 10s–100s of GB hidden in Xcode/sim/node_modules/Docker caches | No *free* tool unifies cross-toolchain dev-cache cleaning; this audience most wants to read the source before granting access. |

**Wedge sequencing (important — see §4):**
- **v1.0 differentiates on trust + the maintenance vacuum**, not on dev caches.
- **v1.1 makes the developer-cache cleaner the headline differentiator** — but this rests on an
  assumption that must be validated (see §11, Assumption A1).

> **One measured data point (this author's Mac, June 2026):** Xcode DerivedData 8.2 GB ·
> iOS DeviceSupport 5.7 GB · **CoreSimulator 25 GB** · ~/.npm 3.8 GB · node_modules (partial scan)
> ~6 GB+ · Homebrew cache 0.7 GB → **~50 GB reclaimable on a single developer machine**, with
> old simulator runtimes the largest offender. This corroborates — but does not prove — the
> "50–100 GB" market claim, which remains vendor/anecdote-sourced (A1).

---

## 3. Competitive landscape (condensed)

*App facts are point-in-time (June 2026). Sentiment is sourced from MacRumors/Macworld/HN/Apple
Community; the r/macapps and r/MacOS subreddits were not directly sampled (tool access blocked).*

| App | Model | Price | What it does | Key gap we exploit |
|---|---|---|---|---|
| **CleanMyMac** (MacPaw) | freemium/sub | ~$35–90+/yr; one-time covers current major only | All-in-one clean + uninstall + malware + monitor | Closed (can't audit); subscription resentment; "snake oil"; reported false positives |
| **DaisyDisk** | paid one-time | $9.99 | Beautiful sunburst disk visualizer | Analysis only — no cleaning, no uninstall |
| **Pearcleaner** | OSS (fair-code) | Free | Deep app uninstall + orphan scan (SwiftUI) | **On hold indefinitely**; Commons Clause ≠ OSI; no large-file finder |
| **AppCleaner** | free, closed | Free | Drag-drop uninstall + SmartDelete | Stale (Jan 2024); not Tahoe-tested; closed; uninstall-only |
| **OnyX** | free, closed | Free | Deep maintenance + cache clearing | Dangerous for novices; expert-only; per-OS download friction |
| **macOS built-in** | built-in | Free | Auto-manages safe caches/logs | Shallow, opaque; no leftovers/dev caches; no manual control |
| **BleachBit** (Mac) | OSS (GPL) | Free | The FOSS cleaner — but Mac build is CLI-only | No working GUI; not macOS-junk-aware |
| **DevCleaner / DeepClean** | OSS (Xcode-only) / paid $49 | Free / $49 | Xcode-only / 17+ dev envs (paid) | No free tool unifies cross-toolchain dev caches |
| **MacKeeper** | sub | — | (Reputational anchor) | Court-documented scareware — the pattern we must *not* resemble |

---

## 4. Goals & non-goals

### Goals
1. Be the **most trustworthy** cleaner on macOS — auditable, preview-first, reversible, zero network.
2. **Fill the abandonment vacuum** (Pearcleaner/AppCleaner) with a maintained, OSI-licensed,
   Tahoe-ready app-uninstaller + leftover/orphan remover.
3. Reclaim **genuinely meaningful space** (large files, app leftovers, dev caches) — and be
   honest that macOS already self-manages routine caches/logs.
4. Make the **developer-cache cleaner** a category-defining free feature (v1.1).

### Non-goals (deliberate — their absence is a trust signal)
- ❌ "Free up RAM" / memory boosters / speed meters — **debunked placebo**.
- ❌ Malware/antivirus scanning — scareware-adjacent; a real AV does it better.
- ❌ Mac App Store version — Full Disk Access is incompatible with the mandatory App Sandbox.
- ❌ Resident background daemon (SmartDelete-style) in v1 — launch-only maximizes trust.
- ❌ Permanent (non-Trash) deletion or any "X GB of junk found!" alarmist framing.
- ❌ Aggressive maintenance scripts / database rebuilds (OnyX-style) — too dangerous for a trust-first v1.

---

## 5. v1 scope & roadmap

> **Sequencing rationale (per advisor review):** the differentiator (dev caches) is **P1**, so
> the *first shippable release* must win on **trust + the maintenance vacuum**. Dev caches are the
> fast-follow that makes the product category-defining — gated on Assumption A1.

### v1.0 — "The cleaner you can trust" (P0 only)
The minimum that is **safe, shippable, and differentiated on trust**:

| # | Feature | Why it's safe |
|---|---|---|
| P0-1 | **App uninstaller** with deep leftover removal | User already chose to uninstall — inherently low-risk |
| P0-2 | **Orphan scan** for files left by already-deleted apps | Fills the exact Pearcleaner/AppCleaner gap |
| P0-3 | **Large-file & folder finder** with disk-usage visualization | Read-only analysis + manual move-to-Trash → zero data-loss risk |
| P0-4 | **Mandatory preview/dry-run** — full paths + per-item size before *any* delete | Nothing auto-deletes |
| P0-5 | **Move-to-Trash (reversible)** default + per-item Safe/Caution risk labels | No permanent delete in v1 |
| P0-6 | **Notarized, Developer-ID-signed DMG** + GitHub Releases; zero network/telemetry (verifiable in source) | Distribution integrity is existential |

### v1.1 — "The developer's cleaner" (P1, the differentiation bet — gated on A1)
| Feature | Notes |
|---|---|
| **Curated developer-cache cleaner** over *known safe paths*: Xcode DerivedData + old simulator runtimes + DeviceSupport, npm/yarn/pnpm, pip/Poetry, Gradle/Maven, Cargo, Homebrew cache | Rebuildable caches → safe; paths externalized into community manifests (see A-risk: path drift) |
| **Docker.raw / VM image reclaim** | Must run *actual compaction* — pruning images alone doesn't shrink the disk image |
| **Scriptable CLI** with feature parity | For the CI/cron + "I'll just script it" crowd |
| **Community-editable cleaning-rule manifests** | Distributes maintenance burden; survives macOS yearly path churn |
| **Homebrew Cask + Show HN + awesome-list** go-to-market | Cask has a notability gate — seed discovery via HN/Reddit first |

### v2+ — backlog (P2)
Recursive project-dir scan (`node_modules`/`.venv`/`target`/`build`, npkill-style) ·
"System Data"/"Other" explainer view · scheduled-scan *reminders* (notification only, never
auto-clean) · GitHub Sponsors/Open Collective to cover the $99/yr Apple fee.

---

## 6. UX & safety principles (non-negotiable)

1. **Preview before everything.** Every action shows full file paths + sizes; the user confirms.
2. **Trash, not `rm`.** Reversible by default. No permanent delete in v1.
3. **Risk labels.** Every item tagged Safe / Caution. Never touch SIP-protected paths.
4. **No fearmongering.** No "threats found," no fake counts, no alarm colors. State plainly what
   macOS already handles and only act where value is real.
5. **No resident daemon.** Launch-only. The app does nothing when closed.
6. **Conservative space reporting.** Because of purgeable space / APFS snapshots, avoid
   "X GB reclaimed!" claims that may not be immediately true — report cautiously.

---

## 7. Technical constraints (macOS realities)

- **Full Disk Access (TCC)** is required to scan `~/Library`, caches, and leftover support files
  — the same broad permission as malware. Auditable open source is the *only* way to earn it.
- **MAS is off-limits.** Full Disk Access is incompatible with the mandatory App Sandbox →
  distribute as a direct, notarized download (like Pearcleaner/AppCleaner).
- **Notarization is table stakes, not a differentiator.** Requires Apple Developer ID ($99/yr) +
  Hardened Runtime + notarization + stapling for Gatekeeper. (Malware lures can be notarized too.)
- **SIP** protects system files — off-limits, never targeted. Stay within user/app-owned data.
- **Purgeable space + APFS local snapshots** make "space freed" reporting unreliable — report
  conservatively.
- **Docker.raw / qcow2** images don't shrink after pruning without explicit reclaim/compaction.
- **Path drift:** DerivedData and package-manager caches are safe to delete (tools rebuild them)
  but live in *undocumented, per-version* folder structures → favor externalized,
  community-maintainable manifests over hardcoded paths.
- **Yearly macOS releases** move cache locations → ship a single auto-updating universal build to
  avoid OnyX-style per-OS download friction.

---

## 8. Differentiation & positioning

**Positioning line:** *"No subscription, no upsell, no telemetry, no scareware — and you can read
every line that touches your disk."*

Every incumbent weakness becomes our reason to exist:
- **Auditability** answers the Full-Disk-Access trust problem closed apps can't.
- **Behavioral safety** (preview, Trash, conservative defaults, no daemon) answers "it deleted my
  music library" and the breach memories.
- **Honest scoping** ("this only does the parts macOS won't") disarms the "snake oil" critique.
- **Maintained + OSI-licensed** beats the abandoned/fair-code free tools.
- **Free, unified dev-cache cleaning** (v1.1) undercuts the paywalled DeepClean/CodeCleaner.

---

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| **Category reputation = snake oil/scareware** (the technical audience pattern-matches instantly) | Lead with *safety + transparency*, not generic "open source." Preview-before-delete, Trash, zero network (auditable), honest "macOS already self-manages caches." Plain non-scammy name (avoid CleanMy*/Booster/Optimizer). Refuse every debunked feature. |
| **Data-loss liability** (one viral "it nuked my data" thread is fatal for a free tool) | Conservative defaults, mandatory dry-run, Trash-not-rm, Safe/Caution labels, never touch SIP paths, never auto-delete. |
| **Full Disk Access paradox + trojaned builds** (fake CleanMyMac/Pearcleaner mirrors exist) | Dev-ID-signed, notarized, checksum-verified builds from official channels only; explicit "not affiliated with / not impersonating" stance; open source. |
| **Single-maintainer abandonment** (the demonstrated failure mode — Pearcleaner, AppCleaner) | Externalize cleaning rules into community manifests; OSI license that permits forks; GitHub Sponsors/Open Collective from launch. |
| **"macOS already does this" critique** | Honest scoping — tell users what macOS handles, then only act on residual value (leftovers, orphans, dev caches, large files). |
| **No revenue vs perpetual notarization/churn cost** | $99/yr is the only hard cost → transparent Sponsors/Open Collective; OSS nonprofit may qualify for Apple's fee waiver. |
| **"Source-available but not OSI" trap** (Pearcleaner's Commons Clause) | Pick a precise OSI license up front (GPL-3.0 recommended — discourages closed adware reskins). |

---

## 10. Distribution & sustainability

- **Distribution:** notarized DMG via **GitHub Releases** + **Homebrew Cask** (seed discovery via
  Show HN / r/macapps / awesome-macos *before* the Cask notability gate clears).
- **Funding:** GitHub Sponsors / Open Collective covering the recurring $99/yr Apple Developer fee;
  never gate features behind payment. Consider an OSS-nonprofit vehicle (fee-waiver eligible,
  reduces bus-factor).
- **Trust signals:** reproducible builds, published checksums, zero-network claim verifiable in source.

---

## 11. Assumptions & open decisions

> **These are flagged, not settled.** The research synthesis explicitly labeled the items below as
> guesses or unsampled — the PRD carries them forward as such rather than laundering them into fact.

### Assumptions to validate
- **A1 (load-bearing — the wedge).** The "50–100 GB reclaimable in dev caches" figure and the size
  of the "devs who need this *and* won't just script it" niche are **vendor/anecdote-sourced**, now
  corroborated by exactly **one measured machine (~50 GB)**. *Before betting v1.1's positioning on
  this, validate with real data from ≥10–20 developer machines* (e.g. a tiny `du` script shared on
  HN/Reddit). If it doesn't hold broadly, keep dev caches as a feature, not the headline.
- **A2.** Pearcleaner's exact 2026 license/maintenance status and whether CleanMyMac still misses
  per-project `node_modules` are point-in-time — re-verify before launch messaging.
- **A3.** Pricing/sentiment facts are point-in-time and partially second-hand (named subreddits not
  directly sampled). Re-check before any public comparison claims.

### Open decisions — status as of 2026-06-11
| # | Decision | Options | Status |
|---|---|---|---|
| D1 | **Launch wedge narrative** | Developer-first vs consumer-safe-uninstaller-first | **RESOLVED**: consumer-safe core (v1.0) built; dev-cache headline (v1.1) still pending A1 |
| D2 | **License** | GPL-3.0 (anti-reskin copyleft) vs Apache-2.0/MIT (contributor-friendly) | **RESOLVED**: GPL-3.0, shipped in the repo since first push |
| D3 | **Name** | Must avoid CleanMy*/Booster/Optimizer patterns; must be discoverable | **RESOLVED** (2026-06-11): **Dustpan** — cleanest collision profile of 15 collision-checked candidates (no App Store app, no Homebrew cask/formula, no notable repo); metaphor matches the preview-then-Trash model. Remaining diligence: 2-min USPTO search before Cask submission (research was web/brew/gh-based, not a trademark query) |
| D4 | **Intel support** | Universal vs Apple-Silicon-only | **RESOLVED** (2026-06-11): Universal — Release builds verified fat (arm64 + x86_64), zero extra cost |
| D5 | **Background watcher** (ever?) | Defer vs never | **RESOLVED**: deferred past v1.0 (per D7, 2026-06-10) |
| D6 | **Stack** | Native SwiftUI vs cross-platform | **RESOLVED**: native SwiftUI — the entire app is built on it |

---

## 12. Success metrics (proposed)

- **Trust:** GitHub stars, "recommend without caveat" sentiment on HN/r/macapps, zero data-loss
  incidents.
- **Adoption:** Homebrew Cask installs, GitHub Release download counts.
- **Reclaim value:** median GB surfaced/reclaimed per run (reported honestly).
- **Health:** contributor count + manifest PRs (the anti-abandonment signal), Tahoe+ compatibility
  maintained within N weeks of each macOS release.

---

## Appendix — primary sources (selected)

- CleanMyMac review/pricing: macworld.com, apps.apple.com/us/app/cleanmymac/id1339170533, macpaw.com support
- "Snake oil" sentiment: forums.macrumors.com/threads/is-cleanmymac-actually-legit-or-snake-oil
- MacBooster "people think it's malware": macworld.com/article/2424786
- Fake-CleanMyMac malware: cybernews.com/security/fake-cleanmymac-website-delivers-macos-malware
- Pearcleaner (license + on-hold): github.com/alienator88/Pearcleaner
- BleachBit Mac (CLI-only): bleachbit.org/download/mac
- AppCleaner release notes: freemacsoft.net/appcleaner/releasenotes.html
- OnyX review: drbuho.com/review/onyx-mac-review
- macOS Optimize Storage: support.apple.com/guide/mac-help/optimize-storage-space-sysp4ee93ca4
- DeepClean (paid dev cleaner): deepclean.app
- GrandPerspective: grandperspectiv.sourceforge.net
- HN trust/UX discussion: news.ycombinator.com/item?id=46711394
- Real dev-cache measurement: this author's Mac, June 2026 (see §2)
