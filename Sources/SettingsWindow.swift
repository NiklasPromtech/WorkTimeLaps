import Cocoa
import SwiftUI
import UniformTypeIdentifiers

/// Observable model that backs the settings SwiftUI view. Reads and writes
/// straight through to the UserDefaults-backed stores — there's no separate
/// "apply" step, edits take effect as soon as you toggle.
///
/// `objectWillChange` is fired manually in each setter because the stores
/// are plain enums (not `@Published` property wrappers). This keeps the
/// single source of truth in the stores themselves rather than duplicating
/// state here.
@MainActor
final class SettingsViewModel: ObservableObject {

    private var observers: [NSObjectProtocol] = []

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .worktimelapsAPIKeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        })
    }

    // MARK: Recording

    var launchAtLogin: Bool {
        get { LoginItem.isEnabled }
        set {
            objectWillChange.send()
            LoginItem.setEnabled(newValue)
        }
    }

    var loginItemNeedsApproval: Bool { LoginItem.needsApproval }

    var autoStartRecording: Bool {
        get { Preferences.autoStartRecording }
        set {
            objectWillChange.send()
            Preferences.autoStartRecording = newValue
        }
    }

    var retentionHours: Int {
        get { RetentionSweeper.retentionHours }
        set {
            objectWillChange.send()
            RetentionSweeper.retentionHours = newValue
            // Apply right away so a shorter period frees space now.
            DiaryScheduler.shared.sweepExpiredVideo()
        }
    }

    // MARK: Work diary

    var cutoffHour: Int {
        get { WorkDay.cutoffHour }
        set {
            objectWillChange.send()
            WorkDay.cutoffHour = newValue
        }
    }

    var notificationTime: Date {
        get {
            var c = DateComponents()
            c.hour = Preferences.diaryNotificationHour
            c.minute = Preferences.diaryNotificationMinute
            return Calendar.current.date(from: c) ?? Date()
        }
        set {
            objectWillChange.send()
            let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            Preferences.diaryNotificationHour = c.hour ?? 9
            Preferences.diaryNotificationMinute = c.minute ?? 0
        }
    }

    var writeDiaryWithClaude: Bool {
        get { Preferences.writeDiaryWithClaude }
        set {
            objectWillChange.send()
            Preferences.writeDiaryWithClaude = newValue
        }
    }

    // MARK: API key

    var apiKeyFingerprint: String? { APIKeyStore.load().map(APIKeyStore.fingerprint) }

    func changeAPIKey() {
        APIKeyPrompt.run()
    }

    func removeAPIKey() {
        APIKeyStore.clear()
    }

    // MARK: Privacy filters

    var enabledPrivacy: Set<PrivacyTag> { PrivacyFilterStore.enabled }

    func setPrivacyEnabled(_ tag: PrivacyTag, _ on: Bool) {
        objectWillChange.send()
        PrivacyFilterStore.setEnabled(tag, on)
    }

    // MARK: Data folder

    var recordingsFolder: URL { TimeLapseRecorder.recordingsFolder }

    func revealRecordingsFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: recordingsFolder.path)
    }

    // MARK: Privacy rules (app + window-title blocklist)

    var privacyRules: [PrivacyRule] { PrivacyRulesStore.rules }

    func setRuleEnabled(_ rule: PrivacyRule, _ on: Bool) {
        objectWillChange.send()
        var copy = rule
        copy.enabled = on
        PrivacyRulesStore.update(copy)
    }

    func removeRule(id: UUID) {
        objectWillChange.send()
        PrivacyRulesStore.remove(id: id)
    }

    /// Opens NSOpenPanel rooted at /Applications and lets the user pick an
    /// .app bundle. We read its `CFBundleIdentifier` and name so the new
    /// rule has both the match string and a friendly label.
    func addAppRuleViaPicker() {
        let panel = NSOpenPanel()
        panel.title = "Pick an app to never send or record"
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bundle = Bundle(url: url)
        let bundleID = bundle?.bundleIdentifier
        let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent

        guard let id = bundleID, !id.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Couldn't read that app's bundle identifier."
            alert.informativeText = "Try a different app, or add a window-title rule instead."
            alert.runModal()
            return
        }

        objectWillChange.send()
        PrivacyRulesStore.add(PrivacyRule(kind: .app, pattern: id, label: displayName))
    }

    /// Adds a window-title (substring) rule. Empty input is ignored so an
    /// accidental empty save can't insert a rule that matches every frame.
    func addWindowTitleRule(pattern: String, label: String) {
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPattern.isEmpty else { return }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel = trimmedLabel.isEmpty ? trimmedPattern : trimmedLabel
        objectWillChange.send()
        PrivacyRulesStore.add(PrivacyRule(kind: .windowTitle, pattern: trimmedPattern, label: finalLabel))
    }
}

// MARK: - SwiftUI content view

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

                section(
                    title: "Recording",
                    subtitle: "WorkTimeLaps captures a screenshot every 10 seconds and pauses by itself while your screen is locked or your Mac is asleep."
                ) {
                    RecordingSettings(model: model)
                }

                section(
                    title: "Work diary",
                    subtitle: "Each work day ends at the time below, so late nights count toward the day they started. The diary is written after the day ends and announced the next morning."
                ) {
                    DiarySettings(model: model)
                }

                section(
                    title: "Anthropic API key",
                    subtitle: "Screenshots are labeled by Claude Haiku 4.5 (roughly half a cent each, about $10 for an 8-hour day). Diary entries are written by Claude Opus 5.5 from the day's text log (about $0.10 a day). The key is stored in your keychain."
                ) {
                    APIKeySettings(model: model)
                }

                section(
                    title: "Privacy filters",
                    subtitle: "Frames that Claude tags with an enabled category are replaced with a REDACTED placeholder in the video. The log keeps the category and a generic summary."
                ) {
                    ForEach(PrivacyTag.selectable, id: \.rawValue) { tag in
                        PrivacyToggleRow(model: model, tag: tag)
                    }
                }

                section(
                    title: "Apps and windows to block",
                    subtitle: "While one of these apps is in front, or the front window's title contains the text, screenshots are never sent to Claude and the video shows a REDACTED placeholder. The log records only a generic label."
                ) {
                    PrivacyRulesSection(model: model)
                }

                section(
                    title: "Data folder",
                    subtitle: model.recordingsFolder.path
                ) {
                    Button("Reveal in Finder") {
                        model.revealRecordingsFolder()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 580, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.title2).bold()
            Text("Changes apply immediately.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        subtitle: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Recording, diary and key sections

private struct RecordingSettings: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Open WorkTimeLaps at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.launchAtLogin = $0 }
            ))
            if model.loginItemNeedsApproval {
                HStack(spacing: 6) {
                    Text("Approve WorkTimeLaps under Login Items to finish setting this up.")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Button("Open Login Items") { LoginItem.openSystemSettings() }
                        .controlSize(.small)
                }
            }
            Toggle("Start recording when WorkTimeLaps opens", isOn: Binding(
                get: { model.autoStartRecording },
                set: { model.autoStartRecording = $0 }
            ))

            HStack(spacing: 12) {
                Text("Keep video for")
                Picker("Keep video for", selection: Binding(
                    get: { model.retentionHours },
                    set: { model.retentionHours = $0 }
                )) {
                    ForEach(RetentionSweeper.options, id: \.hours) { option in
                        Text(option.label).tag(option.hours)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
            }
            .padding(.top, 4)
            Text("Older videos and thumbnails are deleted automatically. The activity log, journal, diaries and highlights are text and are kept.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DiarySettings: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Day ends at")
                Picker("Day ends at", selection: Binding(
                    get: { model.cutoffHour },
                    set: { model.cutoffHour = $0 }
                )) {
                    ForEach(Array(WorkDay.allowedCutoffHours), id: \.self) { hour in
                        Text(Self.hourLabel(hour)).tag(hour)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            HStack(spacing: 12) {
                Text("Notify me at")
                DatePicker("Notify me at", selection: Binding(
                    get: { model.notificationTime },
                    set: { model.notificationTime = $0 }
                ), displayedComponents: .hourAndMinute)
                .labelsHidden()
            }
            Toggle("Have Claude write the entry", isOn: Binding(
                get: { model.writeDiaryWithClaude },
                set: { model.writeDiaryWithClaude = $0 }
            ))
            Text("When off, or without an API key, the diary is assembled on your Mac from the day's numbers and longest stretches.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func hourLabel(_ hour: Int) -> String {
        if hour == 0 { return "Midnight" }
        var c = DateComponents()
        c.hour = hour
        let f = DateFormatter()
        f.timeStyle = .short
        return Calendar.current.date(from: c).map { f.string(from: $0) } ?? "\(hour):00"
    }
}

private struct APIKeySettings: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        HStack(spacing: 10) {
            if let fingerprint = model.apiKeyFingerprint {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Key saved (\(fingerprint))")
                Spacer()
                Button("Change…") { model.changeAPIKey() }
                Button("Remove") { model.removeAPIKey() }
            } else {
                Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
                Text("No key — screenshots won't be labeled or checked for secrets")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Add Key…") { model.changeAPIKey() }
            }
        }
    }
}

// MARK: - Rules section

private struct PrivacyRulesSection: View {
    @ObservedObject var model: SettingsViewModel
    @State private var showWindowTitleSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.privacyRules) { rule in
                PrivacyRuleRow(model: model, rule: rule)
                Divider()
            }
            HStack(spacing: 8) {
                Button {
                    model.addAppRuleViaPicker()
                } label: {
                    Label("Add app…", systemImage: "app.badge.checkmark")
                }
                Button {
                    showWindowTitleSheet = true
                } label: {
                    Label("Add window title…", systemImage: "macwindow.badge.plus")
                }
                Spacer()
            }
        }
        .sheet(isPresented: $showWindowTitleSheet) {
            AddWindowTitleSheet(isPresented: $showWindowTitleSheet) { pattern, label in
                model.addWindowTitleRule(pattern: pattern, label: label)
            }
        }
    }
}

private struct PrivacyRuleRow: View {
    @ObservedObject var model: SettingsViewModel
    let rule: PrivacyRule

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.label).font(.body)
                HStack(spacing: 6) {
                    Text(rule.kind.display)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.gray.opacity(0.15)))
                    Text(rule.pattern)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Button {
                model.removeRule(id: rule.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this rule")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { rule.enabled },
            set: { model.setRuleEnabled(rule, $0) }
        )
    }
}

private struct AddWindowTitleSheet: View {
    @Binding var isPresented: Bool
    let onAdd: (_ pattern: String, _ label: String) -> Void

    @State private var pattern: String = ""
    @State private var label: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add window-title rule")
                .font(.headline)
            Text("Frames whose frontmost window title contains this text (case-insensitive) will be redacted. Example: \"Margins by Client\".")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Substring to match").font(.caption.weight(.semibold))
                TextField("e.g. Google Sheets", text: $pattern)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Label (optional)").font(.caption.weight(.semibold))
                TextField("Defaults to the substring", text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    onAdd(pattern, label)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct PrivacyToggleRow: View {
    @ObservedObject var model: SettingsViewModel
    let tag: PrivacyTag

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(tag.display).font(.body)
                Text(tag.blurb)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { model.enabledPrivacy.contains(tag) },
            set: { model.setPrivacyEnabled(tag, $0) }
        )
    }
}

// MARK: - Window controller

/// Lazy, singleton-y window holding the SwiftUI settings view.
///
/// Calling `show()` reopens the same window rather than spawning a new one,
/// so toggling "Settings…" rapidly from the menu bar doesn't pile up
/// ghost windows.
@MainActor
final class SettingsWindowController {

    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let model = SettingsViewModel()

    private init() {}

    func show() {
        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 640, height: 780))
        window.center()
        window.isReleasedWhenClosed = false   // so we can reopen without crashing

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
