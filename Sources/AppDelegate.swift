import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenuBarController()
        self.menuBarController = controller

        // Opportunistic disk-quota sweep + optional auto-start. Both live
        // inside the controller so the policy stays in one place; we only
        // have to remember to call them at launch.
        controller.autoStartIfConfigured()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = menuBarController else { return .terminateNow }
        return controller.shouldTerminateNow() ? .terminateNow : .terminateLater
    }
}
