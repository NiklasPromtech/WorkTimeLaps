import Cocoa
import UserNotifications

/// NSSecureTextField subclass that handles cmd-C / cmd-V / cmd-X / cmd-A
/// itself. Inside an NSAlert's modal event loop, the main-menu Edit actions
/// don't route to the accessory view, which is why cmd-V does nothing in a
/// stock NSSecureTextField-in-alert. Dispatching the action explicitly to
/// the responder chain fixes that.
final class PasteableSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers {
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a":
                if NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: self) { return true }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class MenuBarController: NSObject {

    private let statusItem: NSStatusItem
    private let recorder = TimeLapseRecorder()

    private var startStopItem: NSMenuItem!
    private var statusItemLabel: NSMenuItem!
    private var categoryItem: NSMenuItem!
    private var safetyStatusItem: NSMenuItem!
    private var apiKeyMenuItem: NSMenuItem!
    private var autoStartItem: NSMenuItem!

    /// True while we are still writing out the MP4 after the user pressed Stop.
    /// Read by AppDelegate to decide whether to defer terminate.
    private(set) var isFinalizing = false

    /// Set when applicationShouldTerminate has returned .terminateLater, so
    /// we remember to call NSApp.reply(...) once stop() completes.
    private var isTerminationPending = false

    // MARK: - Preferences

    private static let autoStartKey = "WorkTimeLaps.autoStartOnLaunch"

    static var isAutoStartEnabled: Bool {
        UserDefaults.standard.bool(forKey: autoStartKey)
    }

    static func setAutoStartEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoStartKey)
    }

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setIcon(recording: false, engagement: nil)
        buildMenu()
        requestNotificationAuthorizationIfPossible()
        configureAnalyzerFromStoredKey()

        // Refresh counters + rev meter each time a frame lands.
        recorder.onFrameAppended = { [weak self] in
            self?.refreshRecordingStatusLabel()
            self?.refreshEngagementIcon()
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        // We control enabled state ourselves (e.g. disable Start while finalizing).
        menu.autoenablesItems = false

        statusItemLabel = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusItemLabel.isEnabled = false
        menu.addItem(statusItemLabel)

        categoryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        categoryItem.isEnabled = false
        categoryItem.isHidden = true
        menu.addItem(categoryItem)

        safetyStatusItem = NSMenuItem(title: "Safety check: Off (no API key)", action: nil, keyEquivalent: "")
        safetyStatusItem.isEnabled = false
        menu.addItem(safetyStatusItem)

        menu.addItem(NSMenuItem.separator())

        startStopItem = NSMenuItem(title: "Start Time Lapse", action: #selector(toggleRecording), keyEquivalent: "s")
        startStopItem.target = self
        menu.addItem(startStopItem)

        menu.addItem(NSMenuItem.separator())

        apiKeyMenuItem = NSMenuItem(title: "Set Anthropic API Key…", action: #selector(setAPIKey), keyEquivalent: "")
        apiKeyMenuItem.target = self
        menu.addItem(apiKeyMenuItem)

        autoStartItem = NSMenuItem(title: "Auto-start on launch", action: #selector(toggleAutoStart), keyEquivalent: "")
        autoStartItem.toolTip = "When enabled, WorkTimeLaps begins recording automatically whenever it launches. Add the app to System Settings → General → Login Items to have it launch at login."
        autoStartItem.target = self
        autoStartItem.state = Self.isAutoStartEnabled ? .on : .off
        menu.addItem(autoStartItem)

        let highlightsItem = NSMenuItem(title: "Open Highlights…", action: #selector(openHighlights), keyEquivalent: "h")
        highlightsItem.target = self
        highlightsItem.toolTip = "Moments worth remembering — recognition captured from your work."
        menu.addItem(highlightsItem)

        let journalItem = NSMenuItem(title: "Open Journal…", action: #selector(openJournal), keyEquivalent: "j")
        journalItem.target = self
        menu.addItem(journalItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit WorkTimeLaps", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Analyzer state / status labels

    private func configureAnalyzerFromStoredKey() {
        if let key = APIKeyStore.load() {
            recorder.configureAnalyzer(FrameAnalyzer(apiKey: key))
        } else {
            recorder.configureAnalyzer(nil)
        }
        refreshSafetyLabel()
    }

    private func refreshSafetyLabel() {
        if let key = APIKeyStore.load() {
            let fp = APIKeyStore.fingerprint(of: key)
            safetyStatusItem.title = "Safety check: On  (key \(fp))"
            apiKeyMenuItem.title = "Change Anthropic API Key…"
        } else {
            safetyStatusItem.title = "Safety check: Off (no API key)"
            apiKeyMenuItem.title = "Set Anthropic API Key…"
        }
    }

    private func refreshRecordingStatusLabel() {
        guard recorder.isRecording else { return }
        let safe = recorder.safeFrameCount
        let redacted = recorder.redactedFrameCount
        if recorder.isSafetyCheckEnabled {
            statusItemLabel.title = "Recording… (\(safe) safe, \(redacted) redacted)"
        } else {
            let total = safe + redacted
            statusItemLabel.title = "Recording… (\(total) frames)"
        }

        // Secondary line: current activity + summary, if we have one.
        if let category = recorder.currentCategory {
            let suffix = recorder.currentSummary.isEmpty ? "" : " — \(recorder.currentSummary)"
            categoryItem.title = "\(category.display)\(suffix)"
            categoryItem.isHidden = false
        } else {
            categoryItem.isHidden = true
        }
    }

    private func refreshEngagementIcon() {
        setIcon(recording: recorder.isRecording, engagement: recorder.currentEngagement)
    }

    // MARK: - Icon (dot + optional rev-meter number)

    /// Tiered color for the engagement tachometer. Ranges chosen to map the
    /// feel we talked about: grey for idle/warmup, blue for steady, orange
    /// for deep work, red for peak. Uses semantic system colors so the look
    /// tracks Light/Dark mode and accessibility contrast.
    private func engagementColor(_ value: Int) -> NSColor {
        switch value {
        case ..<40:   return .secondaryLabelColor
        case 40..<70: return .systemBlue
        case 70..<90: return .systemOrange
        default:      return .systemRed
        }
    }

    private func setIcon(recording: Bool, engagement: Int?) {
        guard let button = statusItem.button else { return }
        let symbolName = recording ? "record.circle.fill" : "record.circle"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "WorkTimeLaps") {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
        } else {
            button.image = nil
            button.title = recording ? "●" : "○"
        }

        if recording, let e = engagement {
            let padded = String(format: " %d", e)
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small),
                                                       weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: engagementColor(e)
            ]
            button.attributedTitle = NSAttributedString(string: padded, attributes: attrs)
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    // MARK: - Actions

    @objc private func toggleRecording() {
        if recorder.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    /// Called by AppDelegate at launch. If the user turned on "Auto-start
    /// on launch" and their API key + permission work out, start the
    /// recorder without them having to open the menu.
    func autoStartIfConfigured() {
        // Run the retention sweep first — opportunistic, off-main-actor
        // wouldn't buy anything meaningful since it's already fast.
        RetentionSweeper.sweep()

        guard Self.isAutoStartEnabled else { return }
        guard !recorder.isRecording else { return }
        startRecording()
    }

    private func startRecording() {
        startStopItem.isEnabled = false
        statusItemLabel.title = "Starting…"

        Task { @MainActor in
            do {
                try await recorder.start()
                startStopItem.title = "Stop Time Lapse"
                refreshRecordingStatusLabel()
                if statusItemLabel.title == "Starting…" {
                    statusItemLabel.title = recorder.isSafetyCheckEnabled
                        ? "Recording… (safety check on)"
                        : "Recording…"
                }
                setIcon(recording: true, engagement: nil)
            } catch {
                statusItemLabel.title = "Idle"
                presentError(error)
            }
            startStopItem.isEnabled = true
        }
    }

    private func stopRecording() {
        isFinalizing = true
        statusItemLabel.title = "Finalizing video…"
        startStopItem.isEnabled = false
        setIcon(recording: false, engagement: nil)

        Task { @MainActor in
            defer {
                self.isFinalizing = false
                self.startStopItem.title = "Start Time Lapse"
                self.startStopItem.isEnabled = true
                self.categoryItem.isHidden = true
                // Run a sweep post-stop so a newly-written MP4 that pushes us
                // over quota gets pruned against older material promptly.
                RetentionSweeper.sweep()
                if self.isTerminationPending {
                    self.isTerminationPending = false
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
            let redacted = recorder.redactedFrameCount
            do {
                let url = try await recorder.stop()
                if redacted > 0 {
                    statusItemLabel.title = "Saved: \(url.lastPathComponent)  (\(redacted) redacted)"
                } else {
                    statusItemLabel.title = "Saved: \(url.lastPathComponent)"
                }
                notifyFinished(url: url, redacted: redacted)
            } catch {
                statusItemLabel.title = "Idle"
                presentError(error)
            }
        }
    }

    /// Called from AppDelegate when the app is asked to quit. Returns true if
    /// termination can happen immediately; returns false if we've started an
    /// async stop and the caller should return .terminateLater.
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

    @objc private func setAPIKey() {
        let alert = NSAlert()
        alert.messageText = "Anthropic API Key"
        alert.informativeText = """
        WorkTimeLaps sends each captured frame to Claude Haiku to check for visible secrets \
        (API keys, passwords, tokens) and to label what you're working on. Frames that look \
        risky are replaced with a black REDACTED placeholder before being written to the MP4.

        Paste your Anthropic API key below. It's stored locally in your preferences and \
        only sent to api.anthropic.com.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove Key")

        let field = PasteableSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "sk-ant-…"
        if let existing = APIKeyStore.load() {
            field.stringValue = existing
        }
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: // Save
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                APIKeyStore.clear()
            } else {
                APIKeyStore.save(trimmed)
            }
        case .alertThirdButtonReturn: // Remove
            APIKeyStore.clear()
        default: // Cancel
            return
        }
        configureAnalyzerFromStoredKey()
    }

    @objc private func toggleAutoStart() {
        let next = !Self.isAutoStartEnabled
        Self.setAutoStartEnabled(next)
        autoStartItem.state = next ? .on : .off
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openJournal() {
        JournalWindowController.shared.show(recorder: recorder)
    }

    @objc private func openHighlights() {
        HighlightsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Notifications & errors

    private func requestNotificationAuthorizationIfPossible() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyFinished(url: URL, redacted: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Time lapse saved"
        if redacted > 0 {
            let noun = redacted == 1 ? "frame" : "frames"
            content.body = "\(url.lastPathComponent) · \(redacted) \(noun) redacted"
        } else {
            content.body = url.lastPathComponent
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
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
