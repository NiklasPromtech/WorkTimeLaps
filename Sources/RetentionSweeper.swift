import Foundation

/// Size-quota pruner for the recordings folder.
///
/// Policy: users set a cap in GB (default 10, or unlimited). When the total
/// size of MP4 files exceeds the cap, oldest-first MP4s are deleted along
/// with their matching sidecar (`<stem>.json`) and thumbnail
/// (`<stem>.thumb.jpg`) until we're back under quota. The day-journal
/// directory (`_journal/`) is *never* touched — that's the long-term memory
/// the future reviewer reads from.
///
/// This is a deliberately simple policy: oldest-first, MP4-weighted. We
/// don't try to be clever about keeping "interesting" days; disk space is
/// the only signal we've got at this layer, and the journal preserves the
/// gist of what was recorded even after the video is gone.
enum RetentionSweeper {

    /// UserDefaults key holding the quota, in bytes. Absent = default 10 GB.
    /// A stored value of 0 means "unlimited" (sweeper is a no-op).
    static let quotaKey = "WorkTimeLaps.retentionQuotaBytes"

    /// 10 GB default. Chosen to fit comfortably on most laptops while
    /// covering ~6 weeks of 8-hour days at 3 Mbps — roughly what the user
    /// asked for up front.
    static let defaultQuotaBytes: Int64 = 10 * 1024 * 1024 * 1024

    static var quotaBytes: Int64 {
        let stored = UserDefaults.standard.object(forKey: quotaKey) as? Int64
        return stored ?? defaultQuotaBytes
    }

    static func setQuotaBytes(_ bytes: Int64) {
        UserDefaults.standard.set(bytes, forKey: quotaKey)
    }

    /// Human-friendly label for the current setting. Used by the menu.
    static var currentLabel: String {
        let q = quotaBytes
        if q <= 0 { return "Unlimited" }
        let gb = Double(q) / Double(1024 * 1024 * 1024)
        if gb >= 1 {
            return String(format: "%.0f GB", gb)
        }
        let mb = Double(q) / Double(1024 * 1024)
        return String(format: "%.0f MB", mb)
    }

    /// Run the sweep. Safe to call from any thread; no UI interaction.
    /// Returns the number of MP4 files deleted (useful for logging / tests).
    @discardableResult
    static func sweep() -> Int {
        let quota = quotaBytes
        if quota <= 0 { return 0 }   // unlimited

        let folder = TimeLapseRecorder.recordingsFolder
        let fm = FileManager.default

        struct Entry {
            let url: URL
            let size: Int64
            let mtime: Date
        }

        // Only consider top-level MP4s. Sidecars/thumbnails follow along on
        // delete; the `_journal/` subdirectory is skipped entirely.
        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return 0 }

        var mp4s: [Entry] = []
        var totalMP4Bytes: Int64 = 0

        for url in contents where url.pathExtension.lowercased() == "mp4" {
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(vals?.fileSize ?? 0)
            let mtime = vals?.contentModificationDate ?? .distantPast
            mp4s.append(Entry(url: url, size: size, mtime: mtime))
            totalMP4Bytes += size
        }

        guard totalMP4Bytes > quota else { return 0 }

        // Oldest first.
        mp4s.sort { $0.mtime < $1.mtime }

        var deleted = 0
        var running = totalMP4Bytes

        for entry in mp4s {
            if running <= quota { break }
            let stem = entry.url.deletingPathExtension().lastPathComponent
            let sidecar = folder.appendingPathComponent("\(stem).json")
            let thumb = folder.appendingPathComponent("\(stem).thumb.jpg")

            do {
                try fm.removeItem(at: entry.url)
                running -= entry.size
                deleted += 1
                try? fm.removeItem(at: sidecar)
                try? fm.removeItem(at: thumb)
                NSLog("WorkTimeLaps: pruned \(entry.url.lastPathComponent) (\(entry.size) bytes)")
            } catch {
                NSLog("WorkTimeLaps: failed to prune \(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return deleted
    }
}
