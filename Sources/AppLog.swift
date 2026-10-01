import os

/// Diagnostics that reach the unified log, so they show up in Console.app and
/// in `log show --predicate 'subsystem == "com.niklas.worktimelaps"'`.
///
/// NSLog output from a menu-bar app doesn't reliably reach the unified log
/// on current macOS — which once hid the fact that every frame of a day was
/// being dropped.
enum AppLog {

    private static let logger = Logger(subsystem: "com.niklas.worktimelaps", category: "app")

    /// Something went wrong.
    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    /// Something worth knowing happened.
    static func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}
