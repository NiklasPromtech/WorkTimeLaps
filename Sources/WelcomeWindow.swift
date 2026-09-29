import AppKit
import SwiftUI
import UserNotifications

/// First-run setup. Explains what WorkTimeLaps records and what leaves the
/// Mac, takes the API key, checks Screen Recording access, and sets the
/// always-on defaults. Recording never starts before this is completed.
@MainActor
final class WelcomeModel: ObservableObject {
    @Published var apiKey = ""
    @Published var launchAtLogin = true
    @Published var autoStart = true
    @Published var hasScreenAccess = ScreenAccess.isGranted

    let savedKeyFingerprint = APIKeyStore.load().map(APIKeyStore.fingerprint)

    var onFinish: ((_ startRecording: Bool) -> Void)?

    func refreshScreenAccess() {
        hasScreenAccess = ScreenAccess.isGranted
    }

    func requestScreenAccess() {
        ScreenAccess.request()
        refreshScreenAccess()
    }

    func finish(startRecording: Bool) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            APIKeyStore.save(key)
        }
        Preferences.autoStartRecording = autoStart
        LoginItem.setEnabled(launchAtLogin)
        Preferences.hasCompletedOnboarding = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        onFinish?(startRecording)
    }
}

struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel

    var body: some View {
        ZStack {
            BackgroundCanvas()
            VStack(spacing: 0) {
                ScrollView {
                    content
                }
                // The actions stay visible however far the page scrolls.
                buttons
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(.regularMaterial)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                    }
            }
        }
        .frame(width: 640, height: 780)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshScreenAccess()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(symbol: "record.circle", title: "Records your day as a time-lapse",
                           text: "A screenshot every 10 seconds becomes a video you can scrub through. Recording pauses while your screen is locked.")
                FeatureRow(symbol: "book.closed", title: "Writes your work diary",
                           text: "After each work day ends, Claude writes a short entry about what you worked on. It's waiting for you at 9:00 the next morning.")
                FeatureRow(symbol: "star.bubble", title: "Keeps the receipts",
                           text: "Specific praise from colleagues and clients is saved to Highlights for your next review.")
            }
            privacyCard
            setupCard
        }
        .padding(32)
    }

    private var header: some View {
        HStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to WorkTimeLaps")
                    .font(.system(size: 28, weight: .bold, design: .serif))
                Text("A work diary that writes itself.")
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("What leaves your Mac", systemImage: "lock.shield")
                .font(.system(.headline, design: .rounded))
            PrivacyPoint("To label your activity, each screenshot is downscaled and sent to Anthropic's API (Claude Haiku 4.5) with your API key. Screenshots of blocked apps — Messages, Signal, WhatsApp and others you add — are never sent.")
            PrivacyPoint("Diary entries are written by Claude from the day's text log, never from screenshots.")
            PrivacyPoint("Everything else stays in ~/Movies/WorkTimeLaps. Video is deleted after 48 hours; the text log, diaries and highlights are kept.")
            PrivacyPoint("API usage costs roughly half a cent per screenshot — about $10 for an 8-hour day — plus about $0.10 per diary entry.")
            PrivacyPoint("Recording a work computer may be covered by your employer's policies. Check before you start.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16, padding: 18)
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Anthropic API key")
                        .font(.system(.headline, design: .rounded))
                    Spacer()
                    Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.callout)
                }
                SecureField(model.savedKeyFingerprint.map { "Using saved key \($0) — paste to replace" } ?? "sk-ant-…", text: $model.apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Without a key, WorkTimeLaps still records, but frames aren't labeled or checked for secrets, and the diary is assembled locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.5)

            HStack(spacing: 10) {
                Image(systemName: model.hasScreenAccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(model.hasScreenAccess ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Recording access")
                        .font(.system(.headline, design: .rounded))
                    Text(model.hasScreenAccess
                         ? "Granted."
                         : "Turn on WorkTimeLaps in System Settings, then quit and reopen the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !model.hasScreenAccess {
                    Button("Grant Access…") { model.requestScreenAccess() }
                }
            }

            Divider().opacity(0.5)

            Toggle("Open WorkTimeLaps at login", isOn: $model.launchAtLogin)
            Toggle("Start recording when WorkTimeLaps opens", isOn: $model.autoStart)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16, padding: 18)
    }

    private var buttons: some View {
        HStack {
            Button("Not Now") { model.finish(startRecording: false) }
                .controlSize(.large)
            Spacer()
            Button("Start Recording") { model.finish(startRecording: true) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.headline, design: .rounded))
                Text(text)
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PrivacyPoint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(Color.secondary.opacity(0.6))
                .frame(width: 5, height: 5)
                .offset(y: -2)
            Text(text)
                .font(.system(.callout, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
final class WelcomeWindowController {

    static let shared = WelcomeWindowController()

    private var window: NSWindow?
    private let model = WelcomeModel()

    private init() {}

    /// Shows the welcome window. `onFinish` is called with whether the user
    /// chose to start recording now.
    func show(onFinish: @escaping (_ startRecording: Bool) -> Void) {
        model.onFinish = { [weak self] start in
            self?.window?.close()
            onFinish(start)
        }
        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: WelcomeView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to WorkTimeLaps"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
