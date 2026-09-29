import Cocoa
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private(set) var menuBarController: MenuBarController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set before launch completes, so clicking a diary notification that
        // launched the app is still delivered here.
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        SystemStateMonitor.shared.start()

        // Close out anything a crash or forced restart left open, so it
        // counts in the journal and the diary.
        SessionRecovery.recoverUnfinishedSessions()

        let controller = MenuBarController()
        menuBarController = controller
        DiaryScheduler.shared.start(recorder: controller.recorder)

        if Preferences.hasCompletedOnboarding {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            controller.startIfConfigured()
        } else {
            WelcomeWindowController.shared.show { [weak controller] startNow in
                if startNow {
                    controller?.startRecording(userInitiated: true)
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = menuBarController else { return .terminateNow }
        return controller.shouldTerminateNow() ? .terminateNow : .terminateLater
    }

    /// Menu-bar apps have no visible main menu, but text fields still rely
    /// on it for ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z. A hidden Edit menu restores them.
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Notifications

    /// Clicking "Yesterday's diary is ready" opens that day's page.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let dayKey = response.notification.request.content.userInfo["dayKey"] as? String
        await MainActor.run {
            DiaryWindowController.shared.show(dayKey: dayKey)
        }
    }

    /// Show banners even when a WorkTimeLaps window is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
