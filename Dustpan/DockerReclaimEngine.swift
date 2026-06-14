import Foundation

// v1.1 — container VM disk-image reclaim, REPORT-ONLY by design.
//
// Docker Desktop / colima / Podman each back their Linux VM with a single
// sparse disk image (Docker.raw, colima's diffdisk, an applehv .raw). These
// are the classic "I pruned everything and my disk is still full" trap: the
// PRD calls it out — pruning images frees space INSIDE the VM, but the host
// file stays allocated; macOS never auto-shrinks it. Reclaiming the gap needs
// the runtime's own compaction (TRIM + convert), which only the running VM can
// do safely. So Dustpan measures honestly and points at the blessed fix; it
// never offers to delete or compact a live VM disk (that would corrupt it).
//
// Foundation-only (no SwiftUI), like DiagnosticsEngine/SnapshotEngine —
// testable standalone via scripts + a main.swift of assertions.

/// One container runtime's VM disk image, measured two ways. `apparent` is the
/// logical size (the VM's max disk cap); `onDisk` is the allocated size — what
/// actually consumes the volume. The reclaimable slice lives in the gap between
/// onDisk and the VM's real usage, knowable only by the runtime itself, so we
/// report the honest pair and explain rather than inventing a "reclaim X" number.
struct VMDiskImage: Identifiable {
    let id: String
    let runtime: String        // "Docker Desktop", "colima", "Podman"
    let systemImage: String
    let url: URL
    let apparentBytes: Int64    // logical size (sparse cap)
    let onDiskBytes: Int64      // allocated blocks — the real consumption
    let denied: Bool            // exists but unreadable → show "—", never a fake 0
    let explanation: String
    let blessedFix: String

    /// On-disk consumption, or "—" when the image is present but unreadable.
    var onDiskText: String {
        denied ? "—" : ByteCountFormatter.string(fromByteCount: onDiskBytes, countStyle: .file)
    }
    var apparentText: String {
        ByteCountFormatter.string(fromByteCount: apparentBytes, countStyle: .file)
    }
    /// True when the file is meaningfully sparse — apparent notably exceeds the
    /// blocks actually allocated, the signature of post-prune dead space.
    var isSparse: Bool { !denied && apparentBytes > onDiskBytes + (256 << 20) } // >256 MB gap
}

enum DockerReclaimEngine {

    /// A known VM-disk location to probe. Externalized so the candidate list is
    /// readable and the per-runtime guidance lives next to its path.
    private struct Candidate {
        let runtime: String
        let systemImage: String
        let relativePaths: [String]   // tried in order; first existing wins
        let explanation: String
        let blessedFix: String
    }

    private static let candidates: [Candidate] = [
        Candidate(
            runtime: "Docker Desktop",
            systemImage: "shippingbox",
            relativePaths: [
                "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
                "Library/Containers/com.docker.docker/Data/vms/0/Docker.raw",
            ],
            explanation: "Docker keeps its whole Linux VM in this one sparse file. `docker system prune` frees space inside the VM, but the file stays allocated on your Mac — macOS never shrinks it on its own.",
            blessedFix: "After `docker system prune -af --volumes`, reclaim the host file via Docker Desktop → Settings → Resources → Advanced (or Troubleshoot → “Clean / Purge data”). Dustpan won't touch a live VM disk — deleting it loses every image and volume."),
        Candidate(
            runtime: "colima",
            systemImage: "cube",
            relativePaths: [".colima/_lima/colima/diffdisk"],
            explanation: "colima's Lima VM grows this disk as you build images and doesn't return the space to macOS when you delete them.",
            blessedFix: "`colima stop`, then `colima delete` and `colima start` recreates a lean disk (you'll re-pull images). For a non-destructive trim, run `fstrim -a` inside `colima ssh`."),
        Candidate(
            runtime: "Podman",
            systemImage: "cube.box",
            relativePaths: [
                ".local/share/containers/podman/machine/applehv/podman-machine-default-arm64.raw",
                ".local/share/containers/podman/machine/applehv/podman-machine-default-amd64.raw",
            ],
            explanation: "Podman's macOS machine stores its Linux VM in this image; pruning containers frees VM space but leaves the host file allocated.",
            blessedFix: "`podman machine stop` then `podman machine reset` recreates a fresh, compact machine. Dustpan reports only — it won't delete a machine image out from under Podman."),
    ]

    /// Report every container VM disk image found in its default location.
    /// Absent runtimes are simply not listed (a missing image is not a 0-byte
    /// image). Sorted by real on-disk consumption, biggest first.
    static func scan() -> [VMDiskImage] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var found: [VMDiskImage] = []
        for c in candidates {
            for rel in c.relativePaths {
                let url = home.appendingPathComponent(rel)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                found.append(report(at: url, candidate: c))
                break // first existing path for this runtime wins
            }
        }
        return found.sorted { $0.onDiskBytes > $1.onDiskBytes }
    }

    /// Measure one image. Logical size from `.fileSizeKey`, real consumption
    /// from `.totalFileAllocatedSizeKey`. Unreadable resource values ⇒ denied
    /// (rendered "—"), never a fabricated 0. Exposed for the harness.
    static func report(at url: URL, runtime: String, systemImage: String,
                       explanation: String, blessedFix: String) -> VMDiskImage {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let values = try? url.resourceValues(forKeys: keys)
        let apparent = Int64(values?.fileSize ?? 0)
        // Prefer totalFileAllocatedSize (includes metadata); fall back to
        // fileAllocatedSize; a nil for both on an existing file means denied.
        let allocated = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize
        let denied = (values == nil) || (allocated == nil && apparent == 0)
        return VMDiskImage(
            id: "vm-\(url.path)",
            runtime: runtime,
            systemImage: systemImage,
            url: url,
            apparentBytes: apparent,
            onDiskBytes: Int64(allocated ?? 0),
            denied: denied,
            explanation: explanation,
            blessedFix: blessedFix)
    }

    private static func report(at url: URL, candidate c: Candidate) -> VMDiskImage {
        report(at: url, runtime: c.runtime, systemImage: c.systemImage,
               explanation: c.explanation, blessedFix: c.blessedFix)
    }
}
