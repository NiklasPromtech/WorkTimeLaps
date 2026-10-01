import AppKit
import UserNotifications

/// Background upkeep while the app is running:
/// - writes each finished work day's diary (Claude when enabled, otherwise
///   a locally assembled entry), retrying failures with back-off;
/// - schedules the "your diary is ready" notification for the next morning;
/// - deletes expired video once an hour.
///
/// Runs on a one-minute timer and whenever the Mac wakes or a session ends,
/// so a laptop that was asleep at the 2 AM cutoff catches up on wake.
@MainActor
final class DiaryScheduler {

    static let shared = DiaryScheduler()

    /// How far back automatic diaries go. Older days can be written from the
    /// Diary window.
    private let automaticLookbackDays = 3
    private let maxAutomaticAttempts = 5

    private weak var recorder: TimeLapseRecorder?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastSweep: Date?
    private var isWorking = false

    /// Day keys whose diary is being written right now.
    private(set) var inProgress: Set<String> = []

    /// Why the most recent write for a day didn't produce a Claude entry
    /// (nil after a success).
    private(set) var lastErrors: [String: String] = [:]

    private init() {}

    func start(recorder: TimeLapseRecorder) {
        self.recorder = recorder
        guard timer == nil else { return }

        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { DiaryScheduler.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { DiaryScheduler.shared.tick() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .worktimelapsSessionCompleted, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { DiaryScheduler.shared.tick() }
        })

        tick()
    }

    func tick() {
        let now = Date()
        if lastSweep.map({ now.timeIntervalSince($0) >= 3600 }) ?? true {
            sweepExpiredVideo()
        }
        Task { await writePendingDiaries(now: now) }
    }

    /// Deletes video past the retention period, sparing the recording in
    /// progress.
    func sweepExpiredVideo() {
        var protected: Set<String> = []
        if let video = recorder?.currentVideoFilename {
            protected.insert(video)
            protected.insert((video as NSString).deletingPathExtension + ".thumb.jpg")
        }
        RetentionSweeper.sweep(protecting: protected)
        lastSweep = Date()
    }

    // MARK: - Automatic diaries

    /// Finished work days that should get a diary now: recorded, within the
    /// lookback window, and either without a diary yet or holding a local
    /// fallback that Claude can now replace.
    func pendingDays(now: Date = Date()) -> [String] {
        let todayKey = WorkDay.key(for: now)
        // A session still open for an earlier day means the rollover hasn't
        // happened yet (the Mac just woke up, say) — wait for it.
        let openDay = recorder?.currentSessionStartedAt.map { WorkDay.key(for: $0) }
        let claudeAvailable = Preferences.writeDiaryWithClaude && APIKeyStore.load() != nil

        var result: [String] = []
        for offset in 1...automaticLookbackDays {
            guard let key = WorkDay.key(todayKey, offsetBy: -offset), key != openDay,
                  let log = Journal.load(dayKey: key), !log.sessions.isEmpty else { continue }

            if let existing = DiaryStore.load(dayKey: key) {
                guard claudeAvailable, !existing.isWrittenByClaude else { continue }
            }
            // After a failure, retry with back-off, up to a limit.
            let status = DiaryStore.status(for: key)
            if status.lastError != nil {
                guard status.attempts < maxAutomaticAttempts else { continue }
                if let last = status.lastAttempt, now.timeIntervalSince(last) < backoff(afterAttempts: status.attempts) {
                    continue
                }
            }
            result.append(key)
        }
        return result.sorted()
    }

    /// 15 min, 30 min, 1 h, 2 h …
    private func backoff(afterAttempts attempts: Int) -> TimeInterval {
        15 * 60 * pow(2, Double(max(0, attempts - 1)))
    }

    private func writePendingDiaries(now: Date) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        for key in pendingDays(now: now) {
            await write(dayKey: key, notify: true)
        }
    }

    // MARK: - Writing

    /// Writes (or rewrites) the diary for `dayKey`. Claude writes it when
    /// enabled and a key is set. If that fails, an existing entry is kept, or
    /// a local one is saved so there's always something to read in the
    /// morning. Returns the entry now on disk.
    @discardableResult
    func write(dayKey: String, notify: Bool) async -> WorkDiary? {
        guard !inProgress.contains(dayKey) else { return nil }
        inProgress.insert(dayKey)
        lastErrors[dayKey] = nil
        DiaryStore.postUpdate()
        defer {
            inProgress.remove(dayKey)
            DiaryStore.postUpdate()
        }

        // The brief also plans the day it's read on — but only for the most
        // recent finished day, so rewriting an old entry never touches
        // today's follow-ups.
        let now = Date()
        let planDayKey = WorkDay.key(for: now)
        let plansToday = isLatestFinishedDay(dayKey, before: planDayKey)
        let includeFollowUps = Preferences.noticeFollowUpsAndMeetings

        // Reading two weeks of logs takes a moment; keep it off the main thread.
        let (loadedMaterial, plan) = await Task.detached(priority: .utility) { () -> (DayMaterial?, PlanContext?) in
            guard let material = DiaryComposer.material(for: dayKey) else { return (nil, nil) }
            let plan = plansToday
                ? DiaryComposer.planContext(for: material, planDayKey: planDayKey, includeFollowUps: includeFollowUps, now: now)
                : nil
            return (material, plan)
        }.value

        guard let material = loadedMaterial else {
            DiaryStore.updateStatus(for: dayKey) {
                $0.attempts += 1
                $0.lastAttempt = Date()
                $0.lastError = "No activity log was found for this day."
            }
            return nil
        }

        let diary: WorkDiary
        if Preferences.writeDiaryWithClaude, let apiKey = APIKeyStore.load() {
            DiaryStore.updateStatus(for: dayKey) {
                $0.attempts += 1
                $0.lastAttempt = Date()
            }
            do {
                let (draft, model) = try await DiaryWriter(apiKey: apiKey).write(material, plan: plan)
                var dayPlan: DayPlan?
                if let plan {
                    if plan.includesFollowUps, let updates = draft.followUps {
                        FollowUpStore.apply(updates)
                    }
                    let open = plan.includesFollowUps ? FollowUpStore.open : []
                    dayPlan = DayPlan(
                        dayKey: plan.planDayKey,
                        focus: draft.today?.focus ?? [],
                        meetings: draft.today?.meetings ?? [],
                        waitingOn: open.filter(\.isWaitingOnThem).map(DayPlan.FollowUpItem.init),
                        youOwe: open.filter { !$0.isWaitingOnThem }.map(DayPlan.FollowUpItem.init)
                    )
                }
                diary = WorkDiary(
                    dayKey: dayKey,
                    generatedAt: Date(),
                    model: model,
                    headline: draft.headline,
                    entry: draft.entry,
                    highlights: draft.highlights,
                    timeline: draft.timeline,
                    looseEnds: draft.looseEnds,
                    dayShape: draft.dayShape,
                    stats: material.stats,
                    recognition: DiaryComposer.quotes(from: material.recognitions),
                    note: nil,
                    today: dayPlan
                )
                DiaryStore.updateStatus(for: dayKey) { $0.lastError = nil }
            } catch {
                let message = error.localizedDescription
                AppLog.error("diary for \(dayKey) failed: \(message)")
                DiaryStore.updateStatus(for: dayKey) { $0.lastError = message }
                lastErrors[dayKey] = message
                if let existing = DiaryStore.load(dayKey: dayKey) {
                    return existing
                }
                diary = DiaryComposer.localDiary(from: material, note: "Claude couldn't write this entry (\(message)). It will try again.")
            }
        } else {
            let note = Preferences.writeDiaryWithClaude
                ? "Add your Anthropic API key in Settings and Claude will write these entries for you."
                : nil
            diary = DiaryComposer.localDiary(from: material, note: note)
        }

        do {
            try DiaryStore.save(diary)
        } catch {
            AppLog.error("couldn't save diary for \(dayKey): \(error.localizedDescription)")
            return nil
        }
        if notify {
            scheduleNotification(for: diary)
        }
        return diary
    }

    /// True when no recorded day lies between `dayKey` and the day in progress.
    private func isLatestFinishedDay(_ dayKey: String, before todayKey: String) -> Bool {
        guard dayKey < todayKey else { return false }
        return !Journal.loadAllDays().contains { $0.date > dayKey && $0.date < todayKey }
    }

    // MARK: - Notifications

    /// Announces the entry at the configured time (09:00 by default) on the
    /// morning after the work day, or right away if that time has passed.
    /// A rewrite before delivery replaces the pending notification; a day is
    /// never announced twice, and stale backfills aren't announced at all.
    func scheduleNotification(for diary: WorkDiary) {
        guard let interval = WorkDay.interval(forKey: diary.dayKey) else { return }
        let cal = Calendar.current
        let morning = cal.startOfDay(for: interval.end)
        guard var deliverAt = cal.date(bySettingHour: Preferences.diaryNotificationHour,
                                       minute: Preferences.diaryNotificationMinute,
                                       second: 0,
                                       of: morning) else { return }
        if deliverAt < interval.end {
            deliverAt = cal.date(byAdding: .day, value: 1, to: deliverAt) ?? deliverAt
        }

        let now = Date()
        if let previous = DiaryStore.status(for: diary.dayKey).notificationDeliverAt, previous <= now {
            return
        }
        if now.timeIntervalSince(deliverAt) > 18 * 3600 {
            return
        }

        let effectiveDeliver = max(deliverAt, now)
        let content = UNMutableNotificationContent()
        if let plan = diary.today, !plan.isEmpty {
            content.title = "Your daily brief is ready"
            var today: [String] = []
            if !plan.meetings.isEmpty {
                today.append(plan.meetings.count == 1 ? "1 meeting to prep" : "\(plan.meetings.count) meetings to prep")
            }
            let followUps = plan.waitingOn.count + plan.youOwe.count
            if followUps > 0 {
                today.append(followUps == 1 ? "1 follow-up" : "\(followUps) follow-ups")
            }
            content.body = "Yesterday: \(diary.headline)." + (today.isEmpty ? "" : " Today: " + today.joined(separator: ", ") + ".")
        } else {
            if cal.isDate(effectiveDeliver, inSameDayAs: morning) {
                content.title = "Yesterday's diary is ready"
            } else {
                let day = WorkDay.date(fromKey: diary.dayKey) ?? interval.start
                content.title = "Your diary for \(DiaryFormat.weekday(day)) is ready"
            }
            content.body = "\(diary.headline) · \(DiaryFormat.duration(diary.stats.activeSeconds)) worked"
        }
        content.sound = .default
        content.userInfo = ["dayKey": diary.dayKey]

        var trigger: UNNotificationTrigger?
        if deliverAt > now {
            let components = cal.dateComponents([.year, .month, .day, .hour, .minute], from: deliverAt)
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        }
        let request = UNNotificationRequest(identifier: "diary-\(diary.dayKey)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLog.error("couldn't schedule diary notification: \(error.localizedDescription)")
            }
        }
        DiaryStore.updateStatus(for: diary.dayKey) { $0.notificationDeliverAt = effectiveDeliver }
    }
}
