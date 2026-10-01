import Foundation

/// Age-based cleanup of the recordings folder.
///
/// Policy: videos (`TimeLapse_*.mp4`) and their thumbnails
/// (`TimeLapse_*.thumb.jpg`) older than the retention period — 48 hours by
/// default — are deleted. Everything that's text stays: session sidecars
/// (the frame log), the journal, diaries, highlights and the activity
/// vocabulary. That keeps disk use flat (a couple of GB at most) while the
/// long-term record keeps growing by a few hundred KB a day.
///
/// Runs at launch, after every session ends, hourly while the app is open,
/// and whenever the setting changes.
enum RetentionSweeper {

    static let retentionKey = "WorkTimeLaps.videoRetentionHours"
    static let defaultRetentionHours = 48

    static let options: [(label: String, hours: Int)] = [
        ("1 day", 24),
        ("2 days", 48),
        ("1 week", 24 * 7),
        ("30 days", 24 * 30)
    ]

    static var retentionHours: Int {
        get {
            guard let stored = UserDefaults.standard.object(forKey: retentionKey) as? Int, stored > 0 else {
                return defaultRetentionHours
            }
            return stored
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: retentionKey) }
    }

    static var currentLabel: String {
        options.first(where: { $0.hours == retentionHours })?.label ?? "\(retentionHours) hours"
    }

    /// Deletes expired videos and thumbnails. `protectedFiles` (file names
    /// of the recording in progress) are never touched. Returns the number
    /// of files deleted.
    @discardableResult
    static func sweep(now: Date = Date(), protecting protectedFiles: Set<String> = []) -> Int {
        let cutoff = now.addingTimeInterval(-Double(retentionHours) * 3600)
        let folder = TimeLapseRecorder.recordingsFolder
        let fm = FileManager.default

        // Top level only — `_journal/` is never visited.
        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return 0 }

        var deleted = 0
        for url in contents {
            let name = url.lastPathComponent
            guard name.hasPrefix("TimeLapse_"),
                  name.hasSuffix(".mp4") || name.hasSuffix(".thumb.jpg"),
                  !protectedFiles.contains(name) else { continue }

            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantFuture
            guard modified < cutoff else { continue }

            do {
                try fm.removeItem(at: url)
                deleted += 1
            } catch {
                AppLog.error("couldn't delete expired \(name): \(error.localizedDescription)")
            }
        }
        if deleted > 0 {
            AppLog.notice("deleted \(deleted) video file(s) older than \(retentionHours) h")
        }
        return deleted
    }
}
