import Cocoa

/// Owns the status-bar item, its menu, and the recorder.
///
/// Menu:
///   Recording · 3h 12m today          (status)
///   Coding — editing the capture loop (what the analyzer sees now)
///   ─────
///   Stop Recording / Start Recording
///   Pause ▸ 15 minutes · 1 hour · Until tomorrow   (or Resume Recording)
///   ─────
///   Latest Diary… · Journal… · Highlights…
///   ─────
///   Settings… · Quit
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    let recorder = TimeLapseRecorder()

    private let statusItem: NSStatusItem

    private var statusLine: NSMenuItem!
    private var detailLine: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var startStopItem: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var resumeItem: NSMenuItem!

    /// True while the MP4 is being finalized after Stop. Read by
    /// AppDelegate to decide whether to defer termination.
    private(set) var isFinalizing = false
    private var isStarting = false
    private var isTerminationPending = false

    /// Set when an automatic start failed for lack of Screen Recording
    /// permission; the menu then offers to fix it instead of nagging.
    private var needsScreenPermission = false

    private var observers: [NSObjectProtocol] = []

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        buildMenu()
        configureAnalyzer()
        JournalStore.shared.recorder = recorder

        recorder.onFrameAppended = { [weak self] in
            self?.refresh()
        }
        let names: [Notification.Name] = [
            .worktimelapsRecorderStateChanged,
            .worktimelapsSystemStateChanged,
            .worktimelapsAPIKeyChanged
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let isKeyChange = note.name == .worktimelapsAPIKeyChanged
                MainActor.assumeIsolated {
                    if isKeyChange { self?.configureAnalyzer() }
                    self?.refresh()
                }
            })
        }
        refresh()
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        statusLine = NSMenuItem(title: "Not recording", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        detailLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        detailLine.isEnabled = false
        detailLine.isHidden = true
        menu.addItem(detailLine)

        permissionItem = NSMenuItem(title: "Grant Screen Recording Access…", action: #selector(grantScreenAccess), keyEquivalent: "")
        permissionItem.target = self
        permissionItem.isHidden = true
        menu.addItem(permissionItem)

        menu.addItem(.separator())

        startStopItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "s")
        startStopItem.target = self
        menu.addItem(startStopItem)

        let pauseMenu = NSMenu()
        for (title, minutes) in [("For 15 Minutes", 15), ("For 1 Hour", 60), ("Until Tomorrow", -1)] {
            let item = NSMenuItem(title: title, action: #selector(pauseSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            pauseMenu.addItem(item)
        }
        pauseItem = NSMenuItem(title: "Pause Recording", action: nil, keyEquivalent: "")
        pauseItem.submenu = pauseMenu
        menu.addItem(pauseItem)

        resumeItem = NSMenuItem(title: "Resume Recording", action: #selector(resume), keyEquivalent: "")
        resumeItem.target = self
        menu.addItem(resumeItem)

        menu.addItem(.separator())

        let diaryItem = NSMenuItem(title: "Latest Diary…", action: #selector(openDiary), keyEquivalent: "d")
        diaryItem.target = self
        menu.addItem(diaryItem)

        let journalItem = NSMenuItem(title: "Journal…", action: #selector(openJournal), keyEquivalent: "j")
        journalItem.target = self
        menu.addItem(journalItem)

        let highlightsItem = NSMenuItem(title: "Highlights…", action: #selector(openHighlights), keyEquivalent: "h")
        highlightsItem.target = self
        menu.addItem(highlightsItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit WorkTimeLaps", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    // MARK: - State

    func configureAnalyzer() {
        if let key = APIKeyStore.load() {
            recorder.configureAnalyzer(FrameAnalyzer(apiKey: key))
        } else {
            recorder.configureAnalyzer(nil)
        }
    }

    /// Brings the icon and every menu line in line with the recorder.
    func refresh() {
        let pause = recorder.pauseReason
        let today = JournalStore.shared.cell(for: JournalStore.currentWorkDay).totalDuration
        let todayText = today >= 60 ? " · \(DiaryFormat.duration(today)) today" : ""

        if isStarting {
            statusLine.title = "Starting…"
        } else if isFinalizing {
            statusLine.title = "Finishing the video…"
        } else if !recorder.isRecording {
            statusLine.title = needsScreenPermission ? "Not recording — needs Screen Recording access" : "Not recording\(todayText)"
        } else if let pause {
            statusLine.title = pause.label
        } else {
            statusLine.title = "Recording\(todayText)"
        }

        if recorder.isRecording && pause == nil {
            if !recorder.isAnalyzerEnabled {
                detailLine.title = "Activity labels off — add an API key in Settings"
                detailLine.isHidden = false
            } else if let category = recorder.currentCategory {
                let summary = recorder.currentSummary
                detailLine.title = summary.isEmpty ? category.display : "\(category.display) — \(summary)"
                detailLine.isHidden = false
            } else {
                detailLine.isHidden = true
            }
        } else {
            detailLine.isHidden = true
        }

        permissionItem.isHidden = !needsScreenPermission || recorder.isRecording

        startStopItem.title = recorder.isRecording ? "Stop Recording" : "Start Recording"
        startStopItem.isEnabled = !isStarting && !isFinalizing

        let userPaused: Bool = {
            if case .user = pause { return true }
            return false
        }()
        pauseItem.isHidden = !recorder.isRecording || userPaused
        resumeItem.isHidden = !userPaused

        updateIcon(pause: pause)
    }

    // MARK: - Icon

    /// Grey / blue / orange / red: idle, steady, deep, peak.
    private func engagementColor(_ value: Int) -> NSColor {
        switch value {
        case ..<40:   return .secondaryLabelColor
        case 40..<70: return .systemBlue
        case 70..<90: return .systemOrange
        default:      return .systemRed
        }
    }

    private func updateIcon(pause: TimeLapseRecorder.PauseReason?) {
        guard let button = statusItem.button else { return }
        let symbol: String
        if !recorder.isRecording {
            symbol = "record.circle"
        } else if pause != nil {
            symbol = "pause.circle"
        } else {
            symbol = "record.circle.fill"
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "WorkTimeLaps") {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
        }

        if recorder.isRecording, pause == nil, let e = recorder.currentEngagement {
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .semibold)
            button.attributedTitle = NSAttributedString(string: String(format: " %d", e), attributes: [
                .font: font,
                .foregroundColor: engagementColor(e)
            ])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    // MARK: - Recording

    /// Starts recording at launch when the user has opted in.
    func startIfConfigured() {
        guard Preferences.hasCompletedOnboarding,
              Preferences.autoStartRecording,
              !recorder.isRecording else { return }
        startRecording(userInitiated: false)
    }

    func startRecording(userInitiated: Bool) {
        guard !recorder.isRecording, !isStarting else { return }
        isStarting = true
        refresh()

        Task { @MainActor in
            do {
                try await recorder.start()
                needsScreenPermission = false
            } catch let error as TimeLapseRecorder.RecorderError where error.isPermissionProblem {
                needsScreenPermission = true
                if userInitiated { presentPermissionAlert() }
            } catch {
                if userInitiated { presentError(error) }
                NSLog("WorkTimeLaps: couldn't start recording: \(error.localizedDescription)")
            }
            isStarting = false
            refresh()
        }
    }

    private func stopRecording() {
        isFinalizing = true
        refresh()

        Task { @MainActor in
            await recorder.stop()
            isFinalizing = false
            refresh()
            DiaryScheduler.shared.sweepExpiredVideo()
            if isTerminationPending {
                isTerminationPending = false
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
    }

    /// Called by AppDelegate when the app is asked to quit. Returns false if
    /// a stop has started and termination must wait for it.
    func shouldTerminateNow() -> Bool {
        if !recorder.isRecording && !isFinalizing {
            return true
        }
        isTerminationPending = true
        if recorder.isRecording {
            stopRecording()
        }
        return false
    }

    // MARK: - Actions

    @objc private func toggleRecording() {
        if recorder.isRecording {
            stopRecording()
        } else {
            startRecording(userInitiated: true)
        }
    }

    @objc private func pauseSelected(_ sender: NSMenuItem) {
        let until: Date
        if sender.tag < 0 {
            until = WorkDay.nextBoundary(after: Date())
        } else {
            until = Date().addingTimeInterval(TimeInterval(sender.tag * 60))
        }
        recorder.pause(until: until)
    }

    @objc private func resume() {
        recorder.pause(until: nil)
    }

    @objc private func grantScreenAccess() {
        ScreenAccess.request()
    }

    @objc private func openDiary() {
        DiaryWindowController.shared.showLatest()
    }

    @objc private func openJournal() {
        JournalWindowController.shared.show(recorder: recorder)
    }

    @objc private func openHighlights() {
        HighlightsWindowController.shared.show()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Alerts

    private func presentPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "WorkTimeLaps needs Screen Recording access"
        alert.informativeText = "Turn on WorkTimeLaps in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen WorkTimeLaps."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenAccess.request()
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "WorkTimeLaps ran into a problem"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Screen Recording permission helpers.
@MainActor
enum ScreenAccess {

    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for access (it prompts once), then opens the matching
    /// System Settings pane if access still isn't granted.
    static func request() {
        if CGRequestScreenCaptureAccess() { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
