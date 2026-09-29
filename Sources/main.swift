import Cocoa

// Top-level code runs on the main thread but, under Swift 6 strict
// concurrency, isn't automatically in the main-actor context. Since our
// AppDelegate and MenuBarController are @MainActor, we need to enter an
// isolated region explicitly. `assumeIsolated` crashes if we're somehow
// not on main — at process start, we always are.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
