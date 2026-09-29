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
    init() {}

    // MARK: Privacy filters

    var enabledPrivacy: Set<PrivacyTag> { PrivacyFilterStore.enabled }

    func setPrivacyEnabled(_ tag: PrivacyTag, _ on: Bool) {
        objectWillChange.send()
        PrivacyFilterStore.setEnabled(tag, on)
    }

    // MARK: Storage quota

    /// Menu options in bytes. 0 = unlimited.
    static let quotaOptions: [(label: String, bytes: Int64)] = [
        ("5 GB",       5  * 1024 * 1024 * 1024),
        ("10 GB",      10 * 1024 * 1024 * 1024),
        ("25 GB",      25 * 1024 * 1024 * 1024),
        ("50 GB",      50 * 1024 * 1024 * 1024),
        ("Unlimited",  0)
    ]

    var quotaBytes: Int64 {
        get { RetentionSweeper.quotaBytes }
        set {
            objectWillChange.send()
            RetentionSweeper.setQuotaBytes(newValue)
            // Apply immediately so a shrunk cap prunes right away.
            RetentionSweeper.sweep()
        }
    }

    // MARK: Recordings folder

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
    /// .app bundle. We read its `CFBundleIdentifier` and `CFBundleName` so
    /// the new rule has both the technical match string and a friendly
    /// label for the UI.
    func addAppRuleViaPicker() {
        let panel = NSOpenPanel()
        panel.title = "Pick an app to never record from"
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
            // Couldn't read a bundle id (rare — corrupted bundle, or a
            // wrapper without an Info.plist). Surface a small alert so the
            // user knows nothing happened.
            let alert = NSAlert()
            alert.messageText = "Couldn't read that app's bundle identifier."
            alert.informativeText = "Try a different app, or add a window-title rule instead."
            alert.runModal()
            return
        }

        objectWillChange.send()
        PrivacyRulesStore.add(PrivacyRule(kind: .app, pattern: id, label: displayName))
    }

    /// Adds a window-title (substring) rule. Trimmed; empty input is
    /// silently ignored so an accidental empty save doesn't insert a
    /// universal-match rule that would redact every frame.
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
            VStack(alignment: .leading, spacing: 24) {
                header

                section(
                    title: "Privacy filters",
                    subtitle: "Frames matching an enabled tag have their image replaced with a REDACTED placeholder in the MP4. The sidecar log still records the category and a generic activity summary."
                ) {
                    ForEach(PrivacyTag.selectable, id: \.rawValue) { tag in
                        PrivacyToggleRow(model: model, tag: tag)
                    }
                }

                section(
                    title: "Apps and windows to redact",
                    subtitle: "Frames captured while one of these apps is in front, or while the frontmost window's title contains the matching text, are replaced with a REDACTED placeholder. The analyzer still runs so the category and engagement are still logged — only the image and specific summary are scrubbed."
                ) {
                    PrivacyRulesSection(model: model)
                }

                section(
                    title: "Storage cap",
                    subtitle: "Maximum total size of saved MP4s. Oldest recordings are pruned first when the cap is exceeded. The daily journal under _journal/ is never pruned."
                ) {
                    Picker("Maximum size", selection: quotaBinding) {
                        ForEach(SettingsViewModel.quotaOptions, id: \.bytes) { opt in
                            Text(opt.label).tag(opt.bytes)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                section(
                    title: "Recordings folder",
                    subtitle: model.recordingsFolder.path
                ) {
                    Button("Reveal in Finder") {
                        model.revealRecordingsFolder()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WorkTimeLaps")
                .font(.title2).bold()
            Text("Settings apply immediately — no restart needed.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Helpers

    private var quotaBinding: Binding<Int64> {
        Binding(
            get: { model.quotaBytes },
            set: { model.quotaBytes = $0 }
        )
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
        window.title = "WorkTimeLaps Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 720))
        window.center()
        window.isReleasedWhenClosed = false   // so we can reopen without crashing

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
