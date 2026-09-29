import Foundation

/// A work day runs from `cutoffHour` on one calendar day to `cutoffHour` on
/// the next — 02:00 → 02:00 by default — so a session that runs past
/// midnight still belongs to the day it started on.
///
/// Everything that groups by day (the journal, the week grid, the diary,
/// session rotation) goes through here, so the boundary is defined in
/// exactly one place. Keys are Gregorian "yyyy-MM-dd" strings in the
/// user's current time zone regardless of the system calendar, matching
/// the file names under `_journal/`.
enum WorkDay {

    static let cutoffHourKey = "WorkTimeLaps.dayCutoffHour"
    static let defaultCutoffHour = 2

    /// Midnight through 6 AM. Any later and "yesterday" stops meaning what
    /// people expect when the diary arrives in the morning.
    static let allowedCutoffHours = 0...6

    static var cutoffHour: Int {
        get {
            guard let stored = UserDefaults.standard.object(forKey: cutoffHourKey) as? Int,
                  allowedCutoffHours.contains(stored) else { return defaultCutoffHour }
            return stored
        }
        set {
            let clamped = min(max(newValue, allowedCutoffHours.lowerBound), allowedCutoffHours.upperBound)
            UserDefaults.standard.set(clamped, forKey: cutoffHourKey)
        }
    }

    /// Gregorian calendar in the current time zone. Used for every key so a
    /// user with a non-Gregorian system calendar still gets stable file names.
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    /// Start of the calendar day that names the work day containing `date`.
    /// With a 2 AM cutoff, 01:30 on Wednesday belongs to Tuesday.
    static func day(containing date: Date, cutoffHour: Int = WorkDay.cutoffHour) -> Date {
        let cal = calendar
        let shifted = cal.date(byAdding: .hour, value: -cutoffHour, to: date) ?? date
        return cal.startOfDay(for: shifted)
    }

    /// Key of the work day containing `date`.
    static func key(for date: Date, cutoffHour: Int = WorkDay.cutoffHour) -> String {
        key(forDay: day(containing: date, cutoffHour: cutoffHour))
    }

    /// Key for a calendar day as-is (no cutoff shift).
    static func key(forDay day: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Start of the calendar day named by `key`, or nil for a malformed key.
    static func date(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]
        c.month = parts[1]
        c.day = parts[2]
        return calendar.date(from: c)
    }

    /// True for strings shaped like a day key ("2026-09-29").
    static func isKey(_ s: String) -> Bool {
        s.count == 10 && date(fromKey: s) != nil
    }

    /// [start, end) of the work day named by the calendar day `day`.
    static func interval(forDay day: Date, cutoffHour: Int = WorkDay.cutoffHour) -> DateInterval {
        let cal = calendar
        let startOfDay = cal.startOfDay(for: day)
        let nextDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay.addingTimeInterval(86_400)
        let start = cal.date(byAdding: .hour, value: cutoffHour, to: startOfDay) ?? startOfDay
        let end = cal.date(byAdding: .hour, value: cutoffHour, to: nextDay) ?? nextDay
        return DateInterval(start: start, end: max(end, start))
    }

    static func interval(forKey key: String, cutoffHour: Int = WorkDay.cutoffHour) -> DateInterval? {
        date(fromKey: key).map { interval(forDay: $0, cutoffHour: cutoffHour) }
    }

    /// The first work-day boundary strictly after `date`.
    static func nextBoundary(after date: Date, cutoffHour: Int = WorkDay.cutoffHour) -> Date {
        interval(forDay: day(containing: date, cutoffHour: cutoffHour), cutoffHour: cutoffHour).end
    }

    /// Key of the work day `offset` days away from the one named by `key`.
    static func key(_ key: String, offsetBy offset: Int) -> String? {
        guard let day = date(fromKey: key),
              let shifted = calendar.date(byAdding: .day, value: offset, to: day) else { return nil }
        return self.key(forDay: shifted)
    }
}
